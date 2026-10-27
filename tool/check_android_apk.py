#!/usr/bin/env python3
"""Check the packaged Android privacy declarations after manifest merging."""

import argparse
from pathlib import Path
import re
import subprocess
import sys
import zipfile


def native_capture_manifest_errors(manifest: str) -> list[str]:
    """Inspect exact nodes in aapt2 xmltree output, including merged metadata.

    Reading attributes from the owning node avoids accepting an exported scan
    activity just because a different activity happens to be private.
    """
    nodes = []
    stack = []
    for line in manifest.splitlines():
        element = re.match(r"^(\s*)E: ([\w-]+)\b", line)
        if element:
            indent = len(element[1])
            while stack and stack[-1][0] >= indent:
                stack.pop()
            path = (*stack[-1][1], element[2]) if stack else (element[2],)
            attributes = {}
            stack.append((indent, path, attributes))
            nodes.append((path, attributes))
        elif stack:
            attribute = re.match(
                r"^\s*A: http://schemas\.android\.com/apk/res/android:"
                r"([\w]+)(?:\([^)]*\))?=(.*)$",
                line,
            )
            if attribute:
                stack[-1][2][attribute[1]] = attribute[2].split(" (Raw: ", 1)[0]

    errors = []
    ar_metadata = [
        attrs for path, attrs in nodes
        if path == ("manifest", "application", "meta-data")
        and attrs.get("name") == '"com.google.ar.core"'
    ]
    if len(ar_metadata) != 1 or ar_metadata[0].get("value") != '"optional"':
        errors.append("Packaged application must declare Google ARCore optional")
    scan_activities = [
        attrs for path, attrs in nodes
        if path == ("manifest", "application", "activity")
        and attrs.get("name", "").endswith('.BathroomScanActivity"')
    ]
    if len(scan_activities) != 1:
        errors.append("Expected exactly one packaged bathroom scan activity")
    else:
        if scan_activities[0].get("exported") != "false":
            errors.append("Packaged bathroom scanner must explicitly be unexported")
        if scan_activities[0].get("excludeFromRecents") != "true":
            errors.append("Packaged bathroom scanner must be excluded from recents")
    return errors


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("apk", type=Path)
    parser.add_argument("--aapt2", required=True, type=Path)
    args = parser.parse_args()
    badging = subprocess.check_output(
        [str(args.aapt2), "dump", "badging", str(args.apk)], text=True
    )
    manifest = subprocess.check_output(
        [str(args.aapt2), "dump", "xmltree", "--file", "AndroidManifest.xml", str(args.apk)],
        text=True,
    )
    permissions = set(re.findall(r"^uses-permission(?:-sdk-\d+)?: name='([^']+)'", badging, re.M))
    errors = native_capture_manifest_errors(manifest)
    for permission in ("CAMERA", "INTERNET"):
        if f"android.permission.{permission}" not in permissions:
            errors.append(f"Missing required {permission} declaration")
    forbidden = {
        "RECORD_AUDIO", "READ_EXTERNAL_STORAGE", "WRITE_EXTERNAL_STORAGE",
        "READ_MEDIA_IMAGES", "READ_MEDIA_VIDEO", "READ_MEDIA_AUDIO",
        "MANAGE_EXTERNAL_STORAGE",
    }
    for permission in sorted(forbidden):
        if f"android.permission.{permission}" in permissions:
            errors.append(f"Unneeded microphone/media-library permission: {permission}")
    required_features = re.findall(r"^\s+uses-feature: name='([^']+)'", badging, re.M)
    for feature in required_features:
        if feature.startswith("android.hardware.camera") or feature == "android.hardware.microphone":
            errors.append(f"Photo import/manual entry must work without required hardware: {feature}")
    if not re.search(r":allowBackup\([^\n]+\)=false", manifest):
        errors.append("Packaged application does not explicitly disable backup")
    with zipfile.ZipFile(args.apk) as archive:
        for resource in ("res/xml/backup_rules.xml", "res/xml/data_extraction_rules.xml"):
            if resource not in archive.namelist():
                errors.append(f"Missing packaged privacy rule: {resource}")
    if errors:
        for error in errors:
            print(f"FAIL: {error}", file=sys.stderr)
        return 1
    print("Packaged APK privacy declarations passed: camera-only media permission, optional hardware/ARCore, private scanner activity, backup disabled.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
