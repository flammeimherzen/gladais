"""Russian F5-TTS for Gladais. One voice, cloned from the user's reference."""

from __future__ import annotations

import io
import wave
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parent
MODEL = ROOT / "models" / "f5" / "model_last_inference.safetensors"
VOCAB = ROOT / "models" / "f5" / "vocab.txt"
REF_DIR = ROOT / "voices" / "mine"
AUDIO_NAMES = ("reference.wav", "reference.mp3", "reference.flac", "reference.m4a")


class Engine:
    def __init__(self) -> None:
        if not MODEL.is_file() or MODEL.stat().st_size < 100_000_000:
            raise RuntimeError(f"F5 weights are missing: {MODEL}")
        if not VOCAB.is_file():
            raise RuntimeError(f"F5 vocab is missing: {VOCAB}")
        import torch
        from f5_tts.api import F5TTS

        if torch.backends.mps.is_available():
            device = "mps"
        elif torch.cuda.is_available():
            device = "cuda"
        else:
            device = "cpu"
        print(f"Loading F5-TTS on {device}...", flush=True)
        self.tts = F5TTS(
            model="F5TTS_v1_Base",
            ckpt_file=str(MODEL),
            vocab_file=str(VOCAB),
            device=device,
        )
        self.sample_rate = int(self.tts.target_sample_rate)

    @property
    def voices(self) -> list[dict]:
        return [{"id": "mine", "name": "Your voice", "detail": "reference"}]

    def reference(self) -> tuple[Path, str]:
        audio = next((REF_DIR / name for name in AUDIO_NAMES if (REF_DIR / name).is_file()), None)
        text_file = REF_DIR / "reference.txt"
        if audio is None or not text_file.is_file():
            raise RuntimeError(
                "Add your voice sample as voices/mine/reference.wav "
                "and the exact words as voices/mine/reference.txt"
            )
        text = text_file.read_text(encoding="utf-8").strip()
        if not text:
            raise RuntimeError("voices/mine/reference.txt is empty")
        return audio, text

    def synthesize(self, text: str) -> bytes:
        audio, ref_text = self.reference()
        wav, sample_rate, _spec = self.tts.infer(
            ref_file=str(audio),
            ref_text=ref_text,
            gen_text=text,
            nfe_step=16,
            speed=1.0,
            seed=1,
            show_info=lambda *_args, **_kwargs: None,
        )
        samples = np.asarray(wav, dtype=np.float32).reshape(-1)
        return wav_bytes(samples, int(sample_rate or self.sample_rate))


def wav_bytes(samples: np.ndarray, rate: int) -> bytes:
    pcm = (np.clip(samples, -1, 1) * 32767).astype(np.int16)
    buf = io.BytesIO()
    with wave.open(buf, "wb") as handle:
        handle.setnchannels(1)
        handle.setsampwidth(2)
        handle.setframerate(rate)
        handle.writeframes(pcm.tobytes())
    return buf.getvalue()
