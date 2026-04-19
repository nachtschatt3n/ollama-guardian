#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${ROOT_DIR}/.build/verification"
RUNNER="${BUILD_DIR}/guardian-verification"

mkdir -p "${BUILD_DIR}"

swiftc \
  -enable-bare-slash-regex \
  -o "${RUNNER}" \
  "${ROOT_DIR}/Sources/local-ollama-monitor/Diagnostics.swift" \
  "${ROOT_DIR}/Sources/local-ollama-monitor/Models.swift" \
  "${ROOT_DIR}/Sources/local-ollama-monitor/SettingsStore.swift" \
  "${ROOT_DIR}/Sources/local-ollama-monitor/HTTPServer.swift" \
  "${ROOT_DIR}/Sources/local-ollama-monitor/Support.swift" \
  "${ROOT_DIR}/Sources/local-ollama-monitor/OllamaRuntime.swift" \
  "${ROOT_DIR}/Tests/VerificationRunner.swift"

"${RUNNER}"
