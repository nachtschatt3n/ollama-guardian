# Local TTS fallback — architecture & voice-tuning findings

Notes from building and tuning the self-hosted German TTS (Qwen3-TTS via mlx-audio) that
Ollama Guardian supervises. It's the default voice for the OpenClaw morning briefing (when
ElevenLabs is over quota), Open WebUI read-aloud, and is wired for Home Assistant
announcements. Captured so the non-obvious parts don't have to be rediscovered.

Server: [`tts/tts_server.py`](../tts/tts_server.py) · model:
`mlx-community/Qwen3-TTS-12Hz-1.7B-VoiceDesign-8bit` · **MLX/Metal GPU** on Apple Silicon
(`mx.default_device() == gpu`).

---

## 1. Architecture decisions (and why)

- **Custom OpenAI-compatible shim instead of `mlx_audio.server`.** The bundled server loads
  the model in one thread and runs inference in a daemon worker thread; the Qwen3-TTS
  VoiceDesign path then crashes with `RuntimeError: There is no Stream(gpu, 0) in current
  thread`. Fix: a **single worker thread that both loads and runs** the model. (A plain
  `mx.eval` in a fresh thread works fine — the crash is specifically cross-thread
  model-load-vs-eval where VoiceDesign references a stream bound to the load thread.)
- **Lazy-load, then keep resident.** The model (~3 GB, ~6 GB resident incl. GPU buffers)
  co-resident with Ollama caused a Metal **OOM** (`kIOGPUCommandBufferCallbackErrorOutOfMemory`)
  only during *concurrent load spikes* (Ollama warming `gemma4:26b@131k` while TTS loaded).
  So the model loads on the **first request** (after Ollama's boot warm-up — no collision),
  cold-load is **~1.1 s**, and then it **stays resident** (`TTS_IDLE_UNLOAD_S=0`) for
  low-latency interactive use. Set `TTS_IDLE_UNLOAD_S>0` to unload after N idle seconds if
  you'd rather free the GPU between uses.
- **Output format.** `audio_io` writes WAV natively and uses **ffmpeg** for mp3/opus/flac.
  ffmpeg + rubberband are installed on the host; the server honors `response_format`
  (Open WebUI/HA request **mp3**; the OpenClaw pod requests WAV and converts to OGG/Opus
  itself). Note: ffmpeg/rubberband are bare-name shell-outs, so the server prepends
  `/opt/homebrew/bin` to `PATH` (GUI-launched processes get a minimal PATH).

## 2. Model variant matters

Qwen3-TTS ships three variants; they are NOT interchangeable:

| Variant | Voice selection | German result |
|---|---|---|
| `Base` | **none** — `spk_id` empty; `--voice` silently ignored → random default voice | speaks German, unstable timbre |
| `CustomVoice` | 9 named speakers (serena, vivian, ryan, …) | works, but speakers are Chinese/English timbres → **foreign-accented** German |
| **`VoiceDesign`** | voice generated from a free-text `instruct` description | **best** — can ask for native Hochdeutsch directly |

→ Use **VoiceDesign**, pass `language="german"` (without it the model uses English G2P and
mispronounces German). **bf16 was tested and rejected**: at the same seed it maps to a
*different*, American-accented German voice — the 8-bit is the keeper.

## 3. Tuning method — objective acoustic matching

Goal: match an ElevenLabs reference clip. Done by **measuring acoustic features** of the
reference and tuning toward them (you can't A/B audio without ears; this makes it
reproducible and quantitative — see `analyze.py` in the mlx-tts dir):

| Metric | Perceptual meaning | Reference target |
|---|---|---|
| median F0 | pitch height / age | **179.6 Hz** |
| F0 std | intonation range (not flat / not sing-songy) | ~46 |
| duration / s-per-char | speaking pace | 54 s (sample) |
| spectral centroid | brightness / "strong" vs warm | **~2740 Hz** |
| voiced runs/s | articulation crispness (good smear detector) | ~1.7 |

## 4. Key model findings

- **Instruct wording is the main timbre lever** — "deep, low, warm chest voice" lowered
  pitch markedly vs "lower-pitched … not high-pitched".
- **Seed strongly selects timbre/pitch** (swept ~126–256 Hz median). Pick by measurement.
- **Temperature is CHAOTIC, not a smooth dial** — `0.70 → 0.72` flipped median F0 178 → 231.
  So `(seed, temperature)` is a *joint* voice selector — grid-search and pin both. **Never
  set temperature ≤ ~0.5**: the model degenerates into minutes of looping audio.
- **Deterministic across process/model reloads** for fixed `(seed, temp, instruct, text)` —
  verified byte-identical (md5) across two processes, so reloads don't drift the voice.
- **Final pinned voice:** seed **99**, temperature **0.7**, the deep-low-chest instruct →
  median **~178 Hz** (ref 179.6), down from ~237 Hz on the first attempt.

## 5. Post-processing: brightness softening + pace

The raw 8-bit voice is **too bright** (centroid ~3350 Hz vs ref ~2740) — reads as "strong"
pronunciation — and a bit **slow** (76 s vs 54 s; the opening greeting/date is slower than
the body). Two CPU post-processing steps on the synthesized audio fix both:

- **Soften** — a −4 dB high-shelf (RBJ biquad) above ~3.5 kHz brings the centroid down near
  the reference. (`TTS_SOFTEN_DB` / `TTS_SOFTEN_FC`; 0 = off.)
- **Speed up with RubberBand** — `TTS_SPEED=1.15` (76 s → 66 s). **Use RubberBand, not WSOLA
  or a phase vocoder**: the phase vocoder smears consonants into an "underwater/spacey"
  artifact (voiced runs/s collapse 1.37 → 1.00); WSOLA is better but still audibly smeared;
  **RubberBand (formant-preserving, `--fine`) is clean**. There's also an optional intro
  ramp (`TTS_INTRO_SPEED`, off by default) to speed the slow opening harder than the body.

## 6. Speed / latency (MLX-accelerated)

GPU (MLX/Metal) inference, **RTF ≈ 0.3 (≈3× faster than real-time)**. Cold model load
~1.1 s; resident by default so interactive callers skip it. Measured (warm):

| Utterance | chars | synth |
|---|---|---|
| short HA announcement | 27 | ~0.7 s |
| medium alert | 64 | ~1.5 s |
| longer (weather+calendar) | 90 | ~2.3 s |
| full morning briefing | ~3066 | ~63 s (→ fits the 180 s send_voice budget) |

Plus ~0.3–0.5 s for softening/RubberBand/mp3. So HA announcements land in **~1–3 s**.

## 7. Text handling

- **Strip SSML.** Qwen3-TTS has no SSML; ElevenLabs `<break time="0.7s"/>` tags were read
  aloud literally. The server strips `<…>` tags; punctuation drives prosody/pauses.

## 8. Configuration reference (env vars)

The Guardian launches the server and injects `TTS_MODEL`, `TTS_SEED`, `TTS_LANG`,
`TTS_INSTRUCT` from its `TTSConfig` — **these override the file defaults**, so keep the
Guardian `TTSConfig.default` (in `Models.swift`) in sync with the server file. The rest fall
back to the file defaults:

| Env | Default | Purpose |
|---|---|---|
| `TTS_MODEL` | Qwen3-TTS-…-VoiceDesign-8bit | model id (8-bit; bf16 rejected) |
| `TTS_SEED` | 99 | voice selector (pin with temperature) |
| `TTS_TEMPERATURE` | 0.7 | voice selector; keep ≥ ~0.65 |
| `TTS_INSTRUCT` | deep-low-chest German newsreader | timbre |
| `TTS_LANG` | german | spoken language |
| `TTS_SOFTEN_DB` / `TTS_SOFTEN_FC` | −4 / 3500 | high-shelf brightness cut; 0 dB = off |
| `TTS_SPEED` | 1.15 | body time-stretch (RubberBand); 1.0 = off |
| `TTS_INTRO_SPEED` / `TTS_INTRO_SECONDS` | 1.15 / 15 | stronger intro speed-up; == TTS_SPEED disables |
| `TTS_IDLE_UNLOAD_S` | 0 | 0 = keep resident (low-latency, HA); >0 = unload after N idle s |
| `TTS_TOP_K` / `TTS_TOP_P` / `TTS_REPETITION_PENALTY` | 50 / 1.0 / 1.05 | sampling |

All are also per-request overridable on `POST /v1/audio/speech` (`speed`, `temperature`,
`seed`, …). Runtime deps: `ffmpeg`, `rubberband` (brew) + `pyrubberband`, `soundfile`,
`scipy`, `mlx-audio`, `uvicorn`, `fastapi`, `webrtcvad-wheels`.

## 9. How to re-tune the voice

1. Capture a reference clip + the exact text; measure its features (`analyze.py`).
2. Grid-search `(seed × temperature)` with candidate `instruct` wordings on a short excerpt;
   score by distance to the reference's median F0 / std / pace.
3. Validate the winner on the **full** text (long text can degenerate where a short excerpt
   didn't — always check duration for runaway looping).
4. Confirm cross-process determinism (synthesize twice in separate processes; md5 must match).
5. Pin `seed`/`temperature`/`instruct` in **both** `tts/tts_server.py` and the Guardian
   `TTSConfig.default`; adjust `TTS_SOFTEN_DB` for brightness and `TTS_SPEED` for pace.
