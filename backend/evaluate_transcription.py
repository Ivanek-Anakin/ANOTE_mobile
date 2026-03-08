"""Whisper + VAD transcription quality evaluation for ANOTE.

Sweeps VAD/Whisper parameters on Hurvínek MP3 test files and measures
WER/CER against reference (human) transcripts.

Mirrors the Dart transcribeFull() pipeline from whisper_service.dart:
  1. Fresh Silero VAD pass over entire audio → speech segments
  2. Concatenate speech segments
  3. If ≤ 30s: single-shot Whisper transcription
  4. If > 30s: 15s chunks with 3s overlap + word deduplication

Usage:
    # Default smart sweep (one-at-a-time, ~45 runs)
    python evaluate_transcription.py

    # Single config test
    python evaluate_transcription.py --threshold 0.45 --min-silence 0.5 \
        --min-speech 0.25 --tail-paddings 800

    # Full sweep (all combos — very slow)
    python evaluate_transcription.py --full-sweep

    # Custom audio directory
    python evaluate_transcription.py --audio-dir ../testing_hurvinek/
"""

import argparse
import json
import os
import re
import struct
import subprocess
import sys
import time
import wave
from dataclasses import dataclass, field, asdict
from datetime import datetime
from pathlib import Path
from typing import Optional

import numpy as np

# ── Ensure jiwer is installed ────────────────────────────────────────────────

try:
    import jiwer
except ImportError:
    print("Installing jiwer…")
    subprocess.check_call([sys.executable, "-m", "pip", "install", "jiwer", "-q"])
    import jiwer

import sherpa_onnx

# ── Constants ────────────────────────────────────────────────────────────────

SAMPLE_RATE = 16000

MODEL_FILES = {
    "small-encoder.int8.onnx": (
        "https://huggingface.co/csukuangfj/sherpa-onnx-whisper-small/resolve/main/small-encoder.int8.onnx"
    ),
    "small-decoder.int8.onnx": (
        "https://huggingface.co/csukuangfj/sherpa-onnx-whisper-small/resolve/main/small-decoder.int8.onnx"
    ),
    "small-tokens.txt": (
        "https://huggingface.co/csukuangfj/sherpa-onnx-whisper-small/resolve/main/small-tokens.txt"
    ),
    "silero_vad.onnx": (
        "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/silero_vad.onnx"
    ),
}

# Minimum valid file sizes (conservative — catches truncated downloads)
MIN_SIZES = {
    "small-encoder.int8.onnx": 50 * 1024 * 1024,  # ≥ 50 MB
    "small-decoder.int8.onnx": 50 * 1024 * 1024,
    "small-tokens.txt": 10 * 1024,                  # ≥ 10 KB
    "silero_vad.onnx": 300 * 1024,                   # ≥ 300 KB
}

# Defaults from whisper_service.dart (live VAD uses 0.5, final pass uses 0.45)
DEFAULT_THRESHOLD = 0.45
DEFAULT_MIN_SILENCE = 0.5
DEFAULT_MIN_SPEECH = 0.25
DEFAULT_TAIL_PADDINGS = 800

# Smart sweep values (from TRANSCRIPTION_EVAL_SPEC.md §3.1)
SWEEP_THRESHOLD = [0.3, 0.4, 0.45, 0.5, 0.6]
SWEEP_MIN_SILENCE = [0.3, 0.5, 0.8, 1.0]
SWEEP_MIN_SPEECH = [0.1, 0.25, 0.5]
SWEEP_TAIL_PADDINGS = [400, 800, 1200]


# ── Data classes ─────────────────────────────────────────────────────────────


@dataclass
class VADConfig:
    """VAD + Whisper parameter configuration."""

    threshold: float = DEFAULT_THRESHOLD
    min_silence_duration: float = DEFAULT_MIN_SILENCE
    min_speech_duration: float = DEFAULT_MIN_SPEECH
    tail_paddings: int = DEFAULT_TAIL_PADDINGS

    def label(self) -> str:
        return (
            f"thr={self.threshold} sil={self.min_silence_duration} "
            f"sp={self.min_speech_duration} pad={self.tail_paddings}"
        )


@dataclass
class TranscriptionResult:
    """Result of a single transcription run."""

    config: VADConfig
    scenario: str
    wer: float
    cer: float
    speech_duration_ratio: float
    segment_count: int
    speech_seconds: float
    total_seconds: float
    transcript: str
    reference: str
    elapsed_s: float


# ── Model management ─────────────────────────────────────────────────────────


def ensure_models(model_dir: Path) -> None:
    """Download Whisper INT8 + Silero VAD models if not already present."""
    model_dir.mkdir(parents=True, exist_ok=True)

    for filename, url in MODEL_FILES.items():
        filepath = model_dir / filename
        min_size = MIN_SIZES.get(filename, 0)

        if filepath.exists() and filepath.stat().st_size >= min_size:
            continue

        if filepath.exists():
            print(f"  ⚠ {filename} too small ({filepath.stat().st_size} bytes), re-downloading.")
            filepath.unlink()

        print(f"  ↓ Downloading {filename}…", end="", flush=True)
        tmp_path = filepath.with_suffix(".tmp")

        for attempt in range(3):
            try:
                import urllib.request

                urllib.request.urlretrieve(url, str(tmp_path))
                downloaded_size = tmp_path.stat().st_size

                if downloaded_size < min_size:
                    tmp_path.unlink(missing_ok=True)
                    raise ValueError(
                        f"Downloaded {filename} too small: "
                        f"{downloaded_size} < {min_size} bytes"
                    )

                tmp_path.rename(filepath)
                print(f" OK ({downloaded_size / 1024 / 1024:.1f} MB)")
                break
            except Exception as e:
                tmp_path.unlink(missing_ok=True)
                if attempt < 2:
                    wait = 2 ** attempt * 5
                    print(f" retry in {wait}s ({e})…", end="", flush=True)
                    time.sleep(wait)
                else:
                    print(f" FAILED: {e}")
                    raise


# ── Audio conversion ─────────────────────────────────────────────────────────


def convert_mp3_to_wav(mp3_path: Path, cache_dir: Optional[Path] = None) -> Path:
    """Convert MP3 to 16kHz mono 16-bit WAV using macOS afconvert.

    Caches converted files to avoid re-conversion on subsequent runs.
    """
    if cache_dir is None:
        cache_dir = mp3_path.parent

    # Use a deterministic cache name based on the original filename
    wav_name = mp3_path.stem + ".wav"
    wav_path = cache_dir / wav_name

    if wav_path.exists() and wav_path.stat().st_size > 1000:
        return wav_path

    print(f"  ♻ Converting {mp3_path.name} → WAV…", end="", flush=True)
    result = subprocess.run(
        [
            "afconvert",
            "-f", "WAVE",
            "-d", "LEI16@16000",
            "-c", "1",
            str(mp3_path),
            str(wav_path),
        ],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        raise RuntimeError(f"afconvert failed: {result.stderr}")

    print(f" OK ({wav_path.stat().st_size / 1024:.0f} KB)")
    return wav_path


def read_wav_samples(wav_path: Path) -> np.ndarray:
    """Read a 16kHz mono WAV file and return float32 samples in [-1, 1]."""
    with wave.open(str(wav_path), "rb") as wf:
        assert wf.getnchannels() == 1, f"Expected mono, got {wf.getnchannels()} channels"
        assert wf.getsampwidth() == 2, f"Expected 16-bit, got {wf.getsampwidth() * 8}-bit"
        assert wf.getframerate() == SAMPLE_RATE, f"Expected {SAMPLE_RATE}Hz, got {wf.getframerate()}Hz"
        n_frames = wf.getnframes()
        raw_data = wf.readframes(n_frames)

    samples = np.frombuffer(raw_data, dtype=np.int16).astype(np.float32) / 32768.0
    return samples


# ── Reference text normalization ─────────────────────────────────────────────


def load_reference_text(txt_path: Path) -> str:
    """Load and normalize a reference transcript for WER/CER comparison.

    Strips UniScribe watermarks, lowercases, removes punctuation,
    and collapses whitespace.
    """
    raw = txt_path.read_text(encoding="utf-8")
    return normalize_text(raw)


def normalize_text(text: str) -> str:
    """Normalize text for fair WER/CER comparison.

    - Strip UniScribe watermark lines
    - Lowercase
    - Remove punctuation
    - Collapse whitespace
    """
    lines = text.strip().splitlines()
    # Remove UniScribe watermark lines (case-insensitive)
    lines = [l for l in lines if "uniscribe" not in l.lower()]
    text = " ".join(lines)

    text = text.lower()
    # Remove punctuation but keep letters (including Czech diacritics), digits, spaces
    text = re.sub(r"[^\w\s]", " ", text, flags=re.UNICODE)
    # Collapse whitespace
    text = re.sub(r"\s+", " ", text).strip()
    return text


# ── VAD + Whisper transcription pipeline ─────────────────────────────────────


def extract_speech_segments(
    samples: np.ndarray,
    model_dir: Path,
    config: VADConfig,
) -> list[np.ndarray]:
    """Run Silero VAD over audio and extract speech segments.

    Mirrors whisper_service.dart _extractSpeechSegments().
    """
    vad_model_path = str(model_dir / "silero_vad.onnx")

    vad_config = sherpa_onnx.VadModelConfig(
        silero_vad=sherpa_onnx.SileroVadModelConfig(
            model=vad_model_path,
            threshold=config.threshold,
            min_silence_duration=config.min_silence_duration,
            min_speech_duration=config.min_speech_duration,
            max_speech_duration=30.0,
            window_size=512,
        ),
        sample_rate=SAMPLE_RATE,
        num_threads=1,
        provider="cpu",
        debug=False,
    )

    vad = sherpa_onnx.VoiceActivityDetector(vad_config, buffer_size_in_seconds=120.0)

    segments: list[np.ndarray] = []
    window_size = 512

    for i in range(0, len(samples), window_size):
        chunk = samples[i : i + window_size]
        # Pad last chunk if needed
        if len(chunk) < window_size:
            padded = np.zeros(window_size, dtype=np.float32)
            padded[: len(chunk)] = chunk
            chunk = padded

        vad.accept_waveform(chunk.tolist())

        while not vad.empty():
            seg = vad.front
            # IMPORTANT: copy samples BEFORE pop() — vad.front returns a
            # reference that is invalidated by any subsequent VAD method call.
            seg_samples = list(seg.samples)
            vad.pop()
            if len(seg_samples) > 0:
                segments.append(np.array(seg_samples, dtype=np.float32))

    # Flush remaining speech
    vad.flush()
    while not vad.empty():
        seg = vad.front
        seg_samples = list(seg.samples)
        vad.pop()
        if len(seg_samples) > 0:
            segments.append(np.array(seg_samples, dtype=np.float32))

    return segments


def create_recognizer(
    model_dir: Path,
    tail_paddings: int = DEFAULT_TAIL_PADDINGS,
) -> "sherpa_onnx.OfflineRecognizer":
    """Create a Whisper Small INT8 recognizer (reuse across chunks)."""
    return sherpa_onnx.OfflineRecognizer.from_whisper(
        encoder=str(model_dir / "small-encoder.int8.onnx"),
        decoder=str(model_dir / "small-decoder.int8.onnx"),
        tokens=str(model_dir / "small-tokens.txt"),
        language="cs",
        task="transcribe",
        tail_paddings=tail_paddings,
        num_threads=2,
        debug=False,
        provider="cpu",
    )


def transcribe_samples(
    samples: np.ndarray,
    recognizer: "sherpa_onnx.OfflineRecognizer",
) -> str:
    """Run Whisper Small INT8 on audio samples. Returns transcribed text."""
    stream = recognizer.create_stream()
    stream.accept_waveform(SAMPLE_RATE, samples.tolist())
    recognizer.decode_stream(stream)
    result = stream.result.text.strip()
    return result


def _normalize_word(word: str) -> str:
    """Normalize a word for overlap deduplication (mirrors Dart _normalizeWord)."""
    w = word.lower()
    for src, dst in [
        ("á", "a"), ("à", "a"),
        ("é", "e"), ("ě", "e"),
        ("í", "i"), ("ì", "i"),
        ("ó", "o"), ("ò", "o"),
        ("ú", "u"), ("ů", "u"), ("ù", "u"),
        ("ý", "y"),
        ("č", "c"), ("š", "s"), ("ž", "z"),
        ("ř", "r"), ("ň", "n"), ("ď", "d"), ("ť", "t"),
    ]:
        w = w.replace(src, dst)
    w = re.sub(r"[.,;:!?]", "", w)
    return w


def _last_words(text: str, n: int) -> str:
    """Return the last n words of text."""
    words = text.split()
    if len(words) <= n:
        return text
    return " ".join(words[-n:])


def remove_overlap(previous_tail: str, new_text: str) -> str:
    """Remove words from the start of new_text that overlap with previous_tail.

    Mirrors whisper_service.dart removeOverlap().
    """
    if not previous_tail or not new_text:
        return new_text

    tail_words = [_normalize_word(w) for w in previous_tail.split() if w]
    new_words = [w for w in new_text.split() if w]
    normalized_new = [_normalize_word(w) for w in new_words]

    max_len = min(len(tail_words), len(normalized_new))
    for length in range(max_len, 0, -1):
        tail_suffix = tail_words[-length:]
        new_prefix = normalized_new[:length]
        if tail_suffix == new_prefix:
            return " ".join(new_words[length:])
    return new_text


def transcribe_full(
    samples: np.ndarray,
    model_dir: Path,
    config: VADConfig,
) -> tuple[str, int, float]:
    """Full transcription pipeline mirroring Dart transcribeFull().

    Returns (transcript, segment_count, speech_seconds).
    """
    total_seconds = len(samples) / SAMPLE_RATE

    # 1. Extract speech segments via VAD
    segments = extract_speech_segments(samples, model_dir, config)

    if not segments:
        return "", 0, 0.0

    segment_count = len(segments)

    # 2. Calculate speech duration
    total_speech_samples = sum(len(seg) for seg in segments)
    speech_seconds = total_speech_samples / SAMPLE_RATE

    # 3. Concatenate all speech
    all_speech = np.concatenate(segments)

    # 4. Create recognizer once for all chunks
    recognizer = create_recognizer(model_dir, config.tail_paddings)

    # 5. Transcribe
    max_single_pass = 30 * SAMPLE_RATE  # 30s

    if len(all_speech) <= max_single_pass:
        # Short speech — single shot
        transcript = transcribe_samples(all_speech, recognizer)
        return transcript, segment_count, speech_seconds

    # Longer speech — chunk with overlap (mirrors Dart logic exactly)
    chunk_size = 15 * SAMPLE_RATE   # 15s chunks
    overlap = 3 * SAMPLE_RATE       # 3s overlap
    parts: list[str] = []
    prev_tail = ""

    start = 0
    while start < len(all_speech):
        end = min(start + chunk_size, len(all_speech))
        chunk = all_speech[start:end]

        try:
            text = transcribe_samples(chunk, recognizer)
            if text:
                deduped = remove_overlap(prev_tail, text)
                if deduped:
                    parts.append(deduped)
                prev_tail = _last_words(text, 20)
        except Exception as e:
            print(f"    ⚠ Chunk error at {start / SAMPLE_RATE:.1f}s: {e}")

        start += chunk_size - overlap

    transcript = " ".join(parts)
    return transcript, segment_count, speech_seconds


# ── Metrics ──────────────────────────────────────────────────────────────────


def compute_metrics(
    hypothesis: str,
    reference: str,
    speech_seconds: float,
    total_seconds: float,
    segment_count: int,
) -> dict:
    """Compute WER, CER, speech ratio, and segment count."""
    # Normalize both sides for comparison
    hyp_norm = normalize_text(hypothesis)
    ref_norm = reference  # Already normalized when loaded

    # Handle empty cases
    if not ref_norm:
        return {
            "wer": 0.0 if not hyp_norm else 1.0,
            "cer": 0.0 if not hyp_norm else 1.0,
            "speech_duration_ratio": speech_seconds / total_seconds if total_seconds > 0 else 0.0,
            "segment_count": segment_count,
        }

    wer = jiwer.wer(ref_norm, hyp_norm) if hyp_norm else 1.0
    cer = jiwer.cer(ref_norm, hyp_norm) if hyp_norm else 1.0

    return {
        "wer": round(wer, 4),
        "cer": round(cer, 4),
        "speech_duration_ratio": round(speech_seconds / total_seconds, 4) if total_seconds > 0 else 0.0,
        "segment_count": segment_count,
    }


# ── Sweep logic ──────────────────────────────────────────────────────────────


def build_smart_sweep_configs() -> dict[str, list[VADConfig]]:
    """Build one-at-a-time sweep configs (from TRANSCRIPTION_EVAL_SPEC.md §3.1).

    Returns dict mapping parameter name → list of configs to test.
    """
    configs: dict[str, list[VADConfig]] = {}

    # Sweep threshold, hold others at default
    configs["threshold"] = [
        VADConfig(threshold=v) for v in SWEEP_THRESHOLD
    ]

    # Sweep min_silence_duration
    configs["min_silence_duration"] = [
        VADConfig(min_silence_duration=v) for v in SWEEP_MIN_SILENCE
    ]

    # Sweep min_speech_duration
    configs["min_speech_duration"] = [
        VADConfig(min_speech_duration=v) for v in SWEEP_MIN_SPEECH
    ]

    # Sweep tail_paddings
    configs["tail_paddings"] = [
        VADConfig(tail_paddings=v) for v in SWEEP_TAIL_PADDINGS
    ]

    return configs


def build_full_sweep_configs() -> list[VADConfig]:
    """Build full cross-product sweep (5×4×3×3 = 180 configs)."""
    configs: list[VADConfig] = []
    for thr in SWEEP_THRESHOLD:
        for sil in SWEEP_MIN_SILENCE:
            for sp in SWEEP_MIN_SPEECH:
                for pad in SWEEP_TAIL_PADDINGS:
                    configs.append(VADConfig(
                        threshold=thr,
                        min_silence_duration=sil,
                        min_speech_duration=sp,
                        tail_paddings=pad,
                    ))
    return configs


# ── Core evaluation runner ───────────────────────────────────────────────────


def run_single_config(
    config: VADConfig,
    audio_files: list[tuple[Path, np.ndarray, str]],
    model_dir: Path,
) -> list[TranscriptionResult]:
    """Run transcription with a single config on all audio files.

    audio_files: list of (mp3_path, wav_samples, normalized_reference_text)
    """
    results: list[TranscriptionResult] = []

    for mp3_path, samples, ref_text in audio_files:
        scenario = mp3_path.stem
        total_seconds = len(samples) / SAMPLE_RATE

        t0 = time.time()
        transcript, seg_count, speech_sec = transcribe_full(samples, model_dir, config)
        elapsed = time.time() - t0

        metrics = compute_metrics(
            transcript, ref_text, speech_sec, total_seconds, seg_count
        )

        result = TranscriptionResult(
            config=config,
            scenario=scenario,
            wer=metrics["wer"],
            cer=metrics["cer"],
            speech_duration_ratio=metrics["speech_duration_ratio"],
            segment_count=metrics["segment_count"],
            speech_seconds=round(speech_sec, 1),
            total_seconds=round(total_seconds, 1),
            transcript=transcript,
            reference=ref_text,
            elapsed_s=round(elapsed, 1),
        )
        results.append(result)

    return results


# ── Console output ───────────────────────────────────────────────────────────


def print_sweep_header(param_name: str) -> None:
    """Print a parameter sweep section header."""
    print(f"\nParameter: {param_name} (others at default)")
    print("─" * 100)
    print(
        f"{'Value':>8}  {'Scenario':<45} {'WER%':>6} {'CER%':>6} "
        f"{'Speech%':>7} {'Segs':>5} {'Time':>6}"
    )
    print("─" * 100)


def print_result_row(param_value: str, result: TranscriptionResult) -> None:
    """Print a single result row in the sweep table."""
    # Truncate scenario name for display
    scenario = result.scenario[:43]
    print(
        f"{param_value:>8}  {scenario:<45} "
        f"{result.wer * 100:>5.1f}% {result.cer * 100:>5.1f}% "
        f"{result.speech_duration_ratio * 100:>6.1f}% {result.segment_count:>5} "
        f"{result.elapsed_s:>5.1f}s"
    )


def print_best_config(all_results: list[TranscriptionResult]) -> None:
    """Find and print the best config by mean WER."""
    # Group by config
    config_scores: dict[str, list[float]] = {}
    config_cer: dict[str, list[float]] = {}
    config_map: dict[str, VADConfig] = {}

    for r in all_results:
        key = r.config.label()
        config_scores.setdefault(key, []).append(r.wer)
        config_cer.setdefault(key, []).append(r.cer)
        config_map[key] = r.config

    best_key = min(config_scores, key=lambda k: sum(config_scores[k]) / len(config_scores[k]))
    best_config = config_map[best_key]
    mean_wer = sum(config_scores[best_key]) / len(config_scores[best_key])
    mean_cer = sum(config_cer[best_key]) / len(config_cer[best_key])

    print(f"\n{'═' * 80}")
    print("  BEST CONFIG:")
    print(
        f"  threshold={best_config.threshold}, "
        f"min_silence={best_config.min_silence_duration}, "
        f"min_speech={best_config.min_speech_duration}, "
        f"tail_paddings={best_config.tail_paddings}"
    )
    print(f"  Mean WER: {mean_wer * 100:.1f}%  Mean CER: {mean_cer * 100:.1f}%")
    print(f"{'═' * 80}\n")


# ── JSON output ──────────────────────────────────────────────────────────────


def save_results(
    all_results: list[TranscriptionResult],
    output_path: Path,
    mode: str,
) -> None:
    """Save full results to JSON."""
    # Group by config for readability
    results_json: list[dict] = []
    for r in all_results:
        results_json.append({
            "config": {
                "threshold": r.config.threshold,
                "min_silence_duration": r.config.min_silence_duration,
                "min_speech_duration": r.config.min_speech_duration,
                "tail_paddings": r.config.tail_paddings,
            },
            "scenario": r.scenario,
            "metrics": {
                "wer": r.wer,
                "cer": r.cer,
                "speech_duration_ratio": r.speech_duration_ratio,
                "segment_count": r.segment_count,
                "speech_seconds": r.speech_seconds,
                "total_seconds": r.total_seconds,
            },
            "transcript": r.transcript,
            "reference": r.reference,
            "elapsed_s": r.elapsed_s,
        })

    # Compute aggregate stats
    config_scores: dict[str, list[float]] = {}
    config_cer: dict[str, list[float]] = {}
    config_map: dict[str, dict] = {}

    for r in all_results:
        key = r.config.label()
        config_scores.setdefault(key, []).append(r.wer)
        config_cer.setdefault(key, []).append(r.cer)
        config_map[key] = {
            "threshold": r.config.threshold,
            "min_silence_duration": r.config.min_silence_duration,
            "min_speech_duration": r.config.min_speech_duration,
            "tail_paddings": r.config.tail_paddings,
        }

    best_key = min(config_scores, key=lambda k: sum(config_scores[k]) / len(config_scores[k]))

    output = {
        "metadata": {
            "date": datetime.now().isoformat(),
            "mode": mode,
            "sherpa_onnx_version": sherpa_onnx.__version__,
            "num_results": len(results_json),
        },
        "best_config": {
            **config_map[best_key],
            "mean_wer": round(sum(config_scores[best_key]) / len(config_scores[best_key]), 4),
            "mean_cer": round(sum(config_cer[best_key]) / len(config_cer[best_key]), 4),
        },
        "results": results_json,
    }

    output_path.write_text(json.dumps(output, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"Results saved to: {output_path.resolve()}")


# ── Main pipeline ────────────────────────────────────────────────────────────


def load_audio_files(
    audio_dir: Path, wav_cache_dir: Path
) -> list[tuple[Path, np.ndarray, str]]:
    """Load and convert all MP3 + reference .txt pairs from audio_dir.

    Returns list of (mp3_path, wav_samples, normalized_reference_text).
    """
    mp3_files = sorted(audio_dir.glob("*.mp3"))
    if not mp3_files:
        print(f"Error: no .mp3 files found in '{audio_dir}'.")
        sys.exit(1)

    wav_cache_dir.mkdir(parents=True, exist_ok=True)
    audio_files: list[tuple[Path, np.ndarray, str]] = []

    for mp3 in mp3_files:
        # Find matching .txt reference
        txt = mp3.with_suffix(".txt")
        if not txt.exists():
            print(f"  ⚠ Skipping {mp3.name} — no matching .txt reference found.")
            continue

        try:
            wav_path = convert_mp3_to_wav(mp3, wav_cache_dir)
            samples = read_wav_samples(wav_path)
            ref_text = load_reference_text(txt)
            audio_files.append((mp3, samples, ref_text))
            duration = len(samples) / SAMPLE_RATE
            print(f"  ✓ {mp3.name} ({duration:.1f}s, {len(ref_text.split())} ref words)")
        except Exception as e:
            print(f"  ⚠ Skipping {mp3.name} — error: {e}")

    if not audio_files:
        print("Error: no valid audio/reference pairs found.")
        sys.exit(1)

    return audio_files


def run_smart_sweep(
    audio_files: list[tuple[Path, np.ndarray, str]],
    model_dir: Path,
    output_path: Path,
) -> list[TranscriptionResult]:
    """Run the smart sweep (one parameter at a time)."""
    sweep_configs = build_smart_sweep_configs()
    all_results: list[TranscriptionResult] = []

    total_runs = sum(len(cfgs) * len(audio_files) for cfgs in sweep_configs.values())
    run_idx = 0

    for param_name, configs in sweep_configs.items():
        print_sweep_header(param_name)

        for config in configs:
            # Determine the swept parameter value for display
            if param_name == "threshold":
                param_val = str(config.threshold)
            elif param_name == "min_silence_duration":
                param_val = str(config.min_silence_duration)
            elif param_name == "min_speech_duration":
                param_val = str(config.min_speech_duration)
            elif param_name == "tail_paddings":
                param_val = str(config.tail_paddings)
            else:
                param_val = "?"

            results = run_single_config(config, audio_files, model_dir)
            for r in results:
                run_idx += 1
                print_result_row(param_val, r)
            all_results.extend(results)

            # Show progress
            print(f"{'':>8}  {'':45} {'':>6} {'':>6} {'':>7} {'':>5} [{run_idx}/{total_runs}]")

        print("─" * 100)

    return all_results


def run_full_sweep(
    audio_files: list[tuple[Path, np.ndarray, str]],
    model_dir: Path,
    output_path: Path,
) -> list[TranscriptionResult]:
    """Run full cross-product sweep."""
    configs = build_full_sweep_configs()
    all_results: list[TranscriptionResult] = []

    total_runs = len(configs) * len(audio_files)
    run_idx = 0

    print(f"\nFull sweep: {len(configs)} configs × {len(audio_files)} files = {total_runs} runs")
    print("─" * 100)
    print(
        f"{'Config':<45} {'Scenario':<30} {'WER%':>6} {'CER%':>6} "
        f"{'Speech%':>7} {'Segs':>5} {'Time':>6}"
    )
    print("─" * 100)

    for config in configs:
        results = run_single_config(config, audio_files, model_dir)
        for r in results:
            run_idx += 1
            scenario = r.scenario[:28]
            label = config.label()[:43]
            print(
                f"{label:<45} {scenario:<30} "
                f"{r.wer * 100:>5.1f}% {r.cer * 100:>5.1f}% "
                f"{r.speech_duration_ratio * 100:>6.1f}% {r.segment_count:>5} "
                f"{r.elapsed_s:>5.1f}s  [{run_idx}/{total_runs}]"
            )
        all_results.extend(results)

    print("─" * 100)
    return all_results


def run_single(
    audio_files: list[tuple[Path, np.ndarray, str]],
    model_dir: Path,
    config: VADConfig,
) -> list[TranscriptionResult]:
    """Run a single configuration on all audio files."""
    print(f"\nSingle config: {config.label()}")
    print("─" * 100)
    print(
        f"{'Scenario':<50} {'WER%':>6} {'CER%':>6} "
        f"{'Speech%':>7} {'Segs':>5} {'Time':>6}"
    )
    print("─" * 100)

    results = run_single_config(config, audio_files, model_dir)
    for r in results:
        scenario = r.scenario[:48]
        print(
            f"{scenario:<50} "
            f"{r.wer * 100:>5.1f}% {r.cer * 100:>5.1f}% "
            f"{r.speech_duration_ratio * 100:>6.1f}% {r.segment_count:>5} "
            f"{r.elapsed_s:>5.1f}s"
        )

    print("─" * 100)

    # Mean row
    if results:
        mean_wer = sum(r.wer for r in results) / len(results)
        mean_cer = sum(r.cer for r in results) / len(results)
        mean_ratio = sum(r.speech_duration_ratio for r in results) / len(results)
        total_time = sum(r.elapsed_s for r in results)
        print(
            f"{'MEAN':<50} "
            f"{mean_wer * 100:>5.1f}% {mean_cer * 100:>5.1f}% "
            f"{mean_ratio * 100:>6.1f}% {'':>5} "
            f"{total_time:>5.1f}s"
        )

    return results


def main() -> None:
    """CLI entry point."""
    parser = argparse.ArgumentParser(
        description="ANOTE Whisper+VAD transcription quality evaluation — "
        "parameter sweep with WER/CER metrics"
    )
    parser.add_argument(
        "--audio-dir",
        default="../testing_hurvinek/",
        help="Directory containing .mp3 audio + .txt reference files "
        "(default: ../testing_hurvinek/)",
    )
    parser.add_argument(
        "--output",
        default="transcription_eval_results.json",
        help="Output JSON file path (default: transcription_eval_results.json)",
    )
    parser.add_argument(
        "--full-sweep",
        action="store_true",
        help="Run full cross-product sweep (180 configs × files — very slow!)",
    )
    parser.add_argument(
        "--threshold", type=float, default=None,
        help="VAD threshold (single config mode)",
    )
    parser.add_argument(
        "--min-silence", type=float, default=None,
        help="VAD min silence duration in seconds (single config mode)",
    )
    parser.add_argument(
        "--min-speech", type=float, default=None,
        help="VAD min speech duration in seconds (single config mode)",
    )
    parser.add_argument(
        "--tail-paddings", type=int, default=None,
        help="Whisper tail paddings (single config mode)",
    )

    args = parser.parse_args()
    audio_dir = Path(args.audio_dir)
    output_path = Path(args.output)
    if not output_path.is_absolute():
        output_path = Path(__file__).parent / output_path
    model_dir = Path(__file__).parent / "models"

    # Determine mode
    has_single_args = any([
        args.threshold is not None,
        args.min_silence is not None,
        args.min_speech is not None,
        args.tail_paddings is not None,
    ])

    if has_single_args:
        mode = "single"
    elif args.full_sweep:
        mode = "full-sweep"
    else:
        mode = "smart-sweep"

    # Header
    print(f"\n{'═' * 80}")
    print(f"  ANOTE Transcription Evaluation")
    print(f"  Mode: {mode}  |  Date: {datetime.now().strftime('%Y-%m-%d %H:%M')}")
    print(f"  Audio: {audio_dir.resolve()}")
    print(f"  Models: {model_dir.resolve()}")
    print(f"  sherpa-onnx: {sherpa_onnx.__version__}")
    print(f"{'═' * 80}")

    # Ensure models are downloaded
    print("\nChecking models…")
    ensure_models(model_dir)
    print("  ✓ All models ready.")

    # Load audio files
    print(f"\nLoading audio files from {audio_dir}…")
    wav_cache_dir = model_dir / "wav_cache"
    audio_files = load_audio_files(audio_dir, wav_cache_dir)
    print(f"  ✓ {len(audio_files)} audio/reference pairs loaded.\n")

    t_start = time.time()

    if mode == "single":
        config = VADConfig(
            threshold=args.threshold if args.threshold is not None else DEFAULT_THRESHOLD,
            min_silence_duration=args.min_silence if args.min_silence is not None else DEFAULT_MIN_SILENCE,
            min_speech_duration=args.min_speech if args.min_speech is not None else DEFAULT_MIN_SPEECH,
            tail_paddings=args.tail_paddings if args.tail_paddings is not None else DEFAULT_TAIL_PADDINGS,
        )
        all_results = run_single(audio_files, model_dir, config)
    elif mode == "full-sweep":
        all_results = run_full_sweep(audio_files, model_dir, output_path)
    else:
        all_results = run_smart_sweep(audio_files, model_dir, output_path)

    total_time = time.time() - t_start
    print(f"\nTotal time: {total_time:.0f}s ({total_time / 60:.1f} min)")

    # Save results
    save_results(all_results, output_path, mode)

    # Print best config
    if len(set(r.config.label() for r in all_results)) > 1:
        print_best_config(all_results)


if __name__ == "__main__":
    main()
