# ML Provenance Pipeline – Setup & Recreation Guide

BU EC528 Spring 2026 · Intel Labs Atlas CLI

---

## Prerequisites

- **Docker Desktop** — [docker.com/products/docker-desktop](https://www.docker.com/products/docker-desktop/)
  - macOS: download from the site above
  - Windows: `winget install Docker.DockerDesktop`, then open a new terminal
- **Python 3.11+**
  - Windows: `winget install Python.Python.3.11`
- **Test dependencies** — `pip install pytest requests pytest-timeout`

---

## Step 1 — Start the Stack

Choose one local runtime. Do not run both at the same time — they bind the same ports (8001–8004, 9000).

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

---

### Option B — Kubernetes on Docker Desktop

#### macOS / Linux

**One-time setup:**

```bash
# 1. Enable Kubernetes: Docker Desktop → Settings → Kubernetes → Enable Kubernetes → Apply & Restart

# 2. Switch kubectl context
kubectl config use-context docker-desktop

# 3. Build images into Docker Desktop's local image store (one-time, or after code changes)
./scripts/build_and_push.sh --docker-desktop
```

**Deploy:**

```bash
kubectl apply -k k8s/
```

**Wait for all pods to be ready:**

```bash
kubectl rollout status deployment/minio          -n ml-pipeline
kubectl rollout status deployment/data-ingestion -n ml-pipeline
kubectl rollout status deployment/preprocessing  -n ml-pipeline
kubectl rollout status deployment/fine-tuning    -n ml-pipeline
kubectl rollout status deployment/atlas-sidecar  -n ml-pipeline
```

**Start port-forwards** (run in a dedicated terminal or in the background):

```bash
kubectl port-forward svc/minio          9000:9000 9001:9001 -n ml-pipeline &
kubectl port-forward svc/data-ingestion 8001:8001           -n ml-pipeline &
kubectl port-forward svc/preprocessing  8002:8002           -n ml-pipeline &
kubectl port-forward svc/fine-tuning    8003:8003           -n ml-pipeline &
kubectl port-forward svc/atlas-sidecar  8004:8004           -n ml-pipeline &
```

Stop all port-forwards:

```bash
pkill -f "kubectl port-forward"
```

#### Windows

```bat
:: 1. Enable Kubernetes in Docker Desktop → Settings → Kubernetes → Enable Kubernetes

:: 2. Build images and deploy (one-shot wrapper)
scripts\setup_k8s_docker_desktop.bat
```

That wrapper builds the images, deploys the Kubernetes stack, clears existing deployments first, and streams `kubectl get pods -w` in the same terminal.

```bat
:: Deploy without the live watcher
scripts\setup_k8s_docker_desktop.bat --no-watch
```

**Start port-forwards** in a separate terminal:

```powershell
pwsh scripts\port_forward.ps1
```

Stop port-forwards:

```bat
scripts\stop_k8s_port_forward.bat
```

---

### Verify services are healthy

**macOS / Linux:**
```bash
curl http://localhost:8001/health   # data-ingestion
curl http://localhost:8002/health   # preprocessing
curl http://localhost:8003/health   # fine-tuning
curl http://localhost:8004/health   # atlas-sidecar
```

**Windows:**
```powershell
Invoke-RestMethod http://localhost:8001/health
Invoke-RestMethod http://localhost:8002/health
Invoke-RestMethod http://localhost:8003/health
Invoke-RestMethod http://localhost:8004/health
```

Each should return `{"status": "ok"}`.

---

## Step 2 — Run the Demo

Open a new terminal while your chosen backend is running:

```bash
# Ingestion + preprocessing only (fast, ~1 minute)
python demo.py

# Custom sample count and pipeline ID
python demo.py --samples 200 --pipeline-id demo-200

# Full pipeline including fine-tuning (slow on CPU, ~10-30 min)
python demo.py --stage full --samples 50 --train-epochs 1

# Full pipeline with custom inference text
python demo.py --samples 500 --train --pipeline-id demo-500 --predict-text "Loved it."

# Full pipeline with longer training
python demo.py --samples 500 --train --train-epochs 3 --pipeline-id demo-500

# Individual stages (useful when re-running after a partial run)
python demo.py --stage ingest     --samples 200 --pipeline-id stage-demo
python demo.py --stage preprocess --pipeline-id stage-demo
python demo.py --stage train      --pipeline-id stage-demo
```

The demo:
- waits for all four `/health` endpoints before starting
- runs the requested stages and prints the provenance chain and status
- on Kubernetes, prints `Runtime backend: kubernetes` with pod and node names for each service
- pressing `Ctrl+C` during polling sends a cancellation request to the active service job

Use a fresh `--pipeline-id` for a clean provenance chain without reusing older artifacts.

---

## Step 3 — Verify Provenance

After a pipeline run, query the sidecar directly:

**macOS / Linux:**
```bash
PIPELINE=demo-200

curl "http://localhost:8004/lineage?pipeline_id=$PIPELINE"
curl "http://localhost:8004/pipeline/status?pipeline_id=$PIPELINE"
curl "http://localhost:8004/registry?pipeline_id=$PIPELINE"

curl "http://localhost:8001/provenance?pipeline_id=$PIPELINE"
curl "http://localhost:8002/provenance?pipeline_id=$PIPELINE"
curl "http://localhost:8003/provenance?pipeline_id=$PIPELINE"

# SLSA attestations (Stretch Goal 7)
curl "http://localhost:8004/slsa?pipeline_id=$PIPELINE"
```

**Windows:**
```powershell
$pipeline = "demo-200"

Invoke-RestMethod "http://localhost:8004/lineage?pipeline_id=$pipeline"
Invoke-RestMethod "http://localhost:8004/pipeline/status?pipeline_id=$pipeline"
Invoke-RestMethod "http://localhost:8004/registry?pipeline_id=$pipeline"

Invoke-RestMethod "http://localhost:8001/provenance?pipeline_id=$pipeline"
Invoke-RestMethod "http://localhost:8002/provenance?pipeline_id=$pipeline"
Invoke-RestMethod "http://localhost:8003/provenance?pipeline_id=$pipeline"

Invoke-RestMethod "http://localhost:8004/slsa?pipeline_id=$pipeline"
```

Export and verify a specific manifest:

**macOS / Linux:**
```bash
MANIFEST_ID="urn:c2pa:..."   # from lineage output

curl "http://localhost:8004/export/$MANIFEST_ID"
curl "http://localhost:8004/verify/$MANIFEST_ID"
```

**Windows:**
```powershell
$lineage = Invoke-RestMethod "http://localhost:8004/lineage?pipeline_id=demo-200"
$manifest = $lineage.chain[0].manifest_id
$encoded = [uri]::EscapeDataString($manifest)

Invoke-RestMethod "http://localhost:8004/export/$encoded"
Invoke-RestMethod "http://localhost:8004/verify/$encoded"
```

Expected success signals:
- `/lineage` shows `chain_complete: true` after all stages
- every lineage entry has a sidecar `tracking_id`
- `/pipeline/status` marks all completed stages as done
- `/registry` contains the raw, tokenized, and model artifact URIs
- `/slsa` returns `{"count": N, "attestations": [...]}` with in-toto Statements

---

## Step 4 — Run the Tests

```bash
# Smoke tests — fast health + schema checks, no pipeline run needed
pytest tests/test_slsa.py -v -m smoke

# All SLSA attestation tests (Stretch Goal 7)
pytest tests/test_slsa.py -v

# All non-slow tests
pytest tests/ -v -m smoke
pytest tests/ -v

# Automated atlas-cli pipeline test (Stretch Goal 2)
./scripts/test_atlas_pipeline.sh           # macOS / Linux
bash scripts/test_atlas_pipeline.sh        # Windows (Git Bash)
```

### Test files

| File | What it tests |
|------|--------------|
| `test_health.py` | All services reachable, /docs reachable |
| `test_connection_handling.py` | Transient disconnect retry, startup waits, timeout behavior |
| `test_data_ingestion.py` | Ingestion job lifecycle, SHA-256, S3 URI, idempotency |
| `test_preprocessing.py` | Token counts, max_length, source linkage |
| `test_fine_tuning.py` | Loss progression, model metadata, `/predict` schema |
| `test_pipeline_e2e.py` | Full provenance chain, SHA-256 uniqueness, sentiment accuracy |
| `test_atlas_sidecar.py` | Direct sidecar calls, manifest collect/export/verify |
| `test_provenance_chain.py` | /lineage and /pipeline/status schema + wired chain correctness |
| `test_slsa.py` | SLSA v0.2 attestation structure, /slsa endpoint, in-toto Statement format |
| `test_demo_cancellation.py` | Demo interrupt behavior and remote cancellation requests |

---

## Step 5 — Stop and Switch Backends

**Stop Docker Compose:**
```bash
docker compose down

# Also remove local volumes (clears MinIO data):
docker compose down -v
```

**Stop Kubernetes port-forwards:**

macOS / Linux:
```bash
pkill -f "kubectl port-forward"
```

Windows:
```bat
scripts\stop_k8s_port_forward.bat
```

**Tear down the Kubernetes stack:**
```bash
kubectl delete namespace ml-pipeline
```

**Switch Docker Compose → Kubernetes:**

macOS / Linux:
```bash
docker compose down
kubectl apply -k k8s/
# wait for rollouts, then start port-forwards
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

> **Port conflict:** Docker Desktop binds Kubernetes `containerPort` values to `localhost` even for ClusterIP services. You must fully delete the namespace before `docker compose up` will work. If port 9000 is still allocated after namespace deletion, find the process holding it:
> - macOS: `lsof -i :9000`
> - Windows: `netstat -ano | findstr :9000`
>
> Stale `kind` or other project containers are a common cause — stop them with `docker stop <container-name>`.

---

## Recreate from Scratch

```bash
# Tear down all containers and data
docker compose down -v

# Rebuild and restart
docker compose up --build

# Re-run demo (new terminal)
python demo.py --samples 200 --pipeline-id recreate-demo

# Run tests
pytest tests/test_slsa.py -v -m smoke
./scripts/test_atlas_pipeline.sh
```

---

## Kubernetes Debugging

```bash
# Watch pod status
kubectl get pods -n ml-pipeline -w

# Tail logs for a service
kubectl logs -n ml-pipeline deployment/atlas-sidecar -f
kubectl logs -n ml-pipeline deployment/fine-tuning -f

# Describe a pod (events, image pull status, probe failures)
kubectl describe pod -n ml-pipeline -l app=atlas-sidecar

# Check PVCs are bound
kubectl get pvc -n ml-pipeline

# Check MinIO bucket was created
kubectl logs job/minio-init -n ml-pipeline
```

---

## Troubleshooting

| Problem | Fix |
|---------|-----|
| `docker compose up` fails with port already allocated | Find the process: `lsof -i :9000` (macOS) or `netstat -ano \| findstr :9000` (Windows). Stop stale containers with `docker stop <name>`, or run `kubectl delete namespace ml-pipeline` if Kubernetes is the cause |
| Container stuck `unhealthy` | `docker compose logs <service>` |
| `atlas-sidecar` never becomes healthy | Rust build may have timed out — retry `docker compose up --build` |
| Kubernetes pod restarts during fine-tuning | Liveness probe times out during BERT model loading on CPU — expected on first job submission; pod recovers and resubmitting succeeds |
| `pytest-timeout` warnings | `pip install pytest-timeout` |
| All predictions return `negative` | Re-run ingestion, then preprocess and train again |
| `split=validation` not found | Ingest the validation split first: `python demo.py --stage ingest --split validation` |
| `wired` tests fail with "not in registry" | Restart containers with `docker compose up -d --force-recreate`, re-run the pipeline, then re-run tests |
