# Transcription Hallucination Fix — Tier A VAD + Tier B Prompt

## Problem

During long silent gaps the cloud transcription model (`gpt-4o-mini-transcribe`,
West Europe) emits two distinct failure modes:

1. **Prompt regurgitation** — the model copies back our ~800-char Czech medical
   prompt almost verbatim (observed in-field: user saw the exact terms
   "Lékařská prohlídka, anamnéza pacienta, …" written as transcript output).
2. **Silence hallucination** — random medical-flavoured Czech words and
   repetition loops, because the autoregressive decoder has no explicit
   "silence" token and keeps emitting text while silent audio plays.

Both are well-known properties of the Whisper / GPT-4o-mini-transcribe family
and are amplified in our setup by:

- uploading the entire raw buffer (including every silent gap);
- resending the whole buffer on every partial-transcription tick;
- packing ~70 tokens of topical vocabulary into the `prompt` field.

## Scope

Address both failure modes without changing:

- The model itself (user wants to keep `gpt-4o-mini-transcribe`).
- The backend region (West Europe).
- On-device (local Whisper) behaviour.
- The partial-transcription timer (out of scope — covered by a future Tier A #2).

## Tier B #3 — Shrink the cloud prompt

### Current

`mobile/lib/services/cloud_transcription_service.dart` attaches ~800 chars of
Czech medical terminology in the `prompt` multipart field. Whisper treats
this as recent conversation context, so silent regions get decoded as
prompt echoes.

### Change

Replace with a short prompt (≤200 chars) listing only proper nouns that Whisper
is known to mishear (Czech eponymous clinical signs + common drug brand
spellings):

```
Lékařská zpráva. Homansovo, Murphyho, Lasègueovo znamení. 
Metformin, Prestarium, bisoprolol, atorvastatin, warfarin, furosemid.
```

Rationale: OpenAI's own Whisper guide recommends using `prompt` strictly to
pin spelling of rare named entities, not for topic priming. Shorter prompt →
less to regurgitate; the decoder still learns the correct Czech spelling of
eponyms and drug names.

## Tier A #1 — VAD-gate the cloud upload

### Current

`CloudTranscriptionService.transcribe(samples)` takes the full raw PCM buffer
→ downsamples → encodes WAV → uploads. Silence is uploaded verbatim. Whisper
hallucinates inside it.

### Change

Before WAV encoding, run Silero VAD on the buffer in a background isolate and
keep only the detected speech segments. Concatenate speech segments back-to-back
with 100 ms of silence padding between them (so segment boundaries don't
create artificial glottal stops).

#### Safety rails

- **Fallback on VAD failure.** If the VAD model is missing, fails to load, or
  throws, upload the raw buffer (current behaviour).
- **Fallback on degenerate VAD output.** If VAD keeps < 20 % of total samples,
  treat as a false-negative (very quiet speaker, noisy room) and upload the
  raw buffer. Threshold is conservative; real clinical dictation is typically
  40–70 % speech.
- **Guard padding.** Add 150 ms guard padding around each segment before
  concatenation to avoid clipping word onsets/offsets (Silero can cut 30–50 ms
  at boundaries).

### Model distribution

The on-device Whisper path already downloads `silero_vad.onnx` (~300 KB) from
`github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/silero_vad.onnx`
into the Whisper model dir. Cloud-only users never trigger that download, so
the VAD file may not be present.

Strategy: `VadService.ensureModel()` lazily downloads the file on first cloud
transcription (or on app start when cloud mode is selected). Stored at
`<app-docs>/vad/silero_vad.onnx`, independent of the Whisper model dir so it
is not deleted when the user switches Whisper model size. If download fails,
`ensureModel()` returns `null` → `CloudTranscriptionService` falls back to raw
upload (no user-visible error).

### VAD configuration

Match the settings already used in `whisper_service.dart` for consistency:

| Param | Value |
|---|---|
| `threshold` | 0.35 |
| `minSilenceDuration` | 0.5 s |
| `minSpeechDuration` | 0.25 s |
| `maxSpeechDuration` | 30 s |
| `windowSize` | 512 samples |
| `sampleRate` | 16 000 Hz |

### Compute location

VAD runs in `Isolate.run` (a.k.a. Flutter `compute`). For a 2-minute recording
the VAD pass takes ~30–80 ms on a mid-range Android device, well under
perceptual threshold. Running off the main isolate avoids any UI jank.

## Files changed

| File | Change |
|---|---|
| `mobile/lib/services/vad_service.dart` | **new** — model download + `extractSpeech()` |
| `mobile/lib/services/cloud_transcription_service.dart` | shorter prompt; call VAD before upload |

## Expected impact

- Prompt regurgitation eliminated (prompt is now 20 % of original length and
  contains no full sentences to echo).
- Silence hallucination reduced to near-zero on normal dictation (the silence
  is physically absent from the uploaded audio).
- Upload size reduced proportionally to silence ratio → slightly faster
  round-trips.
- Zero quality regression expected on clean speech; fallback rails cover the
  edge cases (quiet speakers, noisy rooms).

## Non-goals / Future work

- Tier A #2 (incremental partials instead of full-buffer re-uploads)
- Tier B #4 (`temperature=0`)
- Tier B #5 (`verbose_json` + `no_speech_prob` per-segment filter)
- Tier C (statistical post-filter for repetition loops)
