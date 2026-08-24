# Ollama model setup (Mac mini)

The local LLM setup this Guardian manages: **Ollama 0.32.15** on the Mac mini (Apple M4 Pro,
48 GB unified memory), serving `192.168.30.111:11434` to the home-lab cluster. A separate
mlx-audio Qwen3-TTS server runs at `:8000` (see [tts-voice-tuning.md](tts-voice-tuning.md)).
Last reviewed 2026-08-24.

## Model roster (3 models, all kept warm)

| Model | Role | Format | Context | Vision | Speed | Consumers |
|---|---|---|---|---|---|---|
| **`gemma4:26b`** | big / quality / **vision** — the everything-model | GGUF Q4_K_M | **131k** | ✅ | 57 tok/s | ~15 cluster apps (chat, agents, OCR, vision) |
| **`gemma4:e2b-mlx`** | small / edge / fast text | MLX nvfp4 (5.2B) | default | ❌ | 163–193 tok/s | ha-ai-harness `EDGE_MODEL`, openclaw catalog |
| **`nomic-embed-text:latest`** | embeddings | — | — | — | 39 ms/doc | RAG: anythingllm, affine, nextcloud |

Plus **`qwen3-tts`** (mlx-audio VoiceDesign, `:8000`) for TTS — OpenClaw voice notes, Open
WebUI read-aloud, HA announcements.

**Warm set** (Guardian `TTSConfig`/warm config, `keep_alive=-1`): all three Ollama models +
the TTS model are pre-warmed and resident (~24 GB of models). The models fit comfortably; how
much of the remaining 48 GB is free depends on what else the box is doing (agent processes and
the ARAG Android emulator are the usual pressure, not Ollama).

## Runtime tuning
- **KV cache `q8_0` + flash attention** on the GGUF path (`gemma4:26b`, `nomic`) — halves
  K-cache memory, fits 131k comfortably. (These are llama.cpp flags; they do **not** apply
  to the MLX-engine `e2b-mlx`.)
- `OLLAMA_NUM_PARALLEL=1`, `OLLAMA_MAX_LOADED_MODELS=3`, `OLLAMA_KEEP_ALIVE=-1` (Guardian
  injects these when it launches `ollama serve`).

## Why GGUF (not MLX) for the big model — evaluated & decided 2026-07-05

Migrating the big model to `gemma4:26b-mlx` was evaluated and **rejected**:
- **The MLX Gemma 4 builds are text-only in Ollama.** Verified with a discriminative image
  test on `gemma4:26b-mlx`: a red image → "White", a green image → "Red" (wrong *and*
  uncorrelated), and `ollama show` lists only `completion, tools, thinking` — no vision.
  The ollama.com/library/gemma4 "Text, Image" badge is the **family** badge, not the actual
  per-tag MLX capability.
- The big model **must keep vision** (paperless-gpt OCR, frigate object descriptions,
  home-assistant camera vision).
- **MTP** (multi-token prediction, "powered by MLX", automatic on 0.31.1) gave only **~17%**
  (prose) to **~32%** (code) on the 26B **MoE at single-user batch-1** — not the ~90%
  coding-agent headline (MoE expert-activation caps the draft benefit at batch-1). Not worth
  losing vision.

→ Keep vision-capable **`gemma4:26b` GGUF** as the everything-model; use **`e2b-mlx`** as the
fast text-only edge model. (`qwen3-vl` VLMs are *not* installed — vision runs on the GGUF
26b.)

## Context: full 131k (kept)
`gemma4:26b` runs at its default `num_ctx 131072`. Reducing to 68k was tried and **reverted**:
gemma4 uses **sliding-window attention**, so KV barely scales past the window
(18.0 GB @ 68k ≈ 17.7 GB @ 131k) — 68k gave no meaningful memory saving. `num_ctx` is a baked
model parameter that overrides `OLLAMA_CONTEXT_LENGTH`; a fresh re-pull restores 131072
automatically.

## Storage
Roster trimmed to the 3 models above (~23 GB) on 2026-07-05; removed 14 unused models
(`gemma4:26b-mlx` test pull, GGUF `e2b`/`e4b`/`31b`, all `qwen3*` and `qwen3-vl*`,
`gpt-oss:20b`, `text-embedding-3-small`, `allenporter/assist-llm`), freeing **~122 GB**.

## Engine: 0.31.1 → 0.32.9 (2026-08-13)
Taken for three changes that hit this setup directly:
- **0.32.1** fixed a recurrent **MLX model cache leak** that grew memory across requests — the
  exact shape of problem a `Forever`-pinned `e2b-mlx` accumulates over multi-week uptimes.
- **0.32.1** improved **Gemma 4 tool calling** and multi-turn tool-response continuations.
- **0.32.6** made `/v1/chat/completions` streaming match the OpenAI wire format (`role` only on
  the first chunk, `finish_reason` on its own chunk, usage separate) and made truncated
  responses report `finish_reason: "length"` instead of `"tool_calls"` — most cluster apps talk
  to the OpenAI-compatible endpoint.

Deliberately **not** on 0.32.10: it flips the `repeat_penalty` default from 1.1 to 1.0 (off) for
models that don't set one, which can surface repetition.

Verified after the swap: discriminative image test (red→Red, green→Green), a tool call with
correct name/args, the streaming wire format above, 768-dim embeddings, and all three models
back to `Forever`.

## Measured performance (0.32.9, 2026-08-13)
> Re-measured on 0.32.15 on 2026-08-24: `gemma4:26b` unchanged at 57.2 tok/s generation and
> 670 tok/s prefill, so the figures below still hold.

Measured on the live host, so numbers carry some noise from real cluster traffic. Prefill was
measured with a unique nonce at the head of each prompt — without it Ollama's prompt cache
returns a near-zero prompt-eval duration and nonsensical throughput.

| | `gemma4:26b` (GGUF) | `gemma4:e2b-mlx` (MLX) |
|---|---|---|
| Generation, prose | 56.5 tok/s | 162.8 tok/s |
| Generation, code | 56.8 tok/s | 193.2 tok/s |
| Prefill @ 1.8k tokens | 691 tok/s (2.7 s) | 3412 tok/s (0.5 s) |
| Prefill @ 6k tokens | 656 tok/s (9.2 s) | 3495 tok/s (1.7 s) |
| Prefill @ 20k tokens | 501 tok/s (40.8 s) | 3162 tok/s (6.5 s) |

- Vision (`26b`, 768×768 image + 64 tokens out): **2.9 s** end to end.
- Embeddings (`nomic`): **38.6 ms** single, **19.0 ms/doc** batched at 32 — batch where possible.
- **The 26b is unchanged from the 0.31.1 baseline (~56 tok/s)**, as expected: the 0.32.x MLX and
  MTP work does not touch the llama.cpp/GGUF path. The engine update was taken for correctness
  and the MLX leak fix, not for GGUF speed.
- The e2b-mlx figure is well above the ~120 tok/s this doc previously carried, but that older
  number was not measured the same way — treat the gap as indicative, not as a measured 0.32.9
  gain.
- **Long prompts are the 26b's weak spot**: 20k tokens of input cost ~41 s before the first
  token, and prefill throughput decays with length while the MLX model's stays flat. Route
  bulk/long-context text work to `e2b-mlx` where quality allows.

## Engine: 0.32.9 → 0.32.15 (2026-08-24)
Taken because `qwen3.8` requires ≥ 0.32.12 (the pull is refused outright below that), and
0.32.13–0.32.15 add three follow-up fixes for that model — stopping at .12 would have walked
into them. Two changes help regardless of any model swap:
- **Model metadata is cached between requests**, roughly halving time-to-first-token
  (Ollama's benchmark: 995 ms → 524 ms).
- **Fixed chat/generate wedging after a mid-stream parser error** — precisely the stuck-runtime
  class the Guardian's watchdog exists for.

Accepted risk: 0.32.10 flipped the `repeat_penalty` default from 1.1 to 1.0 (off) for models
that don't set one, and `gemma4:26b` doesn't. Watch for repetition; a Modelfile
`PARAMETER repeat_penalty 1.1` restores the old behaviour if it appears.

Backup at `/Applications/Ollama-0.32.9.app`.

## Candidate evaluations — is anything better than `gemma4:26b`?

### Method
A model can replace the everything-model here only if it clears four bars, so all candidates
run the same suite (`compare.py` in the session scratchpad):
1. **vision** — discriminative red/green image test. A single image can be passed by guessing;
   both must be right. Registry `capabilities` metadata is **not** evidence (see the Gemma 4
   MLX case above, where it advertises vision the engine does not implement).
2. **tools** — openclaw / hermes / librechat depend on it.
3. **structured JSON** — sure-worker's real workload: 5 transactions in, merchant + category
   out, counting empty fields rather than just "was it parseable".
4. **speed** — generation *and* prefill. Prefill turned out to be the discriminator.

Three traps, each of which produced a false negative before being understood — a model that
looks broken here is usually the harness:
- **`thinking` is on by default** and consumes the `num_predict` budget before any answer
  appears. Pass `"think": false`.
- **A tight `num_predict` still truncates**: some models (Muse Glimmer) emit a preamble even
  with thinking disabled. 24 tokens reported "no vision"; 300 tokens answered correctly. Give
  the vision probe room.
- **Bare `format: "json"` constrains output to a *single object***, so the model answers only
  the first of five transactions — a plausible source of the nulls driving sure's retries. Use
  a real JSON schema.

An empty response with `done_reason: "length"` is the signature of all three.

### qwen3.8:27b-mlx — rejected 2026-08-24

| | `gemma4:26b` (MoE) | `qwen3.8:27b-mlx` (dense) |
|---|---|---|
| Vision (discriminative) | ✅ | ✅ |
| Tool calling | ✅ | ✅ |
| JSON, 5 transactions | 5/5, 0 empty, 1.6 s | 5/5, 0 empty, 3.3 s |
| **Generation** | **57.2 tok/s** | **28.0 tok/s** |
| **Prefill** | **670 tok/s** | **118 tok/s** |

Time to first token, by prompt size:

| Prompt | `gemma4:26b` | `qwen3.8:27b-mlx` |
|---|---|---|
| 1.8k tokens | 2.7 s | 14.8 s |
| 6k tokens | 9.2 s | 49.2 s |
| 20k tokens | 40.8 s | **173.6 s** |

Qualitatively equal — it fails purely on speed, and **prefill (5.7×) hurts far more than
generation (2.0×)**, because that is what this host's traffic is made of.

Worth recording: **vision genuinely works in Qwen 3.8's MLX build.** So Ollama's MLX engine is
capable of vision; it simply omits it for the Gemma 4 conversions. That closes the question
left open in July.

### muse-glimmer:30b-mlx — rejected 2026-08-24
Meta's 30B agent model, the most promising candidate on paper: vision + tools + thinking, and
Ollama explicitly advertises "state-of-the-art performance on Apple Silicon" for it with DFlash
support. It is nonetheless **dense** (52 layers, no experts), and that decides it.

| | `gemma4:26b` (MoE) | `qwen3.8:27b-mlx` (dense) | `muse-glimmer:30b-mlx` (dense) |
|---|---|---|---|
| Vision (discriminative) | ✅ | ✅ | ✅ |
| Tool calling | ✅ | ✅ | ✅ |
| JSON, 5 transactions | 5/5, 0 empty, **1.5 s** | 5/5, 0 empty, 3.3 s | 5/5, 0 empty, **9.8 s** |
| **Generation** | **59.4 tok/s** | 28.0 tok/s | **22.3 tok/s** |
| **Prefill** | **635 tok/s** | 118 tok/s | **123 tok/s** |
| Size on disk | 17.7 GB | 18.2 GB | 21.2 GB |

All three are capability-equivalent; the two MLX models lose purely on speed. Muse Glimmer is
the slowest of the three despite being the one explicitly tuned for Apple Silicon — DFlash did
not close the dense gap. Its 9.8 s on the JSON task is **6.5× gemma's**, on exactly the
workload that dominates this host.

### The deciding factor is MoE, not MLX
`gemma4:26b` is a 26B-A4B: 128 experts, ~4B active. It reads ~3 GB of weights per token where
a dense 27B reads all ~17 GB, and on an M4 Pro (~273 GB/s) generation is bandwidth-bound. That
is why a GGUF MoE beats an MLX dense model on the supposedly better-optimised path.

Two dense candidates now confirm it independently, and the pattern is consistent: both land at
~120 tok/s prefill against gemma's ~650, regardless of MLX tuning or DFlash. **Treat "is it
MoE?" as the first question about any future candidate** — check `num_experts` in the model's
HuggingFace `config.json` before spending 20 GB of disk on a pull.

### Library survey (2026-08-24)
All 20 vision-capable models in the Ollama library, checked for an MLX variant that fits:

| Family | MLX tags | Verdict |
|---|---|---|
| `qwen3.5` | 0.8b–35b | **no `tools`** capability |
| `qwen3.6` | 27b, 35b | **no `tools`**, and dense |
| `gemma4` | e2b–31b | **vision absent in the engine** (proven for e2b/26b; 31b untested) |
| `qwen3.8` | 27b | dense — measured above |
| `muse-glimmer` | 30b | dense (52 layers, no experts) — measured, slowest of the three |
| all others | none | no MLX build at all |

Everything else is out on size (`mistral-medium-3.5` 80 GB, kimi-k2/k3 larger), too small for
the quality bar (`qwen3-vl` 6 GB, `minicpm-v4.6` 1.6 GB), or a specialist (`glm-ocr` 2.2 GB,
`medgemma`).

→ **`gemma4:26b` stays.** It is currently the only model in the library combining vision,
tools and MoE at a size that fits this box.

Idea parked: `glm-ocr` (2.2 GB) as a *complement* rather than a replacement, to take OCR load
off the 26b if paperless-gpt ever becomes the bottleneck.

## Log rotation
The Guardian rotates `ollama.log` and `tts.log` at **64 MB, keeping 3 generations** (Settings →
Server & Paths). It uses copy-truncate, not rename: the child processes hold their log
descriptor for weeks, so a rename would leave them writing to the renamed inode. Added
2026-08-13 after `ollama.log` reached 713 MB unbounded.

## Orphaned model runners (found 2026-08-24)
`ollama serve` spawns one **runner child per loaded model** (`ollama runner --mlx-engine …` for
MLX, `llama-server` for GGUF), each on an ephemeral localhost port. When the server is killed
rather than shut down gracefully, those children survive, are reparented to launchd, and keep
their model resident. **`ollama ps` cannot see them** — it reports only the current server's own
runners — so the memory is invisible to every normal check.

The 0.31.1→0.32.9 restart on 2026-08-13 left two behind. Eleven days later one was still holding
**6.2 GB** for a `gemma4:e2b-mlx` nothing was talking to. Effect, measured before and after
killing it:

| | with orphan | after reaping |
|---|---|---|
| `gemma4:e2b-mlx` generation | 72.8 tok/s | **148.6 tok/s** |
| `gemma4:26b` generation | 56.5 tok/s | 57.6 tok/s (unaffected) |
| Swap in use | 26.3 GB | 19.6 GB |

The GGUF model was never affected — only the MLX one, which is the memory-pressure-sensitive
path. The Guardian now terminates runner children on stop and sweeps orphans on start
(`RunnerReaper`), reporting `ollama_guardian_orphaned_runners_reaped`. **A non-zero value there
means a stop path failed to clean up.**

To check by hand: `ps -Ao pid=,ppid=,command= | grep -E "Ollama.app.*(runner|llama-server)"` —
anything with ppid 1 is an orphan.

## Contention, not slowness
Also measured 2026-08-24: `gemma4:26b` reported **88.8 s total duration for 2.6 s of actual
work — 97 % internal queue wait**. With `OLLAMA_NUM_PARALLEL=1` the model serves strictly one
request at a time, and three cluster clients (192.168.55.11/.12/.13, ~90–115 req/h) were
saturating it. If an app feels slow against the 26b, check the queue before suspecting the
model: raw generation was 56.5 tok/s, exactly its baseline.

## Rollback / operational notes
- **Engine rollback**: `/Applications/Ollama-0.31.1.app` (and `-0.30.8`, `-0.24.0`) backups
  exist — quit the Guardian, swap `/Applications/Ollama.app`, relaunch.
- The Guardian is the single server on `:11434`; its watchdog restarts `ollama serve` on the
  current binary if it's stopped.
- Cluster apps reference the model by tag `gemma4:26b` (unchanged) — no app changes were
  needed for any of this.
