# Ollama model setup (Mac mini)

The local LLM setup this Guardian manages: **Ollama 0.31.1** on the Mac mini (Apple M4 Pro,
48 GB unified memory), serving `192.168.30.111:11434` to the home-lab cluster. A separate
mlx-audio Qwen3-TTS server runs at `:8000` (see [tts-voice-tuning.md](tts-voice-tuning.md)).
Last reviewed 2026-07-05.

## Model roster (3 models, all kept warm)

| Model | Role | Format | Context | Vision | Speed | Consumers |
|---|---|---|---|---|---|---|
| **`gemma4:26b`** | big / quality / **vision** — the everything-model | GGUF Q4_K_M | **131k** | ✅ | ~56 tok/s | ~15 cluster apps (chat, agents, OCR, vision) |
| **`gemma4:e2b-mlx`** | small / edge / fast text | MLX nvfp4 (5.2B) | default | ❌ | ~120 tok/s | ha-ai-harness `EDGE_MODEL`, openclaw catalog |
| **`nomic-embed-text:latest`** | embeddings | — | — | — | — | RAG: anythingllm, affine, nextcloud |

Plus **`qwen3-tts`** (mlx-audio VoiceDesign, `:8000`) for TTS — OpenClaw voice notes, Open
WebUI read-aloud, HA announcements.

**Warm set** (Guardian `TTSConfig`/warm config, `keep_alive=-1`): all three Ollama models +
the TTS model are pre-warmed and resident (~24.5 GB of models; ~46% memory free).

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

## Rollback / operational notes
- **Engine rollback**: `/Applications/Ollama-0.30.8.app` backup exists (revert via the
  0.24→0.30 runbook if ever needed).
- The Guardian is the single server on `:11434`; its watchdog restarts `ollama serve` on the
  current binary if it's stopped.
- Cluster apps reference the model by tag `gemma4:26b` (unchanged) — no app changes were
  needed for any of this.
