#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Ollama Guardian.app"
EXECUTABLE_NAME="OllamaGuardian"
BUILD_DIR="${ROOT_DIR}/.build/apple"
APP_DIR="${BUILD_DIR}/${APP_NAME}"
CONTENTS_DIR="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"

mkdir -p "${BUILD_DIR}"

swift build -c release --product local-ollama-monitor

rm -rf "${APP_DIR}"
mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}"

cp "${ROOT_DIR}/macos/Info.plist" "${CONTENTS_DIR}/Info.plist"
cp "${ROOT_DIR}/.build/release/local-ollama-monitor" "${MACOS_DIR}/${EXECUTABLE_NAME}"
chmod +x "${MACOS_DIR}/${EXECUTABLE_NAME}"

echo "${APP_DIR}"
