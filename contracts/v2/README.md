# Private assessment, annotations and draft exports v2

The `/v2` envelopes extend the existing service. `CaseSnapshot`, `CaseDraft`,
canonical PNG descriptors and saved administrative form answers remain strict v1.
No v1 parser accepts new fields or silently strips overlays.

- `POST /v2/read-assessment` returns one consistent case, case fingerprint,
  evidence catalog revision, provenance and server history.
- `POST /v2/save-assessment` atomically saves the full v1 draft and metadata using
  expected case/fingerprint/catalog/assessment revisions. Retain an exact request
  and `mutationId` for uncertain retries; acknowledgement proves the mutation was
  applied even when a later case revision exists. A revision increase alone is
  not proof. History is server appended, capped at 500 events and 256 KiB. At the
  limit, no part of the new edit is saved; there is no silent history truncation.
- Measurement originals use stable `(findingId,type)` keys. Raw text is retained;
  parsing uses trimmed input, the selected decimal separator, at most four decimal
  places and nine significant digits. Conversion must equal the canonical mm
  measurement. Legacy measurements retain explicitly unknown provenance. Device
  capture/recording times remain reported values; server history times/actors are
  authoritative. Findings and reviews remain observations, not professional facts.
- `POST /v2/read-evidence-annotations` and `/v2/save-evidence-annotations` bind boxes
  and labels to the canonical PNG revision, SHA-256 and dimensions. Coordinates
  are `[left,top,width,height]` integer millionths of the top-left-oriented image.
  Maximum 20 marks, 80 characters per label, 800 label characters total and 12 KiB
  marks. Save advances the annotation and evidence catalog revisions. Image
  replacement/deletion clears overlays and review while retaining the monotonic
  annotation counter. Concurrent or uncertain writes require reloading/reviewing.
- `POST /v2/create-draft-export` includes `expectedAnnotationRevision` for every
  selected photo. Nonempty overlays require explicit review for the current case.
  PDFs draw boxes and labels using the same transform as the canonical image.
  Export metadata binds the full annotation hash and revision. `POST
  /v2/download-draft-export` revalidates these dependencies. A v1 request selecting
  evidence with saved marks is rejected with `ANNOTATIONS_REQUIRE_V2`.

Schemas describe the wire shape; runtime additionally enforces ownership, unique
keys, cross-record bindings, UTF-8 byte limits, exact timestamps and mathematical
rectangle/unit constraints. Shared Dart clients enforce fixed origins, bounded
responses, account/request guards, private response types and PDF hashes. They
never retry automatically or write private bytes to disk.

Migration 004 stores assessment and annotation sidecars; 005 stores the three
program-specific intake routes. All use forced owner RLS. Case/account deletion
purges sidecars, capacity reports count them, and backup captures validate them.
Restore remains quarantine-only and clears annotation review as well as existing
derived output capabilities. Archives bind the complete migration manifest; older
archives require their matching restore software. Nothing in this local contract
change applies a cloud migration or deploys the service.

Program intake and form review also expose `/v2/read-program-intake`,
`/v2/save-program-intake`, `/v2/read-form-answers`, `/v2/save-form-answers` with their
typed definitions in the backend and shared clients. See the implementation's
program-specific question definitions and official-form/preparation-sheet labels.

Intake saves use case and intake revisions and a pinned questionnaire version/hash.
They advance the case revision; missing facts stay unknown and recorded facts do
not become professional determinations. Form review v2 returns independently
allowlisted `fieldDefinitions` and an `artifactKind`. Saved administrative answers
remain schema v1 inside the v2 envelope. `fixtures/team-programs.json` contains
fictional SCFHP, HPSM and RTP round trips used by the shared Dart tests.

v2 exports bind the questionnaire and saved intake into the artifact identity and
append clearly labelled reported answers. Older-case reported facts are labelled
for re-review. Changing intake invalidates earlier downloads. A v1 export with
saved program intake fails with `INTAKE_REQUIRES_V2` rather than omitting it.
HPSM amounts above $7,500 add a documented exception-review notice. RTP exports
remain preparation worksheets and link to the separate official application.

Run the real cross-language integration from the app directory with Node 24.22
on PATH and resolved Flutter/backend dependencies:

```sh
dart --packages=.dart_tool/package_config.json tool/check_team_beta_api.dart --backend backend
```

It starts a loopback-only, in-memory HTTP server with the actual team bundle and
uses the production Dart clients for all three programs. It covers original
measurement text/history, exact retry after a lost successful response, private
photo upload/download, cross-client annotation resume, current-case review,
false/zero/unknown intake, independent form fields, owner isolation, and stale
draft invalidation. The downloaded PDFs are digest-checked in Dart and inspected
locally for rendered box/label operators and the reported-intake appendix,
including explicit prior-revision warnings and RTP worksheet labelling. Generated
pixels, tokens and PDF contents stay in memory and are not logged. The fixture
process receives no cloud environment. This check also runs in
`bash tool/verify_project.sh all`; it does not replace PostgreSQL, hosted-session
or physical-device acceptance.
