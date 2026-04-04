# Transcription Quality Evaluation — Whisper + VAD Parameter Sweep

## Tech Spec & Implementation Plan

**Date:** 1 March 2026  
**Status:** Planned  
**Script:** `backend/evaluate_transcription.py`

---

## 1. Goal

Test the exact same Whisper Small INT8 + Silero VAD pipeline the mobile app uses, but from Python, on the 3 Hurvínek `.mp3` files. Sweep VAD/Whisper parameters to find the best combination by comparing output transcripts against reference texts.

## 2. Available Resources

| Resource | Status |
|----------|--------|
| Audio files | 3 × MP3 in `testing_hurvinek/` (~7 min each) |
| Reference transcripts | 3 × `.txt` in `testing_hurvinek/` (human-made) |
| sherpa-onnx Python | v1.12.28 installed, confirmed working |
| Whisper model files | Need to download (~250MB) — same HuggingFace URLs as `whisper_service.dart:583` |
| Silero VAD model | Need to download (~2MB) — same URL as Dart code |
| MP3→WAV conversion | `afconvert` (macOS built-in) — no extra deps needed |
| WER computation | `jiwer` package (`pip install`) — standard WER/CER metric library |

## 3. Architecture

### 3.1 Parameter Sweep Matrix

**VAD parameters** (primary target — most impact on what reaches Whisper):

| Parameter | Values to test | Default (from Dart) |
|-----------|---------------|---------------------|
| `threshold` | 0.3, 0.4, 0.45, 0.5, 0.6 | 0.5 (live) / 0.45 (final) |
| `min_silence_duration` | 0.3, 0.5, 0.8, 1.0 | 0.5 |
| `min_speech_duration` | 0.1, 0.25, 0.5 | 0.25 |

**Whisper parameters** (secondary — fewer knobs):

| Parameter | Values to test | Default (from Dart) |
|-----------|---------------|---------------------|
| `tail_paddings` | 400, 800, 1200 | 800 |

**Full sweep** = 5 × 4 × 3 × 3 = 180 combos × 3 audio files = 540 runs. Too many.

**Smart sweep** (one-at-a-time, hold others at default):

- VAD threshold: 5 values × 3 files = 15 runs
- min_silence_duration: 4 values × 3 files = 12 runs
- min_speech_duration: 3 values × 3 files = 9 runs
- tail_paddings: 3 values × 3 files = 9 runs
- **Total: ~45 runs, likely ~20–30 min on laptop**

Then a focused "top-3 combos" full cross-product run on the winners.

### 3.2 Metrics

| Metric | What it measures | Library |
|--------|-----------------|---------|
| **WER** (Word Error Rate) | % of words wrong (insertions + deletions + substitutions / total words) | `jiwer` |
| **CER** (Character Error Rate) | Same but at character level — better for Czech (compound words, diacritics) | `jiwer` |
| **Speech duration ratio** | Total speech detected / total audio — catches over/under-filtering | Built-in |
| **Segment count** | How many speech segments VAD found — catches fragmentation issues | Built-in |

### 3.3 Output

- **Console table:** Each config → WER, CER, speech_ratio, segments per scenario
- **`transcription_eval_results.json`:** Full results with all transcripts for inspection
- **Best config recommendation** printed at end

## 4. Key Implementation Details

### 4.1 MP3 → WAV Conversion

Use `subprocess.run(["afconvert", "-f", "WAVE", "-d", "LEI16@16000", "-c", "1", input_mp3, output_wav])`.  
This converts to 16kHz, 16-bit PCM, mono — exactly what sherpa-onnx expects.

### 4.2 Model Download

Reuse the exact same URLs from `whisper_service.dart:583-588`:

```
https://huggingface.co/csukuangfj/sherpa-onnx-whisper-small/resolve/main/small-encoder.int8.onnx
https://huggingface.co/csukuangfj/sherpa-onnx-whisper-small/resolve/main/small-decoder.int8.onnx
https://huggingface.co/csukuangfj/sherpa-onnx-whisper-small/resolve/main/small-tokens.txt
https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/silero_vad.onnx
```

Store models in `backend/models/` (gitignored) or a temp directory.

### 4.3 Transcription Pipeline

Mirror the Dart `transcribeFull()` logic in `whisper_service.dart:340-406`:

1. Fresh VAD pass over entire audio
2. Concatenate all speech segments
3. If ≤ 30s: single-shot transcription
4. If > 30s: chunk into 15s segments with 3s overlap, then deduplicate overlapping words

### 4.4 Reference Text Normalization

Strip UniScribe watermarks, normalize whitespace, lowercase for WER comparison. Keep original for display.

### 4.5 Dependencies

- `sherpa-onnx` (installed)
- `jiwer` (need to install)
- `wave` (stdlib)
- No `ffmpeg` needed — `afconvert` is macOS built-in

## 5. CLI Interface

```bash
# Default smart sweep
python evaluate_transcription.py

# Single config test
python evaluate_transcription.py --threshold 0.45 --min-silence 0.5 --min-speech 0.25 --tail-paddings 800

# Full sweep (not recommended — ~5-9 hours)
python evaluate_transcription.py --full-sweep

# Custom audio directory
python evaluate_transcription.py --audio-dir ../testing_hurvinek/ --output transcription_eval_results.json
```

## 6. Estimated Time & Cost

| Item | Estimate |
|------|----------|
| Model download (one-time) | ~250MB, ~2 min |
| MP3→WAV conversion | ~5s per file |
| Single transcription run (7 min audio) | ~30–60s on M-series Mac |
| Smart sweep (45 runs) | ~25–45 min |
| Full sweep (540 runs) | ~5–9 hours (not recommended) |
| Cost | **$0** — everything runs locally |

## 7. Risk: Reference Text Quality

The `.txt` files in `testing_hurvinek/` are manual transcripts of a children's puppet show. WER comparison assumes they're accurate. If they contain their own errors or differ in formatting (e.g., "Dr." vs "doktor"), WER will be noisy. The script should normalize both sides (lowercase, strip punctuation, collapse whitespace) before comparing.

## 8. Expected Output Example

```
TRANSCRIPTION EVAL — Smart Sweep — 2026-03-01
═══════════════════════════════════════════════════════════════════════════
Parameter: VAD threshold (others at default)
───────────────────────────────────────────────────────────────────────────
Threshold  Scenario            WER%   CER%  Speech%  Segments
0.30       Nachlazení          38.2   22.1    82.3%      47
0.30       Zlomenina           35.7   20.8    79.1%      52
0.30       Angína              41.3   25.4    85.6%      44
0.40       Nachlazení          32.1   18.5    74.2%      38
...
───────────────────────────────────────────────────────────────────────────

BEST CONFIG:
  threshold=0.45, min_silence=0.5, min_speech=0.25, tail_paddings=800
  Mean WER: 30.2%  Mean CER: 17.8%
```
