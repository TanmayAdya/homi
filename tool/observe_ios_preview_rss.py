#!/usr/bin/env python3
"""Read-only RSS observation of one explicitly selected local simulator run.

Does not launch/stop processes, change caches, collect garbage, or read secrets.
The functional marker is separate from Flutter's final suite result and from
physical-device memory acceptance. Reports contain no copied log/command lines.
"""

import argparse
import datetime
import json
import os
from pathlib import Path
import re
import statistics
import subprocess
import tempfile
import time
import uuid


MAX_LOG_BYTES = 16 * 1024 * 1024
READY = re.compile(
    r"LOCAL_NATIVE_PREVIEW_SOAK_READY: pid=(\d+) cycles=(\d+) "
    r"durationSeconds=(\d+) startedAt=([^\s]+)"
)
CHECKPOINT = re.compile(
    r"LOCAL_NATIVE_PREVIEW_SOAK_CHECKPOINT: cycle=(\d+) elapsedMs=(\d+)"
)
PASSED = re.compile(
    r"LOCAL_NATIVE_PREVIEW_SOAK_PASSED: cycles=(\d+) elapsedMs=(\d+) "
    r"functionalAssertionsOnly=true"
)


def utc():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def read_log(path):
    if not path.exists():
        return ""
    if not path.is_file() or path.stat().st_size > MAX_LOG_BYTES:
        raise ValueError("The selected log is not a bounded regular file.")
    with path.open("rb") as source:
        data = source.read(MAX_LOG_BYTES + 1)
    if len(data) > MAX_LOG_BYTES:
        raise ValueError("The selected log exceeds its read bound.")
    return data.decode("utf-8", errors="replace")


def process_field(pid, field):
    result = subprocess.run(
        ["ps", "-p", str(pid), "-o", field + "="],
        capture_output=True,
        text=True,
        timeout=5,
        env={**os.environ, "LC_ALL": "C"},
        check=False,
    )
    return result.stdout.strip() if result.returncode == 0 else ""


def new_report_path(raw):
    root = Path(__file__).resolve().parent.parent / "backend" / "local-artifacts"
    output = Path(raw).expanduser().absolute()
    if root.is_symlink() or not root.is_dir():
        raise ValueError("The private local-artifacts directory must already exist.")
    parent = output.parent.resolve(strict=True)
    if not parent.is_relative_to(root.resolve()) or output.suffix != ".json":
        raise ValueError("Use a new .json report inside backend/local-artifacts.")
    output = parent / output.name
    fd = os.open(output, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    os.close(fd)
    return output


def save_report(path, report):
    fd, temporary = tempfile.mkstemp(prefix=".preview-rss-", dir=path.parent)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as target:
            json.dump(report, target, indent=2)
            target.write("\n")
            target.flush()
            os.fsync(target.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def observe(args, output, report):
    start = time.monotonic()
    total_deadline = start + 55 * 60 - 20
    ready_deadline = min(total_deadline, start + 10 * 60)
    match = None
    while time.monotonic() < ready_deadline:
        data = read_log(args.log)
        matches = list(READY.finditer(data))
        if len(matches) > 1:
            raise ValueError("Use a fresh log with one resource-session marker.")
        if matches:
            match = matches[0]
            break
        time.sleep(1)
    if match is None:
        report["status"] = "no_ready_marker"
        return False
    if CHECKPOINT.search(data[:match.start()]) or PASSED.search(data[:match.start()]):
        raise ValueError("Resource results must follow the selected READY marker.")
    ready_marker = match.group(0)
    pid, cycles, seconds = map(int, match.group(1, 2, 3))
    if pid < 1 or cycles != args.minutes * 5 or seconds != args.minutes * 60:
        raise ValueError("The resource marker does not match the selected duration.")
    started_text = match.group(4)
    if len(started_text) > 40:
        raise ValueError("Invalid resource start timestamp.")
    resource_start = datetime.datetime.fromisoformat(started_text.replace("Z", "+00:00"))
    if resource_start.tzinfo is None:
        raise ValueError("The resource timestamp must include its UTC offset.")
    ready_age = (datetime.datetime.now(datetime.timezone.utc) - resource_start).total_seconds()
    if not -10 <= ready_age <= 60:
        raise ValueError("Start the observer before, or promptly after, a fresh resource session.")
    arguments = process_field(pid, "args")
    birth = process_field(pid, "lstart")
    device_path = f"/CoreSimulator/Devices/{args.simulator}/"
    if device_path.lower() not in arguments.lower() or "/Runner.app/Runner" not in arguments or not birth:
        report["status"] = "process_identity_rejected"
        return False
    birth_time = datetime.datetime.strptime(birth, "%a %b %d %H:%M:%S %Y").astimezone(datetime.timezone.utc)
    if birth_time > resource_start + datetime.timedelta(seconds=2):
        raise ValueError("The current process started after the resource marker.")
    report.update(
        pid=pid,
        processStarted=birth,
        resourceStartedAt=resource_start.astimezone(datetime.timezone.utc).isoformat(),
        readyAgeAtAttachmentSeconds=round(ready_age, 3),
        observedAt=utc(),
        status="observing",
    )
    save_report(output, report)
    observed = time.monotonic()
    deadline = min(total_deadline, observed + (args.minutes + 4) * 60)
    checkpoints = {}
    while time.monotonic() < deadline:
        data = read_log(args.log)
        current_markers = list(READY.finditer(data))
        if len(current_markers) != 1 or current_markers[0].group(0) != ready_marker:
            raise ValueError("The selected resource log changed identity.")
        current_data = data[current_markers[0].end():]
        for cycle, elapsed in CHECKPOINT.findall(current_data):
            cycle, elapsed = int(cycle), int(elapsed)
            if not 1 <= cycle <= cycles or not 0 <= elapsed <= (args.minutes + 4) * 60000:
                raise ValueError("A checkpoint exceeded its declared session bounds.")
            if cycle in checkpoints and checkpoints[cycle] != elapsed:
                raise ValueError("Conflicting checkpoints in the selected log.")
            checkpoints[cycle] = elapsed
        report["checkpoints"] = [
            {"cycle": cycle, "elapsedMilliseconds": elapsed}
            for cycle, elapsed in sorted(checkpoints.items())
        ]
        passed = PASSED.search(current_data)
        functional = bool(
            passed
            and int(passed.group(1)) == cycles
            and seconds * 1000 <= int(passed.group(2)) <= (args.minutes + 4) * 60000
            and len(checkpoints) == cycles
        )
        report["functionalPassMarker"] = functional
        report["testSuitePassedObserved"] = "All tests passed!" in current_data
        if process_field(pid, "lstart") != birth:
            report["status"] = (
                "process_exited_after_functional_pass"
                if functional else "process_exited_before_functional_pass"
            )
            return functional
        raw = process_field(pid, "rss")
        if not raw.isdigit() or not 0 < int(raw) < 1024 * 1024 * 1024:
            report["status"] = "rss_unavailable"
            return False
        report["samples"].append({
            "utc": utc(),
            "elapsedSeconds": round(time.monotonic() - observed, 3),
            "rssBytes": int(raw) * 1024,
            "lastCompletedCycle": max(checkpoints, default=0),
        })
        save_report(output, report)
        if functional:
            report["status"] = "functional_pass_observed"
            return True
        time.sleep(min(5, max(0, deadline - time.monotonic())))
    report["status"] = "observer_deadline_exceeded"
    return False


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--log", type=Path, required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--simulator", type=uuid.UUID, required=True)
    parser.add_argument("--minutes", type=int, choices=(20, 45), default=20)
    args = parser.parse_args()
    try:
        output = new_report_path(args.output)
    except (ValueError, OSError):
        parser.error("Use a new .json report in the existing backend/local-artifacts directory.")
    report = {
        "schemaVersion": 1,
        "scope": "local_iOS_simulator_native_debug_process_RSS",
        "simulator": str(args.simulator),
        "requestedMinutes": args.minutes,
        "maximumObserverMinutes": 55,
        "sampleIntervalSeconds": 5,
        "physicalDeviceFootprint": False,
        "forcedGarbageCollection": False,
        "startedAt": utc(),
        "samples": [],
        "functionalPassMarker": False,
        "testSuitePassedObserved": False,
        "sampleCoverageSufficient": False,
    }
    save_report(output, report)
    success = False
    try:
        success = observe(args, output, report)
    except KeyboardInterrupt:
        report["status"] = "observer_interrupted"
    except (ValueError, OSError, subprocess.SubprocessError):
        report["status"] = "observer_input_or_process_error"
    finally:
        values = [sample["rssBytes"] for sample in report["samples"]]
        if values:
            window = min(24, max(1, len(values) // 3))
            elapsed = [sample["elapsedSeconds"] for sample in report["samples"]]
            span = elapsed[-1] - elapsed[0]
            maximum_gap = max((b - a for a, b in zip(elapsed, elapsed[1:])), default=0)
            coverage = (
                span >= args.minutes * 60 - 10
                and maximum_gap <= 15
                and report.get("readyAgeAtAttachmentSeconds", 61) <= 10
            )
            report["sampleCoverageSufficient"] = coverage
            report["summary"] = {
                "sampleCount": len(values),
                "firstRSS": values[0],
                "lastRSS": values[-1],
                "minimumRSS": min(values),
                "peakRSS": max(values),
                "medianFirstWindow": int(statistics.median(values[:window])),
                "medianLastWindow": int(statistics.median(values[-window:])),
                "windowSamples": window,
                "sampleSpanSeconds": round(span, 3),
                "maximumSampleGapSeconds": round(maximum_gap, 3),
            }
        if success and not report["sampleCoverageSufficient"]:
            report["status"] = "functional_pass_with_incomplete_sampling"
            success = False
        report.update(
            finishedAt=utc(),
            interpretation="Finite debug simulator RSS observation; not a physical-device memory limit or proof of indefinite leak freedom.",
        )
        save_report(output, report)
    print(json.dumps({
        "status": report["status"],
        "functionalPassMarker": report["functionalPassMarker"],
        "testSuitePassedObserved": report["testSuitePassedObserved"],
        "sampleCoverageSufficient": report["sampleCoverageSufficient"],
        "summary": report.get("summary"),
    }))
    return 0 if success else 1


if __name__ == "__main__":
    raise SystemExit(main())
