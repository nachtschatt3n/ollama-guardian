# Ollama Guardian

Native macOS control plane for a local Ollama node.

Ollama Guardian keeps a shared Ollama runtime healthy on macOS by monitoring the host, watching Ollama API/log activity, detecting stuck states, restarting and rewarming models when needed, exposing Prometheus metrics, and offering a small authenticated remote-ops API for automation or AI-SRE workflows.

It also supervises a self-hosted **local TTS fallback** (Qwen3-TTS via mlx-audio) as a second managed process, checks daily for new Ollama releases and stale loaded-model digests, and tracks live request throughput — all surfaced in the dashboard, menu bar, and metrics.

## Screenshots

![Dashboard](docs/screenshots/dashboard.png)

![Live Logs](docs/screenshots/live-logs.png)

## What It Does

- Runs as a menu bar app (with a native app icon and About panel) and a unified dashboard window.
- Manages `ollama serve` directly instead of relying on a wrapper proxy.
- Monitors host CPU, Metal GPU utilization, memory, load average, Ollama process stats, API health, and log-derived inference activity.
- Tracks live request throughput from the Ollama logs: requests/minute and peak in-flight concurrency vs. the parallel limit.
- Detects likely stuck-runtime conditions and can reload Ollama automatically.
- Warms a configurable model set after startup or reload.
- Supervises a local **TTS fallback** server (Qwen3-TTS via mlx-audio) as a managed process: lazy model load, health polling, and automatic restart on crash.
- Checks daily for a newer Ollama release (GitHub) and for stale loaded-model digests (Ollama registry), surfacing an in-app banner/badge and a "Check for Updates" action.
- Exposes Prometheus metrics on a configurable network bind host and port.
- Exposes a bearer-protected control API for restart, warmup, cooldown clearing, status, and recent logs.
- Shows actionable recovery guidance instead of crashing when required runtime pieces are missing or misconfigured.

## Defensive Behavior

Ollama Guardian now fails softly and tells the operator what to do next when:

- `ollama` is not installed or not on `PATH`
- the managed log path is not writable
- the Ollama API never becomes healthy
- the metrics or control API port is already in use
- required settings such as ports or bearer token are invalid

The app surfaces these as clear in-app recovery cards and keeps the control plane itself alive.

## Requirements

- macOS 14 or later
- Ollama installed locally
- Command Line Tools for Xcode for command-line builds

Recommended Ollama install options:

```bash
brew install ollama
```

Or install Ollama from the official app/download and verify:

```bash
ollama --version
```

## Install

### Option 1: Download the app bundle

1. Download the latest `Ollama Guardian.app` from the GitHub Releases page.
2. Move it to `/Applications`.
3. Launch the app.
4. Open `Settings` and confirm your Ollama host, ports, warm models, and control token.

### Option 2: Build from source

```bash
git clone git@github.com:nachtschatt3n/ollama-guardian.git
cd ollama-guardian
swift build
./scripts/package-app.sh
open ".build/apple/Ollama Guardian.app"
```

To install the packaged build into `/Applications`:

```bash
cp -R ".build/apple/Ollama Guardian.app" /Applications/
open "/Applications/Ollama Guardian.app"
```

## Configuration

The Settings view exposes the practical Ollama server/runtime options for a guardian-managed node, including:

- Ollama base URL, bind host, and port
- model storage directory and allowed origins
- keep-alive, context length, queueing, parallelism, and loaded-model limits
- load timeout, K/V cache type, LLM library override, and GPU overhead
- flash attention, debug logging, prune/cloud toggles, spread scheduling, and multi-user cache
- warm model list and endpoint type (`generate` or `embed`)
- watchdog thresholds
- Prometheus metrics bind host/port
- authenticated control API bind host/port and bearer token generation

Every option has inline hover help in the UI.

## Prometheus Metrics

The metrics server exposes:

- `GET /health`
- `GET /metrics`

Example scrape target:

```text
http://0.0.0.0:9464/metrics
```

Key exported metrics include:

- `ollama_guardian_system_cpu_percent`
- `ollama_guardian_system_gpu_percent`
- `ollama_guardian_system_load_1m`
- `ollama_guardian_ollama_cpu_percent`
- `ollama_guardian_ollama_resident_memory_bytes`
- `ollama_guardian_loaded_models`
- `ollama_guardian_api_healthy`
- `ollama_guardian_requests_per_minute`
- `ollama_guardian_inflight_peak_60s`
- `ollama_guardian_parallel_limit`
- `ollama_guardian_last_inference_timestamp_seconds`
- `ollama_guardian_last_reload_timestamp_seconds`
- `ollama_guardian_stuck_state`
- `ollama_guardian_ollama_update_available`
- `ollama_guardian_model_update_available{model="..."}`
- `ollama_guardian_tts_enabled`
- `ollama_guardian_tts_up`
- `ollama_guardian_tts_healthy`
- `ollama_guardian_tts_restart_total`

## Remote Control API

The control API is exposed on its own bind host and port and requires:

```http
Authorization: Bearer <token>
```

Available endpoints:

- `GET /api/status`
- `POST /api/actions/restart`
- `POST /api/actions/warm`
- `POST /api/actions/clear-cooldown`
- `GET /api/logs/recent?lines=50`

## Local TTS Fallback

Ollama Guardian can supervise a self-hosted, German-capable text-to-speech server as a
second managed process, used as a fallback when a primary cloud TTS (e.g. ElevenLabs) is
unavailable. It runs [Qwen3-TTS](https://huggingface.co/collections/mlx-community/qwen3-tts)
via [`mlx-audio`](https://github.com/Blaizzy/mlx-audio) on Apple Silicon.

- A small OpenAI-compatible server (`tts_server.py`, kept in the configured working
  directory alongside its venv) exposes `POST /v1/audio/speech` and `GET /health`.
- It **lazy-loads** the model on the first request and **unloads after idle**, so it does
  not hold GPU memory while idle (avoiding contention with Ollama's resident models).
- The voice is a fixed [VoiceDesign](https://huggingface.co/mlx-community) description with a
  pinned seed, so output is reproducible day to day. Model, seed, language, and the voice
  description are all configurable in Settings.
- The Guardian starts it, polls `/health`, restarts it on crash, and reports status in the
  dashboard card, the menu bar, and the `ollama_guardian_tts_*` metrics.

Disable it entirely with the "Enable TTS Fallback" toggle in Settings.

One-time host setup (in the configured TTS working directory):

```bash
python3 -m venv venv
./venv/bin/pip install mlx-audio uvicorn fastapi webrtcvad-wheels audiotsm
cp /path/to/repo/tts/tts_server.py .   # reference copy is vendored in this repo
# the Guardian launches: <venv>/bin/python -m uvicorn tts_server:app
```

The server script is vendored at [`tts/tts_server.py`](tts/tts_server.py) for reference; the
Guardian runs the copy in the configured working directory.

## Verification

This repo includes a runnable verification harness in `Tests/VerificationRunner.swift`.

Run it with:

```bash
./scripts/run-tests.sh
```

That script compiles a standalone verification runner against the real runtime sources and currently checks:

- settings persistence
- log endpoint parsing
- stuck-state detection rules
- HTTP bearer parsing
- executable discovery
- configuration validation
- missing-Ollama recovery guidance

## Project Layout

```text
Sources/local-ollama-monitor/
  AppMain.swift
  Branding.swift          # procedural app/menu-bar mascot + AppIcon source
  GuardianController.swift
  HTTPServer.swift
  Diagnostics.swift
  Models.swift
  OllamaRuntime.swift      # Ollama process, log/RPM monitor, release + registry checks
  TTSRuntime.swift         # managed TTS server process + health client
  SettingsStore.swift
  Support.swift
  Views.swift
  Resources/
    AppIcon.icns
    guardian-brand-*.png

scripts/
  package-app.sh
  generate-app-icon.swift  # renders the mascot into AppIcon.iconset/.icns
  run-tests.sh

tts/
  tts_server.py            # OpenAI-compatible Qwen3-TTS fallback server (run on the host)

docs/screenshots/
  dashboard.png
  live-logs.png
```

`tts/tts_server.py` is a reference copy; at runtime the Guardian launches the copy in the
configured TTS working directory (alongside its mlx-audio venv).

## License

MIT. See [LICENSE](LICENSE).
