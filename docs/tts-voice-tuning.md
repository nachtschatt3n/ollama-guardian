# Local TTS fallback — architecture & voice-tuning findings

Notes from building and tuning the self-hosted German TTS fallback (Qwen3-TTS via
mlx-audio) that Ollama Guardian supervises and OpenClaw uses when ElevenLabs is over
quota. Captured so the non-obvious parts don't have to be rediscovered.

Server: [`tts/tts_server.py`](../tts/tts_server.py) · runtime model:
`mlx-community/Qwen3-TTS-12Hz-1.7B-VoiceDesign-8bit` on Apple Silicon (MLX).

---

## 1. Architecture decisions (and why)

- **Custom OpenAI-compatible shim instead of `mlx_audio.server`.** The bundled server
  loads the model in one thread and runs inference in a daemon worker thread; the
  Qwen3-TTS VoiceDesign path then crashes with `RuntimeError: There is no Stream(gpu, 0)
  in current thread`. Fix: a **single worker thread that both loads and runs** the model.
  (A plain `mx.eval` in a fresh thread works fine — the crash is specifically cross-thread
  model-load-vs-eval where the VoiceDesign path references a stream bound to the load
  thread.)
- **Lazy-load + idle-unload.** The model (~4 GB) co-resident with Ollama's models caused a
  Metal **OOM** (`Insufficient Memory … kIOGPUCommandBufferCallbackErrorOutOfMemory`)
  during concurrent load spikes (Ollama warming `gemma4:26b@131k` while TTS loaded). For a
  rarely-used fallback, load the model on first request and release it after
  `TTS_IDLE_UNLOAD_S` so the GPU stays free for Ollama while idle. First-request latency is
  ~10 s (model load) + synth, well within the briefing's 180 s budget.
- **WAV @ 24000 only.** mlx-audio writes WAV natively; mp3/opus/flac need **ffmpeg**, which
  the mini does not have. The OpenClaw pod already converts WAV→OGG/Opus via its own
  ffmpeg for Telegram `sendVoice`, so the server returns WAV and lets the consumer convert.
  (If a consumer needs mp3/opus directly — e.g. Home Assistant's OpenAI TTS — install
  ffmpeg on the mini.)

## 2. Model variant matters

Qwen3-TTS ships three variants; they are NOT interchangeable:

| Variant | Voice selection | German result |
|---|---|---|
| `Base` | **none** — `spk_id` is empty; `--voice` is silently ignored → random default voice | speaks German, random/unstable timbre |
| `CustomVoice` | 9 named speakers (serena, vivian, ryan, aiden, …) | works, but the speakers are Chinese/English timbres → **foreign-accented** German |
| **`VoiceDesign`** | voice generated from a free-text `instruct` description | **best** — can ask for native Hochdeutsch directly |

→ Use **VoiceDesign**. Pass `language="german"` (lang_code `de`); without it the model
defaults to English G2P and mispronounces German.

## 3. Tuning method — objective acoustic matching

The goal was to match an ElevenLabs reference clip. Tuning was done by **measuring
acoustic features** of the reference and tuning the local voice toward them (you cannot
A/B audio without ears; this makes it reproducible and quantitative). Metrics that map to
perception (see `analyze.py` in the mlx-tts dir):

| Metric | Perceptual meaning | Reference target |
|---|---|---|
| median F0 | pitch height / age ("lower-pitched mature") | **179.6 Hz** |
| F0 std, p10–p90 | intonation range ("not flat" vs "not sing-songy") | std ~46 |
| duration / s-per-char | speaking pace | 54 s (sample) |
| spectral centroid | brightness / warmth | ~2740 Hz |
| voiced runs/s | articulation crispness (good smear detector) | ~1.7 |

## 4. Key model findings

- **Instruct wording is the main timbre lever.** "A mature German woman … with a **deep,
  low, warm chest voice**" measurably lowered pitch vs the original "lower-pitched … not
  high-pitched" phrasing.
- **Seed strongly selects timbre/pitch.** Sweeping seeds with a fixed instruct moved median
  F0 across ~126–256 Hz. Pick by measurement, then pin.
- **Temperature is CHAOTIC, not a smooth dial.** A `0.70 → 0.72` change flipped median F0
  from 178 → 231 Hz. So `(seed, temperature)` is a *joint* voice selector — grid-search the
  pair and pin both together. **Never set temperature ≤ ~0.5**: the model degenerates into
  minutes of looping audio (e.g. 281 s for a short clip).
- **Output is deterministic across process/model reloads** for a fixed
  `(seed, temperature, instruct, text)` — verified byte-identical (md5) in two separate
  processes. So idle-unload + reload does **not** drift the voice day-to-day.
- **Final pinned voice:** seed **99**, temperature **0.7**, the deep-low-chest instruct →
  median **178.6 Hz** (ref 179.6), down from ~237 Hz on the first attempt.

## 5. Pace — the model has no speed control

VoiceDesign exposes no speed/pitch arg, and synthesis runs slow (sample: 76 s vs ref 54 s),
with the **opening greeting + spelled-out date noticeably slower than the body** (voiced
runs/s ~1.0 in the first 15 s vs ~1.6 in the body; the reference *starts* brisk at ~2.0).
No `(seed, temp)` combo gave low pitch **and** fast pace. So pace is fixed in
post-processing:

- **Use WSOLA, not a phase vocoder.** `librosa.effects.time_stretch` (phase vocoder) smears
  consonants into an "underwater/spacey" artifact — objectively visible as voiced runs/s
  collapsing from 1.37 → 1.00 and RMS dropping. **WSOLA** (overlap-add, `audiotsm`)
  preserves articulation (runs/s 1.26–1.39) and loudness. Both preserve pitch.
- **Ramp the intro.** Uniform speed-up keeps the intro proportionally slow. Speeding the
  first ~15 s harder (`1.3×`) and the body gently (`1.15×`), with a short crossfade at the
  seam, evens it out. Defaults: `TTS_SPEED=1.15`, `TTS_INTRO_SPEED=1.3`,
  `TTS_INTRO_SECONDS=15`.

## 6. Text handling

- **Strip SSML.** Qwen3-TTS has no SSML; ElevenLabs `<break time="0.7s"/>` tags were being
  read aloud literally. The server strips `<…>` tags and lets punctuation drive prosody.

## 7. Configuration reference (env vars)

The Guardian launches the server and injects `TTS_MODEL`, `TTS_SEED`, `TTS_LANG`,
`TTS_INSTRUCT` from its `TTSConfig` — **these override the file defaults**, so keep the
Guardian `TTSConfig.default` (in `Models.swift`) in sync with the server file. The rest fall
back to the file defaults:

| Env | Default | Purpose |
|---|---|---|
| `TTS_MODEL` | Qwen3-TTS-…-VoiceDesign-8bit | model id |
| `TTS_SEED` | 99 | voice selector (pin with temperature) |
| `TTS_TEMPERATURE` | 0.7 | voice selector; keep ≥ 0.65 |
| `TTS_INSTRUCT` | deep-low-chest German newsreader | timbre |
| `TTS_LANG` | german | spoken language |
| `TTS_SPEED` | 1.15 | body time-stretch (WSOLA); 1.0 = off |
| `TTS_INTRO_SPEED` | 1.3 | first-`TTS_INTRO_SECONDS` time-stretch |
| `TTS_INTRO_SECONDS` | 15 | length of the "intro" region |
| `TTS_IDLE_UNLOAD_S` | 0 | 0 = keep model resident (low-latency, e.g. Home Assistant); >0 = unload after N idle seconds |
| `TTS_TOP_K` / `TTS_TOP_P` / `TTS_REPETITION_PENALTY` | 50 / 1.0 / 1.05 | sampling |

All are also per-request overridable on `POST /v1/audio/speech` (`speed`, `temperature`,
`seed`, …).

## 8. How to re-tune the voice

1. Capture a reference clip + the exact text; measure its features (`analyze.py`).
2. Grid-search `(seed × temperature)` with candidate `instruct` wordings on a short
   excerpt; score each by distance to the reference's median F0 / std / pace.
3. Validate the winner on the **full** text (long text can degenerate where a short excerpt
   did not — always check duration for runaway looping).
4. Confirm cross-process determinism (synthesize twice in separate processes; md5 must
   match).
5. Pin `seed`/`temperature`/`instruct` in **both** `tts/tts_server.py` and the Guardian
   `TTSConfig.default`; adjust `TTS_SPEED`/`TTS_INTRO_SPEED` for pace.
