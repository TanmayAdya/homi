#!/usr/bin/env python3
"""Run the fictional connected-home acceptance app with a separate native app identity.

No hosted services, production configuration, existing app data, or Git writes.
The temporary source copy/log remain outside the checkout for review.
"""
import argparse
import json
import re
from pathlib import Path
import shutil
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--device", required=True)
    parser.add_argument("--flutter", default="flutter")
    parser.add_argument("--ios-team", help="Optional existing cached signing team")
    args = parser.parse_args()
    if args.ios_team and not re.fullmatch(r"[A-Z0-9]{10}", args.ios_team):
        parser.error("Supply a valid existing cached signing team")
    flutter = shutil.which(args.flutter)
    if not flutter:
        parser.error("Flutter executable not found")
    devices = json.loads(subprocess.check_output(
        [flutter, "devices", "--machine"], text=True))
    device = next((d for d in devices if d["id"] == args.device), None)
    if not device or device.get("emulator") or device.get("targetPlatform") != "ios":
        parser.error("Select an available physical iPhone by exact ID")
    root = Path(__file__).resolve().parent.parent
    work = Path(tempfile.mkdtemp(prefix="sah-home-device-"))
    for name in ("lib", "test", "integration_test", "contracts", "third_party", "ios", "android"):
        shutil.copytree(root / name, work / name, symlinks=True,
                        ignore=shutil.ignore_patterns(".gradle", "build", "local.properties"))
    catalog = Path("backend/src/assessment/steadi-catalog.json")
    (work / catalog).parent.mkdir(parents=True)
    shutil.copy2(root / catalog, work / catalog)
    for name in ("pubspec.yaml", "pubspec.lock", "analysis_options.yaml", "l10n.yaml", ".metadata"):
        if (root / name).exists():
            shutil.copy2(root / name, work / name)
    project = work / "ios/Runner.xcodeproj/project.pbxproj"
    original = project.read_text()
    if "com.example.safeAtHome" not in original:
        raise RuntimeError("Review the fixture bundle identity for this checkout")
    project_text = original.replace("com.example.safeAtHome", "com.example.safeAtHome.homeCheck")
    if args.ios_team:
        project_text = project_text.replace('"iPhone Developer"', '"Apple Development"')
        project_text = re.sub(r"DEVELOPMENT_TEAM = [A-Z0-9]+;", (
            f"DEVELOPMENT_TEAM = {args.ios_team};\n"
            f"\t\t\t\tCODE_SIGN_STYLE = Automatic;"
        ), project_text)
    project.write_text(project_text)
    info = work / "ios/Runner/Info.plist"
    info.write_text(info.read_text().replace(
        "<string>Safe At Home</string>", "<string>Home Model Check</string>"
    ).replace("<string>safeathome</string>", "<string>sah-home-device-check</string>"))
    print(f"Isolated source and log: {work}", flush=True)
    print("App identity: com.example.safeAtHome.homeCheck (iOS only)", flush=True)
    with (work / "device-check.log").open("w") as log:
        subprocess.run([flutter, "pub", "get", "--offline"], cwd=work,
                       stdout=log, stderr=subprocess.STDOUT, check=True)
        result = subprocess.run([
            flutter, "test", "--no-pub", "-v", "-d", args.device,
            "--dart-define=SAH_HOME_ISOLATED_APP=true",
            "integration_test/native_connected_home_test.dart", "--reporter=expanded",
        ], cwd=work, stdout=log, stderr=subprocess.STDOUT, timeout=900)
    print(f"Device runner exit: {result.returncode}; log: {work / 'device-check.log'}", flush=True)
    if result.returncode == 0:
        subprocess.run([
            "xcrun", "devicectl", "device", "uninstall", "app", "--device", args.device,
            "com.example.safeAtHome.homeCheck",
        ], check=True)
    raise SystemExit(result.returncode)


if __name__ == "__main__":
    main()
