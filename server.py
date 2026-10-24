#!/usr/bin/env python3
"""Local engine for the Glaze Mac app.

Keeps Whisper and Silero loaded, and talks to Ollama.
"""

from __future__ import annotations

import io
import json
import subprocess
import sys
import time
import urllib.request
import wave
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT))

import main as glaze  # noqa: E402

HOST = "127.0.0.1"
PORT = 8765
LOCK = __import__("threading").Lock()

WHISPER = None
ENGINE = None
VOICES: list[dict] = [{"id": "mine", "name": "Your voice", "detail": "reference"}]

VOICE_META = {
    "xenia": ("Sophie", "soft"),
    "kseniya": ("Claire", "bright"),
    "baya": ("Belle", "calm"),
    "aidar": ("Adam", "low"),
    "eugene": ("Evan", "steady"),
}


def ensure_ollama() -> None:
    try:
        urllib.request.urlopen("http://127.0.0.1:11434/api/tags", timeout=2).read()
        return
    except Exception:
        pass
    binary = ROOT / "bin" / "ollama"
    if not binary.exists():
        return
    log = open(ROOT / "ollama.log", "a", encoding="utf-8")
    subprocess.Popen(
        [str(binary), "serve"],
        stdout=log,
        stderr=subprocess.STDOUT,
        start_new_session=True,
    )
    for _ in range(40):
        try:
            urllib.request.urlopen("http://127.0.0.1:11434/api/tags", timeout=1).read()
            return
        except Exception:
            time.sleep(0.4)


def ollama_models() -> list[str]:
    try:
        with urllib.request.urlopen("http://127.0.0.1:11434/api/tags", timeout=3) as resp:
            body = json.loads(resp.read().decode("utf-8"))
    except Exception:
        return ["qwen2.5:14b"]
    names = []
    for item in body.get("models") or []:
        name = item.get("name") or item.get("model")
        if name:
            names.append(name.split(":")[0] + ":" + name.split(":")[1] if name.count(":") > 1 else name)
            # Keep the tag Ollama shows, without a duplicate ":latest" only when absent.
            names[-1] = name if ":" in name else name
    # Prefer bare repo:tag, dropping an extra :latest suffix for the menu.
    cleaned = []
    for name in names:
        short = name[:-7] if name.endswith(":latest") else name
        if short not in cleaned:
            cleaned.append(short)
    return cleaned or ["qwen2.5:14b"]


def wav_bytes(samples: np.ndarray, rate: int) -> bytes:
    pcm = (np.clip(samples, -1, 1) * 32767).astype(np.int16)
    buf = io.BytesIO()
    with wave.open(buf, "wb") as handle:
        handle.setnchannels(1)
        handle.setsampwidth(2)
        handle.setframerate(rate)
        handle.writeframes(pcm.tobytes())
    return buf.getvalue()


def synthesize(text: str, speaker: str) -> bytes:
    del speaker
    if ENGINE is None:
        raise RuntimeError("F5-TTS is not loaded")
    with LOCK:
        return ENGINE.synthesize(text)


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt: str, *args) -> None:
        print("[glaze] " + (fmt % args), flush=True)

    def _json(self, code: int, payload: dict) -> None:
        raw = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def _read_json(self) -> dict:
        length = int(self.headers.get("Content-Length") or "0")
        raw = self.rfile.read(length) if length else b"{}"
        return json.loads(raw.decode("utf-8"))

    def do_GET(self) -> None:  # noqa: N802
        if self.path.startswith("/health"):
            self._json(200, {"ok": True, "ready": WHISPER is not None})
            return
        if self.path.startswith("/v1/options"):
            self._json(200, {"voices": VOICES, "models": ollama_models()})
            return
        self._json(404, {"error": "not found"})

    def do_POST(self) -> None:  # noqa: N802
        try:
            if self.path.startswith("/v1/transcribe"):
                self._transcribe()
            elif self.path.startswith("/v1/reply"):
                self._reply()
            elif self.path.startswith("/v1/speak"):
                self._speak()
            else:
                self._json(404, {"error": "not found"})
        except Exception as exc:
            self._json(500, {"error": str(exc)})

    def _transcribe(self) -> None:
        length = int(self.headers.get("Content-Length") or "0")
        raw = self.rfile.read(length)
        audio = np.frombuffer(raw, dtype=np.float32).copy()
        with LOCK:
            text = glaze.transcribe(WHISPER, audio)
        if glaze.is_junk(text):
            text = ""
        self._json(200, {"text": text})

    def _reply(self) -> None:
        body = self._read_json()
        model = body.get("model") or glaze.OLLAMA_MODEL
        history = body.get("messages") or []
        messages = [{"role": "system", "content": glaze.SYSTEM_PROMPT}]
        for item in history[-16:]:
            role = item.get("role")
            content = (item.get("content") or "").strip()
            if role in {"user", "assistant"} and content:
                messages.append({"role": role, "content": content})
        payload = {
            "model": model,
            "messages": messages,
            "stream": False,
            "keep_alive": "30m",
            "options": {"temperature": 0.7, "num_ctx": 8192},
        }
        req = urllib.request.Request(
            "http://127.0.0.1:11434/api/chat",
            data=json.dumps(payload).encode("utf-8"),
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        with urllib.request.urlopen(req, timeout=300) as resp:
            data = json.loads(resp.read().decode("utf-8"))
        content = ((data.get("message") or {}).get("content") or "").strip()
        self._json(200, {"text": content})

    def _speak(self) -> None:
        body = self._read_json()
        text = (body.get("text") or "").strip()
        speaker = body.get("speaker") or "mine"
        raw = synthesize(text, speaker)
        self.send_response(200)
        self.send_header("Content-Type", "audio/wav")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)


def load_models() -> None:
    global WHISPER, ENGINE, VOICES
    ensure_ollama()
    WHISPER = glaze.load_whisper()
    from f5_engine import Engine

    ENGINE = Engine()
    VOICES = ENGINE.voices
    print("GLAZE_READY", flush=True)


def main() -> None:
    load_models()
    server = ThreadingHTTPServer((HOST, PORT), Handler)
    print(f"listening http://{HOST}:{PORT}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
