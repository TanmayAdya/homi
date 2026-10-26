#!/usr/bin/env python3
"""Check Android bridges in a separate app identity; never download a model or open camera."""
import argparse
import json
from pathlib import Path
import shutil
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--device", required=True)
    parser.add_argument("--flutter", default="flutter")
    args = parser.parse_args()
    flutter = shutil.which(args.flutter)
    if not flutter:
        parser.error("Flutter executable not found")
    devices = json.loads(subprocess.check_output([flutter, "devices", "--machine"], text=True))
    device = next((d for d in devices if d["id"] == args.device), None)
    if not device or not device.get("targetPlatform", "").startswith("android"):
        parser.error("Select an available Android device or emulator by exact ID")
    root = Path(__file__).resolve().parent.parent
    work = Path(tempfile.mkdtemp(prefix="sah-android-features-"))
    for name in ("lib", "test", "integration_test", "contracts", "third_party", "android"):
        shutil.copytree(root / name, work / name, symlinks=True,
                        ignore=shutil.ignore_patterns(".gradle", "build", "local.properties"))
    asset = Path("backend/src/assessment/steadi-catalog.json")
    (work / asset).parent.mkdir(parents=True)
    shutil.copy2(root / asset, work / asset)
    for name in ("pubspec.yaml", "pubspec.lock", "analysis_options.yaml", ".metadata"):
        shutil.copy2(root / name, work / name)
    gradle = work / "android/app/build.gradle.kts"
    original = gradle.read_text()
    identity = 'applicationId = "com.example.safe_at_home"'
    if original.count(identity) != 1:
        raise RuntimeError("Review the fixture app identity for this checkout")
    namespace = 'namespace = "com.example.safe_at_home"'
    if original.count(namespace) != 1:
        raise RuntimeError("Review the fixture namespace for this checkout")
    gradle.write_text(original.replace(identity, 'applicationId = "com.example.safe_at_home.android_features_check"')
        .replace(namespace, 'namespace = "com.example.safe_at_home.android_features_check"'))
    manifest = work / "android/app/src/main/AndroidManifest.xml"
    manifest.write_text(manifest.read_text().replace('android:label="Safe at Home"',
        'android:label="Android Feature Check"').replace('android:scheme="safeathome"',
        'android:scheme="sah-android-features-check"')
        .replace('android:name=".MainActivity"', 'android:name="com.example.safe_at_home.MainActivity"')
        .replace('android:name=".BathroomScanActivity"', 'android:name="com.example.safe_at_home.BathroomScanActivity"'))
    local = root / "android/local.properties"
    if local.exists():
        shutil.copy2(local, work / "android/local.properties")
    print(f"Isolated source and log: {work}", flush=True)
    print("Separate app: com.example.safe_at_home.android_features_check", flush=True)
    with (work / "device-check.log").open("w") as log:
        subprocess.run([flutter, "pub", "get", "--offline"], cwd=work,
                       stdout=log, stderr=subprocess.STDOUT, check=True)
        result = subprocess.run([flutter, "test", "--no-pub", "-d", args.device,
            "--dart-define=SAH_ANDROID_ISOLATED_APP=true",
            "integration_test/native_android_features_test.dart", "--reporter=expanded"],
            cwd=work, stdout=log, stderr=subprocess.STDOUT, timeout=900)
    print(f"Exit: {result.returncode}; log: {work / 'device-check.log'}", flush=True)
    raise SystemExit(result.returncode)


if __name__ == "__main__":
    main()
