#!/usr/bin/env python
"""Minimal OpenAI-compatible TTS server for Qwen3-TTS (mlx-audio / VoiceDesign).

Why a custom shim instead of `mlx_audio.server`: the bundled server runs
inference in a daemon worker thread while loading the model in a separate
thread, which crashes the Qwen3-TTS VoiceDesign path with
"RuntimeError: There is no Stream(gpu, 0) in current thread.".
This server loads AND runs the model in a single dedicated worker thread, and
pins a fixed RNG seed so the VoiceDesign voice is reproducible day-to-day.

Endpoint: POST /v1/audio/speech  (OpenAI Audio Speech compatible + extras)
  body: {
    "model": "<ignored; this server hosts one model>",
    "input": "<text to speak>",
    "instruct": "<voice description>",   # optional; defaults to the chosen DE voice
    "lang_code": "german" | "de",         # optional; default german
    "voice": "<ignored for VoiceDesign>",
    "response_format": "wav" | "mp3" | "opus" | "ogg" | "flac",  # default wav
    "seed": <int>                          # optional; default DEFAULT_SEED
  }
"""
import io
import os
import queue
import threading
import time

import numpy as np
from fastapi import FastAPI, HTTPException
from fastapi.responses import JSONResponse, Response
from pydantic import BaseModel

from mlx_audio.audio_io import write as audio_write
from mlx_audio.tts.utils import load_model
import mlx.core as mx

MODEL_ID = os.environ.get("TTS_MODEL", "mlx-community/Qwen3-TTS-12Hz-1.7B-VoiceDesign-8bit")
DEFAULT_SEED = int(os.environ.get("TTS_SEED", "1234"))
DEFAULT_LANG = os.environ.get("TTS_LANG", "german")
# Chosen fallback voice: mature German woman (~45), grounded Hochdeutsch newsreader.
DEFAULT_INSTRUCT = os.environ.get(
    "TTS_INSTRUCT",
    "A mature German woman around 45 years old. Calm, warm, lower-pitched and "
    "grounded newsreader voice, neutral standard High German (Hochdeutsch), "
    "composed and professional. NOT youthful, NOT high-pitched, no cute, no "
    "energetic anime tone.",
)
_LANG_MAP = {"de": "german", "en": "english", "auto": "auto"}
# Lazy-load + idle-unload: keep the GPU free for Ollama while idle (this is a rarely
# used fallback). The model is loaded on the first synth request and released after
# TTS_IDLE_UNLOAD_S seconds of inactivity.
IDLE_UNLOAD_S = int(os.environ.get("TTS_IDLE_UNLOAD_S", "300"))

app = FastAPI(title="qwen3-tts-fallback")
_jobs: "queue.Queue" = queue.Queue()
_ready = threading.Event()
_state = {"model": None, "sr": 24000, "err": None, "last_used": 0.0, "loaded": False}


class SpeechRequest(BaseModel):
    model: str | None = None
    input: str
    instruct: str | None = None
    lang_code: str | None = None
    voice: str | None = None
    response_format: str | None = "wav"
    seed: int | None = None


def _ensure_loaded():
    if _state["model"] is None:
        m = load_model(MODEL_ID)
        _state["model"] = m
        _state["sr"] = int(getattr(m, "sample_rate", 24000))
        _state["loaded"] = True


def _unload():
    if _state["model"] is not None:
        _state["model"] = None
        _state["loaded"] = False
        try:
            mx.clear_cache()
        except Exception:  # noqa: BLE001
            pass


def _worker():
    # The HTTP server is ready immediately; the model is loaded lazily per request.
    _ready.set()
    while True:
        try:
            job = _jobs.get(timeout=5)
        except queue.Empty:
            if _state["loaded"] and (time.time() - _state["last_used"]) > IDLE_UNLOAD_S:
                _unload()
            continue
        try:
            req: SpeechRequest = job["req"]
            _ensure_loaded()
            mx.random.seed(job["seed"])
            results = list(
                _state["model"].generate_voice_design(
                    text=req.input, language=job["lang"], instruct=job["instruct"]
                )
            )
            audio = np.array(results[0].audio, dtype=np.float32).reshape(-1)
            job["audio"] = audio
            _state["last_used"] = time.time()
        except Exception as e:  # noqa: BLE001
            job["error"] = repr(e)
            # On failure (e.g. a transient Metal OOM) drop the model so the next
            # request reloads cleanly instead of reusing a half-broken state.
            _unload()
        finally:
            job["event"].set()


threading.Thread(target=_worker, daemon=True).start()


@app.get("/health")
def health():
    if not _ready.is_set():
        return JSONResponse({"status": "loading"}, status_code=503)
    return {"status": "ok", "model": MODEL_ID, "model_loaded": _state["loaded"]}


@app.get("/v1/models")
def models():
    return {"object": "list", "data": [{"id": MODEL_ID, "object": "model"}]}


@app.post("/v1/audio/speech")
def speech(req: SpeechRequest):
    if not _ready.wait(timeout=120):
        raise HTTPException(503, "model still loading")
    if _state["err"]:
        raise HTTPException(500, f"model load failed: {_state['err']}")
    if not (req.input or "").strip():
        raise HTTPException(400, "empty input")

    lang = req.lang_code or DEFAULT_LANG
    lang = _LANG_MAP.get(lang.lower(), lang.lower())
    job = {
        "req": req,
        "lang": lang,
        "instruct": req.instruct or DEFAULT_INSTRUCT,
        "seed": req.seed if req.seed is not None else DEFAULT_SEED,
        "event": threading.Event(),
    }
    _jobs.put(job)
    if not job["event"].wait(timeout=300):
        raise HTTPException(504, "synthesis timed out")
    if "error" in job:
        raise HTTPException(500, f"synthesis failed: {job['error']}")

    fmt = (req.response_format or "wav").lower()
    buf = io.BytesIO()
    try:
        audio_write(buf, job["audio"], _state["sr"], format=fmt)
        out_fmt = fmt
    except Exception:  # noqa: BLE001 - ffmpeg likely missing for non-wav
        buf = io.BytesIO()
        audio_write(buf, job["audio"], _state["sr"], format="wav")
        out_fmt = "wav"
    data = buf.getvalue()
    return Response(
        content=data,
        media_type=f"audio/{out_fmt}",
        headers={"X-TTS-Format": out_fmt, "X-TTS-Model": MODEL_ID},
    )
