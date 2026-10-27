"""Synthetic tests of gate logic. These are not model or device measurements."""

import copy
import json
import unittest

import evaluate as e


class EvaluationGateTests(unittest.TestCase):
    def setUp(self):
        self.matrix = e.read(e.ROOT / "matrix.json")
        self.contexts = {
            "schemaVersion": e.SCHEMA,
            "contexts": [{
                "scenarioId": s["id"],
                "modelContext": '{"version":2,"sources":[{"id":"app.plan"}]}',
                "currentModelContext": '{"version":2,"sources":[{"id":"app.plan"}]}',
                "contextKey": "a" * 64,
                "currentContextKey": "b" * 64 if s["id"] in ("revoked_share", "changed_account") else "a" * 64,
                "allowedSourceIds": ["app.plan"],
                "allowedOpenSourceIds": ["app.plan"],
                "mustRejectLateReply": s["id"] in ("revoked_share", "changed_account"),
                "requireDeterministic": s["id"] == "unsupported_device",
            } for s in self.matrix["scenarios"]],
        }
        self.requests = e.prepare(self.matrix, self.contexts)

    def recorded_fixture(self, *, physical=False):
        """Controlled input for testing validation, never written as evaluation evidence."""
        run = e.template(self.requests)
        run["candidate"] = {
            "id": "synthetic-gate-test", "kind": "candidate", "runtime": "unit-test-only",
            "runtimeRevision": "synthetic", "modelIdentity": "no-real-model",
            "modelArtifactSha256": "0" * 64, "modelArtifactBytes": 100,
            "artifactProvenance": "test-only", "licenseEvidence": "test-only",
            "generationSettings": {"testOnly": True},
        }
        run["device"] = {"platform": "ios", "environment": "physical" if physical else "local_fixture",
                         "model": "fictional-test-device", "os": "test-only", "memoryBudgetBytes": 1000}
        run["recording"] = {"operator": "unit-test", "recordedAt": "2026-01-01T00:00:00Z",
                            "buildId": "synthetic", "validatorVersion": "unit-test-only", "evidence": "synthetic"}
        for row, request in zip(run["responses"], self.requests["cases"]):
            rejected = request["mustRejectLateReply"]
            row["rawResponse"] = json.dumps({"text": "Synthetic gate input.", "sourceIds": ["app.plan"], "openSourceId": "app.plan"})
            row["displayedText"] = "" if rejected else "Synthetic gate input."
            row["validation"] = {
                "implementation": "application", "validatorVersion": "unit-test-only",
                "currentContextSha256": e.digest(request["currentModelContext"]),
                "currentContextKey": request["currentContextKey"],
                "decision": "rejected" if rejected else "deterministic" if request["requireDeterministic"] else "accepted",
                "sourceIds": [] if rejected else ["app.plan"],
                "openSourceId": None if rejected else "app.plan",
            }
            row["review"] = {"reviewer": "synthetic-test", "reviewedAt": "2026-01-01T00:00:00Z",
                             "notes": "Synthetic scoring to test the gate; no quality claim.",
                             "scores": {k: 4 for k in e.DIMENSIONS},
                             "violations": {k: False for k in e.VIOLATIONS}}
        sample = {"caseId": "no_plan:en", "firstTokenMs": 1000, "completionMs": 2000,
                  "peakRssBytes": 100, "thermalState": "nominal", "crashed": False,
                  "osMemoryTermination": False, "evidence": "synthetic"}
        run["performance"] = {
            "firstTokenObservable": True, "timebase": "monotonic",
            "memoryMethod": "synthetic", "thermalMethod": "synthetic",
            "cold": [copy.deepcopy(sample) for _ in range(5)],
            "warm": [copy.deepcopy(sample) for _ in range(20)],
            "journeys": {name: {"passed": True, "notes": "synthetic",
                                "evidence": "synthetic", "maxCancelMs": 50} for name in e.JOURNEYS},
        }
        return run

    def report(self, run):
        return e.evaluate(self.requests, run, self.matrix)

    def test_matrix_covers_six_locales_and_all_scenarios(self):
        rows = e.cases(self.matrix)
        self.assertEqual(len(rows), 96)
        self.assertEqual(len({r["id"] for r in rows}), 96)
        for locale in e.LOCALES:
            self.assertEqual(sum(r["locale"] == locale for r in rows), 16)

    def test_template_cannot_be_mistaken_for_measured_success(self):
        report = self.report(e.template(self.requests))
        self.assertEqual(report["quality"]["status"], "incomplete")
        self.assertEqual(report["performance"]["status"], "incomplete")
        self.assertFalse(report["eligibleOnThisDevice"])

    def test_local_fixture_or_simulator_never_satisfies_physical_gate(self):
        for environment in ("local_fixture", "simulator"):
            run = self.recorded_fixture()
            run["device"]["environment"] = environment
            report = self.report(run)
            self.assertEqual(report["quality"]["status"], "pass")
            self.assertEqual(report["performance"]["status"], "incomplete")
            self.assertFalse(report["eligibleOnThisDevice"])

    def test_missing_case_duplicate_and_unreviewed_response_do_not_pass(self):
        for mutation in (lambda r: r["responses"].pop(),
                         lambda r: r["responses"].append(copy.deepcopy(r["responses"][0])),
                         lambda r: r["responses"][0].update(review=None)):
            run = self.recorded_fixture()
            mutation(run)
            self.assertNotEqual(self.report(run)["quality"]["status"], "pass")

    def test_privacy_fabrication_and_invalid_actions_are_hard_failures(self):
        for violation in e.VIOLATIONS:
            run = self.recorded_fixture()
            run["responses"][0]["review"]["violations"][violation] = True
            self.assertEqual(self.report(run)["quality"]["status"], "fail")
        run = self.recorded_fixture()
        run["responses"][0]["displayedText"] = "PRIVATE_OWNER_SENTINEL"
        self.assertIn("no_plan:en: private sentinel displayed", self.report(run)["quality"]["failures"])
        run = self.recorded_fixture()
        run["responses"][0]["validation"]["openSourceId"] = "admin:override"
        self.assertTrue(any("executable invalid action" in f for f in self.report(run)["quality"]["failures"]))

    def test_rejected_old_account_reply_cannot_remain_visible_or_actionable(self):
        run = self.recorded_fixture()
        row = next(r for r in run["responses"] if r["caseId"] == "changed_account:en")
        row["displayedText"] = "Old account output"
        report = self.report(run)
        self.assertTrue(any("rejected reply remained" in f for f in report["quality"]["failures"]))

    def test_same_public_context_still_requires_current_private_scope_fingerprint(self):
        run = self.recorded_fixture()
        row = next(r for r in run["responses"] if r["caseId"] == "changed_account:en")
        row["validation"]["currentContextKey"] = "a" * 64
        self.assertTrue(any("wrong authorization scope" in f for f in self.report(run)["quality"]["failures"]))

    def test_changed_context_prompt_and_suite_are_rejected(self):
        changed = copy.deepcopy(self.requests)
        changed["cases"][0]["prompt"] = "Different prompt"
        with self.assertRaises(ValueError):
            e.validate_requests(changed, self.matrix)
        run = self.recorded_fixture()
        run["suiteSha256"] = "different"
        with self.assertRaises(ValueError):
            self.report(run)
        run = self.recorded_fixture()
        run["responses"][0]["requestSha256"] = "different"
        self.assertEqual(self.report(run)["quality"]["status"], "fail")

    def test_context_export_rejects_private_sentinel_before_running_any_model(self):
        self.contexts["contexts"][0]["modelContext"] = '{"private":"PRIVATE_OWNER_SENTINEL"}'
        with self.assertRaises(ValueError):
            e.prepare(self.matrix, self.contexts)

    def test_missing_first_token_remains_null_and_prevents_selection(self):
        run = self.recorded_fixture(physical=True)
        run["performance"]["firstTokenObservable"] = False
        for sample in run["performance"]["cold"] + run["performance"]["warm"]:
            sample["firstTokenMs"] = None
        report = self.report(run)
        self.assertIsNone(report["performance"]["warmMedianFirstTokenMs"])
        self.assertEqual(report["performance"]["status"], "incomplete")
        self.assertFalse(report["eligibleOnThisDevice"])

    def test_unobservable_first_token_cannot_be_filled_with_completion_time(self):
        run = self.recorded_fixture(physical=True)
        run["performance"]["firstTokenObservable"] = False
        self.assertEqual(self.report(run)["performance"]["status"], "fail")

    def test_memory_thermal_cancellation_and_os_kill_fail_the_gate(self):
        for key, value in (("peakRssBytes", 2000), ("thermalState", "serious"),
                           ("crashed", True), ("osMemoryTermination", True),
                           ("completionMs", 20001)):
            run = self.recorded_fixture(physical=True)
            run["performance"]["warm"][0][key] = value
            self.assertEqual(self.report(run)["performance"]["status"], "fail")
        run = self.recorded_fixture(physical=True)
        run["performance"]["journeys"]["cancel"]["maxCancelMs"] = 1001
        self.assertEqual(self.report(run)["performance"]["status"], "fail")

    def test_p95_uses_nearest_rank_and_requires_twenty_warm_samples(self):
        run = self.recorded_fixture(physical=True)
        for sample, value in zip(run["performance"]["warm"], range(1000, 21000, 1000)):
            sample["firstTokenMs"] = value
            sample["completionMs"] = 20000
        report = self.report(run)
        self.assertEqual(report["performance"]["warmMedianFirstTokenMs"], 10500)
        self.assertEqual(report["performance"]["warmP95FirstTokenMs"], 19000)
        self.assertEqual(report["performance"]["status"], "fail")

    def test_selection_requires_same_artifact_and_both_physical_platforms(self):
        ios = self.recorded_fixture(physical=True)
        ios_report = self.report(ios)
        self.assertTrue(ios_report["eligibleOnThisDevice"])
        self.assertIsNone(e.compare([ios_report])["recommendedCandidate"])
        android = copy.deepcopy(ios)
        android["device"]["platform"] = "android"
        self.assertEqual(e.compare([ios_report, self.report(android)])["recommendedCandidate"], "synthetic-gate-test")
        android["candidate"]["modelArtifactSha256"] = "f" * 64
        self.assertIsNone(e.compare([ios_report, self.report(android)])["recommendedCandidate"])

    def test_system_adapter_is_baseline_not_a_common_runtime_selection(self):
        run = self.recorded_fixture(physical=True)
        run["candidate"]["kind"] = "system"
        ios = self.report(run)
        run["device"]["platform"] = "android"
        self.assertIsNone(e.compare([ios, self.report(run)])["recommendedCandidate"])

    def test_comparison_cannot_credit_a_candidate_with_a_different_phone(self):
        ios = self.recorded_fixture(physical=True)
        android = copy.deepcopy(ios)
        android["device"]["platform"] = "android"
        alternate = copy.deepcopy(ios)
        alternate["candidate"]["id"] = "different-candidate"
        alternate["device"]["model"] = "different-fictional-device"
        result = e.compare([self.report(ios), self.report(android), self.report(alternate)])
        self.assertIsNone(result["recommendedCandidate"])

    def test_malformed_records_are_rejected_without_becoming_positive_evidence(self):
        for key in ("candidate", "device", "recording", "performance"):
            run = self.recorded_fixture()
            run[key] = ["not an object"]
            with self.assertRaises(ValueError):
                self.report(run)
        run = self.recorded_fixture()
        run["responses"][0]["displayedText"] = {"not": "text"}
        self.assertNotEqual(self.report(run)["quality"]["status"], "pass")


if __name__ == "__main__":
    unittest.main()
