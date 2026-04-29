# Distributed ML Model Provenance System in Cloud-Native Environments

**BU EC528 Spring 2026**
Mentors: Marcela Melara, Marcin Spoczynski (Intel Labs)

[![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](LICENSE)

Extending [Atlas CLI](https://github.com/IntelLabs/atlas-cli) into a cloud-native distributed provenance system.

Demo 1 presentation: https://docs.google.com/presentation/d/1z5usLUe9r3ex-ovyxyOwZE1G7A_tVfEOVQuWLKoFlhg/edit?usp=sharing

Demo 2 presentation: https://docs.google.com/presentation/d/1GpcsQxISsixNy81IAFUo-bQrctSp6YLsWTR8mN-bK7E/edit?usp=sharing

Demo 2 video: https://drive.google.com/file/d/1iPYX0nW1rNNxc22FYdzfefnvu_PNE1oM/view?usp=sharing

Demo 3 presentation: https://docs.google.com/presentation/d/1WfeDlM877Tw3Msrw_t-0FO3Swb3vk92SMZvVm914wR0/edit?usp=sharing

Demo 3 video: https://drive.google.com/file/d/1BLxXcpIp_xUrE9GHFw9CGTNGA9couwYI/view?usp=sharing

---
## Final Presentation
Slides: https://docs.google.com/presentation/d/1O9D4g4Zt7UJEP9EzIyZKgcTbSV5nw0h0g138V8SgS-k/edit?slide=id.g3966e706cf1_0_0#slide=id.g3966e706cf1_0_0

Video presentation: https://drive.google.com/file/d/1TyvwNBzbEEqTooh9x9XlKcMvtueIAA2V/view?usp=drive_link

---

## Overview

This project extends the [IntelLabs Atlas CLI](https://github.com/IntelLabs/atlas-cli) into a cloud-native distributed provenance system by implementing a three-stage ML pipeline — data ingestion, preprocessing, and fine-tuning — where every artifact produced is automatically tracked with cryptographically signed C2PA provenance manifests via an Atlas CLI sidecar service.

Each pipeline stage runs as an independent containerised service. Artifacts flow through S3-compatible object storage (MinIO locally). The Atlas sidecar intercepts each completed stage and calls `atlas-cli` to generate a manifest that records what was produced, how, and by whom — forming a linked provenance chain from raw data to trained model.

Pipelines are detached from service instances through a shared `pipeline_id` contract. The same running services can host multiple independent pipelines by storing artifacts under `pipelines/<pipeline_id>/...` and querying provenance with that same ID.

---

### Provenance chain

```
pipelines/default/raw/train_data.json
    │  dataset manifest  (atlas-cli dataset create)
    ▼
pipelines/default/preprocessed/train_tokenized.json
    │  pipeline manifest (atlas-cli pipeline generate-provenance)
    ▼
pipelines/default/models/classifier/model.pt
       model manifest    (atlas-cli model create)
       linked back to upstream dataset manifests
```

---

## Services

| Service | Port | Responsibility |
|---------|------|----------------|
| **data-ingestion** | 8001 | Downloads IMDB from HuggingFace, shuffles for class balance, stores `{text, label}` JSON to S3 |
| **preprocessing** | 8002 | Tokenizes with `BertTokenizer` (`bert-base-uncased`, max_length=128), stores tensor arrays to S3 |
| **fine-tuning** | 8003 | Fine-tunes BERT for binary sentiment classification with AdamW + linear warmup; serves `/predict` |
| **atlas-sidecar** | 8004 | Wraps Atlas CLI via HTTP API; generates signed C2PA manifests for every artifact after each stage |

All services are FastAPI with async background jobs. Storage is MinIO (local) or AWS S3 (cloud) — switching requires only changing the `S3_ENDPOINT_URL` environment variable. The default pipeline ID is `default`, but each job/status/provenance call can override it with `pipeline_id=<name>`.

---

## Stack

| Layer | Technology |
|-------|-----------|
| ML model | `bert-base-uncased` (HuggingFace Transformers) |
| Dataset | IMDB sentiment (HuggingFace `datasets`) |
| Services | Python 3.11, FastAPI, uvicorn |
| Storage | MinIO (S3-compatible), boto3 |
| Provenance | [IntelLabs Atlas CLI](https://github.com/IntelLabs/atlas-cli) — C2PA / OMS manifests, RSA-4096 signing |
| Orchestration | Docker Compose (local), Kubernetes (deployment) |
| Testing | pytest, requests, pytest-timeout |

---

## Quick Start

**Prerequisites:** Docker Desktop, Python 3.11+

```bash
pip install pytest requests pytest-timeout
```

Choose one local runtime:

### Option A — Docker Compose

**macOS / Linux:**
```bash
docker compose up --build
```

**Windows:**
```bat
docker compose --progress plain up --build
```

Keep that terminal open. The first build is slow because `atlas-sidecar` compiles `atlas-cli` from Rust source; later starts reuse cached Docker layers and are much faster.

### Option B — Kubernetes on Docker Desktop

**macOS / Linux:**

```bash
# 1. Enable Kubernetes: Docker Desktop → Settings → Kubernetes → Enable Kubernetes → Apply & Restart

# 2. Switch kubectl context
kubectl config use-context docker-desktop

# 3. Build images into Docker Desktop's local image store
./scripts/build_and_push.sh --docker-desktop

# 4. Deploy
kubectl apply -k k8s/

# 5. Wait for pods
kubectl rollout status deployment/minio          -n ml-pipeline
kubectl rollout status deployment/data-ingestion -n ml-pipeline
kubectl rollout status deployment/preprocessing  -n ml-pipeline
kubectl rollout status deployment/fine-tuning    -n ml-pipeline
kubectl rollout status deployment/atlas-sidecar  -n ml-pipeline

# 6. Port-forward (run in a dedicated terminal or background)
kubectl port-forward svc/minio          9000:9000 9001:9001 -n ml-pipeline &
kubectl port-forward svc/data-ingestion 8001:8001           -n ml-pipeline &
kubectl port-forward svc/preprocessing  8002:8002           -n ml-pipeline &
kubectl port-forward svc/fine-tuning    8003:8003           -n ml-pipeline &
kubectl port-forward svc/atlas-sidecar  8004:8004           -n ml-pipeline &

# Stop all port-forwards
pkill -f "kubectl port-forward"
```

**Windows:**

```bat
:: 1. Enable Kubernetes in Docker Desktop → Settings → Kubernetes → Enable Kubernetes

:: 2. Switch context and deploy
scripts\setup_k8s_docker_desktop.bat

:: 3. Start port-forwards in a separate terminal
pwsh scripts\port_forward.ps1

:: 4. To stop port-forwards
scripts\stop_k8s_port_forward.bat
```

### Verify services are healthy

**macOS / Linux:**
```bash
curl http://localhost:8001/health
curl http://localhost:8002/health
curl http://localhost:8003/health
curl http://localhost:8004/health
```

**Windows:**
```powershell
Invoke-RestMethod http://localhost:8001/health
Invoke-RestMethod http://localhost:8002/health
Invoke-RestMethod http://localhost:8003/health
Invoke-RestMethod http://localhost:8004/health
```

### Run the demo

```bash
# Ingestion + preprocessing only (fast, ~1 min)
python demo.py

# Custom sample count and pipeline ID
python demo.py --samples 200 --pipeline-id demo-200

# Full pipeline including fine-tuning (slow on CPU, ~10-30 min)
python demo.py --stage full --samples 50 --train-epochs 1

# Full pipeline with custom inference text
python demo.py --samples 500 --train --pipeline-id demo-500 --predict-text "Loved it."

# Full pipeline with longer training
python demo.py --samples 500 --train --train-epochs 3 --pipeline-id demo-500

# Individual stages
python demo.py --stage ingest     --samples 200 --pipeline-id stage-demo
python demo.py --stage preprocess --pipeline-id stage-demo
python demo.py --stage train      --pipeline-id stage-demo
```

### Run tests

```bash
# Smoke tests — fast health + schema checks, no pipeline run needed
pytest tests/test_slsa.py -v -m smoke

# All SLSA attestation tests (Stretch Goal 7)
pytest tests/test_slsa.py -v

# Automated atlas-cli pipeline test (Stretch Goal 2)
./scripts/test_atlas_pipeline.sh          # macOS / Linux
bash scripts/test_atlas_pipeline.sh       # Windows (Git Bash)
```

---

## Stopping and Switching Backends

**Stop Docker Compose:**
```bash
docker compose down

# Also remove local volumes (clears MinIO data):
docker compose down -v
```

**Stop Kubernetes port-forwards:**

macOS / Linux: `pkill -f "kubectl port-forward"`

Windows: `scripts\stop_k8s_port_forward.bat`

**Tear down Kubernetes stack:**
```bash
kubectl delete namespace ml-pipeline
```

**Switch Docker Compose → Kubernetes:**

macOS / Linux:
```bash
docker compose down
kubectl apply -k k8s/
# ... wait for rollouts, then start port-forwards
```

Windows:
```powershell
docker compose down
scripts\setup_k8s_docker_desktop.bat
```

**Switch Kubernetes → Docker Compose:**

macOS / Linux:
```bash
pkill -f "kubectl port-forward"
kubectl delete namespace ml-pipeline
docker compose up
```

Windows:
```powershell
scripts\stop_k8s_port_forward.bat
kubectl delete -k k8s
docker compose --progress plain up --build
```

> **Port conflict warning:** Docker Desktop binds Kubernetes `containerPort` values to localhost even for ClusterIP services. You must fully delete the namespace (not just scale pods to 0) before `docker compose up` will work. If port 9000 is still held after namespace deletion, check for stale containers from other projects: `lsof -i :9000` (macOS) or `netstat -ano | findstr :9000` (Windows). Stop them with `docker stop <container-name>`.

---

## API Reference

### Pipeline services

| Method | Endpoint | Description |
|--------|----------|-------------|
| GET | `:8001/health` | Liveness + deployment mode and runtime location metadata |
| POST | `:8001/ingest?split=train&num_samples=500&pipeline_id=default` | Start ingestion job |
| GET | `:8001/jobs/{id}` | Poll job status |
| POST | `:8001/jobs/{id}/cancel` | Request cancellation |
| GET | `:8001/status?split=train&pipeline_id=default` | Check if raw data exists in S3 |
| POST | `:8002/preprocess?split=train&pipeline_id=default` | Start tokenization job |
| GET | `:8002/jobs/{id}` | Poll job status |
| POST | `:8002/jobs/{id}/cancel` | Request cancellation |
| POST | `:8003/train?split=train&pipeline_id=default` | Start fine-tuning job |
| GET | `:8003/jobs/{id}` | Poll job status (includes epoch, loss, progress while training) |
| POST | `:8003/jobs/{id}/cancel` | Request cancellation |
| POST | `:8003/predict` | `{"text": "...", "pipeline_id": "default"}` → label + confidence |
| GET | `:8003/model/info?pipeline_id=default` | Trained model metadata |

### Atlas sidecar

| Method | Endpoint | Description |
|--------|----------|-------------|
| GET | `:8004/health` | Liveness + atlas-cli version + key status + deployment mode |
| POST | `:8004/collect/dataset` | Register dataset artifact, create C2PA manifest |
| POST | `:8004/collect/pipeline` | Register pipeline-step SLSA provenance |
| POST | `:8004/collect/model` | Register model artifact, link to dataset manifests |
| GET | `:8004/lineage?pipeline_id=default` | Ordered provenance history |
| GET | `:8004/pipeline/status?pipeline_id=default` | Per-stage completion flags and manifest counts |
| GET | `:8004/registry?pipeline_id=default` | All tracked artifacts for a pipeline |
| GET | `:8004/pipelines` | Summary of all known pipeline IDs |
| GET | `:8004/export/{manifest_id}` | Export full provenance graph as JSON |
| GET | `:8004/verify/{manifest_id}` | Verify manifest cryptographic integrity |
| GET | `:8004/signing-key` | RSA public key PEM |
| GET | `:8004/slsa?pipeline_id=default` | List SLSA attestations (filterable by pipeline_id, stage, tracking_id) |

### Per-service provenance

| Service | Endpoint |
|---------|----------|
| data-ingestion | `:8001/provenance` |
| preprocessing | `:8002/provenance` |
| fine-tuning | `:8003/provenance` |

---

## Tests

```bash
pytest tests/ -v -m smoke          # fast health + schema checks only
pytest tests/ -v                   # all non-slow tests
pytest tests/test_slsa.py -v       # SLSA attestation tests (Stretch Goal 7)
```

| File | What it covers |
|------|---------------|
| `test_health.py` | All services reachable, /docs reachable |
| `test_connection_handling.py` | Startup waits, transient disconnect retry, timeout handling |
| `test_data_ingestion.py` | Job lifecycle, SHA-256, S3 URI, idempotency |
| `test_preprocessing.py` | Token counts, max_length, source linkage |
| `test_fine_tuning.py` | Loss progression, model metadata, predict schema, sentiment accuracy |
| `test_pipeline_e2e.py` | Full provenance chain, SHA-256 uniqueness, end-to-end sentiment |
| `test_atlas_sidecar.py` | Direct collect calls, registry updates, manifest export/verify |
| `test_provenance_chain.py` | /lineage and /pipeline/status schema + wired chain correctness |
| `test_slsa.py` | SLSA v0.2 attestation structure and /slsa endpoint |
| `test_demo_cancellation.py` | Demo-side remote cancellation requests on local interrupt |

---

## Notes

- Keep the selected backend running while using the demo or tests. Do not run both Docker Compose and Kubernetes port-forwards at the same time on the same ports.
- `demo.py` waits for service health automatically before starting the pipeline.
- When the backend is Kubernetes, `demo.py` prints `Runtime backend: kubernetes` and includes each service pod and node name in the health section.
- `demo.py` is self-contained. You do not need to run the test suite before running the demo.
- `--train` defaults to 1 epoch to keep the demo short. Use `--train-epochs 3` for a longer run.
- `--stage pipeline` runs ingestion + preprocessing only. `--stage full` runs all three stages. `--train` is a legacy alias for `--stage full`.
- Pressing `Ctrl+C` during demo job polling sends a cancellation request to the active service job.
- Use a fresh `--pipeline-id` when you want isolated artifacts and a clean provenance chain.
- `split=validation` only works after ingesting that split first.

---

## Project Goals

| Requirement | Status |
|-------------|--------|
| Data ingestion service | Done — IMDB via HuggingFace, S3 storage |
| Preprocessing service | Done — BertTokenizer, chunked processing |
| Fine-tuning service | Done — BERT sentiment classifier, `/predict` endpoint |
| Kubernetes deployment | Done — `k8s/` manifests (namespace, MinIO, configmap, 3 services, atlas-sidecar) |
| Sidecar container pattern | Done — Atlas CLI wrapped as HTTP service, called automatically after each stage |
| C2PA / OMS manifests | Done — `dataset create`, `pipeline generate-provenance`, `model create` |
| Cryptographic signing | Done — RSA-4096 key on sidecar startup, signs all manifests |
| Artifact sharing via S3 | Done — MinIO; boto3 `S3_ENDPOINT_URL` switches to real AWS S3 |
| Provenance query API | Done — `/registry`, `/export`, `/verify`, `/lineage`, `/pipeline/status` |
| Provenance verification (stretch) | Done — `atlas-cli manifest validate` via `/verify/{id}` |
| SLSA Provenance v0.2 (stretch) | Done — in-toto Statements with SLSA predicates via `/slsa` endpoint |
| Atlas CLI testing script (stretch) | Done — `scripts/test_atlas_pipeline.sh` automated pipeline test |
| Confidential computing (stretch) | Not implemented |
| Multi-cloud (stretch) | Not implemented |
