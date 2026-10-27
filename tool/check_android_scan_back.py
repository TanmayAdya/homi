#!/usr/bin/env python3
"""Run the real native scanner Back regression on a local Android emulator.

Installs the integration-test entrypoint; does not open the camera or sign in.
Rebuild/install the normal app afterward. Never sends input to a physical phone
or another foreground activity. Uses existing Flutter/Android tools only.
"""

import argparse
from datetime import datetime, timezone
import os
from pathlib import Path
import re
import signal
import subprocess
import time


def run_adb(adb: str, device: str, *arguments: str) -> str:
    return subprocess.check_output(
        [adb, "-s", device, *arguments], text=True, timeout=10,
    ).strip()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--flutter", required=True)
    parser.add_argument("--adb", required=True)
    parser.add_argument("--device", required=True)
    args = parser.parse_args()
    if not re.fullmatch(r"emulator-[0-9]+", args.device):
        parser.error("Choose an already booted local emulator, not a physical phone.")
    if run_adb(args.adb, args.device, "shell", "getprop", "ro.kernel.qemu") != "1":
        parser.error("The selected device did not identify itself as an emulator.")

    root = Path(__file__).resolve().parent.parent
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
    output = root / "backend" / "local-artifacts" / f"native-system-back-{stamp}.log"
    output.parent.mkdir(parents=True, exist_ok=True)
    print(f"Private local test log: {output}", flush=True)
    command = [args.flutter, "test", "--no-pub",
               "integration_test/native_scan_contract_test.dart",
               "--dart-define=SAH_TEST_SYSTEM_BACK=true", "--reporter", "expanded",
               "-d", args.device]
    process = None
    back_sent = False
    try:
        with output.open("w") as log:
            process = subprocess.Popen(command, cwd=root, stdout=log,
                                       stderr=subprocess.STDOUT, start_new_session=True)
            deadline = time.monotonic() + 300
            while process.poll() is None:
                if time.monotonic() >= deadline:
                    raise TimeoutError("Native Back check exceeded its five-minute build/test bound.")
                if not back_sent and "SAH_NATIVE_NOTICE_READY_FOR_SYSTEM_BACK" in output.read_text(errors="replace"):
                    activities = run_adb(args.adb, args.device, "shell", "dumpsys", "activity", "activities")
                    foreground = [line for line in activities.splitlines()
                                  if re.search(r"(?:topResumedActivity|mResumedActivity|ResumedActivity)[:=]", line)]
                    if any("com.example.safe_at_home/.BathroomScanActivity" in line
                           or "com.example.safe_at_home/com.example.safe_at_home.BathroomScanActivity" in line
                           for line in foreground):
                        run_adb(args.adb, args.device, "shell", "input", "keyevent", "KEYCODE_BACK")
                        back_sent = True
                        print("Sent system Back to the resumed native scanner notice.", flush=True)
                time.sleep(0.25)
            if process.returncode != 0:
                print(f"FAIL: Flutter/native acceptance exited {process.returncode}; inspect {output}")
                return process.returncode or 1
            if not back_sent:
                print("FAIL: The system Back event was never exercised.")
                return 1
            print("PASS: installed native system Back cancellation and next-request recovery.")
            return 0
    finally:
        if process is not None and process.poll() is None:
            for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGKILL):
                try:
                    os.killpg(process.pid, sig)
                    process.wait(timeout=10)
                    break
                except ProcessLookupError:
                    break
                except subprocess.TimeoutExpired:
                    continue


if __name__ == "__main__":
    raise SystemExit(main())
