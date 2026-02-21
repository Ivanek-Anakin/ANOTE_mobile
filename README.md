# ANOTE Mobile

Medical report generation from voice — on-device transcription with a Python/FastAPI backend.

## Architecture

```
┌──────────────────── Mobile Device ────────────────────┐
│                                                        │
│  Microphone                                            │
│    ↓                                                   │
│  AudioService (audio_streamer — raw PCM chunks)        │
│    ↓                                                   │
│  WhisperService (whisper_flutter_plus — on-device)     │
│    ↓                                                   │
│  Czech text transcript (local state)                   │
│    ↓ (periodic, ~10-15s intervals + final on stop)     │
│  ReportService → HTTPS POST to backend                 │
│    ↓                                                   │
│  Structured Czech medical report displayed in UI       │
│                                                        │
└────────────────────────────────────────────────────────┘
              │
              │ HTTPS (text only, bearer token auth)
              ▼
┌──── Azure Container Apps (West Europe) ───────────────┐
│                                                        │
│  FastAPI proxy (Python)                                │
│  POST /report → Azure OpenAI GPT-4o-mini               │
│    → returns structured Czech medical report           │
│                                                        │
└────────────────────────────────────────────────────────┘
              │
              │ Azure internal network
              ▼
┌──── Azure OpenAI Service (West Europe) ───────────────┐
│                                                        │
│  GPT-4o-mini deployment                                │
│  - No data retention (abuse monitoring opt-out)        │
│  - No model training on customer data                  │
│  - GDPR compliant, data stays in EU                    │
│                                                        │
└────────────────────────────────────────────────────────┘
```

## Repository Structure

```
ANOTE_mobile/
├── README.md
├── backend/
│   ├── main.py                  # FastAPI app — /health and /report endpoints
│   ├── requirements.txt
│   ├── Dockerfile
│   ├── .env.example
│   └── tests/
│       ├── __init__.py
│       └── test_report_endpoint.py
└── mobile/
    └── .gitkeep                 # Flutter app — implemented in Phase 2-4
```

> **Note:** The mobile app (Flutter) will be implemented in Phase 2-4.

## Backend — Local Development

```bash
cd backend
pip install -r requirements.txt
cp .env.example .env             # fill in real Azure OpenAI credentials
uvicorn main:app --reload --port 8000
```

The API will be available at `http://localhost:8000`.

### Endpoints

| Method | Path | Auth | Description |
|--------|------|------|-------------|
| `GET` | `/health` | None | Health check |
| `POST` | `/report` | Bearer token | Generate structured Czech medical report |

### Request example

```bash
curl -X POST http://localhost:8000/report \
  -H "Authorization: Bearer your-secret-bearer-token" \
  -H "Content-Type: application/json" \
  -d '{"transcript": "Pacient přišel s bolestí hlavy trvající tři dny."}'
```

## Backend — Testing

```bash
cd backend
python -m pytest tests/ -v
```

## Backend — Deployment (Azure Container Apps)

```bash
az containerapp up \
  --name anote-api \
  --resource-group anote-rg \
  --location westeurope \
  --source ./backend \
  --ingress external \
  --target-port 8000 \
  --env-vars \
    AZURE_OPENAI_KEY=secretref:azure-openai-key \
    AZURE_OPENAI_ENDPOINT=https://your-resource.openai.azure.com \
    AZURE_OPENAI_DEPLOYMENT=gpt-4o-mini \
    APP_API_TOKEN=secretref:app-api-token
```
