# Home assessment module (Person 2)

Guided photos, manual measurements, observations, resident review, box
annotations, save/upload and export photo choice. Built against fakes; real
camera, login and app navigation are not wired in yet (see "Still needed").

Nothing here decides eligibility, safety, compliance or medical need.
Confirmation means only that the resident checked the observation and its
evidence.

## Try it

```
flutter run -t lib/features/assessment/dev/main_assessment_demo.dart
```

Development demo only: a fictional camera that draws a generated scene (or
simulates cancel, permission denied, no camera and HEIC), and an in-memory
stand-in server that does **not** sanitize images or keep anything.

## Layout

| Path | Purpose |
|---|---|
| `application/assessment_controller.dart` | Findings, measurements, review; outputs strict v1 `Finding`s; local measurement history |
| `application/assessment_flow.dart` | Guided route state: area → prompt → camera → preview → details → review |
| `application/assessment_sync.dart` | Save findings to the case, upload/replace/delete photos, uncertainty recovery |
| `application/case_evidence_gateway.dart` | Interface over the shared case/evidence clients, plus the real adapter |
| `application/export_review.dart` | Look at sanitized photos and choose up to six for the draft |
| `application/local_evidence_index.dart` | Which staged image holds each evidence ID's bytes |
| `application/fictional_scenarios.dart` | One fictional bathroom and one entrance scenario |
| `presentation/assessment_flow_screen.dart` | **Proposed entry point** for Person 1's navigation |
| `presentation/annotation_editor_screen.dart` | One box per photo, with button alternatives to dragging |
| `presentation/export_review_screen.dart` | Photo choice for the draft PDF |
| `presentation/save_status_card.dart` | Plain statement of what is and is not saved |
| `presentation/assessment_copy.dart` | All resident-facing wording, in one place for review |
| `domain/annotation/box_annotation.dart` | **Proposed** module-local annotation record and image/view mapping |
| `domain/capture/`, `domain/image/` | Camera abstraction, staging, coordinator, image checks |
| `domain/measurement/` | Units, parser, proposed vocabulary and definitions |
| `domain/review/` | Review states, snapshots, transitions and history |
| `domain/export/export_selection_draft.dart` | Six-image, confirmed-only, reviewed-revision selection |
| `domain/ids/id_factory.dart` | ID factory interface |
| `dev/` | Development-only demo, fictional camera and in-memory server |

Tests are in `test/features/assessment/`. All images in tests are synthetic
headers or generated drawings.

## Key behaviour

- **Stable IDs** come only from the injected `IdFactory`; reused or invalid IDs
  are refused, including after removal.
- **Strict v1 output.** `toFinding` passes through `Finding.fromJson`. Review
  history, typed measurement text, staging keys and annotations never appear
  in v1 JSON.
- **Measurements.** Empty means unknown (absent). A recorded 0 is kept and
  questioned where implausible. A changed value starts unconfirmed; earlier
  values are kept locally. An estimate stays an estimate after confirmation.
- **Review.** Any change to the observation, a photo or a measurement value
  withdraws confirmation. Dismissed findings must be restored first.
- **Capture.** Cancel, denial, permanent denial (no relaunch until the
  resident says the setting changed), no camera and unusable photos are
  explained; continuing without a photo is always possible. Retake never
  loses typed text, and neither does backgrounding the app, leaving the
  screen mid-capture or rotating.
- **Editing earlier findings.** The first step lists findings in progress;
  opening one loads its text and measurements exactly as typed. Tapping a
  photo on review opens it for retake or removal, including photos already
  uploaded. Saving unchanged values keeps their review.
- **Measurement history** is shown on review ("Earlier: 20 mm (you entered
  2 cm), then 25 mm"), including measurements cleared since.
- **Annotations** are stored in orientation-corrected image pixels. Only PNGs
  can be marked locally, because a phone JPEG may carry a rotation flag that
  the server applies later. Replacing a photo makes its boxes stale. Boxes
  are not in the PDF.
- **Saving** deletes removed server photos first, then saves the case, then
  uploads. It never retries automatically. After an uncertain result, all
  writes are blocked until `recover()` reloads the case and catalog; an
  upload that did succeed is recognised and not sent again. Staged originals
  are discarded only after a confirmed upload.
- **Export choice** needs the resident to look at each sanitized photo at its
  current revision; only confirmed findings' photos; at most six.

## Still needed

From **Person 1**:
- Mount `AssessmentFlowScreen`, `SaveStatusCard` and `ExportReviewScreen` in
  the app's navigation; own the `AssessmentFlow`, `AssessmentSync` and
  `ExportReview` lifetimes.
- Construct `CaseEvidenceApiClient` and `DraftExportApiClient` and pass
  `ApiCaseEvidenceGateway` in; supply the saved case and adopt
  `onCaseSaved` results into shared state.
- On sign-out or case switch: `controller.clear()`, `sync.reset(...)`,
  `exportReview.clear()`, `annotations.clear()`, and discard staging.
- The real `IdFactory` (`newUuidV4()` fits), camera package, and the
  persistent encrypted staging/backup/deletion policy.
- Agree storage for review history, measurement history and annotations.
- Loading findings from a saved case (for example after an app restart)
  into the controller is not built yet; findings can be reopened only while
  they are still held in memory.

From **Persons 1 and 3**: the measurement `type` vocabulary
(`clearOpening`, `thresholdHeight`, `curbHeight` are proposed), and whether
annotation overlays should ever be rendered in exports.

Not yet verified: native camera behaviour, physical iPhone/Android runs,
`ApiCaseEvidenceGateway` against the real backend, and how the screens look
on a device (no simulator was available when this was written).

## Running checks

```
dart format lib/features/assessment test/features/assessment
flutter analyze
flutter test test/features/assessment
bash tool/verify_project.sh flutter
```

Use the team's Flutter release (3.41.5). Changes are left unstaged and
uncommitted; a human reviews, stages and commits.
