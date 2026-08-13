# Ollama model setup (Mac mini)

The local LLM setup this Guardian manages: **Ollama 0.32.9** on the Mac mini (Apple M4 Pro,
48 GB unified memory), serving `192.168.30.111:11434` to the home-lab cluster. A separate
mlx-audio Qwen3-TTS server runs at `:8000` (see [tts-voice-tuning.md](tts-voice-tuning.md)).
Last reviewed 2026-08-13.

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

## Log rotation
The Guardian rotates `ollama.log` and `tts.log` at **64 MB, keeping 3 generations** (Settings →
Server & Paths). It uses copy-truncate, not rename: the child processes hold their log
descriptor for weeks, so a rename would leave them writing to the renamed inode. Added
2026-08-13 after `ollama.log` reached 713 MB unbounded.

## Rollback / operational notes
- **Engine rollback**: `/Applications/Ollama-0.31.1.app` (and `-0.30.8`, `-0.24.0`) backups
  exist — quit the Guardian, swap `/Applications/Ollama.app`, relaunch.
- The Guardian is the single server on `:11434`; its watchdog restarts `ollama serve` on the
  current binary if it's stopped.
- Cluster apps reference the model by tag `gemma4:26b` (unchanged) — no app changes were
  needed for any of this.
