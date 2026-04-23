"""
SLSA Provenance v0.2 attestation tests (Stretch Goal 7).

Validates that the sidecar generates well-formed in-toto Statements with a
SLSA Provenance v0.2 predicate for every collected artifact, and that the
/slsa endpoint returns them correctly.

Run:
  pytest tests/test_slsa.py -v                    # after any ingest
  pytest tests/test_slsa.py -v -m wired           # after full pipeline run
"""

import pytest
import requests

from conftest import (
    INGEST_TIMEOUT,
    INGEST_URL,
    PIPELINE_ID,
    SIDECAR_URL,
    raw_data_uri,
    wait_for_job,
)

SLSA_STATEMENT_TYPE = "https://in-toto.io/Statement/v0.1"
SLSA_PREDICATE_TYPE = "https://slsa.dev/provenance/v0.2"
DATASET_URI = raw_data_uri()
SLSA_PIPELINE_ID = "slsa-test"


# ── Helpers ────────────────────────────────────────────────────────────────────

def _collect_dataset(pipeline_id: str = SLSA_PIPELINE_ID) -> dict:
    """Run a tiny ingest and collect the artifact, returning the collect response."""
    resp = requests.post(
        f"{INGEST_URL}/ingest",
        params={"split": "train", "num_samples": 8, "pipeline_id": pipeline_id},
        timeout=10,
    )
    resp.raise_for_status()
    job = wait_for_job(INGEST_URL, resp.json()["job_id"], INGEST_TIMEOUT)

    artifact_uri = job["s3_uri"]
    collect_resp = requests.post(
        f"{SIDECAR_URL}/collect/dataset",
        json={
            "pipeline_id": pipeline_id,
            "stage": "data-ingestion",
            "artifact_s3_uri": artifact_uri,
            "ingredient_name": "SLSA test dataset",
            "author": "pytest-slsa",
            "metadata": {"sha256": job.get("sha256", "")},
        },
        timeout=120,
    )
    collect_resp.raise_for_status()
    return collect_resp.json()


def _assert_valid_slsa_statement(att: dict, *, artifact_uri: str = None) -> None:
    """Assert the top-level in-toto Statement structure is well-formed."""
    assert att.get("_type") == SLSA_STATEMENT_TYPE, \
        f"Expected _type={SLSA_STATEMENT_TYPE!r}, got {att.get('_type')!r}"

    assert att.get("predicateType") == SLSA_PREDICATE_TYPE, \
        f"Expected predicateType={SLSA_PREDICATE_TYPE!r}, got {att.get('predicateType')!r}"

    subjects = att.get("subject", [])
    assert isinstance(subjects, list) and len(subjects) >= 1, \
        f"subject must be a non-empty list, got: {subjects}"

    for subj in subjects:
        assert "name" in subj, f"subject entry missing 'name': {subj}"
        assert "digest" in subj, f"subject entry missing 'digest': {subj}"
        assert isinstance(subj["digest"], dict), f"subject.digest must be a dict: {subj}"

    if artifact_uri:
        uris = [s.get("uri") for s in subjects]
        assert artifact_uri in uris, \
            f"Expected artifact_uri {artifact_uri!r} in subject URIs: {uris}"


def _assert_valid_slsa_predicate(predicate: dict) -> None:
    """Assert the SLSA Provenance v0.2 predicate fields are present and typed."""
    assert "builder" in predicate, "predicate missing 'builder'"
    assert "id" in predicate["builder"], "predicate.builder missing 'id'"
    assert isinstance(predicate["builder"]["id"], str)

    assert "buildType" in predicate, "predicate missing 'buildType'"
    assert isinstance(predicate["buildType"], str)

    assert "invocation" in predicate, "predicate missing 'invocation'"
    inv = predicate["invocation"]
    assert "parameters" in inv, "invocation missing 'parameters'"
    params = inv["parameters"]
    assert "pipeline_id" in params, "parameters missing 'pipeline_id'"
    assert "stage" in params, "parameters missing 'stage'"
    assert "stage_order" in params, "parameters missing 'stage_order'"
    assert "artifact_type" in params, "parameters missing 'artifact_type'"

    assert "materials" in predicate, "predicate missing 'materials'"
    assert isinstance(predicate["materials"], list)

    assert "metadata" in predicate, "predicate missing 'metadata'"
    meta = predicate["metadata"]
    assert "buildStartedOn" in meta, "metadata missing 'buildStartedOn'"
    assert "buildFinishedOn" in meta, "metadata missing 'buildFinishedOn'"
    assert "completeness" in meta, "metadata missing 'completeness'"
    completeness = meta["completeness"]
    assert "parameters" in completeness
    assert "environment" in completeness
    assert "materials" in completeness
    assert "reproducible" in meta


# ── /slsa endpoint – smoke (no pipeline data required) ────────────────────────

class TestSLSAEndpointSmoke:

    @pytest.mark.smoke
    @pytest.mark.timeout(10)
    def test_slsa_list_returns_200(self):
        r = requests.get(f"{SIDECAR_URL}/slsa", timeout=5)
        assert r.status_code == 200

    @pytest.mark.smoke
    @pytest.mark.timeout(10)
    def test_slsa_list_schema(self):
        body = requests.get(f"{SIDECAR_URL}/slsa", timeout=5).json()
        assert "count" in body, "Missing 'count' key"
        assert "attestations" in body, "Missing 'attestations' key"
        assert isinstance(body["count"], int)
        assert isinstance(body["attestations"], list)

    @pytest.mark.smoke
    @pytest.mark.timeout(10)
    def test_slsa_unknown_tracking_id_returns_404(self):
        r = requests.get(
            f"{SIDECAR_URL}/slsa",
            params={"tracking_id": "does-not-exist-xyz"},
            timeout=5,
        )
        assert r.status_code == 404

    @pytest.mark.smoke
    @pytest.mark.timeout(10)
    def test_slsa_list_filterable_by_pipeline_id(self):
        body = requests.get(
            f"{SIDECAR_URL}/slsa",
            params={"pipeline_id": PIPELINE_ID},
            timeout=5,
        ).json()
        assert "attestations" in body
        for entry in body["attestations"]:
            assert entry["pipeline_id"] == PIPELINE_ID, \
                f"Entry with wrong pipeline_id returned: {entry}"


# ── SLSA attestation content after a direct collect call ──────────────────────

class TestSLSAAttestationContent:

    @pytest.mark.timeout(180)
    def test_collect_dataset_generates_slsa_attestation(self):
        """A collect/dataset call must produce a retrievable SLSA attestation."""
        collect = _collect_dataset()
        tracking_id = collect.get("tracking_id")
        assert tracking_id, f"No tracking_id in collect response: {collect}"

        r = requests.get(
            f"{SIDECAR_URL}/slsa",
            params={"tracking_id": tracking_id},
            timeout=10,
        )
        assert r.status_code == 200, \
            f"Expected 200, got {r.status_code}: {r.text}"
        att = r.json()
        _assert_valid_slsa_statement(att)

    @pytest.mark.timeout(180)
    def test_slsa_statement_type_is_in_toto(self):
        collect = _collect_dataset()
        tracking_id = collect["tracking_id"]
        att = requests.get(
            f"{SIDECAR_URL}/slsa",
            params={"tracking_id": tracking_id},
            timeout=10,
        ).json()
        assert att["_type"] == SLSA_STATEMENT_TYPE

    @pytest.mark.timeout(180)
    def test_slsa_predicate_type_is_slsa_v02(self):
        collect = _collect_dataset()
        tracking_id = collect["tracking_id"]
        att = requests.get(
            f"{SIDECAR_URL}/slsa",
            params={"tracking_id": tracking_id},
            timeout=10,
        ).json()
        assert att["predicateType"] == SLSA_PREDICATE_TYPE

    @pytest.mark.timeout(180)
    def test_slsa_predicate_fields_are_complete(self):
        collect = _collect_dataset()
        tracking_id = collect["tracking_id"]
        att = requests.get(
            f"{SIDECAR_URL}/slsa",
            params={"tracking_id": tracking_id},
            timeout=10,
        ).json()
        _assert_valid_slsa_predicate(att["predicate"])

    @pytest.mark.timeout(180)
    def test_slsa_subject_matches_artifact_uri(self):
        """The in-toto subject URI must reference the collected artifact."""
        pipeline_id = "slsa-uri-check"
        collect = _collect_dataset(pipeline_id=pipeline_id)
        tracking_id = collect["tracking_id"]
        artifact_uri = collect["artifact_s3_uri"]

        att = requests.get(
            f"{SIDECAR_URL}/slsa",
            params={"tracking_id": tracking_id},
            timeout=10,
        ).json()
        _assert_valid_slsa_statement(att, artifact_uri=artifact_uri)

    @pytest.mark.timeout(180)
    def test_slsa_predicate_stage_matches_collect_stage(self):
        collect = _collect_dataset()
        tracking_id = collect["tracking_id"]
        att = requests.get(
            f"{SIDECAR_URL}/slsa",
            params={"tracking_id": tracking_id},
            timeout=10,
        ).json()
        params = att["predicate"]["invocation"]["parameters"]
        assert params["stage"] == "data-ingestion", \
            f"Expected stage 'data-ingestion', got {params['stage']!r}"
        assert params["artifact_type"] == "dataset", \
            f"Expected artifact_type 'dataset', got {params['artifact_type']!r}"

    @pytest.mark.timeout(180)
    def test_slsa_list_includes_newly_collected_artifact(self):
        """After a collect, /slsa list must include the new attestation."""
        pipeline_id = "slsa-list-check"
        collect = _collect_dataset(pipeline_id=pipeline_id)
        tracking_id = collect["tracking_id"]

        body = requests.get(
            f"{SIDECAR_URL}/slsa",
            params={"pipeline_id": pipeline_id},
            timeout=10,
        ).json()
        assert body["count"] >= 1, "Expected at least one attestation after collect"
        ids = [e["tracking_id"] for e in body["attestations"]]
        assert tracking_id in ids, \
            f"tracking_id {tracking_id!r} not in /slsa list: {ids}"

    @pytest.mark.timeout(180)
    def test_slsa_c2pa_manifest_referenced_in_materials(self):
        """If atlas-cli returned a manifest_id, it must appear in SLSA materials."""
        collect = _collect_dataset()
        manifest_id = collect.get("manifest_id")
        if not manifest_id:
            pytest.skip("No manifest_id from atlas-cli — skipping materials check")

        tracking_id = collect["tracking_id"]
        att = requests.get(
            f"{SIDECAR_URL}/slsa",
            params={"tracking_id": tracking_id},
            timeout=10,
        ).json()
        material_uris = [m["uri"] for m in att["predicate"]["materials"]]
        assert any("c2pa" in uri for uri in material_uris), \
            f"C2PA manifest not referenced in SLSA materials: {material_uris}"


# ── Wired: SLSA attestations after the full pipeline run ─────────────────────

class TestSLSAWired:

    @pytest.mark.wired
    @pytest.mark.timeout(60)
    def test_wired_ingest_has_slsa_attestation(self, ingest_job):
        """After wired ingestion, the registry entry must have a SLSA attestation."""
        body = requests.get(
            f"{SIDECAR_URL}/slsa",
            params={"pipeline_id": PIPELINE_ID, "stage": "data-ingestion"},
            timeout=10,
        ).json()
        assert body["count"] >= 1, \
            "No SLSA attestations for data-ingestion after wired ingest"
        att = body["attestations"][0]["attestation"]
        _assert_valid_slsa_statement(att)
        _assert_valid_slsa_predicate(att["predicate"])

    @pytest.mark.wired
    @pytest.mark.timeout(60)
    def test_wired_preprocess_has_slsa_attestation(self, preprocess_job):
        body = requests.get(
            f"{SIDECAR_URL}/slsa",
            params={"pipeline_id": PIPELINE_ID, "stage": "preprocessing"},
            timeout=10,
        ).json()
        assert body["count"] >= 1, \
            "No SLSA attestations for preprocessing after wired preprocess"

    @pytest.mark.wired
    @pytest.mark.slow
    @pytest.mark.timeout(7200)
    def test_wired_all_stages_have_slsa_attestations(self, train_job):
        """Every stage must have at least one SLSA attestation after a full run."""
        for stage in ("data-ingestion", "preprocessing", "fine-tuning"):
            body = requests.get(
                f"{SIDECAR_URL}/slsa",
                params={"pipeline_id": PIPELINE_ID, "stage": stage},
                timeout=10,
            ).json()
            assert body["count"] >= 1, \
                f"No SLSA attestations for stage {stage!r} after full pipeline run"
            att = body["attestations"][0]["attestation"]
            _assert_valid_slsa_statement(att)
            _assert_valid_slsa_predicate(att["predicate"])
