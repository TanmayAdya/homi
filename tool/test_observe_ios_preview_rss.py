"""Bounded local tests; no ps calls, simulator, observer wait, or cloud access."""

import argparse
import contextlib
import datetime
import importlib.util
import io
import json
from pathlib import Path
import stat
import tempfile
import unittest
from unittest.mock import patch
import uuid


SPEC = importlib.util.spec_from_file_location(
    "preview_observer", Path(__file__).with_name("observe_ios_preview_rss.py")
)
observer = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(observer)
SIMULATOR = uuid.UUID("97259E1A-893D-4AD1-B2D3-D788CA6A06E8")


def ready(age=0):
    started = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(seconds=age)
    return (
        "LOCAL_NATIVE_PREVIEW_SOAK_READY: pid=123 cycles=100 "
        f"durationSeconds=1200 startedAt={started.isoformat()}\n"
    )


class ObserverTests(unittest.TestCase):
    def setUp(self):
        self.args = argparse.Namespace(log=Path("unused"), minutes=20, simulator=SIMULATOR)
        self.report = {"samples": [], "functionalPassMarker": False}

    def reject_log(self, data):
        with patch.object(observer, "read_log", return_value=data), patch.object(
            observer, "process_field", side_effect=AssertionError("No process probe expected")
        ), patch.object(observer, "save_report"), self.assertRaises(ValueError):
            observer.observe(self.args, Path("unused"), self.report)

    def test_stale_completed_log_is_rejected_before_process_probe(self):
        self.reject_log(ready(age=90) + "LOCAL_NATIVE_PREVIEW_SOAK_PASSED: cycles=100 elapsedMs=1200000 functionalAssertionsOnly=true")

    def test_future_ready_timestamp_is_rejected(self):
        self.reject_log(ready(age=-20))

    def test_results_before_ready_are_rejected(self):
        self.reject_log("LOCAL_NATIVE_PREVIEW_SOAK_CHECKPOINT: cycle=1 elapsedMs=12000\n" + ready())

    def test_duplicate_ready_markers_are_rejected(self):
        self.reject_log(ready() + ready())

    def test_wrong_simulator_process_is_rejected(self):
        def process(_pid, field):
            return "/CoreSimulator/Devices/another/Runner.app/Runner" if field == "args" else "Fri Oct 23 01:00:00 2026"
        with patch.object(observer, "read_log", return_value=ready()), patch.object(
            observer, "process_field", side_effect=process
        ), patch.object(observer, "save_report"):
            self.assertFalse(observer.observe(self.args, Path("unused"), self.report))
        self.assertEqual(self.report["status"], "process_identity_rejected")
        self.assertEqual(self.report["samples"], [])

    def test_changed_log_identity_is_rejected_without_sample(self):
        initial = ready()
        birth = (datetime.datetime.now() - datetime.timedelta(seconds=20)).strftime("%a %b %d %H:%M:%S %Y")
        def process(_pid, field):
            return f"/CoreSimulator/Devices/{SIMULATOR}/Runner.app/Runner" if field == "args" else birth
        with patch.object(observer, "read_log", side_effect=[initial, initial.replace("pid=123", "pid=124")]), patch.object(
            observer, "process_field", side_effect=process
        ), patch.object(observer, "save_report"), self.assertRaises(ValueError):
            observer.observe(self.args, Path("unused"), self.report)
        self.assertEqual(self.report["samples"], [])

    def test_output_is_private_atomic_and_never_replaces_existing_report(self):
        root = Path(__file__).resolve().parent.parent / "backend" / "local-artifacts"
        with tempfile.TemporaryDirectory(prefix="observer-test-", dir=root) as directory:
            path = observer.new_report_path(str(Path(directory) / "sample.json"))
            observer.save_report(path, {"fixture": "fictional"})
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
            with self.assertRaises(FileExistsError):
                observer.new_report_path(str(path))
            self.assertEqual(json.loads(path.read_text()), {"fixture": "fictional"})
            self.assertEqual(sorted(p.name for p in Path(directory).iterdir()), ["sample.json"])
        with self.assertRaises(ValueError):
            observer.new_report_path("/tmp/observer-must-not-create.json")

    def test_functional_marker_with_one_sample_does_not_claim_coverage(self):
        root = Path(__file__).resolve().parent.parent / "backend" / "local-artifacts"
        with tempfile.TemporaryDirectory(prefix="observer-test-", dir=root) as directory:
            path = Path(directory) / "coverage.json"
            def simulated_observation(_args, _output, report):
                report.update(status="functional_pass_observed", functionalPassMarker=True, readyAgeAtAttachmentSeconds=0)
                report["samples"] = [{"elapsedSeconds": 0, "rssBytes": 123456}]
                return True
            argv = ["observer", "--log", "unused", "--output", str(path), "--simulator", str(SIMULATOR)]
            with patch("sys.argv", argv), patch.object(observer, "observe", side_effect=simulated_observation), contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(observer.main(), 1)
            report = json.loads(path.read_text())
            self.assertTrue(report["functionalPassMarker"])
            self.assertFalse(report["sampleCoverageSufficient"])
            self.assertFalse(report["testSuitePassedObserved"])
            self.assertEqual(report["status"], "functional_pass_with_incomplete_sampling")

    def test_continuous_full_window_is_reported_separately_from_suite_pass(self):
        root = Path(__file__).resolve().parent.parent / "backend" / "local-artifacts"
        with tempfile.TemporaryDirectory(prefix="observer-test-", dir=root) as directory:
            path = Path(directory) / "coverage.json"
            def simulated_observation(_args, _output, report):
                report.update(status="functional_pass_observed", functionalPassMarker=True, readyAgeAtAttachmentSeconds=0)
                report["samples"] = [{"elapsedSeconds": step, "rssBytes": 123456} for step in range(0, 1201, 5)]
                return True
            argv = ["observer", "--log", "unused", "--output", str(path), "--simulator", str(SIMULATOR)]
            with patch("sys.argv", argv), patch.object(observer, "observe", side_effect=simulated_observation), contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(observer.main(), 0)
            report = json.loads(path.read_text())
            self.assertTrue(report["sampleCoverageSufficient"])
            self.assertFalse(report["testSuitePassedObserved"])
            self.assertEqual(report["summary"]["sampleSpanSeconds"], 1200)

    def test_late_attachment_or_sampling_gap_cannot_claim_complete_coverage(self):
        root = Path(__file__).resolve().parent.parent / "backend" / "local-artifacts"
        for age, steps in [(20, range(0, 1201, 5)), (0, [0, *range(20, 1201, 5)])]:
            with self.subTest(age=age), tempfile.TemporaryDirectory(prefix="observer-test-", dir=root) as directory:
                path = Path(directory) / "coverage.json"
                def simulated_observation(_args, _output, report):
                    report.update(status="functional_pass_observed", functionalPassMarker=True, readyAgeAtAttachmentSeconds=age)
                    report["samples"] = [{"elapsedSeconds": step, "rssBytes": 123456} for step in steps]
                    return True
                argv = ["observer", "--log", "unused", "--output", str(path), "--simulator", str(SIMULATOR)]
                with patch("sys.argv", argv), patch.object(observer, "observe", side_effect=simulated_observation), contextlib.redirect_stdout(io.StringIO()):
                    self.assertEqual(observer.main(), 1)
                self.assertFalse(json.loads(path.read_text())["sampleCoverageSufficient"])


if __name__ == "__main__":
    unittest.main()
