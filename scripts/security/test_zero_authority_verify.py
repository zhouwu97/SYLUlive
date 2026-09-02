"""PR13 证据门禁和出站策略的无外部依赖回归测试。"""

from __future__ import annotations

import copy
import tempfile
import unittest
from pathlib import Path

from scripts.security import egress_policy, zero_authority_verify


def _valid_evidence() -> dict:
    return {
        "release": {
            "release": "F",
            "commit_sha": "a" * 40,
            "recorded_at": "2026-08-31T10:00:00+08:00",
        },
        "roles_signed": {
            "migration_owner": "migration-owner",
            "backend_owner": "backend-owner",
            "client_owner": "client-owner",
            "dba_data_owner": "dba-owner",
            "security_reviewer": "security-reviewer",
            "release_commander": "release-commander",
        },
        "observation_window_hours": 168,
        "metrics": {name: 0 for name in zero_authority_verify.ZERO_METRICS},
        "canary": {name: 0 for name in zero_authority_verify.CANARY_METRICS},
        "routes": [
            {
                "method": method,
                "path": path,
                "status_code": 410,
                "body_read": False,
                "old_handler_calls": 0,
            }
            for method, path in zero_authority_verify.RETIRED_ROUTE_PROBES
        ],
        "old_client": {
            "status_code": 426,
            "requests": 10,
            "upgrade_required_requests": 10,
            "successful_requests": 0,
            "route_family_coverage": 1.0,
        },
        "egress": {
            "mode": "default-deny",
            "school_personal_success": 0,
            "unknown_necessary_destinations": 0,
            "records": [
                {
                    "destination_class": "smtp",
                    "destination_host": "smtp.example.net",
                    "port": 465,
                    "protocol": "tls",
                    "decision": "allow",
                    "process": "sylulive",
                    "service_account": "sylulive",
                    "executable_or_image": "sha256:runtime",
                    "owner": "backend-owner",
                    "health_check": "smtp-connectivity",
                    "expires_at": "2099-01-01T00:00:00Z",
                    "dns_revalidated": True,
                    "network_enforced": True,
                }
            ],
        },
        "historical_zero": {"status": "verified"},
    }


class ZeroAuthorityVerifyTest(unittest.TestCase):
    def test_clean_evidence_and_artifact_pass(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            artifact = Path(directory) / "release"
            artifact.mkdir()
            (artifact / "app.bin").write_bytes(b"local-only runtime")
            report = zero_authority_verify.verify_evidence(_valid_evidence(), artifact)
        self.assertEqual(report["status"], "pass")
        self.assertEqual(report["summary"]["failed_checks"], 0)

    def test_nonzero_canary_and_forbidden_artifact_fail_without_echo(self) -> None:
        evidence = copy.deepcopy(_valid_evidence())
        evidence["canary"]["student_marker_matches"] = 1
        with tempfile.TemporaryDirectory() as directory:
            artifact = Path(directory) / "release"
            artifact.mkdir()
            (artifact / "server.bin").write_bytes(b"RemoteAcademicGateway")
            report = zero_authority_verify.verify_evidence(evidence, artifact)
        self.assertEqual(report["status"], "fail")
        self.assertNotIn("SYLU-ZERO", str(report))
        self.assertTrue(any(item["id"] == "release-artifact" for item in report["checks"]))

    def test_embedded_canary_marker_is_rejected_without_echo(self) -> None:
        evidence = _valid_evidence()
        evidence["canary"]["collector_note"] = "prefix sylu-zero-private-marker suffix"
        with tempfile.TemporaryDirectory() as directory:
            artifact = Path(directory) / "release"
            artifact.mkdir()
            (artifact / "app.bin").write_bytes(b"clean")
            report = zero_authority_verify.verify_evidence(evidence, artifact)
        canary_check = next(item for item in report["checks"] if item["id"] == "canary")
        self.assertIn({"rule": "raw_canary_marker_present"}, canary_check["findings"])
        self.assertNotIn("private-marker", str(report).lower())

    def test_missing_body_measurement_is_not_treated_as_false(self) -> None:
        evidence = _valid_evidence()
        evidence["routes"][0].pop("body_read")
        with tempfile.TemporaryDirectory() as directory:
            artifact = Path(directory) / "release"
            artifact.mkdir()
            (artifact / "app.bin").write_bytes(b"clean")
            report = zero_authority_verify.verify_evidence(evidence, artifact)
        route_check = next(item for item in report["checks"] if item["id"] == "retired-routes")
        self.assertEqual(route_check["status"], "fail")

    def test_every_retired_method_and_path_requires_its_own_probe(self) -> None:
        for missing_probe in zero_authority_verify.RETIRED_ROUTE_PROBES:
            with self.subTest(missing_probe=missing_probe):
                evidence = _valid_evidence()
                evidence["routes"] = [
                    row
                    for row in evidence["routes"]
                    if (row["method"], row["path"]) != missing_probe
                ]
                with tempfile.TemporaryDirectory() as directory:
                    artifact = Path(directory) / "release"
                    artifact.mkdir()
                    (artifact / "app.bin").write_bytes(b"clean")
                    report = zero_authority_verify.verify_evidence(evidence, artifact)
                route_check = next(
                    item for item in report["checks"] if item["id"] == "retired-routes"
                )
                self.assertEqual(route_check["status"], "fail")
                self.assertIn(
                    {
                        "rule": f"route_probe_missing:{missing_probe[0]} {missing_probe[1]}"
                    },
                    route_check["findings"],
                )

    def test_bind_post_probe_does_not_cover_bind_delete(self) -> None:
        evidence = _valid_evidence()
        evidence["routes"] = [
            row
            for row in evidence["routes"]
            if (row["method"], row["path"]) != ("DELETE", "/api/edu/bind")
        ]
        evidence["routes"].append(
            {
                "method": "POST",
                "path": "/api/edu/bind/",
                "status_code": 410,
                "body_read": False,
                "old_handler_calls": 0,
            }
        )
        with tempfile.TemporaryDirectory() as directory:
            artifact = Path(directory) / "release"
            artifact.mkdir()
            (artifact / "app.bin").write_bytes(b"clean")
            report = zero_authority_verify.verify_evidence(evidence, artifact)
        route_check = next(item for item in report["checks"] if item["id"] == "retired-routes")
        self.assertIn(
            {"rule": "route_probe_missing:DELETE /api/edu/bind"},
            route_check["findings"],
        )

    def test_dry_run_lists_explicit_route_probe_contracts(self) -> None:
        contract = zero_authority_verify._dry_run()
        self.assertNotIn("/api/edu/*", str(contract["retired_route_probes"]))
        self.assertIn(
            {"method": "POST", "path": "/api/forgot_password"},
            contract["retired_route_probes"],
        )
        self.assertEqual(
            contract["retired_route_probes"],
            [
                {"method": method, "path": path}
                for method, path in zero_authority_verify.RETIRED_ROUTE_PROBES
            ],
        )

    def test_egress_policy_rejects_secret_and_blocks_metadata(self) -> None:
        secret = egress_policy.validate_egress_record(
            {
                "destination_class": "smtp",
                "destination_host": "smtp.example.net",
                "port": 465,
                "protocol": "tls",
                "decision": "allow",
                "Cookie": "must-not-be-recorded",
            }
        )
        self.assertIn("sensitive_field_present", {issue.code for issue in secret})
        metadata = egress_policy.validate_egress_record(
            {
                "destination_class": "unknown",
                "destination_host": "169.254.169.254",
                "port": 80,
                "protocol": "http",
                "decision": "deny",
            }
        )
        self.assertEqual(metadata, ())

    def test_egress_policy_rejects_nested_identity_and_header_fields(self) -> None:
        record = copy.deepcopy(_valid_evidence()["egress"]["records"][0])
        record["collector"] = {
            "response": {"headers": [{"Set-Cookie": "private-cookie"}]},
            "identity": {
                "email": "private@example.invalid",
                "client-ip": "203.0.113.8",
                "device_id": "private-device",
            },
        }
        issues = egress_policy.validate_egress_record(record)
        self.assertIn("sensitive_field_present", {issue.code for issue in issues})

        summary = egress_policy.summarize_egress([record])
        self.assertEqual(summary["issue_counts"].get("sensitive_field_present"), 1)
        rendered = str(summary).lower()
        for secret in (
            "private-cookie",
            "private@example.invalid",
            "203.0.113.8",
            "private-device",
        ):
            self.assertNotIn(secret, rendered)


if __name__ == "__main__":
    unittest.main()
