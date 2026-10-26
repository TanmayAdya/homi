# Matcher and draft packet preparation

Manual application reports now have private, revision-checked read/append APIs and bounded history. Reports remain explicitly user-reported and never submit a form or verify an agency decision. See [manual request tracking](../docs/request-tracking-api.md) for contracts, uncertain-write recovery, the Flutter client and migration 003 rollout.

The matcher and draft checklist planner are hosting-independent TypeScript modules with no I/O. They have separate authenticated API handlers, a disposable HTTP demo, and an optional durable PostgreSQL/Supabase Auth server. The Free Supabase development project is configured and passed real-session/case checks; the Node API is deployed to Railway with a verified HTTPS development endpoint. The demo uses only a fictional program; the durable command-line server starts with an empty registry and no form artifact. The explicit `SAFEATHOME_BENEFITS_BUNDLE=scfhp-eaa-draft-v1` option enables a source-reviewed SCFHP referral route and pinned public form. It remains excluded from the defaults; see [SCFHP draft workflow](../docs/scfhp-draft-workflow.md). No real route is approved for live eligibility decisions.

The PDF renderers use pinned `pdf-lib` 1.17.1, private image preparation uses Sharp 0.35.5, and the optional PostgreSQL adapter uses `pg` 8.23.1; the matching engine itself remains dependency-free. The form renderer selects the reviewed service route and can populate 18 explicitly reviewed identity/contact/referral answers. The export renderer appends explicitly selected, sanitized evidence images. Answers remain revision-bound records; clinical, consent and signature answers remain manual review tasks.

Run from this `backend/` directory with a Node version supporting native TypeScript stripping (tested on Node 24.22.0):

```bash
npm test
```

Before the shared baseline is integrated into this worktree, explicitly read its canonical fixtures from the original checkout:

```bash
npm run demo -- ../../safe-at-home/contracts/v1/fixtures/scenarios.json
npm run test:contracts -- ../../safe-at-home/contracts/v1/fixtures/scenarios.json
```

After a human integrates the baseline, the default paths work:

```bash
npm run demo
npm run test:contracts
```

The shared scenarios remain in `contracts/v1/fixtures/scenarios.json`, with draft examples in sibling `packets.json`; this branch does not copy or maintain second versions. Both files are required by the contract check. Unit tests construct their own minimal synthetic inputs. The check compares identity, revisions, timestamps, statuses, missing fields, sources, program metadata and checklist IDs/responsibilities while allowing explanatory wording and reason codes to differ.

## Interface and interpretation

`matchPrograms(snapshot, registry, context)` validates unknown inputs and returns the v1 response. Invalid shapes, unsupported keys, wrong types, impossible dates, and malformed rules throw `InputValidationError`. Profile strings must be nonblank or null; false and numeric zero are preserved. Income may be any finite number, including a negative value, as defined in the shared contract.

Supply both `evaluatedAt` (UTC ISO timestamp ending in Z, with zero or one to six fractional digits) and its matching `evaluationDate`. Deadline comparisons preserve microsecond precision. The function never reads the current clock. Callers must use current, trusted server time for a live evaluation; the demo intentionally uses a fixed timestamp.

Rules support equality, inclusive numeric lower/upper bounds, AND/OR groups, explicit criterion exceptions, and `manual_review` leaves. A manual-review leaf has a reviewed reason, source IDs and responsible party, and always remains unknown. It has no synthetic profile field. Missing or conflicting answers produce unknown checks. An unresolved applicable exception prevents rejecting that criterion. An independent verified failure may still fail the overall program while unrelated unknown checks remain visible.

Real program records need verified rules, a review date, referenced sources on every leaf, and a recheck deadline. The engine verifies metadata consistency, not the truth or official ownership of a webpage. Human source review is still necessary. Current-source failures make the program checks unknown; availability remains separate from the eligibility result.

`recheckAfter` is capped at the earliest supplied review deadline or program/source effective transition. Effective-until dates include that whole UTC day; expiry is the following midnight. Null means no reusable freshness guarantee. Consumers must also invalidate responses after case revision or rule version changes. A possible match is never program approval.

Native Node strips type syntax but does not type-check. TypeScript 5.9.3 and Node24 declarations are now pinned development dependencies, with a lockfile for reproducible installs. Run:

```bash
npm ci --ignore-scripts
npm run typecheck
npm test
```

This type-checks source and tests without emission or skipped library checking. Dependencies under `node_modules` are ignored. Renderer/sanitizer tests require the pinned runtime dependencies and Sharp's platform binary from `npm ci --ignore-scripts`; unit tests use synthetic PDFs/images plus the bundled pinned public form, without network downloads.

## Local authenticated API

Saved cases can be discovered through the owner-only, paginated `POST /v1/list-cases` route, then reopened through `read-case`. Both demo and durable compositions enable discovery. Minimal summaries, stable ordering, concurrent-change behavior and the Flutter client are documented in [case discovery and resume](../docs/case-discovery-api.md). This adds no migration or service and makes no invented recency or readiness claims.

Supabase Auth and PostgreSQL are the chosen provider direction. See [Supabase setup](../docs/supabase-setup.md) for Free-plan provisioning, separate private operator/runtime/test configuration, restricted-role bootstrap and the explicit live-session verifier. A successful local unit test is not evidence that a hosted project has been configured.

For the persistent option, see [durable storage and authentication](../docs/durable-storage-auth.md). After an operator configures the separate migration/runtime environments and restricted database login, `npm run migrate` applies explicit migrations and `npm run serve:durable` starts on loopback port 8788 by default. The [HTTPS hosting guide](../docs/https-hosting.md) covers the new container, platform `PORT`/host configuration, health checks, bounded request admission and `verify:hosted-api` command. The Railway development endpoint is live: `https://safe-at-home-api-development.up.railway.app`. Its Linux build, direct Supabase connection, health checks and two-user HTTPS session/isolation checks passed. A generated 12-megapixel photo also passed upload, private preview, owner isolation and cleanup. A real SLEEPING-to-SUCCESS wake check also passed; native phone checks remain outstanding. See the hosting guide. `npm run test:postgres` runs isolated native PostgreSQL integration tests when local server binaries are available. Supabase user checks use a fixed HTTPS origin and a modern publishable key; no elevated API key or mobile database access is required. The separate hosted checks passed authentication, case isolation, revision conflicts and restart persistence. The hosted draft workflow has its own explicit acceptance check; see the hosting guide for exact results and connection limits.

`src/api/match-case.ts` implements `handleMatchCase` using injected authentication, case repository and registry adapters. It authenticates first, loads an owner-scoped case, checks the expected revision, evaluates server-selected rules/time and returns success only after an atomic ownership/revision check and save. Missing/inaccessible cases share the same 404. The local memory adapter is not durable storage.

Run the demo before the shared baseline is integrated:

```bash
npm run serve:demo -- --fixtures ../../safe-at-home/contracts/v1/fixtures/scenarios.json
```

After integration, omit `--fixtures` and its value. The server binds only to `127.0.0.1:8787`, creates random temporary sessions for Alice and Bob, and prints their tokens and fictional case IDs. `--port 0` selects an available local port. `--machine` emits a JSON readiness line with the existing matching `endpoint` and new `packetEndpoint`; it contains temporary demo tokens and should not be copied to shared logs. Stop with Ctrl+C; sessions, cases, saved matches and draft packets disappear.

`POST /v1/match-case` requires `Authorization: Bearer TOKEN`, JSON content type, and exactly:

```json
{"schemaVersion":"1","caseId":"demo-case-matched","expectedCaseRevision":1}
```

Client identity, profile values, rule versions and clock overrides are rejected. Requests are limited to 16 KiB actual bytes. Every application response has `Cache-Control: no-store`; malformed requests, inaccessible cases and revision conflicts produce safe error envelopes. Dependencies must enforce their own bounded operational deadlines when production adapters are added.

The fixture registry has a fixed historical deadline for repeatable tests. Only the local server creates a one-hour fictional demo-session deadline on startup, so it remains usable on later dates. This never changes real policy metadata or the original fixtures. API 200 means evaluated/saved; clients must still check case identity/revision, rule updates and `recheckAfter` before treating a response as current.

From the separate Flutter checkout, exercise the actual Dart transport and this server together:

```bash
dart run tool/check_matching_api.dart --backend ../safe-at-home-backend/backend
```

After both branches are combined, omit the `--backend` argument. The script starts and stops its own local server and checks all three outcomes, valid/invalid sessions, user isolation, revision conflicts and late client responses. The fuller UI/production handoff is `docs/matching-api.md` in the baseline branch.

## Draft packet API

`POST /v1/prepare-packet` uses the same bearer authentication, JSON parsing and 16 KiB actual-body limit. Send exactly:

```json
{"schemaVersion":"1","caseId":"demo-case-matched","expectedCaseRevision":1,"programId":"demo-home-support","generationKey":"draft-request-001"}
```

Case/program IDs must be nonblank and at most 200 Unicode scalar values. Generation keys contain 8–128 ASCII letters, digits, underscores or hyphens. The client supplies no owner, case contents, form, rule, packet ID or clock. `createMatchingServer(matchDeps, packetDeps)` enables matching and packet preparation; without the second argument, packet preparation is disabled. The authorized `/v1/read-case` route remains available for revision recovery.

`handlePreparePacket` loads the authenticated owner's case and current registry, then recomputes the selected match using server time. `planDraftPacket` creates a deterministic checklist. Without a configured form adapter, `formVersion` and `mappingVersion` remain null. An optional server-side `loadFormTemplate(programId)` returns a reviewed template definition plus the actual PDF bytes, or null when no adapter is configured for that program. The handler validates and detaches the definition, verifies the byte digest, then returns its content-based form version, mapping version and field-specific review tasks. Loader errors or changed bytes fail safely instead of silently falling back.

Every checklist API output remains `draft`, with `storageReference` null and `attachments` empty. This route returns no PDF; the separate export/download routes below render and return authorized artifacts. Official form currency and intake still require review. Failed and unresolved checks, conflicting answers, unreviewed findings and uncertain measurements remain review tasks. Evidence IDs alone never prove private evidence is accessible or suitable for inclusion. Required-document names lack provider/supplied-state metadata, so their tasks ask the program to identify who supplies them. A check with unknown responsibility similarly creates a program coordination task.

Use the same generation key to retry one preparation attempt. The atomic repository operation checks ownership, case revision and the `(userId, caseId, generationKey)` record together. A current retry returns the exact saved packet ID, timestamp and checklist. The fingerprint binds the full case, selected program/rules/metadata, current match, planner version and full optional form definition (including its byte pin and field bindings); timestamps of repeated evaluation are excluded. Changing any of that context with the same key produces `409 PACKET_GENERATION_CONFLICT`. Another authenticated user or case has a separate key namespace.

The server checks freshness after loading rules, immediately before persistence and after the awaited repository result. A passed review/source deadline cannot create or return a current draft; the program registry must be reviewed before retrying with a new key. Null `recheckAfter` allows a new unresolved draft but provides no reuse guarantee: repeating that key returns a generation conflict. Unknown programs return `404 PROGRAM_NOT_FOUND`; missing and inaccessible cases share `404 CASE_NOT_FOUND`; revision changes return `409 CASE_REVISION_MISMATCH`. Dependency failures are sanitized 503 responses, malformed internal data is a sanitized 500, and every response disables caching.

## Reviewed answer API

See [reviewed form answers](../docs/form-answers-api.md) for exact requests, supported fields, safe errors and the Flutter handoff. `createMatchingServer(matchDeps, packetDeps, formAnswerDeps)` enables authenticated `/v1/read-form-answers` and `/v1/save-form-answers`. Every successful full replacement atomically advances the case revision and the independent answer revision. A lost save response requires a reload before another save. Stale records can be reviewed but cannot populate a packet; preparation returns `FORM_ANSWERS_STALE` until they are reviewed and saved for the current case/form.

For a fictional end-to-end client exercise, add `--form-answers` to `serve:demo`. It creates a one-field synthetic form for the existing demo program and advertises read/save endpoints in `--machine` output. It does not enable SCFHP policy or accept real records. The ordinary demo includes case creation/saving; photo and export routes require `--exports`. Answer records, like cases and packets, disappear on process exit. The integration check is `dart run tool/check_form_answers_api.dart --backend ../safe-at-home-backend/backend` from the original Flutter checkout.

Production still needs broader capacity and mobile acceptance, automated Auth-deletion worker operations, backup/restore, operational controls, mobile login integration and verified program records. Development Supabase identity, restricted PostgreSQL roles and verified TLS passed hosted checks. The optional durable repository implements transactions and owner/case/generation-key constraints, with expiry checked after lock waits. Dynamic registry/form version changes still require reviewed coordination; the durable CLI starts empty and the demo configuration is fixed for its session. Do not deploy the demo token service or memory store. Signature capture, submission and approval integrations do not exist.

## Private evidence and draft export

See [the evidence/export API handoff](../docs/evidence-export-api.md) for exact requests, revision rules, safe errors and remaining integration work. Add `--exports` to the local demo command to enable a fictional form and generated evidence. The ordinary demo includes case creation/saving; photo and export routes require `--exports`. `createMatchingServer(matchDeps, packetDeps, formAnswerDeps, exportDeps)` enables:

- `POST /v1/list-evidence`: owner-scoped descriptors and catalog revision.
- `POST /v1/download-evidence`: authenticated sanitized PNG bytes after case/catalog/asset checks.
- `POST /v1/create-draft-export`: explicit reviewed selection, internally rendered form and one appendix page per selected image; returns metadata.
- `POST /v1/download-draft-export`: current owner-scoped PDF bytes with a generic download filename.

The service accepts up to six selected images tied to confirmed findings. Every page remains visibly incomplete and not submitted. Form rendering issues, unsupported caption text or layout overflow stop export. Missing facts and estimated/unconfirmed measurements stay explicit; observations never supply clinical answers. No image URL, arbitrary PDF attachment, signature or consent value is accepted.

`registerTrustedEvidence` is the internal assessment handoff, not a public upload API. It authorizes before decoding and saves only newly re-encoded JPEG/PNG-derived PNGs; original filenames, EXIF/GPS/text metadata and original bytes are not stored. Raw input is limited to 8 MiB, 16 million pixels and an 8192-pixel edge. Sanitized output is limited to 24 MiB; the final export and combined selected PNG data are limited to 32 MiB each. Visible private details in pixels still require resident review.

The disposable repository is bounded to 64 MiB, 64 evidence records and 16 artifacts, including retained revision/idempotency tombstones. Waiting for expiry does not free record slots; restarting the disposable server clears its sessions and all data. The PostgreSQL adapter preserves data/tombstones across restart and adds a database-wide 64-case limit; migration 002 counts only live PDF payloads against its 16-export quota and frees slots when bytes are cleared; its 64 MiB cap covers image/PDF bytes, not every metadata row or database file. Packet-key records have no separate retention/count cap yet. Artifact access lasts at most 15 minutes, shortened by a known policy recheck deadline. That operational lifetime never establishes policy currency or automatic erasure; unresolved policy remains labeled unknown. Case, answer, evidence and server-context changes invalidate downloads. Public upload/delete endpoints are described below. The durable server adds case/account deletion and database retention cleanup; see [retention and deletion](../docs/retention-and-deletion.md). Flutter deletion/review/export screens, automated Auth-worker operations and assessment acquisition remain integration work.

## SCFHP research and form preview

See [form preparation](../docs/form-preparation.md) for the exact content pin, local commands, mapping boundaries, and API adapter handoff. See [SCFHP source review](../docs/program-verification/scfhp-eaa.md) for policy conflicts.

`npm run research:scfhp -- --template /absolute/path/41567.pdf` verifies an externally downloaded public template and prints an explained result, field decisions and checklist for one built-in fictional case. Add `--preview /absolute/path/new-draft.pdf` to create a local incomplete PDF preview, and optionally `--reviewed-example` at the end to populate the 18 built-in fictional reviewed answers. Preview output includes `renderIssues`; do not treat a logically mapped field as rendered when an issue is present. The command never overwrites an existing file, does not fetch the template automatically and accepts no personal case file. Downloads and generated artifacts belong outside Git or in ignored `backend/local-artifacts/`.

## Case saving and photo acquisition

See [case and photo APIs](../docs/case-evidence-api.md) for complete wire examples, recovery rules and teammate responsibilities. The fifth `createMatchingServer` argument enables `/v1/create-case` and `/v1/save-case`; the sixth enables `/v1/upload-evidence` and `/v1/delete-evidence`. Both are optional dependency groups. `--exports` enables the full fictional workflow.

Case saves are bounded full replacements with server-owned revisions. Active uploaded evidence cannot be removed or rebound by a case save; explicitly delete it first. Photo upload authenticates before buffering, limits concurrent uploads, re-encodes supported images and atomically checks owner/case/catalog/asset versions. Only this route accepts larger JSON for canonical base64 image data. No original photo bytes are stored.

The shared `CaseEvidenceApiClient` implements all four mutations plus reload, detects uncertain writes and never automatically repeats them. From the Flutter checkout run `dart run tool/check_case_evidence_api.dart --backend ../safe-at-home-backend/backend` for a fictional real-HTTP lifecycle, including intentionally lost successful responses and draft invalidation after replacement. Durable case deletion is documented in [retention and deletion](../docs/retention-and-deletion.md). Case listing, mobile authentication/screens and native camera integration remain separate work.

## Linux container memory checks

`npm run profile:linux-memory -- ...` exercises actual HTTP photo/PDF requests and a disposable PostgreSQL database in an isolated Linux lab. It verifies a 500-MB hard cap, no swap, one CPU, process RSS, cgroup peaks, ownership, draft/download integrity and cleanup. See [the Linux memory guide](../docs/linux-memory-profiling.md) for the required explicit local socket, architecture, private report path, measured results and limits. It never uses cloud credentials or deploys the lab authentication fixture.
