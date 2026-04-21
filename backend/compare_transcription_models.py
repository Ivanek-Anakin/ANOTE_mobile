"""Download 12 diverse Czech audio samples from FLEURS and run whisper vs gpt-4o-mini-transcribe comparison.

Usage: python3 backend/compare_transcription_models.py
"""

import os
import csv
import json
import wave
import time
import http.client
import ssl
import re
import unicodedata
import shutil
from huggingface_hub import hf_hub_download

BASE = "/Users/ivananikin/Documents/Ivanek-Anakin/ANOTE_mobile"
OUT_DIR = os.path.join(BASE, "backend/eval_dataset")
os.makedirs(OUT_DIR, exist_ok=True)

# ============================================================
# Step 1: Download FLEURS Czech test samples
# ============================================================
print("=== Downloading FLEURS Czech test data ===")
tsv_path = hf_hub_download("google/fleurs", "data/cs_cz/test.tsv", repo_type="dataset")
with open(tsv_path) as f:
    rows = list(csv.reader(f, delimiter='\t'))

data_rows = rows[1:]
print(f"  Total test samples: {len(data_rows)}")

# Pick 12 diverse samples spread across dataset, mix genders, varying lengths
selected_indices = []
seen_texts = set()
for stride, start in [(60, 0), (60, 20), (60, 40), (30, 5), (30, 15)]:
    for i in range(start, len(data_rows), stride):
        row = data_rows[i]
        raw_text = row[2]
        n_samples = int(row[5])
        duration = n_samples / 16000
        if raw_text in seen_texts or duration < 4 or duration > 20 or len(raw_text) < 30:
            continue
        seen_texts.add(raw_text)
        selected_indices.append(i)
        if len(selected_indices) >= 12:
            break
    if len(selected_indices) >= 12:
        break

print(f"  Selected {len(selected_indices)} samples")

samples = []
for idx, row_idx in enumerate(selected_indices):
    row = data_rows[row_idx]
    wav_name = row[1]
    raw_text = row[2].replace('\xa0', ' ')
    gender = row[6]
    n_samples = int(row[5])
    duration = n_samples / 16000

    remote_path = f"data/cs_cz/audio/test/{wav_name}"
    try:
        local_path = hf_hub_download("google/fleurs", remote_path, repo_type="dataset")
    except Exception as e:
        print(f"  Failed to download {wav_name}: {e}")
        continue

    out_name = f"fleurs_{idx:02d}.wav"
    out_path = os.path.join(OUT_DIR, out_name)
    shutil.copy2(local_path, out_path)

    samples.append({
        "id": f"fleurs_{idx:02d}",
        "source": "FLEURS",
        "file": out_name,
        "transcript": raw_text,
        "duration": round(duration, 1),
        "gender": gender,
    })
    print(f"  [{idx}] {duration:.1f}s {gender} | {raw_text[:70]}...")

manifest_path = os.path.join(OUT_DIR, "manifest.json")
with open(manifest_path, "w", encoding="utf-8") as f:
    json.dump(samples, f, ensure_ascii=False, indent=2)

total_dur = sum(s["duration"] for s in samples)
print(f"\n  Dataset: {len(samples)} samples, {total_dur:.0f}s ({total_dur/60:.1f}min)\n")

# ============================================================
# Step 2: Run comparison
# ============================================================
print("=== Running model comparison ===\n")

PROMPT = (
    "Lékařská prohlídka, anamnéza pacienta, nynější onemocnění. "
    "Homansovo znamení, Murphyho znamení, Lasègueovo znamení."
)

MODELS = {
    "whisper": {
        "host": "anote-openai.openai.azure.com",
        "key": os.environ["AZURE_OPENAI_KEY"],
        "deployment": "whisper",
    },
    "gpt-4o-mini-transcribe": {
        "host": "anote-openai-swe.openai.azure.com",
        "key": os.environ["AZURE_OPENAI_KEY_SWE"],
        "deployment": "gpt-4o-mini-transcribe",
    },
}

API_VERSION = "2024-06-01"
ctx = ssl.create_default_context()


def normalize_text(text):
    text = text.lower()
    text = unicodedata.normalize("NFC", text)
    text = text.replace('\xa0', ' ')
    text = re.sub(r'[^\w\sáčďéěíňóřšťúůýžÁČĎÉĚÍŇÓŘŠŤÚŮÝŽ]', '', text)
    text = re.sub(r'\s+', ' ', text).strip()
    return text


def transcribe_azure(wav_path, model_cfg):
    with open(wav_path, "rb") as f:
        audio_bytes = f.read()

    boundary = f"----B{int(time.time()*1000)}"
    body = b""
    body += f"--{boundary}\r\n".encode()
    body += b'Content-Disposition: form-data; name="file"; filename="audio.wav"\r\nContent-Type: audio/wav\r\n\r\n'
    body += audio_bytes + b"\r\n"
    body += f"--{boundary}\r\n".encode()
    body += b'Content-Disposition: form-data; name="language"\r\n\r\ncs\r\n'
    body += f"--{boundary}\r\n".encode()
    body += f'Content-Disposition: form-data; name="prompt"\r\n\r\n{PROMPT}\r\n'.encode()
    body += f"--{boundary}\r\n".encode()
    body += b'Content-Disposition: form-data; name="response_format"\r\n\r\njson\r\n'
    body += f"--{boundary}\r\n".encode()
    body += b'Content-Disposition: form-data; name="temperature"\r\n\r\n0\r\n'
    body += f"--{boundary}--\r\n".encode()

    url = f'/openai/deployments/{model_cfg["deployment"]}/audio/transcriptions?api-version={API_VERSION}'
    conn = http.client.HTTPSConnection(model_cfg["host"], context=ctx)
    t0 = time.time()
    conn.request("POST", url, body=body, headers={
        "api-key": model_cfg["key"],
        "Content-Type": f"multipart/form-data; boundary={boundary}",
    })
    resp = conn.getresponse()
    raw = resp.read().decode()
    elapsed = time.time() - t0
    conn.close()

    if resp.status != 200:
        return None, elapsed, f"HTTP {resp.status}: {raw[:200]}"

    data = json.loads(raw)
    text = data.get("text", "")
    if text.startswith(PROMPT):
        text = text[len(PROMPT):].strip()
    return text, elapsed, None


import jiwer

results = {m: [] for m in MODELS}

for sample in samples:
    wav_path = os.path.join(OUT_DIR, sample["file"])
    ref_norm = normalize_text(sample["transcript"])

    print(f"--- {sample['id']} ({sample['duration']}s, {sample.get('gender','?')}) ---")
    print(f"  REF: {sample['transcript'][:80]}")

    for model_name, model_cfg in MODELS.items():
        text, elapsed, error = transcribe_azure(wav_path, model_cfg)
        if error:
            print(f"  {model_name}: ERROR {error}")
            continue

        hyp_norm = normalize_text(text)
        wer = jiwer.wer(ref_norm, hyp_norm)
        cer = jiwer.cer(ref_norm, hyp_norm)

        results[model_name].append({
            "id": sample["id"],
            "wer": wer,
            "cer": cer,
            "time": elapsed,
            "hyp": text,
            "ref": sample["transcript"],
        })

        marker = "✅" if wer < 0.3 else "⚠️" if wer < 0.6 else "❌"
        print(f"  {model_name}: WER={wer:.1%} CER={cer:.1%} {elapsed:.1f}s {marker}")
        print(f"    HYP: {text[:80]}")
    print()

# ============================================================
# Summary
# ============================================================
print(f"{'='*70}")
print(f"{'SUMMARY':^70}")
print(f"{'='*70}")
print(f"{'Model':<30} {'Avg WER':>10} {'Avg CER':>10} {'Avg Time':>10} {'N':>4}")
print(f"{'-'*70}")

for model_name, eps in results.items():
    if not eps:
        continue
    avg_wer = sum(e["wer"] for e in eps) / len(eps)
    avg_cer = sum(e["cer"] for e in eps) / len(eps)
    avg_time = sum(e["time"] for e in eps) / len(eps)
    print(f"{model_name:<30} {avg_wer*100:>9.1f}% {avg_cer*100:>9.1f}% {avg_time:>9.1f}s {len(eps):>4}")

print(f"\n{'Sample':<15} {'Whisper WER':>12} {'GPT4o-mini WER':>15} {'Winner':>10}")
print(f"{'-'*55}")
w_results = {r["id"]: r for r in results.get("whisper", [])}
g_results = {r["id"]: r for r in results.get("gpt-4o-mini-transcribe", [])}
w_wins = g_wins = ties = 0
for s in samples:
    sid = s["id"]
    w = w_results.get(sid, {}).get("wer", -1)
    g = g_results.get(sid, {}).get("wer", -1)
    if w < 0 or g < 0:
        continue
    winner = "whisper" if w < g else "gpt4o-mini" if g < w else "tie"
    if w < g: w_wins += 1
    elif g < w: g_wins += 1
    else: ties += 1
    print(f"{sid:<15} {w*100:>11.1f}% {g*100:>14.1f}% {winner:>10}")

print(f"\nWins: whisper={w_wins}, gpt-4o-mini-transcribe={g_wins}, ties={ties}")

results_path = os.path.join(OUT_DIR, "comparison_results.json")
with open(results_path, "w", encoding="utf-8") as f:
    json.dump(results, f, ensure_ascii=False, indent=2)
print(f"\nFull results: {results_path}")
