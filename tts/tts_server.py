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
import re
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
# Voice pinned to match the ElevenLabs reference (low mature German female newsreader).
# (seed, temperature) jointly select the voice and are CHAOTIC on this model — a 0.02
# temperature change can flip the timbre — so this exact pair was grid-searched against
# the reference's measured pitch/variance and must be pinned together. Output is
# deterministic across process/model reloads for a fixed (seed, temp, instruct, text).
# Measured vs ElevenLabs ref: median F0 178.6 Hz (ref 179.6) — essentially matched,
# down from ~237 Hz on the old voice. Do NOT drop temperature below ~0.65: at 0.5 the
# model degenerates into minutes of looping audio.
DEFAULT_SEED = int(os.environ.get("TTS_SEED", "99"))
DEFAULT_LANG = os.environ.get("TTS_LANG", "german")
DEFAULT_TEMPERATURE = float(os.environ.get("TTS_TEMPERATURE", "0.7"))
DEFAULT_TOP_K = int(os.environ.get("TTS_TOP_K", "50"))
DEFAULT_TOP_P = float(os.environ.get("TTS_TOP_P", "1.0"))
DEFAULT_REPETITION_PENALTY = float(os.environ.get("TTS_REPETITION_PENALTY", "1.05"))
# Pitch-preserving time-stretch (WSOLA) applied AFTER synthesis. 1.0 = off. Values >1.0
# speed up. 1.15 trims this voice's slightly-slow body pace (~76s -> ~66s on the sample).
# WSOLA (overlap-add) is used instead of a phase vocoder because the latter smears
# articulation into an "underwater/spacey" artifact.
DEFAULT_SPEED = float(os.environ.get("TTS_SPEED", "1.15"))
# The model synthesizes the opening greeting + date noticeably slower than the body, so
# the first TTS_INTRO_SECONDS of audio get a stronger speed-up (ramped, with a short
# crossfade into the body). Set TTS_INTRO_SPEED == TTS_SPEED to disable the ramp.
DEFAULT_INTRO_SPEED = float(os.environ.get("TTS_INTRO_SPEED", "1.3"))
DEFAULT_INTRO_SECONDS = float(os.environ.get("TTS_INTRO_SECONDS", "15.0"))
DEFAULT_INSTRUCT = os.environ.get(
    "TTS_INSTRUCT",
    "A mature German woman in her early fifties with a deep, low, warm chest voice. "
    "Calm, smooth, natural radio-news delivery at an easy flowing pace. Rich lower "
    "register, relaxed and grounded. Standard High German (Hochdeutsch). Not bright, "
    "not thin, not youthful, not high-pitched, not sing-songy, not slow.",
)
_LANG_MAP = {"de": "german", "en": "english", "auto": "auto"}
_SSML_RE = re.compile(r"<[^>]+>")


def _clean_text(text: str) -> str:
    # Qwen3-TTS has no SSML; strip tags (e.g. ElevenLabs <break time="0.7s"/>) so they
    # are not read aloud literally. Existing punctuation drives the prosody/pauses.
    return re.sub(r"\s+", " ", _SSML_RE.sub(" ", text)).strip()
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
    temperature: float | None = None
    top_k: int | None = None
    top_p: float | None = None
    repetition_penalty: float | None = None
    speed: float | None = None


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


def _time_stretch(audio, rate):
    # WSOLA overlap-add: preserves pitch AND articulation (no phase-vocoder smear).
    from audiotsm import wsola
    from audiotsm.io.array import ArrayReader, ArrayWriter
    reader = ArrayReader(np.ascontiguousarray(audio.reshape(1, -1), dtype=np.float32))
    writer = ArrayWriter(channels=1)
    wsola(channels=1, speed=float(rate)).run(reader, writer)
    return writer.data.reshape(-1).astype(np.float32)


def _time_stretch_ramped(audio, sr, base_speed, intro_speed, intro_s):
    # Speed up the first `intro_s` seconds (original timeline) at `intro_speed` and the
    # rest at `base_speed`, crossfading the seam. Falls back to a uniform stretch when the
    # ramp is disabled or the clip is shorter than the intro window.
    n = int(intro_s * sr)
    if intro_speed == base_speed or n <= 0 or n >= len(audio):
        return _time_stretch(audio, base_speed)
    head = _time_stretch(audio[:n], intro_speed)
    body = _time_stretch(audio[n:], base_speed)
    xf = int(0.025 * sr)
    if len(head) > xf and len(body) > xf:
        f = np.linspace(0.0, 1.0, xf, dtype=np.float32)
        head[-xf:] = head[-xf:] * (1.0 - f) + body[:xf] * f
        return np.concatenate([head, body[xf:]])
    return np.concatenate([head, body])


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
            _ensure_loaded()
            mx.random.seed(job["seed"])
            results = list(
                _state["model"].generate_voice_design(
                    text=job["text"], language=job["lang"], instruct=job["instruct"],
                    temperature=job["temperature"], top_k=job["top_k"],
                    top_p=job["top_p"], repetition_penalty=job["repetition_penalty"],
                )
            )
            audio = np.array(results[0].audio, dtype=np.float32).reshape(-1)
            if job["speed"] and job["speed"] != 1.0:
                audio = _time_stretch_ramped(
                    audio, _state["sr"], job["speed"],
                    DEFAULT_INTRO_SPEED, DEFAULT_INTRO_SECONDS,
                )
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
    text = _clean_text(req.input)
    if not text:
        raise HTTPException(400, "empty input after cleaning")
    job = {
        "text": text,
        "lang": lang,
        "instruct": req.instruct or DEFAULT_INSTRUCT,
        "seed": req.seed if req.seed is not None else DEFAULT_SEED,
        "temperature": req.temperature if req.temperature is not None else DEFAULT_TEMPERATURE,
        "top_k": req.top_k if req.top_k is not None else DEFAULT_TOP_K,
        "top_p": req.top_p if req.top_p is not None else DEFAULT_TOP_P,
        "repetition_penalty": req.repetition_penalty if req.repetition_penalty is not None else DEFAULT_REPETITION_PENALTY,
        "speed": req.speed if req.speed is not None else DEFAULT_SPEED,
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
