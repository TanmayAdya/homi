# Rooms and home safety v3

These additive envelopes preserve strict v1 cases and v2 assessment APIs.
The canonical public catalog is `backend/src/assessment/steadi-catalog.json`,
also bundled by Flutter. Its source, section, adaptation version and review date
travel with the room/checklist definition; no remote text or model output
controls questions or decisions.

- `POST /v3/read-home-safety`: `{schemaVersion:"3",caseId}`. Returns a consistent
  v1 case plus the separately revisioned room/checklist record. Requires the
  current authenticated case owner and returns `Cache-Control: no-store`.
- `POST /v3/save-home-safety`: expected case and checklist revisions, a retained
  mutation ID, and one operation. Supports adding, renaming, archiving, restoring
  and permanently deleting room instances, answering questions, explicitly reviewing a concern, or assigning an existing
  finding to a room. Requests are bounded by the normal 16 KiB HTTP limit.
- Room IDs and finding IDs are independent of names, locales and question order.
  `bathroom` and `entrance` retain their existing v1 mappings; other room types
  adapt to v1 `other`. Legacy findings remain unassigned until chosen explicitly.
- Answers distinguish yes, no, not sure, not applicable, and unanswered. The
  catalog records which answer suggests a concern. No answer automatically
  creates a finding, a clinical score, a diagnosis, or an eligibility decision.
- Explicit concern review writes a canonical finding and its room/question link
  atomically. It advances the case revision and invalidates matches, packet
  payloads and exports using the existing repository behavior. Answer/name edits
  alone advance only the checklist revision. Existing evidence/measurements are
  preserved when a linked finding is reviewed again. Exactly bound v2 measurement
  provenance is carried forward with an assessment history event in that same
  transaction; stale v2 provenance is never rebound based on equal numeric values.
- A link records the answer revision last reviewed. Later answer edits retain
  the finding and expose the difference for explicit review. Re-review uses the
  same finding ID. A deleted finding is never silently recreated; its checklist
  history remains, and the existing manual assessment supports new observations.
- History records the exact request hash, mutation ID, actor, server timestamp,
  operation, checklist revision and case revision. Exact retries acknowledge the
  original mutation even if later case/checklist changes exist; a reused ID with
  different input fails. Responses may therefore contain a newer head.
- Runtime limits: 32 rooms, 512 answer records, 100 finding links, 500 events and
  256 KiB of compact JSON per record. There is no silent history truncation.
  Flutter limits a pending local queue to 100 operations and the encrypted
  journal to 512 KiB. The transport bounds responses to 288 KiB.

The JSON schemas define shape. Runtime validation additionally checks room/
question applicability, unique IDs, question-to-answer links, revision bounds,
names/control characters, source versions, byte limits, and mutation receipts.
The shared fictional fixture is consumed by Dart; backend and real Dart-to-HTTP
tests exercise the same catalog and behavior.

Migration 007 stores the bounded private sidecar on the existing case row,
inheriting forced owner RLS and case/account deletion. Deletion previews include
its fingerprint. Backup/restore validates and preserves it; exact checksummed
five/six-migration archives normalize its absent value to SQL NULL. Physical
capacity reporting includes its storage in the case relation.

Hosted routes are default-off unless `homeSafetyEnabled` is passed to the
durable server; the executable uses `SAFEATHOME_HOME_SAFETY_ENABLED=true`.
The explicitly fictional local server enables them for development tests.
No migration runs automatically on startup.

## Room lifecycle

Rooms optionally carry `archived: true`; active room JSON retains its exact earlier
shape. `archive_room` and `restore_room` retain scans, findings and task state.
`delete_room` requires an archived room and `expectedModelRevision`, and removes
the current room, answers, assignment links and account model atomically. Existing
findings, photos, tasks and reminders remain; findings need explicit reassignment.
Retired room IDs cannot be reused. Local model cleanup follows acknowledgement,
including after restart, and clears connected models containing the deleted room.
This is not an audit-history or backup erasure. See
[room lifecycle semantics](../../docs/room-lifecycle.md) for compatibility and recovery.

## Simple helper invitations

`permission-sharing.schema.json` adds `create-email-invitation` (recipient's sign-in
email replaces account ID) and owner-only `list-email-sharing` (adds nullable
`invitedEmail`). Legacy list shapes stay exact. Existing review/accept contracts
remain unchanged; redemption requires the invited provider-verified email and an
explicit acceptance. See `fixtures/email-invitation.json` and
[implementation, flags and device checks](../../docs/simple-helper-invitations.md).
Migration 013 and the default-off `SAH_SIMPLE_INVITATIONS_ENABLED` flag are required.

## Sharing labels

There is no server-side profile or display-name source, and plan names stay
owner-only, so shared rows carry no plan name. Create requests may add optional
owner-typed `recipientLabel` ("Who is this for?") and `ownerLabel` (the name the
owner chooses to show). List and review requests opt in with `includeLabels: true`;
without it responses keep the exact earlier shape. `recipientLabel` is returned
only on the owner's `list-sharing`/`list-email-sharing` rows; recipients get only
`ownerLabel`. Labels are not verified identities, are kept by `change-sharing`
and cleared on revocation. See `fixtures/sharing-labels.json`. No migration.

## Detailed helper sharing

`sensitive-sharing.schema.json` and `fixtures/sensitive-sharing.json` define eight
additive selected-data operations. Owner previews and exact permission/source
bindings cover individual photos, measurements and private answers. Filtered PDFs
require independent opt-in and exclude photo bytes and full application packets.
Migration 012 and a separate default-off flag are required; see
[authorization and activation requirements](../../docs/sensitive-sharing-design.md).

## Additive referral tasks

Progress requests may opt into `includeReferrals: true`. Without that capability,
progress task responses retain the exact earlier v3 shape. Opted-in clients can
read/write the optional task `referral` object (`providerId`, optional immutable
import provenance). Legacy writes omit it without erasing an existing referral.
The import's canonical original-task digest and unique source ID are validated at
runtime, including during backup restore. No benefit-program or status report is
created by a referral. See [referral fixtures](fixtures/referral-progress.json)
for saved source provenance and the request/response shapes.

## Notes, photo references and addressed reports

History adds `annotate_answer` (question note and up to six owned revision-bound
photo references) and `set_addressed` (explicit reversible resident report, not
verified repair). `evidenceCatalogRevision` is an additive optional state binding
and photo-bound addressed-report field. Existing fixtures without it remain
readable. New operations require upgraded readers; never silently drop history.

`home-safety-report-request.schema.json` and `home-safety-report.schema.json`
define owner-only `POST /v3/export-home-safety`. Optional notes/reference inclusion
is explicit. No image bytes, public URL or application submission is created.
Hosted rollout and physical-device acceptance require separate verification.
