#!/usr/bin/env python3
"""Glaze — local voice conversation.

Listen with Whisper, answer with Ollama, speak with Silero.
No app control and no screen access.
"""

from __future__ import annotations

import json
import re
import sys
import time
import urllib.error
import urllib.request
import zipfile
from pathlib import Path

import numpy as np
import sounddevice as sd
import torch
import whisper

SAMPLE_RATE = 16_000
SILERO_SAMPLE_RATE = 48_000
OLLAMA_URL = "http://127.0.0.1:11434/api/chat"
OLLAMA_MODEL = "qwen2.5:14b"
WHISPER_MODEL = "small"
SILERO_SPEAKER = "xenia"
MAX_RECORD_SECONDS = 30.0
SILENCE_SECONDS = 1.2
LISTEN_TIMEOUT_SECONDS = 8.0
HISTORY_TURNS = 8
ROOT = Path(__file__).resolve().parent


def speech_config_path() -> Path:
    local = ROOT / "config.json"
    if local.is_file():
        return local
    example = ROOT / "config.example.json"
    if example.is_file():
        return example
    raise RuntimeError("Missing config.json. Copy config.example.json to config.json.")


def _required_text(raw: dict, key: str, filename: str) -> str:
    value = raw.get(key)
    if not isinstance(value, str) or not value.strip():
        raise RuntimeError(f"{filename} needs a non-empty string for {key}")
    return value.strip()


def _phrase_list(raw: dict, key: str, filename: str) -> tuple[str, ...]:
    value = raw.get(key)
    if not isinstance(value, list):
        raise RuntimeError(f"{filename} needs a list for {key}")
    phrases: list[str] = []
    for item in value:
        if not isinstance(item, str) or not item.strip():
            raise RuntimeError(f"{filename} {key} must contain non-empty strings")
        text = item.strip().lower()
        if text.endswith("*"):
            body = " ".join(text[:-1].split())
            if not body:
                raise RuntimeError(f"{filename} {key} has an empty prefix")
            phrases.append(f"{body}*")
        else:
            phrases.append(" ".join(text.split()))
    return tuple(phrases)


def load_speech_settings() -> tuple[str, frozenset[str], tuple[str, ...], str]:
    path = speech_config_path()
    try:
        raw = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        raise RuntimeError(f"Invalid JSON in {path.name}: {exc}") from exc
    if not isinstance(raw, dict):
        raise RuntimeError(f"{path.name} must be a JSON object")
    prompt = _required_text(raw, "system_prompt", path.name)
    goodbye = _required_text(raw, "goodbye", path.name)
    exit_words = frozenset(_phrase_list(raw, "exit_words", path.name))
    junk_phrases = _phrase_list(raw, "junk_phrases", path.name)
    if not exit_words:
        raise RuntimeError(f"{path.name} needs at least one exit word")
    return prompt, exit_words, junk_phrases, goodbye


SYSTEM_PROMPT, EXIT_WORDS, JUNK_PHRASES, GOODBYE = load_speech_settings()


def load_whisper():
    print(f"Loading Whisper ({WHISPER_MODEL})...", flush=True)
    return whisper.load_model(WHISPER_MODEL)


SILERO_REPO = Path.home() / ".cache/torch/hub/snakers4_silero-models_master"
SILERO_MODEL = "v4_ru"
SILERO_WEIGHTS = SILERO_REPO / "src/silero/model/v4_ru.pt"
SILERO_MIRROR = (
    "https://huggingface.co/Derur/silero-models/resolve/main/tts/ru/ru_v4/v4_ru.pt"
)
SILERO_CODE_ZIP = (
    "https://github.com/snakers4/silero-models/archive/refs/heads/master.zip"
)


def _download(url: str, dest: Path) -> None:
    dest.parent.mkdir(parents=True, exist_ok=True)
    tmp = dest.with_suffix(dest.suffix + ".part")
    req = urllib.request.Request(url, headers={"User-Agent": "glaze"})
    with urllib.request.urlopen(req, timeout=180) as resp, tmp.open("wb") as out:
        while True:
            chunk = resp.read(1024 * 256)
            if not chunk:
                break
            out.write(chunk)
    tmp.replace(dest)


def ensure_silero_code() -> None:
    if (SILERO_REPO / "hubconf.py").is_file():
        return
    print("Downloading Silero code...", flush=True)
    zip_path = SILERO_REPO.parent / "silero-models-master.zip"
    _download(SILERO_CODE_ZIP, zip_path)
    with zipfile.ZipFile(zip_path) as archive:
        archive.extractall(SILERO_REPO.parent)
    extracted = SILERO_REPO.parent / "silero-models-master"
    if SILERO_REPO.exists():
        # A partial folder would make torch.hub skip the real checkout.
        leftover = SILERO_REPO.with_name(SILERO_REPO.name + ".partial")
        if leftover.exists():
            raise RuntimeError(f"Cannot replace {SILERO_REPO}")
        SILERO_REPO.rename(leftover)
        extracted.rename(SILERO_REPO)
        leftover.rmdir() if leftover.is_dir() and not any(leftover.iterdir()) else None
    else:
        extracted.rename(SILERO_REPO)
    zip_path.unlink(missing_ok=True)


def ensure_silero_weights() -> None:
    ensure_silero_code()
    if SILERO_WEIGHTS.is_file() and SILERO_WEIGHTS.stat().st_size > 1_000_000:
        return
    print("Downloading Silero Russian voice...", flush=True)
    _download(SILERO_MIRROR, SILERO_WEIGHTS)


def load_silero():
    print("Loading Silero TTS (Russian)...", flush=True)
    ensure_silero_weights()
    loaded = torch.hub.load(
        repo_or_dir="snakers4/silero-models",
        model="silero_tts",
        language="ru",
        speaker=SILERO_MODEL,
        trust_repo=True,
    )
    model = loaded[0]
    model.to(torch.device("cpu"))
    speakers = list(getattr(model, "speakers", []) or [])
    speaker = SILERO_SPEAKER
    if speakers and speaker not in speakers:
        speaker = "baya" if "baya" in speakers else speakers[0]
        print(f"Speaker {SILERO_SPEAKER} unavailable, using {speaker}.", flush=True)
    return model, speaker


def rms(frame: np.ndarray) -> float:
    if frame.size == 0:
        return 0.0
    return float(np.sqrt(np.mean(np.square(frame), dtype=np.float64)))


def record_utterance() -> np.ndarray | None:
    """Record mono float32 audio at 16 kHz until speech then a pause."""
    frame_seconds = 0.03
    block = int(SAMPLE_RATE * frame_seconds)
    silence_blocks = int(SILENCE_SECONDS / frame_seconds)
    min_speech_blocks = int(0.35 / frame_seconds)
    max_blocks = int(MAX_RECORD_SECONDS / frame_seconds)
    start_timeout_blocks = int(LISTEN_TIMEOUT_SECONDS / frame_seconds)

    print("Listening... speak now.", flush=True)

    ambient: list[float] = []
    collected: list[np.ndarray] = []
    speech_started = False
    speech_blocks = 0
    quiet_run = 0
    waited = 0

    with sd.InputStream(
        samplerate=SAMPLE_RATE,
        channels=1,
        dtype="float32",
        blocksize=block,
    ) as stream:
        for _ in range(14):
            data, _overflow = stream.read(block)
            ambient.append(rms(data[:, 0]))
        noise = float(np.median(ambient)) if ambient else 0.0
        threshold = max(noise * 3.0 + 0.004, 0.008)

        while True:
            data, _overflow = stream.read(block)
            frame = np.ascontiguousarray(data[:, 0], dtype=np.float32)
            level = rms(frame)
            if not speech_started:
                waited += 1
                if level >= threshold:
                    speech_started = True
                    collected.append(frame)
                    speech_blocks = 1
                    quiet_run = 0
                elif waited >= start_timeout_blocks:
                    print("No speech. Press Enter to listen again.", flush=True)
                    return None
                continue

            collected.append(frame)
            speech_blocks += 1
            if level < threshold:
                quiet_run += 1
            else:
                quiet_run = 0
            if speech_blocks >= min_speech_blocks and quiet_run >= silence_blocks:
                break
            if speech_blocks >= max_blocks:
                break

    if not collected:
        return None
    return np.concatenate(collected).astype(np.float32)


def transcribe(model, audio: np.ndarray) -> str:
    peak = float(np.max(np.abs(audio))) if audio.size else 0.0
    if peak < 0.01 or audio.size < int(SAMPLE_RATE * 0.3):
        return ""
    if peak > 1.0:
        audio = audio / peak
    result = model.transcribe(
        audio,
        language="ru",
        fp16=False,
        task="transcribe",
        temperature=0.0,
        condition_on_previous_text=False,
        verbose=False,
    )
    return (result.get("text") or "").strip()


def is_junk(text: str) -> bool:
    normalized = " ".join(text.lower().strip(" .!?,;:\"'").split())
    if not normalized:
        return True
    for phrase in JUNK_PHRASES:
        if phrase.endswith("*"):
            prefix = phrase[:-1]
            if normalized == prefix or normalized.startswith(prefix + " "):
                return True
        elif normalized == phrase:
            return True
    return False


def should_exit(text: str) -> bool:
    cleaned = "".join(ch if ch.isalnum() or ch.isspace() else " " for ch in text.lower())
    words = cleaned.split()
    return bool(words) and words[0] in EXIT_WORDS and len(words) <= 2


def ask_llm(messages: list[dict]) -> str:
    payload = {
        "model": OLLAMA_MODEL,
        "messages": messages,
        "stream": False,
        "keep_alive": "30m",
        "options": {"temperature": 0.7, "num_ctx": 8192},
    }
    req = urllib.request.Request(
        OLLAMA_URL,
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=300) as resp:
            body = json.loads(resp.read().decode("utf-8"))
    except urllib.error.URLError as exc:
        raise RuntimeError(
            "Ollama is not answering on 127.0.0.1:11434. Start it with: ollama serve"
        ) from exc
    content = ((body.get("message") or {}).get("content") or "").strip()
    content = re.sub(r"<think>.*?</think>", "", content, flags=re.DOTALL).strip()
    return content


def clean_for_speech(text: str) -> str:
    text = re.sub(r"https?://\S+", " ", text)
    text = text.replace("**", " ").replace("`", " ").replace("#", " ")
    text = text.replace("*", " ").replace("_", " ")
    text = text.replace("—", ", ").replace("–", ", ")
    text = " ".join(text.replace("\n", " ").split())
    return text


def split_for_speech(text: str, limit: int = 420) -> list[str]:
    text = clean_for_speech(text)
    if not text:
        return []
    sentences: list[str] = []
    current = ""
    for ch in text:
        current += ch
        if ch in ".!?;:" and len(current.strip()) > 40:
            sentences.append(current.strip())
            current = ""
    if current.strip():
        sentences.append(current.strip())
    if not sentences:
        sentences = [text]

    parts: list[str] = []
    buf = ""
    for sentence in sentences:
        if len(sentence) > limit:
            if buf:
                parts.append(buf)
                buf = ""
            for i in range(0, len(sentence), limit):
                chunk = sentence[i : i + limit].strip(" ,")
                if chunk:
                    parts.append(chunk)
            continue
        if buf and len(buf) + 1 + len(sentence) > limit:
            parts.append(buf)
            buf = sentence
        else:
            buf = f"{buf} {sentence}".strip()
    if buf:
        parts.append(buf)
    return parts


def speak(tts, speaker: str, text: str) -> None:
    chunks = split_for_speech(text)
    if not chunks:
        return
    for chunk in chunks:
        try:
            with torch.no_grad():
                audio = tts.apply_tts(
                    text=chunk,
                    speaker=speaker,
                    sample_rate=SILERO_SAMPLE_RATE,
                    put_accent=True,
                    put_yo=True,
                )
        except Exception as exc:
            print(f"Could not speak a phrase: {exc}", flush=True)
            continue
        wav = audio.detach().cpu().numpy().astype(np.float32).reshape(-1)
        if wav.size == 0:
            continue
        sd.play(wav, SILERO_SAMPLE_RATE)
        sd.wait()
    time.sleep(0.35)


def main() -> int:
    print("Gladais — local voice assistant", flush=True)
    print(f"Model: {OLLAMA_MODEL}. Say an exit word, or press Ctrl+C to quit.", flush=True)
    try:
        mic = sd.query_devices(kind="input")
        speaker_dev = sd.query_devices(kind="output")
        print(f"Mic: {mic['name']}", flush=True)
        print(f"Speaker: {speaker_dev['name']}", flush=True)
    except Exception as exc:
        print(f"Audio device error: {exc}", flush=True)
        return 1

    whisper_model = load_whisper()
    tts, speaker = load_silero()
    history: list[dict] = [{"role": "system", "content": SYSTEM_PROMPT}]

    while True:
        try:
            audio = record_utterance()
        except KeyboardInterrupt:
            print("\nBye.", flush=True)
            return 0
        except sd.PortAudioError as exc:
            print(f"Microphone error: {exc}", flush=True)
            print(
                "Allow microphone access for Terminal in "
                "System Settings → Privacy & Security → Microphone.",
                flush=True,
            )
            return 1

        if audio is None:
            try:
                input()
            except KeyboardInterrupt:
                print("\nBye.", flush=True)
                return 0
            continue

        print("Transcribing...", flush=True)
        try:
            text = transcribe(whisper_model, audio)
        except Exception as exc:
            print(f"Transcription failed: {exc}", flush=True)
            continue

        if is_junk(text):
            print("No clear speech.", flush=True)
            continue

        print(f"You: {text}", flush=True)
        if should_exit(text):
            speak(tts, speaker, GOODBYE)
            print("Bye.", flush=True)
            return 0

        history.append({"role": "user", "content": text})
        messages = history[:1] + history[1:][-(HISTORY_TURNS * 2) :]

        print("Thinking...", flush=True)
        try:
            reply = ask_llm(messages)
        except Exception as exc:
            print(f"Model error: {exc}", flush=True)
            if history and history[-1].get("role") == "user":
                history.pop()
            continue

        if not reply:
            print("Empty model reply.", flush=True)
            continue

        history.append({"role": "assistant", "content": reply})
        print(f"Gladais: {reply}", flush=True)
        speak(tts, speaker, reply)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        print("\nBye.", flush=True)
        raise SystemExit(0)
