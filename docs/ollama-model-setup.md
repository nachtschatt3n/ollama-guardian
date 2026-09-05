# Ollama model setup (Mac mini)

The local LLM setup this Guardian manages: **Ollama 0.33.3** on the Mac mini (Apple M4 Pro,
48 GB unified memory), serving `192.168.30.111:11434` to the home-lab cluster. A separate
mlx-audio Qwen3-TTS server runs at `:8000` (see [tts-voice-tuning.md](tts-voice-tuning.md)).
Last reviewed 2026-09-05.

## Model roster (3 models, all kept warm)

| Model | Role | Format | Context | Vision | Speed | Consumers |
|---|---|---|---|---|---|---|
| **`gemma4:26b-mlx`** | big / quality / **vision** — the everything-model | MLX (26B-A4B) | **131k** (host env) | ✅ | 66–71 tok/s | ~15 cluster apps (chat, agents, OCR, vision) |
| **`gemma4:e2b-mlx`** | small / edge / fast text | MLX nvfp4 (5.2B) | default | ❌ (no vision tensors at all) | 163–193 tok/s | ha-ai-harness `EDGE_MODEL`, openclaw catalog |
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
- `OLLAMA_NUM_PARALLEL=2`, `OLLAMA_CONTEXT_LENGTH=65536`, `OLLAMA_MAX_LOADED_MODELS=3`,
  `OLLAMA_KEEP_ALIVE=-1` (Guardian injects these when it launches `ollama serve`).
- **`OLLAMA_KEEP_ALIVE=-1` is a loaded footgun.** It pins *every* model anyone requests, not
  just the warm set, and there are only three slots. One person picking an unusual model in
  Open WebUI evicts a production model until the next restart. Worse, any client that sends
  its own `keep_alive` re-stamps the shared model's expiry: three Home Assistant scripts sent
  `"60m"` and silently un-pinned the warm set fleet-wide, and the Guardian only pins at
  startup, so it stayed un-pinned until the next restart.

## Why GGUF (not MLX) for the big model — decided 2026-07-05, **REVERSED 2026-09-04**

> **Superseded.** Ollama 0.33.3 (2026-09-02) added *"gemma4 now supports images and audio on
> MLX engine"*, and the whole fleet moved to `gemma4:26b-mlx` on 2026-09-04 — see the
> migration section below. The reasoning preserved here was correct for the engine of the
> time: the discriminative image test below ran against `gemma4:26b-mlx` itself and failed
> because the *runner* had no image path at all, not because the weights lacked one. They
> did not: the build declares `vision_config: {model_type: gemma4_vision, hidden_size 1152,
> 27 layers}`, readable from the registry without pulling 18 GB. `gemma4:e2b-mlx` genuinely
> has no vision tensors and never will — do not generalise from it to the 26b.


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

## Context: 65536 (lowered 2026-09-05)

`OLLAMA_CONTEXT_LENGTH=65536`. The MLX build bakes no `num_ctx` of its own — unlike the GGUF,
which carried 131072 in the model file — so it takes this value and reserves it **per parallel
slot**.

The number is measured. Across 15471 real prompts from the rotated logs: median 1080, p95
5782, max 73586. **Exactly one prompt exceeds 65536; 32768 would have truncated 257 (1.66 %).**
Four of the large samples were a subagent's synthetic needle probes, so the p99 is contaminated
and is not evidence of workload shape — the max and the over-threshold counts are.

**Every consumer that declares a context window must move first, and stay in step.** This is
not advice, it is the failure mode: `openclaw` and `hermes-agent` both declared 131072 and
would have built prompts the host could no longer serve; both were lowered in
cberg-home-nextgen `af67ee7e` *before* the host changed. Home Assistant is worse — it is the
one consumer that puts `num_ctx` on the wire, and it **cannot omit it**: an unset value sends
`DEFAULT_NUM_CTX = 8192`, not "inherit". A mismatched `num_ctx` forces an evict-and-reload of
the pinned 18 GB model on every call. Its Voice subentry sat at 8192 against a 131072 host for
weeks, silently reloading `e2b-mlx` on every voice command, until this was found.

Earlier history: reducing the **GGUF** from 131k to 68k was tried in July and reverted — gemma4
uses sliding-window attention, so its KV barely scaled past the window (18.0 GB @ 68k ≈ 17.7 GB
@ 131k). That result does not transfer to the MLX runner, which reserves per slot up front.

**Honest accounting of the saving.** The first measurement claimed 8.25 GiB and was wrong: it
compared a loaded runner (26.07 GiB, after a night of traffic) against a freshly warmed one
(17.82 GiB). `size_vram` grows monotonically with use and plateaus, so the two are not
comparable. Like for like, after real traffic: **26.07 → ~24.1 GiB, about 2 GiB.** What did
move unambiguously, because it is system-level and independent of warm-up timing: the
compressor fell from 8.70 to 3.50 GiB and macOS shrank the swap file from 15360 to 7168 MiB on
its own.

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

## Engine 0.32.15 → 0.33.3 and the GGUF → MLX migration (2026-09-04)

`gemma4:26b` (GGUF Q4_K_M) was replaced by `gemma4:26b-mlx` across every consumer. Both the
engine update and the model swap happened the same night; the deploy log for Sure records
both so they stay separable.

**Why the engine had to move first.** 0.33.3, released 2026-09-02, carries *"gemma4 now
supports images and audio on MLX engine"*. On 0.32.15 the MLX runner had no image path at all.

**Vision on MLX had been written off here on bad evidence.** The earlier "no Gemma 4 MLX with
vision" conclusion was drawn from `gemma4:e2b-mlx`, whose weights carry **no vision tensors** —
`/api/show` reports `capabilities: [completion, tools, thinking]` and there is not one
`vision.*` key. That test never exercised the runner. `gemma4:26b-mlx` does ship the encoder;
its config declares `vision_config: {model_type: gemma4_vision, hidden_size 1152, 27 layers}`,
readable from the registry without pulling 18 GB. Verified live afterwards: it reads a
five-digit number out of a synthetic test image and describes a scene correctly.

**The two 26b builds cannot coexist. This is the operational rule.**

```
llama-server model predicted to exceed available memory, evicting
  predicted="27.1 GiB"  predicted_num_ctx=262144
```

The GGUF reserves **27.1 GiB** — 18.6 of weights plus ~8.5 for its baked 131072 context times
two parallel slots. The MLX build peaks at **18.7 GiB**. Together that is 45.8 of 48 GiB, so
whichever loads second evicts the first, and with `OLLAMA_KEEP_ALIVE=-1` both stay pinned and
fight. A vision request in that state panics the MLX runner outright:

```
panic: mlx: [METAL] Command buffer execution failed: Insufficient Memory
  (kIOGPUCommandBufferCallbackErrorOutOfMemory)
```

That panic is **not** a defect in the model — with room, the same model answers in 1.5 s. It is
purely the two-resident condition. A migration must therefore switch *every* consumer, then
swap the model once. A gradual rollout is guaranteed to thrash: during the split state on
2026-09-04, real cluster requests returned 500 after `Request terminated error="context
canceled"`, i.e. clients giving up mid-load.

### Measured: MLX serialises, llama.cpp batches

Same prompts, `num_predict` 300, wall-clock throughput (tokens generated ÷ wall time):

| concurrent | MLX per-request | MLX throughput | GGUF per-request | GGUF throughput |
|---|---|---|---|---|
| 1 | 71.5 tok/s | 63.3 | 58.6 tok/s | — |
| 2 | 68.1 | 64.3 | 34.5 | 66.4 |
| 4 | 69.1 | 64.6 | 34.9 | 66.6 |
| 5 | 70.2 | 65.1 | — | — |
| 6 | 69.0 | 64.5 | — | — |

**Total throughput is the same (~64 vs ~66 tok/s)** — the machine is memory-bandwidth bound
either way. What differs is scheduling, measured directly rather than inferred:

```
MLX,  4 concurrent:  peak simultaneous generation: 1 of 4   (perfect 4 s blocks, 67 tok/s each)
GGUF, 2 concurrent:  peak simultaneous generation: 2 of 2   (35.2 tok/s each)
```

**The MLX runner ignores `OLLAMA_NUM_PARALLEL` entirely** and serves strictly one request at a
time at full speed; llama.cpp fair-shares. Queue wait therefore grows linearly under MLX
(0 → 2.3 → 6.9 → 9.5 → 11.5 s at n=1/2/4/5/6). Do not expect MLX to add capacity — it does not.
What it buys is +22 % single-stream and 8.5 GiB of context allocation back.

### Quality was verified, not assumed

Different quantisation, so output equivalence was checked on the real workload before pointing
Sure's merchant-detection batch at it. Identical, character for character, on all five German
bank descriptors; German prose and arithmetic likewise equivalent. Vision latency in the final
state is 1.53 s cold against the GGUF's 1.8 s.

### Traps this migration walked into

- **A model's config can live outside the manifest.** paperless-ngx stores it in the
  `paperless_applicationconfiguration` DB row, which *wins over* the pod env — Django reported
  `AI_ENABLED=False` while the DB said otherwise.
- **A ConfigMap can be a seed, not the config.** `hermes-agent`'s init container copies it to a
  PVC only if the file is absent; manifest correct, Flux green, pod restarted, and the live
  process still read a 17-day-old file. Grep cannot find this class.
- **The consumer inventory under-counts.** `docs/ai-usage-map.md` in the cluster repo was
  missing `sure` — the single largest consumer — plus `hermes-agent` and `ha-ai-harness`.
- **Nextcloud had four model keys**, not one.
- **Any client sending its own `keep_alive` re-stamps the shared model's expiry.** Three Home
  Assistant scripts sent `"60m"`, which silently un-pinned warm models fleet-wide; the Guardian
  only pins at startup, so that persisted until the next restart.

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

## Contention, not slowness — and why `NUM_PARALLEL` is now 2
Measured 2026-08-24: `gemma4:26b` reported **88.8 s total duration for 2.6 s of actual work —
97 % internal queue wait**, while raw generation sat at 56.5 tok/s, exactly its baseline. If an
app feels slow against the 26b, check the queue before suspecting the model.

Root cause, traced across the access log and the cluster: on **2026-08-16** a Talos maintenance
reboot recreated the Frigate pod, which activated a GenAI config committed on 2026-07-14 (its
ConfigMap is a `subPath` mount with no Reloader annotation, so it only takes effect on pod
recreation). Vision requests jumped from 2–3/day to **1011/day with 3862 images decoded**.

Frigate then timed out against its own load. Its client deadline is **120 s hardcoded** in
`genai/__init__.py` — not exposed in Frigate's config — and the bundled OpenAI SDK retries
twice, so one failed description costs three 120 s requests. Its compute need is p50 **9.5 s**;
only 0.41 % of requests exceed 120 s of GPU time, yet 627 died at exactly 120 s and **65 % of
those never got a slot at all**. Pure queue wait, self-inflicted.

**Fix: `OLLAMA_NUM_PARALLEL` 1 → 2.** Verified after the change: the runner starts with
`-c 262144 -np 2` (`n_slots = 2, n_ctx_slot = 131072` — each slot keeps the full context), and
two concurrent requests both finish in 3.7 s instead of serialising. **Memory is unchanged at
17 GB** despite the doubled `-c`, for the same sliding-window reason that made the 131k→68k
experiment pointless.

### Still 2 after the MLX move — but for a different reason (2026-09-05)

The original justification above is void: it rests on llama.cpp genuinely batching, which the
MLX runner does not do. Setting it back to 1 was tried anyway, to reclaim the KV reservation,
and **reverted after 20 minutes**. The reasoning that led there was wrong in a way worth
keeping:

> The MLX runner ignores `num_parallel` for **batching**, not for **admission**.

Both halves are measured. It serialises generation — four concurrent requests gave `peak
simultaneous generation: 1 of 4`, in clean 4 s blocks at 67 tok/s each, while llama.cpp under
the same test gave `2 of 2` at 35.2 tok/s each. But ollama's scheduler still admits
`num_parallel` requests concurrently, so with one slot the second request waits at the
scheduler instead of interleaving. Within minutes: a 5-token probe took **81.2 s of which
0.1 s was generation**, `/v1/chat/completions` aborted at 3m0s and 15m0s, and frigate burned
two 120 s timeouts. After reverting, the same probe: **1.1 s, 0.0 s queue.**

**The real cost of the MLX move, stated plainly:** aggregate throughput is unchanged (~64 vs
~66 tok/s — the host is memory-bandwidth bound either way), but a short request queued behind
a long one now waits for it *entirely*, where llama.cpp let it progress at half speed. This is
head-of-line blocking, and it is normal, not a fault: a 2446-token request ran 13.3 s, and a
trivial probe started 3 s in returned after 10.6 s — exactly the remaining time. Three separate
"the host is wedged" reports during the migration were all this, including two of my own; each
time the queue was someone else's benchmark. **Before diagnosing the host, check who else is
mid-request.**

It also makes Sure a latency *source*, not just a consumer: 319 candidates at
`AUTO_DETECT_MERCHANTS_BATCH_SIZE=5` is 64 sequential requests of 13–55 s, and that job hangs
off every sync, not just the 02:22 UTC one. Backfills belong outside usage hours.

Two attribution traps worth remembering, both of which produced wrong conclusions first:
- **The client IPs in the access log are node IPs, not pods.** Three distinct client timeouts
  on one address (120 s Frigate / 1800 s Sure / 3600 s unattributed) is what gave it away.
- **A client "appearing" or "vanishing" is usually a pod reschedule.** Sure looked like it
  stepped 50× on 2026-08-17; it had simply moved from node `.12` to `.11` in the same Talos
  roll. Its actual job counts show no step.

The log cannot settle this on its own: Ollama's gin logger records no User-Agent and no model
name (verified across 3.83 M lines), so per-app attribution has to come from the cluster side.

## Rollback / operational notes
- **Engine rollback**: `/Applications/Ollama-0.31.1.app` (and `-0.30.8`, `-0.24.0`) backups
  exist — quit the Guardian, swap `/Applications/Ollama.app`, relaunch.
- The Guardian is the single server on `:11434`; its watchdog restarts `ollama serve` on the
  current binary if it's stopped.
- Cluster apps reference the model by tag `gemma4:26b` (unchanged) — no app changes were
  needed for any of this.
