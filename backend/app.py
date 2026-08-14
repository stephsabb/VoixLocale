from __future__ import annotations

import base64
import io
import hashlib
import json
import os
import re
import random
import shutil
import subprocess
import threading
import unicodedata
import uuid
from datetime import datetime, timezone
from pathlib import Path

import numpy as np
import soundfile as sf
from docx import Document
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel, Field
from pypdf import PdfReader

MODEL_ID = os.environ.get(
    "VOIXLOCALE_MODEL", "mlx-community/Qwen3-TTS-12Hz-1.7B-Base-bf16"
)
DATA_DIR = Path(
    os.environ.get(
        "VOIXLOCALE_DATA_DIR",
        Path.home() / "Library" / "Application Support" / "VoixLocale",
    )
)
VOICES_DIR = DATA_DIR / "voices"
OUTPUTS_DIR = DATA_DIR / "outputs"
TEMP_DIR = DATA_DIR / "temp"
for directory in (VOICES_DIR, OUTPUTS_DIR, TEMP_DIR):
    directory.mkdir(parents=True, exist_ok=True)

app = FastAPI(title="VoixLocale", docs_url=None, redoc_url=None)
_model = None
_model_lock = threading.Lock()


class EnrollRequest(BaseModel):
    name: str = Field(min_length=1, max_length=80)
    transcript: str = Field(min_length=20, max_length=2_000)
    audio_base64: str


class GenerateRequest(BaseModel):
    text: str = Field(min_length=1, max_length=20_000)
    voice_id: str
    speed: float = Field(default=1.0, ge=0.75, le=1.25)
    hesitations: bool = False


class ExtractRequest(BaseModel):
    filename: str = Field(min_length=1, max_length=255)
    data_base64: str


def _run(command: list[str]) -> subprocess.CompletedProcess[str]:
    try:
        return subprocess.run(command, check=True, capture_output=True, text=True)
    except FileNotFoundError as exc:
        raise HTTPException(500, "FFmpeg est introuvable. Installez-le avec Homebrew.") from exc
    except subprocess.CalledProcessError as exc:
        detail = (exc.stderr or exc.stdout or "Erreur audio").strip()[-800:]
        raise HTTPException(422, detail) from exc


def _decode_payload(value: str, maximum: int = 30 * 1024 * 1024) -> bytes:
    try:
        payload = base64.b64decode(value, validate=True)
    except Exception as exc:
        raise HTTPException(422, "Le fichier transmis est invalide.") from exc
    if len(payload) > maximum:
        raise HTTPException(413, "Le fichier dépasse la taille autorisée.")
    return payload


def _probe_duration(path: Path) -> float:
    result = _run([
        "/opt/homebrew/bin/ffprobe" if Path("/opt/homebrew/bin/ffprobe").exists() else "ffprobe",
        "-v", "error", "-show_entries", "format=duration",
        "-of", "default=noprint_wrappers=1:nokey=1", str(path),
    ])
    try:
        return float(result.stdout.strip())
    except ValueError as exc:
        raise HTTPException(422, "Impossible de lire la durée du fichier audio.") from exc


def _voice_dir(voice_id: str) -> Path:
    if not re.fullmatch(r"[a-f0-9-]{36}", voice_id):
        raise HTTPException(404, "Voix inconnue.")
    directory = VOICES_DIR / voice_id
    if not directory.is_dir():
        raise HTTPException(404, "Voix inconnue.")
    return directory


def _profile(directory: Path) -> dict:
    try:
        return json.loads((directory / "profile.json").read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise HTTPException(500, "Un profil vocal local est endommagé.") from exc


def _get_model():
    global _model
    if _model is None:
        with _model_lock:
            if _model is None:
                from mlx_audio.tts.utils import load_model

                _model = load_model(MODEL_ID)
    return _model


def normalize_text(text: str) -> str:
    text = unicodedata.normalize("NFC", text)
    text = text.replace("\u00a0", " ").replace("\u202f", " ")
    text = re.sub(r"[ \t]+", " ", text)
    text = re.sub(r"\n{3,}", "\n\n", text)
    return text.strip()


def chunk_text(text: str, limit: int = 360) -> list[str]:
    """Split on sentence boundaries, then safely cap unusually long sentences."""
    text = normalize_text(text)
    sentences = re.split(r"(?<=[.!?…])\s+|\n+", text)
    chunks: list[str] = []
    current = ""
    for raw in sentences:
        sentence = raw.strip()
        if not sentence:
            continue
        pieces = [sentence]
        if len(sentence) > limit:
            pieces = []
            words = sentence.split()
            part = ""
            for word in words:
                if part and len(part) + len(word) + 1 > limit:
                    pieces.append(part)
                    part = word
                else:
                    part = f"{part} {word}".strip()
            if part:
                pieces.append(part)
        for piece in pieces:
            candidate = f"{current} {piece}".strip()
            if current and len(candidate) > limit:
                chunks.append(current)
                current = piece
            else:
                current = candidate
    if current:
        chunks.append(current)
    return chunks


def add_natural_hesitations(text: str, voice_id: str) -> str:
    """Add sparse, repeatable French fillers without changing core wording."""
    text = normalize_text(text)
    if len(text) < 45:
        return text

    seed_material = f"{voice_id}\0{text}".encode("utf-8")
    seed = int.from_bytes(hashlib.sha256(seed_material).digest()[:8], "big")
    rng = random.Random(seed)
    candidates = list(re.finditer(r"[,;:]\s+|(?<=[.!?…])\s+", text))
    if not candidates:
        words = list(re.finditer(r"\s+", text))
        if not words:
            return text
        candidates = [words[len(words) // 2]]

    # Roughly one audible filler per 450 characters, never more than four.
    count = min(4, max(1, len(text) // 450))
    chosen = sorted(rng.sample(candidates, min(count, len(candidates))), key=lambda m: m.end(), reverse=True)
    fillers = ["euh… ", "hum… "]
    for match in chosen:
        filler = rng.choice(fillers)
        text = text[: match.end()] + filler + text[match.end() :]

    # A sparse silent hesitation in addition to the spoken fillers.
    commas = list(re.finditer(r",\s+", text))
    if commas:
        pause = rng.choice(commas)
        text = text[: pause.start()] + "… " + text[pause.end() :]
    return text


def trim_noisy_edges(samples: np.ndarray, sample_rate: int) -> np.ndarray:
    """Remove low-level model noise before/after speech and add click-free fades."""
    samples = np.asarray(samples, dtype=np.float32).reshape(-1)
    if samples.size < sample_rate // 10:
        return samples
    frame = max(1, int(sample_rate * 0.02))
    energy = np.sqrt(
        np.convolve(np.square(samples), np.ones(frame, dtype=np.float32) / frame, mode="same")
    )
    peak_rms = float(np.percentile(energy, 95))
    # Deliberately conservative: retain breaths and soft consonants.
    threshold = max(0.0012, peak_rms * 0.025)
    active = np.flatnonzero(energy >= threshold)
    if active.size == 0:
        return samples
    padding = int(sample_rate * 0.110)
    start = max(0, int(active[0]) - padding)
    end = min(samples.size, int(active[-1]) + padding + 1)
    cleaned = samples[start:end].copy()
    fade = min(int(sample_rate * 0.025), cleaned.size // 2)
    if fade > 1:
        cleaned[:fade] *= np.linspace(0, 1, fade, dtype=np.float32)
        cleaned[-fade:] *= np.linspace(1, 0, fade, dtype=np.float32)
    return cleaned


def cleaned_reference(directory: Path) -> Path:
    """Create a denoised reference once, including for profiles made by older builds."""
    source = directory / "reference.wav"
    target = directory / "reference-clean.wav"
    if not target.exists() or target.stat().st_mtime < source.stat().st_mtime:
        _run([
            "/opt/homebrew/bin/ffmpeg" if Path("/opt/homebrew/bin/ffmpeg").exists() else "ffmpeg",
            "-y", "-i", str(source),
            "-af", "highpass=f=70,lowpass=f=11000,afftdn=nr=8:nf=-48:tn=1",
            str(target),
        ])
    return target


@app.get("/health")
def health() -> dict:
    return {"status": "ok", "model_loaded": _model is not None}


@app.get("/api/voices")
def list_voices() -> list[dict]:
    profiles = []
    for directory in VOICES_DIR.iterdir():
        if directory.is_dir() and (directory / "profile.json").exists():
            try:
                profiles.append(_profile(directory))
            except HTTPException:
                continue
    return sorted(profiles, key=lambda item: item["created_at"], reverse=True)


@app.post("/api/voices")
def enroll_voice(request: EnrollRequest) -> dict:
    voice_id = str(uuid.uuid4())
    directory = VOICES_DIR / voice_id
    directory.mkdir()
    incoming = directory / "incoming.m4a"
    reference = directory / "reference.wav"
    normalized = directory / "reference-normalized.wav"
    try:
        incoming.write_bytes(_decode_payload(request.audio_base64))
        _run([
            "/opt/homebrew/bin/ffmpeg" if Path("/opt/homebrew/bin/ffmpeg").exists() else "ffmpeg",
            "-y", "-i", str(incoming), "-ac", "1", "-ar", "24000",
            "-af", "highpass=f=70,lowpass=f=11000", str(reference),
        ])
        duration = _probe_duration(reference)
        if duration < 8:
            raise HTTPException(422, "L’échantillon doit durer au moins 8 secondes.")
        if duration > 45:
            raise HTTPException(422, "L’échantillon doit durer moins de 45 secondes.")
        samples, _ = sf.read(reference, dtype="float32", always_2d=False)
        samples = np.asarray(samples, dtype=np.float32).reshape(-1)
        peak = float(np.max(np.abs(samples))) if samples.size else 0.0
        rms = float(np.sqrt(np.mean(np.square(samples)))) if samples.size else 0.0
        peak_db = 20 * np.log10(max(peak, 1e-9))
        rms_db = 20 * np.log10(max(rms, 1e-9))
        if peak_db < -40 or rms_db < -55:
            raise HTTPException(
                422,
                "L’enregistrement est silencieux ou trop faible. Vérifiez le microphone et recommencez en surveillant le vumètre.",
            )
        _run([
            "/opt/homebrew/bin/ffmpeg" if Path("/opt/homebrew/bin/ffmpeg").exists() else "ffmpeg",
            "-y", "-i", str(reference),
            "-af", "loudnorm=I=-20:TP=-2:LRA=11", str(normalized),
        ])
        normalized.replace(reference)
        profile = {
            "id": voice_id,
            "name": request.name.strip(),
            "created_at": datetime.now(timezone.utc).isoformat(),
            "duration": round(duration, 2),
        }
        (directory / "transcript.txt").write_text(request.transcript.strip(), encoding="utf-8")
        (directory / "profile.json").write_text(
            json.dumps(profile, ensure_ascii=False, indent=2), encoding="utf-8"
        )
        incoming.unlink(missing_ok=True)
        return profile
    except Exception:
        shutil.rmtree(directory, ignore_errors=True)
        raise


@app.delete("/api/voices/{voice_id}")
def delete_voice(voice_id: str) -> dict:
    directory = _voice_dir(voice_id)
    profile = _profile(directory)
    shutil.rmtree(directory)
    return profile


@app.post("/api/extract")
def extract_document(request: ExtractRequest) -> dict:
    payload = _decode_payload(request.data_base64, maximum=12 * 1024 * 1024)
    suffix = Path(request.filename).suffix.lower()
    try:
        if suffix in {".txt", ".md", ".rtf"}:
            text = payload.decode("utf-8-sig")
        elif suffix == ".pdf":
            reader = PdfReader(io.BytesIO(payload))
            text = "\n\n".join(page.extract_text() or "" for page in reader.pages)
        elif suffix == ".docx":
            document = Document(io.BytesIO(payload))
            text = "\n".join(paragraph.text for paragraph in document.paragraphs)
        else:
            raise HTTPException(415, "Format non pris en charge. Utilisez TXT, PDF ou DOCX.")
    except HTTPException:
        raise
    except Exception as exc:
        raise HTTPException(422, "Impossible d’extraire le texte de ce document.") from exc
    text = normalize_text(text)
    if not text:
        raise HTTPException(422, "Ce document ne contient aucun texte extractible.")
    if len(text) > 20_000:
        raise HTTPException(422, "Le document dépasse la limite de 20 000 caractères.")
    return {"text": text}


@app.post("/api/generate")
def generate(request: GenerateRequest) -> dict:
    directory = _voice_dir(request.voice_id)
    reference = cleaned_reference(directory)
    prepared_text = (
        add_natural_hesitations(request.text, request.voice_id)
        if request.hesitations
        else request.text
    )
    chunks = chunk_text(prepared_text)
    if not chunks:
        raise HTTPException(422, "Le texte est vide.")

    model = _get_model()
    rendered: list[np.ndarray] = []
    sample_rate = 24_000
    with _model_lock:
        for index, chunk in enumerate(chunks):
            try:
                # Use the speaker x-vector only. Qwen3-TTS ICL mode (ref_audio +
                # ref_text) can echo the reference transcript at every segment.
                # A stable per-profile seed and conservative sampling keep the
                # same speaker identity across independently rendered chunks.
                import mlx.core as mx

                voice_seed = uuid.UUID(request.voice_id).int % 2_147_483_647
                mx.random.seed(voice_seed)
                results = list(model.generate(
                    text=chunk,
                    lang_code="French",
                    ref_audio=str(reference),
                    ref_text=None,
                    temperature=0.55,
                    top_k=20,
                    top_p=0.9,
                    repetition_penalty=1.1,
                    stream=False,
                ))
            except Exception as exc:
                raise HTTPException(
                    500, f"Échec de synthèse au segment {index + 1}: {exc}"
                ) from exc
            if not results:
                raise HTTPException(500, f"Le segment {index + 1} n’a produit aucun son.")
            result = results[0]
            audio = result.audio
            try:
                import mlx.core as mx
                mx.eval(audio)
            except Exception:
                pass
            samples = np.asarray(audio, dtype=np.float32).squeeze()
            if samples.size == 0:
                raise HTTPException(500, f"Le segment {index + 1} est vide.")
            sample_rate = int(getattr(result, "sample_rate", sample_rate) or sample_rate)
            samples = trim_noisy_edges(samples, sample_rate)
            # A short clean preroll prevents phrases from feeling abruptly cut in.
            rendered.append(np.zeros(int(sample_rate * 0.075), dtype=np.float32))
            rendered.append(samples)
            if index < len(chunks) - 1:
                pause = 0.30 if chunk.endswith((".", "!", "?", "…")) else 0.16
                rendered.append(np.zeros(int(sample_rate * pause), dtype=np.float32))

    waveform = np.concatenate(rendered)
    peak = float(np.max(np.abs(waveform)))
    if peak > 0.98:
        waveform = waveform * (0.98 / peak)

    job_id = str(uuid.uuid4())
    wav_path = TEMP_DIR / f"{job_id}.wav"
    mp3_path = OUTPUTS_DIR / f"{job_id}.mp3"
    sf.write(wav_path, waveform, sample_rate, subtype="PCM_16")
    cleanup_filters = [
        "highpass=f=65",
        "lowpass=f=11000",
        "afftdn=nr=6:nf=-52:tn=1",
        "agate=threshold=0.0025:ratio=2:attack=3:release=260",
    ]
    if request.speed != 1:
        cleanup_filters.append(f"atempo={request.speed:.2f}")
    audio_filter = ",".join(cleanup_filters)
    _run([
        "/opt/homebrew/bin/ffmpeg" if Path("/opt/homebrew/bin/ffmpeg").exists() else "ffmpeg",
        "-y", "-i", str(wav_path), "-af", audio_filter,
        "-codec:a", "libmp3lame", "-q:a", "2",
        "-metadata", "comment=Audio synthétique généré localement par VoixLocale",
        str(mp3_path),
    ])
    wav_path.unlink(missing_ok=True)
    duration = _probe_duration(mp3_path)
    return {"path": str(mp3_path), "duration": duration, "segments": len(chunks)}
