# Android bathroom scanning

The Flutter app uses a small native ARCore bridge through
`safe_at_home/bathroom_scan`. The app remains **AR Optional** and supports API 24+.
Photos and manual assessment continue to work on unsupported devices.

The assessment now makes 3D scanning the main option on ARCore-capable phones.
The native availability lookup uses ARCore's asynchronous API, coalesces
overlapping requests, and returns an unresolved result after three seconds if
the platform has not responded. A timed-out or failed check is not evidence
that the hardware is unsupported; the app can retry. Late replies cannot replace
a newer check. No camera session, permission request or installation is started
by this lookup, and depth support remains unknown until actual capture.

Capable phones with missing/outdated Google Play Services for AR or no camera
permission retain the scan setup option. Native capture checks compatibility
again after the user chooses Start, then offers camera permission and an
optional, dismissible service install/update flow. Phones without depth still
use planes and feature points; saved models and the photo/manual route remain
usable when capture is unavailable.

The pinned dependency is `com.google.ar:core:1.57.0`. There is no Google Cloud
project, API key, Cloud Anchor, Geospatial session, subscription or paid capture
service. The native activity presents the Google Play Services for AR notice and
links to Google's privacy policy before requesting camera access or installing
the platform's AR service.

## What is captured

- A real camera preview with tracked plane bounds and sampled 3D points.
- ARCore plane centers, local-axis extents and orientation. Every plane starts as
  `kind: unknown`; horizontal/vertical orientation does **not** identify a floor,
  wall, doorway, toilet, sink or bathtub.
- Sparse raw depth on supported devices, using texture-camera intrinsics and
  camera-to-world transforms. Without depth, the scan uses ARCore's feature
  points and explicitly reports `depth_unavailable`.
- At most 256 planes and 4,096 confidence-filtered points, deduplicated into
  5-centimeter sampling cells. This is a sampling choice, not a claim of
  5-centimeter measurement accuracy. Plane thickness remains zero/unknown.
- Partial coverage on every result. Missing samples never establish empty or
  accessible space. Plane rectangles are model bounds, not verified clearances.
- If the result exceeds the activity's byte budget, retain the planes first and
  evenly sample the retained point sequence. Mark the result truncated with
  `geometry_omitted`; fail explicitly if even the plane payload cannot fit.
  Invalid refined planes are removed instead of keeping an earlier stale shape.

No native camera frame, video, scan file or photo is written. Completed geometry
passes through a private activity result of at most 240 KiB to Flutter, which
validates it and uses the account's existing encrypted local store. The model
does not participate in cloud backups, cross-device resume or PDF attachments.
Explicitly confirmed observations use the normal assessment saving flow.

Captures stop after three minutes and discard the unfinished result. Backgrounding
an active scan also cancels it; the native coordinate frame is never silently
resumed after process death. The previously saved model remains available, and
the saved Flutter capture intent explains an interrupted scan. Cancellation is
scoped to the scan UUID, including late activity results from older scans.
The native session pauses before closing on a background thread. Only one
session can be active or closing; an immediate retry can report a busy camera.
Severe thermal pressure cancels capture on supported Android versions. The
time and geometry limits still apply where device-pressure callbacks are absent.
The camera and scrollable controls share the available inset viewport so short
landscape layouts and large text preserve access to Cancel.

## Local verification commands

Run from the app checkout, with Flutter dependencies already resolved:

```sh
cd /Users/david/Documents/Projects/safeathome/safe-at-home/android
JAVA_HOME=/Library/Java/JavaVirtualMachines/jdk-21.jdk/Contents/Home \
ANDROID_HOME=/Users/david/Library/Android/sdk \
./gradlew :app:testDebugUnitTest
```

The pure Kotlin tests verify filtering, bounded retention, correct coordinate
projection, unchanged unknown semantics, transform validation, depth-buffer
strides, export thinning, request validation, warning behavior, readiness
timeouts, overlapping checks and stale-reply rejection. They do not
open a camera or establish physical scanning accuracy.
The standard Flutter Android debug build and `tool/check_android_apk.py` remain
the packaging/privacy checks. The merged manifest must retain optional camera
hardware and disabled application backup; ARCore must not become required.
The installed-channel harness and packaged-manifest checks are in
`integration_test/native_scan_contract_test.dart` and `tool/check_android_apk.py`.

## Physical Android acceptance

Use fictional cases on a supported Android phone. No paid service is needed.
An emulator's unsupported-device result is useful fallback coverage, but it
cannot establish real Depth API behavior or room reconstruction accuracy.

1. Open **Home assessment → Scan bathroom in 3D** on a supported phone. Check that camera denial and
   unavailable AR services leave the photo/manual route usable. On a device
   needing Google Play Services for AR, verify the install/update prompt can be
   declined without losing the previous saved model.
2. Start a scan in a well-lit, unobstructed bathroom. Confirm the real camera
   view, tracking messages and updating surfaces/points. Move slowly from safe
   positions; do not walk backward while looking at the phone.
3. Finish and rotate the Flutter model. Compare visible plane orientations and
   approximate positions against the room. Confirm that ARCore features remain
   unidentified until the resident labels them. Depth-poor mirrors, glass and
   blank surfaces must remain visibly incomplete.
4. Identify and review a feature, record a resident-reported difficulty, and
   inspect the proposed observation. Add only after explicit confirmation.
   Check that no scan dimension becomes a verified manual measurement and no
   photograph or clinical determination is fabricated.
5. Restart the app and reopen the same fictional case. Check the encrypted
   model, labels and review state. Confirm that changing accounts or deleting
   the case cannot recover another account's model.
6. Start replacing an existing model, then cancel, background the app, terminate
   the process or allow the three-minute deadline to expire. Verify the old
   model survives and retry does not reuse a prior scan's coordinate frame.
7. Test a depth-capable phone and an ARCore-capable phone without depth when
   available. Record each actual device and its result separately; do not
   describe a build, unit test or unsupported emulator as both device passes.

This is a partial plane/point reconstruction, not a watertight house mesh or
automatic fixture-recognition system. Repeated physical measurements, tracking
drift, reflective bathrooms, long sessions and assistive-technology operation
still need real-device acceptance before resident use.

## Official references

- [AR Optional setup and installation](https://developers.google.com/ar/develop/java/enable-arcore)
- [Asynchronous availability and optional installation](https://developers.google.com/ar/reference/java/com/google/ar/core/ArCoreApk)
- [Session configuration and explicit native cleanup](https://developers.google.com/ar/develop/java/session-config)
- [Raw depth and confidence images](https://developers.google.com/ar/develop/java/depth/raw-depth)
- [Camera/depth projection](https://codelabs.developers.google.com/codelabs/arcore-rawdepthapi)
- [Google Play Services for AR disclosure](https://developers.google.com/ar/develop/privacy-requirements)
- [Official SDK releases](https://github.com/google-ar/arcore-android-sdk/releases)
