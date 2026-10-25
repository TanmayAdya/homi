# Home assessment module (Person 2)

The live app opens `presentation/live_assessment_screen.dart` from the case
workspace. It combines the partner's guided bathroom/entrance workflow with
native photo capture, private persistence, saved-case hydration, and the v2
assessment/annotation APIs. The fictional demo remains available separately:

```sh
flutter run -t lib/features/assessment/dev/main_assessment_demo.dart
```

Observations and confirmations do not establish clinical need, legal
compliance, structural safety, or benefits eligibility. LiDAR is outside this
first beta; manual entries work on both mobile platforms.

## Implemented boundaries

- `application/live_assessment_session.dart` owns the selected case's encrypted
  local journal and serializes remote writes through Person 1's CaseCoordinator.
  Local drafts restore typed entries, measurements, correction/review history,
  photo staging descriptors, and image-bound marks. Account/session/case guards
  reject late responses. The local assessment envelope has a 512 KiB bound;
  staged image bytes are stored separately under the account's encrypted quota.
- Camera/library launch waits for a durable local capture checkpoint containing
  the intended area/view/source, planned finding/evidence IDs and any replaced
  photo version. A reservation creates no empty finding or fake server link.
  Cancelled IDs are never reused; at most one active reservation and 4,096
  issued IDs of each type keep this metadata bounded. An interrupted attempt
  restores idle with an explicit retry notice. A same-target/source retry uses
  the planned IDs but starts fresh native work. Late results cannot attach after
  the account, finding or photo version changes. Failed prelaunch persistence
  opens no camera or library UI.
- Photo attachment, removal, selection and conflict replacement publish only
  coherent encrypted snapshots. The full new attachment is saved before a
  potentially slow preview read, and only its durable replacement can retire
  earlier pixels. Intermediate controller notifications cannot save a missing
  or mismatched staging descriptor. Failed initialization cannot overwrite the
  retained journal through background callbacks or Back navigation.
- Retake, privacy-edit and upload cleanup requests are stored in that same
  encrypted envelope (at most 512 photo keys). Old bytes are deleted only after
  a successful draft write proves that its evidence index and pending-upload
  journal no longer reference them. A failed draft write retains the old photo;
  restart retries explicit cleanup intents. Unknown interrupted staging writes
  remain encrypted under the existing quota until explicit case/account cleanup;
  there is no speculative orphan sweep.
- A case saved online at least once can be assessed offline, even while resident
  details have unsaved or unresolved edits. Profile and assessment drafts remain
  separate. Online assessment/photo/annotation writes stay blocked until the
  resident reconciles the case details; guards recheck immediately before
  dispatch. First offline opening uses cached canonical values without inventing
  original-entry metadata, and preserves known remote originals for unchanged
  measurements when reconnecting. New cases need their first online save before
  assessment; previously saved photo downloads need a connection.
- `application/native_capture_adapter.dart` uses the camera package with audio
  disabled. iOS import uses a PHPicker file representation, avoiding an
  unbounded full-resolution UIImage before processing. Android uses the system
  photo picker. Imported photos have unknown capture time; camera photos carry
  the device-clock shutter completion time before normalization. Camera and
  library permission denials are independent. A backgrounded shutter result
  cannot complete a newly opened camera or change its busy state.
- `PrivateMediaPlatform.swift` and `PrivateMediaPlatform.kt` normalize
  orientation, decode to a maximum 2048-pixel edge, and emit JPEG at quality 85
  without inherited EXIF/GPS metadata. Inputs and decoded dimensions are
  bounded. iOS processing is serialized and uses complete file protection and
  backup exclusion. Android private storage uses `noBackupFilesDir`.
- `presentation/photo_privacy_screen.dart` lets the resident crop or place
  opaque black covers before upload. Edits alter the encoded pixel data. No
  image is written back into the resident's photo library. Separate width and
  height controls, drag alternatives, cover undo, crop reset and a textual
  selection summary support precise edits and large text.
  Opening the editor records a bounded original-photo/version marker. Crops and
  covers are not durable until Apply succeeds; interrupted editing explicitly
  reports that they were not applied and retains the original photo for review.
- Canonical v1 findings still contain only the existing schema fields. The v2
  atomic save stores original typed measurement text, units, method/provenance,
  and review metadata alongside the case. The server records actor, time and
  correction history. Legacy values with no original input remain explicitly
  unknown; stale metadata from older clients is not presented as the original
  value. Only an exactly bound case revision permits
  joining original units/recorder metadata, even when numeric values are equal.
- Live annotations are created only on downloaded sanitized images. The v2
  sidecar binds visible boxes and labels to the exact evidence revision, hash,
  dimensions and top-left normalized coordinates. Hidden/stale boxes are not
  sent for rendering. The private export screen displays and explicitly reviews
  saved photo/mark pairs; v2 PDFs render those reviewed marks.
  Each local annotation edit requests an encrypted draft save immediately,
  including before the editor's Done button is pressed.
- Lost upload responses never treat a revision increment as proof of this
  device's upload. The staged photo remains until the resident sees the saved
  photo and explicitly chooses a version. Atomic assessment saves retain their
  mutation IDs and recover by matching the server's request-hash receipt.
  Different local/cloud findings require an explicit choice before another write.
- Interrupted Android picker results have no verifiable OS operation receipt and
  are discarded with a retry notice. Already staged photos and typed draft
  content are retained. This is an intentional retry boundary, not automatic
  process-death import continuation.

## Verification and remaining device gates

`flutter test test/features/assessment` exercises fictional inputs, controller
hydration, correction history, encrypted staging isolation, concurrency,
uncertain upload recovery, and accessibility/widget flows. Shared client and
backend v2 contract tests cover the wire boundary. Unit fixtures do not prove
native image or permission behavior.

Before a resident beta, complete physical iPhone and Android runs for:

1. Camera denial/re-enable, no camera, capture cancellation, background/lock,
   incoming interruption and rapid account/case changes.
2. JPEG EXIF orientations 1–8, HEIC import (including cloud-backed Photos),
   large panorama rejection/downsampling and metadata inspection of output.
3. Exact opaque-redaction coverage and crop coordinates in portrait/landscape;
   confirm private details cannot be recovered from the uploaded image.
4. Restart while typing, staged-photo restoration, lost upload responses and
   another device replacing the same evidence.
5. Saved box/label placement on the exact sanitized photo, persistence across
   devices, explicit export review and actual generated PDF overlays.
6. VoiceOver/TalkBack, large text, permission settings, device storage exhaustion,
   complete file protection on lock, backup exclusions and sign-out deletion.
7. Resident-owned device signing/install and share-sheet cleanup. Simulator
   compilation does not replace these checks.

No accuracy claims are made for automated hazard detection or LiDAR scanning.
Changes remain unstaged and uncommitted for the user's review.
