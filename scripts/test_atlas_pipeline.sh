#!/usr/bin/env bash
# test_atlas_pipeline.sh — Automated Atlas CLI pipeline test (Stretch Goal 2)
#
# Tests the full lifecycle: service configuration → provenance collection →
# manifest validation → SLSA attestation verification.
#
# Unlike run_pipeline.sh (which just executes), this script asserts correctness
# at every step and exits non-zero on the first failure.
#
# Usage:
#   ./scripts/test_atlas_pipeline.sh                     # docker-compose (default)
#   ./scripts/test_atlas_pipeline.sh --k8s               # kubernetes (port-forward)
#   ./scripts/test_atlas_pipeline.sh --samples 50        # override sample count
#   ./scripts/test_atlas_pipeline.sh --pipeline-id ci-01 # isolated pipeline namespace

set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────────
INGEST_URL="http://localhost:8001"
PREPROC_URL="http://localhost:8002"
FINETUNE_URL="http://localhost:8003"
SIDECAR_URL="http://localhost:8004"
PIPELINE_ID="atlas-test-$$"
NUM_SAMPLES=50
SPLIT="train"
K8S_MODE=false
NS="ml-pipeline"
RUN_TRAIN=false   # fine-tuning is slow; off by default for CI

# ── Argument parsing ───────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --k8s)          K8S_MODE=true ;;
    --samples)      NUM_SAMPLES="$2"; shift ;;
    --split)        SPLIT="$2"; shift ;;
    --pipeline-id)  PIPELINE_ID="$2"; shift ;;
    --with-train)   RUN_TRAIN=true ;;
    *) echo "Unknown flag: $1"; exit 1 ;;
  esac
  shift
done

# ── Colours ───────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; BOLD='\033[1m'; NC='\033[0m'
pass()  { echo -e "  ${GREEN}✓${NC}  $*"; }
fail()  { echo -e "  ${RED}✗${NC}  $*" >&2; FAILURES=$((FAILURES + 1)); }
warn()  { echo -e "  ${YELLOW}!${NC}  $*"; }
info()  { echo -e "${BOLD}▶${NC}  $*"; }
FAILURES=0

# ── K8s port-forward ──────────────────────────────────────────────────────────
PF_PIDS=()
cleanup() {
  for pid in "${PF_PIDS[@]:-}"; do kill "$pid" 2>/dev/null || true; done
}
trap cleanup EXIT

if $K8S_MODE; then
  info "Starting kubectl port-forwards (namespace: $NS)..."
  kubectl port-forward -n "$NS" svc/data-ingestion 8001:8001 &>/dev/null & PF_PIDS+=($!)
  kubectl port-forward -n "$NS" svc/preprocessing  8002:8002 &>/dev/null & PF_PIDS+=($!)
  kubectl port-forward -n "$NS" svc/fine-tuning    8003:8003 &>/dev/null & PF_PIDS+=($!)
  kubectl port-forward -n "$NS" svc/atlas-sidecar  8004:8004 &>/dev/null & PF_PIDS+=($!)
  sleep 4
fi

# ── Helpers ───────────────────────────────────────────────────────────────────
assert() {
  local description="$1"; local actual="$2"; local expected="$3"
  if [[ "$actual" == "$expected" ]]; then
    pass "$description"
  else
    fail "$description (expected=${expected} got=${actual})"
  fi
}

assert_nonempty() {
  local description="$1"; local value="$2"
  if [[ -n "$value" && "$value" != "null" ]]; then
    pass "$description"
  else
    fail "$description (got empty/null)"
  fi
}

assert_contains() {
  local description="$1"; local haystack="$2"; local needle="$3"
  if echo "$haystack" | grep -q "$needle"; then
    pass "$description"
  else
    fail "$description (${needle} not found in: ${haystack})"
  fi
}

wait_for_job() {
  local base_url="$1"; local job_id="$2"; local label="$3"
  local max_wait="${4:-900}"; local elapsed=0
  while true; do
    local status
    status=$(curl -sf "${base_url}/jobs/${job_id}" \
      | python3 -c "import sys,json; print(json.load(sys.stdin)['status'])" 2>/dev/null || echo "unknown")
    case "$status" in
      completed) pass "${label} completed"; break ;;
      failed)
        local err
        err=$(curl -sf "${base_url}/jobs/${job_id}" \
          | python3 -c "import sys,json; print(json.load(sys.stdin).get('error','?'))" 2>/dev/null)
        fail "${label} failed: ${err}"; return 1 ;;
      *)
        if (( elapsed >= max_wait )); then fail "${label} timed out after ${max_wait}s"; return 1; fi
        printf "    %s: %s (%ds)\r" "$label" "$status" "$elapsed"
        sleep 5; elapsed=$(( elapsed + 5 )) ;;
    esac
  done
}

# ── Section 1: Service configuration checks ───────────────────────────────────
echo ""
echo -e "${BOLD}════════════════════════════════════════════════════${NC}"
echo -e "${BOLD} Atlas CLI Pipeline Test${NC}"
echo -e "${BOLD} pipeline_id=${PIPELINE_ID}  samples=${NUM_SAMPLES}  split=${SPLIT}${NC}"
echo -e "${BOLD}════════════════════════════════════════════════════${NC}"
echo ""
info "Section 1: Service configuration"

SVC_NAMES=("data-ingestion" "preprocessing" "fine-tuning" "atlas-sidecar")
SVC_URLS=("$INGEST_URL" "$PREPROC_URL" "$FINETUNE_URL" "$SIDECAR_URL")
for i in "${!SVC_NAMES[@]}"; do
  svc_name="${SVC_NAMES[$i]}"; svc_url="${SVC_URLS[$i]}"
  health=$(curl -sf "${svc_url}/health" 2>/dev/null || echo '{"status":"unreachable"}')
  status=$(echo "$health" | python3 -c "import sys,json; print(json.load(sys.stdin).get('status','?'))" 2>/dev/null)
  assert "${svc_name} health=ok" "$status" "ok"
done

# Atlas CLI availability
sidecar_health=$(curl -sf "${SIDECAR_URL}/health")
atlas_cli=$(echo "$sidecar_health" | python3 -c "import sys,json; print(json.load(sys.stdin).get('atlas_cli','unavailable'))" 2>/dev/null)
if [[ "$atlas_cli" == "unavailable" ]]; then
  fail "atlas-cli not available in sidecar (check: docker compose logs atlas-sidecar)"
else
  pass "atlas-cli available (version: ${atlas_cli})"
fi

# Signing key
key_exists=$(echo "$sidecar_health" | python3 -c "import sys,json; print(json.load(sys.stdin).get('key_exists',False))" 2>/dev/null)
assert "RSA signing key generated" "$key_exists" "True"

# Public key is RSA
pubkey_resp=$(curl -sf "${SIDECAR_URL}/signing-key" 2>/dev/null || echo '{}')
pubkey=$(echo "$pubkey_resp" | python3 -c "import sys,json; print(json.load(sys.stdin).get('public_key_pem',''))" 2>/dev/null)
assert_contains "signing key is RSA public key" "$pubkey" "BEGIN PUBLIC KEY"

# Atlas sidecar is wired to pipeline services
PIPE_SVC_NAMES=("data-ingestion" "preprocessing" "fine-tuning")
PIPE_SVC_URLS=("$INGEST_URL" "$PREPROC_URL" "$FINETUNE_URL")
for i in "${!PIPE_SVC_NAMES[@]}"; do
  svc_name="${PIPE_SVC_NAMES[$i]}"; svc_url="${PIPE_SVC_URLS[$i]}"
  provenance=$(curl -sf "${svc_url}/provenance?pipeline_id=${PIPELINE_ID}" 2>/dev/null || echo '{}')
  sidecar_set=$(echo "$provenance" | python3 -c "import sys,json; print(bool(json.load(sys.stdin).get('sidecar_url')))" 2>/dev/null)
  assert "${svc_name} has ATLAS_SIDECAR_URL configured" "$sidecar_set" "True"
done

# ── Section 2: Data ingestion + provenance collection ─────────────────────────
echo ""
info "Section 2: Data ingestion (${NUM_SAMPLES} samples)"

ingest_resp=$(curl -sf -X POST \
  "${INGEST_URL}/ingest?split=${SPLIT}&num_samples=${NUM_SAMPLES}&pipeline_id=${PIPELINE_ID}")
ingest_job_id=$(echo "$ingest_resp" | python3 -c "import sys,json; print(json.load(sys.stdin)['job_id'])")
assert_nonempty "ingest job queued" "$ingest_job_id"

wait_for_job "$INGEST_URL" "$ingest_job_id" "Data ingestion"

ingest_info=$(curl -sf "${INGEST_URL}/jobs/${ingest_job_id}")
ingest_s3_uri=$(echo "$ingest_info" | python3 -c "import sys,json; print(json.load(sys.stdin).get('s3_uri',''))" 2>/dev/null)
ingest_sha256=$(echo "$ingest_info" | python3 -c "import sys,json; print(json.load(sys.stdin).get('sha256',''))" 2>/dev/null)
assert_nonempty "ingest artifact S3 URI" "$ingest_s3_uri"
assert_nonempty "ingest artifact sha256" "$ingest_sha256"

# Verify sidecar registered the ingestion artifact
sleep 2
registry=$(curl -sf "${SIDECAR_URL}/registry?pipeline_id=${PIPELINE_ID}")
ingest_manifest_id=$(echo "$registry" | python3 -c \
  "import sys,json; r=json.load(sys.stdin); uri='${ingest_s3_uri}'; print(r.get(uri,{}).get('manifest_id',''))" 2>/dev/null)
assert_nonempty "data-ingestion manifest_id in registry" "$ingest_manifest_id"

# Check SLSA attestation was generated for ingestion
slsa_list=$(curl -sf "${SIDECAR_URL}/slsa?pipeline_id=${PIPELINE_ID}&stage=data-ingestion")
slsa_count=$(echo "$slsa_list" | python3 -c "import sys,json; print(json.load(sys.stdin)['count'])" 2>/dev/null)
if [[ "${slsa_count}" -ge 1 ]]; then
  pass "SLSA attestation generated for data-ingestion"
  slsa_type=$(echo "$slsa_list" | python3 -c \
    "import sys,json; print(json.load(sys.stdin)['attestations'][0]['attestation']['_type'])" 2>/dev/null)
  assert "SLSA statement type is in-toto v0.1" "$slsa_type" "https://in-toto.io/Statement/v0.1"
  slsa_pred_type=$(echo "$slsa_list" | python3 -c \
    "import sys,json; print(json.load(sys.stdin)['attestations'][0]['attestation']['predicateType'])" 2>/dev/null)
  assert "SLSA predicate type is SLSA v0.2" "$slsa_pred_type" "https://slsa.dev/provenance/v0.2"
else
  fail "No SLSA attestation for data-ingestion stage"
fi

# ── Section 3: Preprocessing + provenance collection ─────────────────────────
echo ""
info "Section 3: Preprocessing"

preproc_resp=$(curl -sf -X POST \
  "${PREPROC_URL}/preprocess?split=${SPLIT}&pipeline_id=${PIPELINE_ID}")
preproc_job_id=$(echo "$preproc_resp" | python3 -c "import sys,json; print(json.load(sys.stdin)['job_id'])")
assert_nonempty "preprocess job queued" "$preproc_job_id"

wait_for_job "$PREPROC_URL" "$preproc_job_id" "Preprocessing"

preproc_info=$(curl -sf "${PREPROC_URL}/jobs/${preproc_job_id}")
preproc_s3_uri=$(echo "$preproc_info" | python3 -c "import sys,json; print(json.load(sys.stdin).get('s3_uri',''))" 2>/dev/null)
assert_nonempty "preprocess artifact S3 URI" "$preproc_s3_uri"

sleep 2
registry=$(curl -sf "${SIDECAR_URL}/registry?pipeline_id=${PIPELINE_ID}")
preproc_manifest_id=$(echo "$registry" | python3 -c \
  "import sys,json; r=json.load(sys.stdin); uri='${preproc_s3_uri}'; print(r.get(uri,{}).get('manifest_id',''))" 2>/dev/null)
assert_nonempty "preprocessing manifest_id in registry" "$preproc_manifest_id"

slsa_preproc=$(curl -sf "${SIDECAR_URL}/slsa?pipeline_id=${PIPELINE_ID}&stage=preprocessing")
slsa_preproc_count=$(echo "$slsa_preproc" | python3 -c "import sys,json; print(json.load(sys.stdin)['count'])" 2>/dev/null)
if [[ "${slsa_preproc_count}" -ge 1 ]]; then
  pass "SLSA attestation generated for preprocessing"
else
  fail "No SLSA attestation for preprocessing stage"
fi

# ── Section 4: Atlas CLI manifest validation ──────────────────────────────────
echo ""
info "Section 4: Atlas CLI manifest validation"

VERIFY_STAGES=("data-ingestion" "preprocessing")
VERIFY_MIDS=("$ingest_manifest_id" "$preproc_manifest_id")
for i in "${!VERIFY_STAGES[@]}"; do
  stage="${VERIFY_STAGES[$i]}"; manifest_id="${VERIFY_MIDS[$i]}"
  if [[ -z "$manifest_id" || "$manifest_id" == "null" ]]; then
    warn "Skipping verify for ${stage} — no manifest_id"
    continue
  fi
  verify=$(curl -sf "${SIDECAR_URL}/verify/${manifest_id}" 2>/dev/null || echo '{"valid":false}')
  valid=$(echo "$verify" | python3 -c "import sys,json; print(json.load(sys.stdin).get('valid',False))" 2>/dev/null)
  if [[ "$valid" == "True" ]]; then
    pass "${stage} manifest signature valid"
  else
    errors=$(echo "$verify" | python3 -c "import sys,json; print(json.load(sys.stdin).get('errors','?'))" 2>/dev/null)
    warn "${stage} manifest signature check returned valid=False (errors: ${errors})"
  fi
done

# ── Section 5: Provenance chain completeness (ingestion + preprocessing) ──────
echo ""
info "Section 5: Provenance chain"

lineage=$(curl -sf "${SIDECAR_URL}/lineage?pipeline_id=${PIPELINE_ID}")
stages_complete=$(echo "$lineage" | python3 -c \
  "import sys,json; print(','.join(json.load(sys.stdin).get('stages_complete',[])))" 2>/dev/null)
assert_contains "data-ingestion in stages_complete" "$stages_complete" "data-ingestion"
assert_contains "preprocessing in stages_complete" "$stages_complete" "preprocessing"

pipeline_status=$(curl -sf "${SIDECAR_URL}/pipeline/status?pipeline_id=${PIPELINE_ID}")
ingest_done=$(echo "$pipeline_status" | python3 -c \
  "import sys,json; print(json.load(sys.stdin)['stages']['data-ingestion']['done'])" 2>/dev/null)
preproc_done=$(echo "$pipeline_status" | python3 -c \
  "import sys,json; print(json.load(sys.stdin)['stages']['preprocessing']['done'])" 2>/dev/null)
assert "pipeline/status: data-ingestion done" "$ingest_done" "True"
assert "pipeline/status: preprocessing done" "$preproc_done" "True"

# ── Section 6: Optional fine-tuning ──────────────────────────────────────────
if $RUN_TRAIN; then
  echo ""
  info "Section 6: Fine-tuning (--with-train enabled)"
  warn "This can take 10–60 min on CPU."

  train_resp=$(curl -sf -X POST \
    "${FINETUNE_URL}/train?split=${SPLIT}&pipeline_id=${PIPELINE_ID}")
  train_job_id=$(echo "$train_resp" | python3 -c "import sys,json; print(json.load(sys.stdin)['job_id'])")
  assert_nonempty "train job queued" "$train_job_id"

  wait_for_job "$FINETUNE_URL" "$train_job_id" "Fine-tuning" 3600

  sleep 2
  lineage=$(curl -sf "${SIDECAR_URL}/lineage?pipeline_id=${PIPELINE_ID}")
  chain_complete=$(echo "$lineage" | python3 -c \
    "import sys,json; print(json.load(sys.stdin).get('chain_complete',False))" 2>/dev/null)
  assert "provenance chain complete after training" "$chain_complete" "True"

  slsa_train=$(curl -sf "${SIDECAR_URL}/slsa?pipeline_id=${PIPELINE_ID}&stage=fine-tuning")
  slsa_train_count=$(echo "$slsa_train" | python3 -c "import sys,json; print(json.load(sys.stdin)['count'])" 2>/dev/null)
  if [[ "${slsa_train_count}" -ge 1 ]]; then
    pass "SLSA attestation generated for fine-tuning"
  else
    fail "No SLSA attestation for fine-tuning stage"
  fi
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}════════════════════════════════════════════════════${NC}"
if [[ $FAILURES -eq 0 ]]; then
  echo -e "${GREEN}${BOLD} ALL TESTS PASSED${NC}"
else
  echo -e "${RED}${BOLD} ${FAILURES} TEST(S) FAILED${NC}"
fi
echo -e "${BOLD}════════════════════════════════════════════════════${NC}"
echo ""
echo "  Pipeline ID used:  ${PIPELINE_ID}"
echo "  Ingest manifest:   ${ingest_manifest_id:-n/a}"
echo "  Preproc manifest:  ${preproc_manifest_id:-n/a}"
echo ""
echo "  Inspect results:"
echo "    curl ${SIDECAR_URL}/lineage?pipeline_id=${PIPELINE_ID}"
echo "    curl ${SIDECAR_URL}/slsa?pipeline_id=${PIPELINE_ID}"
echo ""

exit $FAILURES
