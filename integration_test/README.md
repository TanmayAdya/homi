# Local installed-iPhone acceptance

`fictional_journey_test.dart` exercises the production screens, clients, encrypted
local storage, native image editing and native PDF rendering against an isolated
loopback HTTP server backed by disposable PostgreSQL. Authentication is an
explicit fictional provider, and camera outcomes use a generated illustration.
Neither is evidence of real Supabase authentication or physical camera access.
The fixture never reads cloud credentials or makes external provider requests.

Use an already installed Node 24, PostgreSQL runtime and iOS simulator. Do not
start a paid/cloud environment for this test. Coordinate Flutter builds/tests so
only one command owns the build directory at a time.

After the default journey passes, append `--dart-define=SAH_IOS_TEXT_SCALE=3.2`
for an optional large-text run with a fresh fixture. This applies a bounded
test-host Flutter text scaler (1 through 3.2); it does not change iOS settings or
prove OS-native sheet scaling. Omitting the define preserves the device's default
text behavior. Record this run separately from the baseline journey.

From `backend/`, start the fixture only when ready to run. The output must be a
new absolute file immediately under `backend/local-artifacts/`. It contains
local-only capabilities and is written with mode 0600; never commit it.

```sh
NODE_ENV=test SAFEATHOME_TEST_PG_BIN=/absolute/existing/postgres/bin \
  node tool/ios-acceptance-fixture.ts \
  --output /absolute/checkout/backend/local-artifacts/ios-acceptance-defines.json
```

In another terminal, from the Flutter checkout:

```sh
flutter test integration_test/fictional_journey_test.dart \
  -d YOUR_BOOTED_IOS_SIMULATOR_ID \
  --dart-define-from-file=backend/local-artifacts/ios-acceptance-defines.json
```

For manual visual review, use the same private define file with the test-only
entrypoint. A persistent corner banner identifies fictional local testing:

```sh
flutter run -d YOUR_BOOTED_IOS_SIMULATOR_ID \
  -t integration_test/manual_local_app.dart \
  --dart-define-from-file=backend/local-artifacts/ios-acceptance-defines.json
```

Fictional login: `alice@example.invalid` or `bob@example.invalid`; password
`fictional-password-only`. These names are not real accounts. The fixture creates
fresh owner IDs and no cases on each run. Generated camera images contain no
resident data. The full automatic journey deletes Alice's application account at
the end; start a fresh fixture before a later independent manual run.

The service binds only `127.0.0.1`, caps requests at 1,000, body controls at 4 KiB,
issued fixture tokens at 100 and lifetime at 45 minutes. Actual API body/rate/
capacity limits still apply. The Dart adapter paces requests and permits only its
one fixed fictional HTTPS origin to be rewritten to loopback. No production
HTTPS policy or startup path is changed. Stop the fixture with Ctrl-C; it closes
connections and removes only its owned temporary PostgreSQL cluster. The private
define file is inert after shutdown; remove it locally when no longer needed.

Acceptance covers denied/cancelled fictional capture, actual redaction, original
measurement text and units, annotation persistence, native encrypted-store
reopening, offline reconciliation, a real committed response lost in transit,
all three program questionnaires/forms/PDFs/manual history, owner isolation,
case/photo deletion, sign-out cleanup and a Keychain deletion receipt persisted
before account deletion is sent, followed by logged-out receipt status recovery.
The PDF bytes and text come from the real renderer and native parser; the native
PDF engine must also rasterize a page containing the saved photo annotation.
The actual displayed viewer's page text and annotated-page pixels must match
the downloaded PDF. Each route also opens its real draft checklist.
Deletion checks include all derived database records as well as cases and photos.
These are test assertions; record actual completed runs separately.

Limits: service/widget recreation is not an OS process-kill test; draft sharing
stops at its warning and Cancel; external Auth deletion remains pending and no
Auth admin worker runs. Physical capture/permissions, OS share destination,
email recovery and hosted real-user sessions need separate acceptance. The
companion `native_media_test.dart` separately tests real native media and storage
plugins; see its actual run results before claiming those checks passed.

`restart_recovery_test.dart` is a separate two-launch test with its own fresh
fixture. Its first launch deliberately waits after a durable encrypted checkpoint
and does not pass. Terminate the installed app process only after
`LOCAL_RESTART_READY`, then run the same target with the same define file and
fixture. The second launch verifies a different process ID, exact photo bytes,
original measurement and pending upload journal, then requires explicit decoded
photo review without a duplicate write. A Flutter failure caused by the deliberate
first-process termination is expected; only `LOCAL_RESTART_PASSED` in the second
launch establishes recovery. The fixture must remain running between launches.

`capture_restart_test.dart` is a separate two-launch target with another fresh
fixture. It saves an earlier fictional photo and original measurement in actual
native encrypted storage, then enters a deliberately pending **fictional**
capture adapter only after the new planned evidence ID is durable. Terminate the
actual app process only at `LOCAL_CAPTURE_RESTART_READY`, then run the same target
with unchanged source, app data and define file. Do not uninstall/reset the app
or restart the fixture between phases. The first launch waits at most eight
minutes and intentionally does not pass. A normal timeout marks its checkpoint
failed, so a later launch cannot misreport that as a successful process kill.

The second launch requires a different OS process ID, verifies the exact earlier
photo/measurement and retained capture intent, and checks that reopening neither
calls the adapter nor attaches/uploads a photo. The production **Choose a photo**
button then explicitly retries using the reserved evidence ID. Both local photos
must persist coherently while the earlier photo stays unchanged and no remote
mutation is sent after the initial case creation. Only
`LOCAL_CAPTURE_RESTART_PASSED` plus a successful second invocation establishes
the second-phase result, including private cleanup. Each launch
has a 12-minute deadline; the fixture's 45-minute TTL still applies. This tests
process death during a pending fictional adapter, not an interrupted physical
camera or native Photos picker. Its source existing does not establish a pass.

`lifecycle_journey_test.dart` is a shorter installed test for the final lifecycle
steps. Use another fresh fixture and substitute that test path in the command
above. It verifies case deletion, complete private sign-out cleanup, a new case,
password-confirmed application-account deletion, receipt-before-confirm ordering,
and logged-out receipt recovery. It uses the same explicit fictional provider;
provider-account deletion remains pending. This focused test supplements the
complete journey and does not replace its photo/annotation/export cascade checks.

`native_share_test.dart` is an optional operator-assisted target. Start a fresh
fixture, pass the same simulator/private defines arguments, and explicitly add
`--dart-define=SAH_NATIVE_SHARE_REVIEW=true`. It prepares a real fictional SCFHP
PDF through the production review screen, opens SharePlus, and prints
`LOCAL_NATIVE_SHARE_READY`. Inspect the actual iOS share sheet and **cancel** it;
do not choose a recipient or save destination. The test waits at most 150 seconds
for the sheet to return, then checks that no history update was sent and the
exact-byte private temporary PDF disappears within the normal two-minute
cleanup interval. Its total deadline is seven minutes. Record the operator's
visible sheet/cancel observation separately: the plugin future returning alone
does not prove that the system sheet appeared. The target skips unless explicitly
enabled and never sends a document or alters an application status.

`native_preview_test.dart` uses another fresh fixture to create real SCFHP and
RTP draft PDFs through the production clients. It mounts both production preview
widgets together, compares displayed text and page pixels with the downloaded
bytes, walks the accessible paging controls, reads reflowed current-page text,
and replaces one document within a single frame while its old page animation is
active. It also closes the production document lease before a controlled loader
returns a genuine native PDF, then verifies native page text and exactly one
public disposal callback after Pdfium closes it. This is a separate native
cache-isolation and accessibility check, with an eight-minute bound.

After the normal preview and full journeys pass, an explicitly requested local
resource session can add `--dart-define=SAH_NATIVE_PREVIEW_SOAK=true` to that
preview target. It downloads the same two genuine route PDFs once, then performs
100 actual native mount/text-extraction/page/swap/dispose cycles at a 12-second
cadence for at least 20 minutes. An optional
`--dart-define=SAH_NATIVE_PREVIEW_SOAK_MINUTES=45` selects 225 cycles over 45
minutes; only the exact durations `20` and `45` are accepted. The loop fails
above the selected duration plus four minutes and the whole test above the
duration plus eight minutes. It performs no forced garbage collection and no further
backend requests during the loop. `LOCAL_NATIVE_PREVIEW_SOAK_READY` reports only
the native PID and timing, followed by bounded cycle checkpoints, so an operator
can separately sample process memory. A passing test attests its functional
assertions; memory results require that separate observation and do not establish
release-device limits or indefinite leak freedom. The mode remains off by
default. The operator can stop the disposable fixture after the READY marker:
both PDFs have been downloaded, subsequent assertions and store cleanup are
local, and no further HTTP is needed. Keep the fixture's 45-minute TTL unchanged.

The standard-Python observer is read-only and must be started separately, from
the checkout, with the exact simulator UUID and a fresh report filename:

```bash
python3 tool/observe_ios_preview_rss.py \
  --log /tmp/sah-ios-native-preview-soak-new.log \
  --output backend/local-artifacts/ios-native-preview-rss-new.json \
  --simulator 97259E1A-893D-4AD1-B2D3-D788CA6A06E8 \
  --minutes 45
```

Use `--minutes 20` for the unchanged default resource session. The observer waits
up to ten minutes for one matching READY marker, verifies the PID, simulator
path and process start time, and samples RSS every five seconds with a hard
55-minute overall ceiling. Start it before the test reaches READY; completed or
stale logs are rejected. A zero observer exit requires functional completion and
sampling coverage: attachment within ten seconds, at least the requested
duration minus ten seconds of sample span, and no gap above fifteen seconds.
These measure the completeness of observation, not acceptable app memory use.
Partial observations remain recorded with a nonzero exit. Reports are new-only, atomically updated private
0600 JSON files under `backend/local-artifacts`; existing reports are refused.
Log reads are bounded, and neither log text nor full process arguments are
copied to the report. A functional resource marker is recorded separately from
any observed final test-suite success: verify Flutter's own exit status as well.
This tool does not launch/stop the app, change memory settings, or turn debug
simulator RSS into physical-device memory acceptance.

Its bounded parser/identity/output/coverage regressions run without a simulator
or process probe: `python3 -m unittest tool/test_observe_ios_preview_rss.py`.

## Recorded local runs — October 23, 2026

- The patched-source native preview target passed in **29 seconds** after a
  **22.7-second build**, exit 0 (`/tmp/sah-ios-preview-pdfpatch-20261023.log`).
  Simultaneous route previews, exact text/pixels, replacement, paging and native
  early-close document disposal passed. Its fixture was removed; the resource
  mode was disabled, so this is not a repeat RSS measurement.
- After the local pdfrx 2.4.7 image-lifetime patch, the complete iOS 26.2 journey
  passed at **3.2× text size** in **5:28**, after a **23.4-second build**, exit 0.
  All three displayed annotated drafts, manual histories, owner isolation,
  case/photo/account deletion and logged-out receipt recovery passed.
  `/tmp/sah-ios-journey-pdfpatch-20261023.log`; its fresh fixture was removed.
  The earlier long resource observation and iOS 18.6 runs below predate this
  dependency patch and are retained as historical evidence.
- The final **45-minute native preview session passed its functional checks**:
  225 cycles in 2,700,251 ms, 20.1-second build, test duration 45:29 and exit 0;
  `/tmp/sah-ios-native-preview-soak45-20261023-a.log`. The separate observer
  exited 0 with all coverage flags true: 538 samples spanning 2,699.260 seconds,
  maximum gap 5.045 seconds. RSS increased from 779,386,880 to 971,489,280 bytes, with a
  1,017,610,240-byte peak. Growth slowed but the final 15-minute trend remained
  positive; this does not establish a flat steady state or physical-device
  memory acceptance. The fixture was removed after READY. Detailed trend,
  limitations and the private report's SHA-256 are recorded in
  `docs/iphone-workflow-session.md`; no cache/GC/settings changes were used.
- iOS 18.6 journey B **passed completely** against the final functional source:
  **4 minutes 47 seconds**, after a **20.2-second build**, exit 0;
  `/tmp/sah-ios18-fictional-journey-20261023-b.log`. All three program routes,
  actual annotated PDFs, manual histories, case/account deletion and the final
  logged-out receipt screen passed. The fresh disposable fixture was stopped
  and removed. This was default text size; the separate iOS 26.2 I run below
  supplies the full 3.2× text result.
- iOS 18.6 journey A is **partial** (21-second build, 2 minutes 3 seconds,
  exit 1; `/tmp/sah-ios18-fictional-journey-20261023-a.log`). It completed
  login/profile/native photo work/offline resume and SCFHP intake/forms, then
  searched for Photo 1 before the export screen's second data read completed.
  Readiness now requires a new current-revision/program administrative-answer
  response as well as current evidence; disabled photo actions are respected.
  The fixture was removed. B subsequently passed with a fresh fixture.
- Large-text journey I (3.2×) completed successfully on the installed iOS 26.2
  simulator with the latest capture, draft-exit, native lifetime and auth-cleanup
  source: **5 minutes 26 seconds**, after a **20.2-second build**, exit 0.
  It verified all three routes, displayed annotated PDFs (seven/eight/three
  pages), manual histories, cross-owner rejection, case/photo deletion, sign-out
  file cleanup, reauthenticated account deletion, receipt-before-confirm and the
  exact logged-out receipt status screen. `/tmp/sah-ios-fictional-journey-large-i.log`.
  Its owned loopback/PostgreSQL fixture was stopped and removed. VoiceOver was
  enabled in this simulator; this automated run does not establish a complete
  manual screen-reader or physical-device review.
- Earlier large-text journey H (3.2×) remains a **partial run**, not a pass. All three
  questionnaires/forms/annotated PDFs/manual histories and actual case/account
  deletion assertions completed, including receipt-before-confirm. The final
  logged-out status notice was still below the lazy viewport; a non-scrolling
  wait timed out after 5 minutes 58 seconds. The locator now waits for a new
  real `auth_pending` status response, then scrolls to and asserts that exact
  notice. `/tmp/sah-ios-fictional-journey-large-h.log`; owned fixture removed.
  I subsequently passed the complete route using a fresh fixture.
- The installed native preview target passed with a six-page SCFHP draft and a
  two-page RTP worksheet (no photo/intake attachments in this focused fixture).
  Two simultaneous previews and same-frame replacement matched the actual
  downloaded text and rendered pixels. Paging boundaries, readable current-page
  text and the real hidden-viewer keyboard-focus exclusion passed. This default
  run did not enable the resource mode. The later updated default run also
  passed the real native early-close disposal check;
  `/tmp/sah-ios-native-preview-b.log`, 18.6-second build and 28-second test.
- The capture-intent restart target passed after an actual operator termination
  at `LOCAL_CAPTURE_RESTART_READY` (11:11:12 UTC). The second process restored
  the exact earlier photo/measurement and planned IDs without replay, then used
  **Choose a photo** to complete the explicit retry. Native encrypted storage
  and OS death were real; the pending capture adapter was fictional. Phase 2
  passed in two seconds after an 18.7-second build;
  `/tmp/sah-ios-capture-restart-c-phase2.log`.
- The installed lifecycle target passed on the iOS simulator: real case deletion,
  encrypted account-file cleanup, receipt-before-confirm ordering, application
  account deletion and logged-out receipt status. The final disposable database
  contained zero cases, evidence or derived rows, with one closed fictional
  account. External provider deletion remained pending.
- The separate restart target passed after a real `simctl terminate` at the
  first launch's `LOCAL_RESTART_READY` checkpoint. The first Flutter invocation
  disconnected as expected; it did not pass. The second launch, using unchanged
  app data and the same fixture, verified a different process ID, exact retained
  photo bytes, original measurement provenance and the uncertain-upload journal.
  Explicit saved-photo review finished without another remote upload.
- Full main journey F passed in 4 minutes 49 seconds after an 18.5-second native
  build. It completed all three real checklists, intake/reviewed answers, displayed
  annotated PDFs (SCFHP seven pages, HPSM eight, RTP three), manual histories,
  cross-owner rejection, case/photo/derived-row deletion, sign-out file cleanup,
  reauthenticated application deletion, and receipt-before-confirm plus logged-out
  receipt recovery. Displayed PDF text and annotated-page raster checks matched
  the downloaded bytes. Earlier iteration E had stopped at a test Back-locator
  ambiguity and remains a partial run; F used a fresh fixture after that locator
  was corrected. The optional 3.2× full journey is a separate gate.

These were installed simulator runs with explicitly fictional authentication and
capture. Their owned loopback servers and disposable PostgreSQL clusters were
stopped and removed. They do not establish physical camera, real provider login,
real email recovery, Android or external submission acceptance.
