import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:safe_at_home/features/assessment/application/assessment_sync.dart';
import 'package:safe_at_home/features/assessment/application/live_assessment_session.dart';
import 'package:safe_at_home/features/assessment/domain/capture/capture_adapter.dart';
import 'package:safe_at_home/features/assessment/domain/measurement/length_unit.dart';
import 'package:safe_at_home/features/assessment/presentation/recovery_photo_review_card.dart';
import 'package:safe_at_home/shared/models/case_draft.dart';

import 'support/local_acceptance_harness.dart';

const _originalText = '  02.50  ';
const _observation = 'Fictional restart-only entrance observation.';
const _photoBound = 96 * 1024;

void _require(bool condition, String message) {
  if (!condition) throw TestFailure(message);
}

Map<String, Object?> _object(Object? value) {
  _require(value is Map, 'The restart checkpoint has an invalid object.');
  return Map<String, Object?>.from(value as Map);
}

Map<String, int> _writes(Map<String, Object?> status) => {
  for (final item in _object(status['routes']).entries)
    if (RegExp(
      r'^/v[12]/(create|save|upload|delete|close)-',
    ).hasMatch(item.key))
      item.key: item.value as int,
};

bool _sameBytes(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var index = 0; index < a.length; index++) {
    if (a[index] != b[index]) return false;
  }
  return true;
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'installed process restart preserves private uncertain upload',
    (tester) async {
      final config = LocalFixtureConfig.fromEnvironment();
      final harness = AcceptanceHarness(config);
      LiveAssessmentSession? assessment;
      var cleanOnExit = false, phaseOneCheckpointReady = false;
      final checkpointKey = 'restart.checkpoint.${config.runId}';
      final statusText = ValueNotifier('FICTIONAL LOCAL RESTART TEST: opening');
      late BuildContext appContext;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              appContext = context;
              return Scaffold(
                body: SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: ValueListenableBuilder<String>(
                      valueListenable: statusText,
                      builder: (_, value, _) => Text(value),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      );

      Future<void> display(String value) async {
        statusText.value = value;
        await tester.pump();
      }

      Future<Map<String, Object?>> status() => config.control('status', {});
      Future<void> unchangedWrites(Map<String, int> expected) async {
        final current = _writes(await status());
        _require(
          current.length == expected.length &&
              current.entries.every((item) => expected[item.key] == item.value),
          'Opening or reconciling repeated a remote write.',
        );
      }

      void originalMeasurement(
        LiveAssessmentSession current,
        String findingId,
      ) {
        final value = current.controller
            .draftOf(findingId)
            ?.measurementOf('thresholdHeight');
        _require(
          value != null &&
              value.originalInputKnown &&
              value.input.originalText == _originalText &&
              value.input.unit == LengthUnit.centimetre &&
              value.input.millimetres == 25 &&
              value.recorder == 'self' &&
              value.recordedAt != null &&
              value.confirmed,
          'Original measurement, provenance or confirmation changed on restart.',
        );
        _require(
          current.controller.draftOf(findingId)?.observation == _observation,
          'Original observation changed on restart.',
        );
      }

      try {
        await harness.session.signIn(
          'alice@example.invalid',
          'fictional-password-only',
        );
        final services = await harness.open();
        _require(
          harness.session.userId == config.alice,
          'Wrong fictional owner.',
        );
        final checkpoint = await services.store.readJson(checkpointKey);
        if (checkpoint == null) {
          final before = await status();
          _require(
            before['cases'] == 0 &&
                before['evidence'] == 0 &&
                before['closedAccounts'] == 0,
            'Start a fresh disposable fixture for the restart test.',
          );
          _require(
            (await services.coordinator.localCaseIds()).isEmpty,
            'This fixture already has local work; retain it for inspection.',
          );
          await services.coordinator.createDraft();
          await services.coordinator.save();
          final current = assessment = LiveAssessmentSession(
            services: services,
            context: () => appContext,
          );
          await current.initialize();
          current.flow.chooseArea(AssessmentArea.entrance);
          await current.flow.openCamera();
          final evidenceId = current.flow.previewEvidenceId;
          final findingId = current.flow.findingId;
          _require(
            evidenceId != null && findingId != null,
            'Generated photo was not staged.',
          );
          current.flow.continueFromPreview();
          current.flow.setObservationText(_observation);
          current.flow.setMeasurementText('thresholdHeight', _originalText);
          current.flow.setMeasurementUnit(
            'thresholdHeight',
            LengthUnit.centimetre,
          );
          _require(
            current.flow.saveDetails(),
            'Fictional measurement was rejected.',
          );
          current.controller.confirmMeasurement(findingId!, 'thresholdHeight');
          current.controller.confirm(findingId);
          final staged = current.evidence[evidenceId!]!;
          final bytes = await current.staging.read(staged.key);
          _require(
            bytes != null && bytes.isNotEmpty && bytes.length <= _photoBound,
            'Generated photo exceeds the restart-test storage bound.',
          );
          harness.transport.loseNextSuccessfulResponse = '/v1/upload-evidence';
          await current.save();
          _require(
            harness.transport.loseNextSuccessfulResponse == null &&
                current.sync.phase == SyncPhase.uncertain,
            'The real upload did not enter the expected lost-response state.',
          );
          await current.flush();
          final pending = _object(current.sync.toLocalJson()['pendingUpload']);
          _require(
            pending['evidenceId'] == evidenceId &&
                current.pendingRequest == null,
            'Expected the genuine pending-upload journal after the acknowledged case save.',
          );
          originalMeasurement(current, findingId);
          final after = await status();
          _require(
            after['cases'] == 1 && after['evidence'] == 1,
            'The fixture did not persist exactly one case and one photo.',
          );
          final writes = _writes(after);
          _require(
            writes['/v1/upload-evidence'] == 1 &&
                !writes.keys.any((route) => route.contains('export')),
            'The restart fixture exceeded its one-photo/no-export mutation bound.',
          );
          await services.store.writeJson(checkpointKey, {
            'version': 1,
            'phase': 'ready',
            'runId': config.runId,
            'owner': config.alice,
            'processId': pid,
            'caseId': current.caseId,
            'findingId': findingId,
            'evidenceId': evidenceId,
            'stagingKey': staged.key.value,
            'photo': base64Encode(bytes!),
            'photoSha256': sha256.convert(bytes).toString(),
            'metadata': current.controller.metadataFor(
              current.controller.findings,
            ),
            'pendingUpload': pending,
            'writes': writes,
          });
          phaseOneCheckpointReady = true;
          await display(
            'LOCAL_RESTART_READY\nPrivate checkpoint is durable. Terminate this app process, then relaunch this same test with the same fixture.',
          );
          debugPrint('LOCAL_RESTART_READY');
          final wait = Stopwatch()..start();
          while (wait.elapsed < const Duration(minutes: 8)) {
            await tester.pump(const Duration(seconds: 1));
          }
          throw TestFailure(
            'Process termination was not performed within eight minutes; checkpoint retained.',
          );
        }

        _require(
          checkpoint['version'] == 1 &&
              checkpoint['phase'] == 'ready' &&
              checkpoint['runId'] == config.runId &&
              checkpoint['owner'] == config.alice,
          'The restart checkpoint does not belong to this fictional run.',
        );
        _require(
          checkpoint['processId'] is int && checkpoint['processId'] != pid,
          'A new OS app process is required; service recreation is insufficient.',
        );
        final caseId = checkpoint['caseId'] as String;
        final findingId = checkpoint['findingId'] as String;
        final evidenceId = checkpoint['evidenceId'] as String;
        _require(
          isCaseUuidV4(caseId) &&
              isCaseUuidV4(findingId) &&
              isCaseUuidV4(evidenceId),
          'Invalid checkpoint identity.',
        );
        final expectedBytes = base64Decode(checkpoint['photo'] as String);
        _require(
          expectedBytes.isNotEmpty &&
              expectedBytes.length <= _photoBound &&
              sha256.convert(expectedBytes).toString() ==
                  checkpoint['photoSha256'],
          'Invalid checkpoint photo.',
        );
        final writes = _object(
          checkpoint['writes'],
        ).map((key, value) => MapEntry(key, value as int));
        await unchangedWrites(writes);
        await services.coordinator.restoreLocal(caseId);
        final current = assessment = LiveAssessmentSession(
          services: services,
          context: () => appContext,
        );
        await current.initialize();
        _require(
          current.sync.phase == SyncPhase.uncertain &&
              current.sync.recoveryConflict == null,
          'Opening the assessment resolved uncertainty without an explicit choice.',
        );
        final staged = current.evidence[evidenceId];
        _require(
          staged != null && staged.key.value == checkpoint['stagingKey'],
          'The original staged attachment was not restored.',
        );
        final restoredBytes = await current.staging.read(staged!.key);
        _require(
          restoredBytes != null && _sameBytes(expectedBytes, restoredBytes),
          'Original encrypted photo bytes changed across process termination.',
        );
        originalMeasurement(current, findingId);
        _require(
          jsonEncode(
                current.controller.metadataFor(current.controller.findings),
              ) ==
              jsonEncode(checkpoint['metadata']),
          'Measurement metadata changed across process termination.',
        );
        _require(
          jsonEncode(current.sync.toLocalJson()['pendingUpload']) ==
              jsonEncode(checkpoint['pendingUpload']),
          'Pending upload journal changed across process termination.',
        );
        await unchangedWrites(writes);
        await display(
          'LOCAL_RESTART_RESTORED\nExact original photo, measurement and pending journal restored. Checking the saved copy explicitly.',
        );
        debugPrint('LOCAL_RESTART_RESTORED');

        await current.recover();
        _require(
          current.sync.recoveryConflict?.evidenceId == evidenceId &&
              current.sync.toLocalJson()['pendingUpload'] != null,
          'Recovery skipped the explicit saved-photo comparison.',
        );
        _require(
          _sameBytes(expectedBytes, (await current.staging.read(staged.key))!),
          'Recovery discarded the device copy before review.',
        );
        final savedPixels = await current.sync.showRecoveredEvidence();
        _require(savedPixels != null, 'Saved photo download failed.');
        Future<void>? choice;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: RecoveryPhotoReviewCard(
                  bytes: savedPixels,
                  busy: false,
                  onShowSaved: () {},
                  onKeepDevice: () {},
                  onKeepSaved: () {
                    choice = services.coordinator.serialize(() async {
                      await current.sync.acceptRecoveredEvidence();
                      await current.flush();
                    });
                  },
                ),
              ),
            ),
          ),
        );
        final button = find.widgetWithText(
          FilledButton,
          'Keep the saved photo',
        );
        final decodeWait = Stopwatch()..start();
        while (tester.widget<FilledButton>(button).onPressed == null) {
          _require(
            decodeWait.elapsed < const Duration(seconds: 15),
            'Canonical saved image did not decode.',
          );
          await tester.pump(const Duration(milliseconds: 100));
        }
        await tester.ensureVisible(button);
        await tester.pump(const Duration(milliseconds: 200));
        await tester.tap(button);
        _require(
          choice != null,
          'The explicit decoded-photo choice was not invoked.',
        );
        await choice;
        _require(
          current.sync.toLocalJson()['pendingUpload'] == null &&
              current.sync.recoveryConflict == null &&
              current.evidence[evidenceId] == null,
          'Explicit recovery did not finalize the pending journal.',
        );
        await unchangedWrites(writes);
        cleanOnExit = true;
        binding.reportData = {
          'scope': 'fictional_local_installed_process_restart',
          'differentOsProcess': true,
          'originalBytesEqual': true,
          'originalMeasurementAndProvenanceEqual': true,
          'pendingUploadPreserved': true,
          'explicitDecodedReview': true,
          'duplicateRemoteWrites': 0,
          'photos': 1,
          'exports': 0,
        };
        await tester.pumpWidget(
          const MaterialApp(
            home: Scaffold(
              body: SafeArea(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: Text(
                    'LOCAL_RESTART_PASSED\nDifferent app process verified. Original private work recovered; no duplicate upload or export.',
                  ),
                ),
              ),
            ),
          ),
        );
        debugPrint('LOCAL_RESTART_PASSED');
      } catch (_) {
        cleanOnExit = false;
        if (phaseOneCheckpointReady) {
          try {
            final store = harness.services?.store;
            final retained = await store?.readJson(checkpointKey);
            if (retained != null && retained['runId'] == config.runId) {
              await store!.writeJson(checkpointKey, {
                ...retained,
                'phase': 'failed_before_termination',
              });
            }
          } catch (_) {
            // ignore: empty_catches
          }
        }
        debugPrint('LOCAL_RESTART_FAILED: checkpoint retained for inspection');
        await tester.pumpWidget(
          const MaterialApp(
            home: Scaffold(
              body: SafeArea(
                child: Text(
                  'LOCAL_RESTART_FAILED\nPrivate checkpoint retained for inspection. No automatic reset.',
                ),
              ),
            ),
          ),
        );
        rethrow;
      } finally {
        assessment?.dispose();
        await harness.close(clear: cleanOnExit);
        harness.session.dispose();
        statusText.dispose();
      }
    },
    timeout: const Timeout(Duration(minutes: 12)),
  );
}
