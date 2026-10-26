import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:safe_at_home/app/theme.dart';
import 'package:safe_at_home/features/assessment/application/assessment_flow.dart';
import 'package:safe_at_home/features/assessment/application/live_assessment_session.dart';
import 'package:safe_at_home/features/assessment/domain/capture/capture_adapter.dart';
import 'package:safe_at_home/features/assessment/domain/measurement/length_unit.dart';
import 'package:safe_at_home/features/assessment/presentation/assessment_flow_screen.dart';
import 'package:safe_at_home/shared/models/case_draft.dart';

import 'support/local_acceptance_harness.dart';

const _original = '  02.50  ';
const _observation = 'Fictional capture-interruption entrance observation.';
const _maxPhoto = 96 * 1024;

class _PendingCapture extends GeneratedCapture {
  Future<CaptureResult> Function(CaptureRequest)? pending;
  final requests = <CaptureRequest>[];
  @override
  Future<CaptureResult> capture(CaptureRequest request) {
    requests.add(request);
    final handler = pending;
    if (handler == null) return super.capture(request);
    attempts++;
    return handler(request);
  }
}

void _require(bool value, String message) {
  if (!value) throw TestFailure(message);
}

Map<String, Object?> _object(Object? value) {
  _require(value is Map, 'Invalid private capture checkpoint.');
  return Map<String, Object?>.from(value as Map);
}

Map<String, int> _writes(Map<String, Object?> status) => {
  for (final entry in _object(status['routes']).entries)
    if (RegExp(
      r'^/v[12]/(create|save|upload|delete|close)-',
    ).hasMatch(entry.key))
      entry.key: entry.value as int,
};

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'actual process restart preserves durable pending capture intent',
    (tester) async {
      final config = LocalFixtureConfig.fromEnvironment();
      final capture = _PendingCapture();
      final h = AcceptanceHarness(config, capture: capture);
      final checkpointKey = 'capture-restart.${config.runId}';
      LiveAssessmentSession? assessment;
      var clean = false, readyForTermination = false;
      late BuildContext appContext;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              appContext = context;
              return const Scaffold(
                body: SafeArea(
                  child: Text(
                    'FICTIONAL LOCAL CAPTURE RESTART TEST\nNative encrypted storage; fictional pending capture.',
                  ),
                ),
              );
            },
          ),
        ),
      );
      Future<void> until(bool Function() value, String reason) async {
        final clock = Stopwatch()..start();
        while (!value()) {
          _require(clock.elapsed < const Duration(seconds: 25), reason);
          await tester.pump(const Duration(milliseconds: 100));
        }
        await tester.pump(const Duration(milliseconds: 100));
      }

      Future<Map<String, Object?>> status() => config.control('status', {});
      Future<void> unchangedWrites(Map<String, int> before) async {
        expect(
          _writes(await status()),
          before,
          reason:
              'Capture restoration and explicit local retry must not send remote mutations.',
        );
      }

      void measurement(LiveAssessmentSession current, String findingId) {
        final draft = current.controller.draftOf(findingId);
        final value = draft?.measurementOf('thresholdHeight');
        _require(
          draft?.observation == _observation &&
              value != null &&
              value.originalInputKnown &&
              value.input.originalText == _original &&
              value.input.unit == LengthUnit.centimetre &&
              value.input.millimetres == 25 &&
              value.recorder == 'self' &&
              value.recordedAt != null &&
              value.confirmed,
          'Prior observation or original measurement/provenance changed.',
        );
      }

      Future<Map<String, Object?>> durableDraft(
        LiveAssessmentSession current,
      ) async {
        final bytes = await h.services!.store.readBytes(current.localKey);
        _require(
          bytes != null && bytes.length <= 512 * 1024,
          'Missing bounded encrypted assessment draft.',
        );
        return _object(jsonDecode(utf8.decode(bytes!)));
      }

      try {
        await h.session.signIn(
          'alice@example.invalid',
          'fictional-password-only',
        );
        final app = await h.open();
        _require(
          h.session.userId == config.alice,
          'Unexpected fictional owner.',
        );
        final checkpoint = await app.store.readJson(checkpointKey);
        if (checkpoint == null) {
          final initial = await status();
          _require(
            initial['cases'] == 0 &&
                initial['evidence'] == 0 &&
                initial['closedAccounts'] == 0,
            'Use a fresh disposable fixture.',
          );
          _require(
            (await app.coordinator.localCaseIds()).isEmpty,
            'Existing private work must not be reset.',
          );
          await app.coordinator.createDraft();
          await app.coordinator.save();
          final current = assessment = LiveAssessmentSession(
            services: app,
            context: () => appContext,
          );
          await current.initialize();
          current.flow.chooseArea(AssessmentArea.entrance);
          await current.flow.openCamera();
          final evidenceId = current.flow.previewEvidenceId!;
          final findingId = current.flow.findingId!;
          current.flow.continueFromPreview();
          current.flow.setObservationText(_observation);
          current.flow.setMeasurementText('thresholdHeight', _original);
          current.flow.setMeasurementUnit(
            'thresholdHeight',
            LengthUnit.centimetre,
          );
          _require(
            current.flow.saveDetails(),
            'Fictional measurement was rejected.',
          );
          current.controller.confirmMeasurement(findingId, 'thresholdHeight');
          current.controller.confirm(findingId);
          await current.flush();
          measurement(current, findingId);
          final prior = current.evidence[evidenceId]!;
          final photo = await current.staging.read(prior.key);
          _require(
            photo != null && photo.isNotEmpty && photo.length <= _maxPhoto,
            'Invalid bounded fictional photo.',
          );
          final metadata = current.controller.metadataFor(
            current.controller.findings,
          );
          final entered = Completer<void>();
          final pending = Completer<CaptureResult>();
          Map<String, Object?>? planned;
          Object? adapterFailure;
          StackTrace? adapterFailureStack;
          capture.pending = (request) async {
            try {
              _require(
                request.source == CaptureSource.library &&
                    request.view == CaptureView.closeUp,
                'The explicit closer-photo attempt changed its source or view.',
              );
              final draft = await durableDraft(current);
              planned = _object(_object(draft['flow'])['captureAttempt']);
              _require(
                draft['caseId'] == current.caseId &&
                    planned!['findingId'] == findingId &&
                    planned!['evidenceId'] != evidenceId &&
                    planned!['newFinding'] == false &&
                    planned!['replacingVersion'] == null &&
                    planned!['source'] == 'library',
                'Planned capture identity was not durable before adapter entry.',
              );
              final controller = _object(draft['controller']);
              expectSync(controller['reservedEvidence'], [
                planned!['evidenceId'],
              ]);
              expectSync(_object(draft['evidence']).keys.toList(), [
                evidenceId,
              ]);
              expectSync(
                current.controller
                    .draftOf(findingId)!
                    .evidence
                    .map((e) => e.evidenceId)
                    .toList(),
                [evidenceId],
              );
              expectSync(await current.staging.read(prior.key), photo);
            } catch (error, stack) {
              adapterFailure = error;
              adapterFailureStack = stack;
              entered.complete();
              rethrow;
            }
            entered.complete();
            return pending.future;
          };
          current.flow.addCloseUp();
          current.flow.openCamera(source: CaptureSource.library).ignore();
          await until(
            () => entered.isCompleted || !current.flow.isBusy,
            'Pending fictional adapter was not reached after durable intent.',
          );
          if (adapterFailure != null) {
            Error.throwWithStackTrace(adapterFailure!, adapterFailureStack!);
          }
          _require(
            entered.isCompleted,
            'Capture stopped before adapter entry: ${current.flow.notice.runtimeType}.',
          );
          _require(
            current.flow.isBusy && capture.requests.length == 2,
            'Capture is not actually pending.',
          );
          measurement(current, findingId);
          final writes = _writes(await status());
          expect(writes, {'/v1/create-case': 1});
          await app.store.writeJson(checkpointKey, {
            'version': 1,
            'phase': 'ready',
            'runId': config.runId,
            'owner': config.alice,
            'processId': pid,
            'caseId': current.caseId,
            'findingId': findingId,
            'evidenceId': evidenceId,
            'stagingKey': prior.key.value,
            'photo': base64Encode(photo!),
            'photoSha256': sha256.convert(photo).toString(),
            'metadata': metadata,
            'captureAttempt': planned,
            'writes': writes,
          });
          readyForTermination = true;
          await tester.pumpWidget(
            const MaterialApp(
              home: Scaffold(
                body: SafeArea(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(
                      'LOCAL_CAPTURE_RESTART_READY\nDurable planned IDs and earlier private work verified. Terminate this app process, then relaunch with the same fixture.',
                    ),
                  ),
                ),
              ),
            ),
          );
          debugPrint('LOCAL_CAPTURE_RESTART_READY');
          final waiting = Stopwatch()..start();
          while (waiting.elapsed < const Duration(minutes: 8)) {
            await tester.pump(const Duration(seconds: 1));
          }
          throw TestFailure(
            'No actual process termination within eight minutes; checkpoint retained.',
          );
        }

        _require(
          checkpoint['version'] == 1 &&
              checkpoint['phase'] == 'ready' &&
              checkpoint['runId'] == config.runId &&
              checkpoint['owner'] == config.alice &&
              checkpoint['processId'] is int &&
              checkpoint['processId'] != pid,
          'A valid same-run checkpoint and a different OS process are required.',
        );
        final caseId = checkpoint['caseId'] as String;
        final findingId = checkpoint['findingId'] as String;
        final evidenceId = checkpoint['evidenceId'] as String;
        final planned = _object(checkpoint['captureAttempt']);
        final plannedId = planned['evidenceId'] as String;
        _require(
          [caseId, findingId, evidenceId, plannedId].every(isCaseUuidV4) &&
              plannedId != evidenceId,
          'Invalid retained case/finding/evidence identifiers.',
        );
        final photo = base64Decode(checkpoint['photo'] as String);
        _require(
          photo.isNotEmpty &&
              photo.length <= _maxPhoto &&
              sha256.convert(photo).toString() == checkpoint['photoSha256'],
          'Invalid retained photo bytes.',
        );
        final writes = _object(
          checkpoint['writes'],
        ).map((key, value) => MapEntry(key, value as int));
        await unchangedWrites(writes);
        await app.coordinator.restoreLocal(caseId);
        final current = assessment = LiveAssessmentSession(
          services: app,
          context: () => appContext,
        );
        await current.initialize();
        _require(
          !current.flow.isBusy &&
              current.flow.notice is InterruptedCaptureNotice,
          'Interrupted capture was not presented for an explicit choice.',
        );
        expect(current.flow.toLocalJson()['captureAttempt'], planned);
        expect(
          capture.requests,
          isEmpty,
          reason: 'Relaunch must not replay the native adapter.',
        );
        expect(current.evidence.evidenceIds.toList(), [evidenceId]);
        expect(current.evidence[plannedId], isNull);
        expect(
          current.controller
              .draftOf(findingId)!
              .evidence
              .map((e) => e.evidenceId)
              .toList(),
          [evidenceId],
        );
        final prior = current.evidence[evidenceId]!;
        expect(prior.key.value, checkpoint['stagingKey']);
        expect(await current.staging.read(prior.key), photo);
        measurement(current, findingId);
        expect(
          current.controller.metadataFor(current.controller.findings),
          checkpoint['metadata'],
        );
        expect(
          _object((await durableDraft(current))['flow'])['captureAttempt'],
          planned,
        );
        await unchangedWrites(writes);
        debugPrint('LOCAL_CAPTURE_RESTART_RESTORED');

        await tester.pumpWidget(
          MaterialApp(
            theme: SafeAtHomeTheme.light(),
            home: AssessmentFlowScreen(flow: current.flow),
          ),
        );
        await tester.pump(const Duration(milliseconds: 200));
        expect(capture.requests, isEmpty);
        final retry = find.widgetWithText(OutlinedButton, 'Choose a photo');
        await tester.scrollUntilVisible(
          retry,
          220,
          scrollable: find.byType(Scrollable).first,
          maxScrolls: 40,
        );
        await tester.ensureVisible(retry);
        await tester.pump(const Duration(milliseconds: 200));
        await tester.tap(retry);
        await until(
          () => capture.requests.length == 1 && !current.flow.isBusy,
          'Explicit retry did not finish the generated capture.',
        );
        expect(capture.requests.single.source, CaptureSource.library);
        expect(current.flow.findingId, findingId);
        expect(current.flow.previewEvidenceId, plannedId);
        expect(current.flow.toLocalJson()['captureAttempt'], isNull);
        expect(current.evidence.evidenceIds.toSet(), {evidenceId, plannedId});
        expect(
          current.controller
              .draftOf(findingId)!
              .evidence
              .map((e) => e.evidenceId)
              .toSet(),
          {evidenceId, plannedId},
        );
        expect(await current.staging.read(prior.key), photo);
        measurement(current, findingId);
        final added = current.evidence[plannedId]!;
        expect(added.key, isNot(prior.key));
        expect(
          current.controller.toFinding(findingId)!.reviewState,
          'needs_review',
        );
        final addedBytes = await current.staging.read(added.key);
        _require(
          addedBytes != null &&
              addedBytes.isNotEmpty &&
              addedBytes.length <= _maxPhoto,
          'Explicit retry did not retain a bounded valid staged photo.',
        );
        await current.flush();
        final durable = await durableDraft(current);
        expect(_object(durable['flow'])['captureAttempt'], isNull);
        expect(_object(durable['evidence']).keys.toSet(), {
          evidenceId,
          plannedId,
        });
        expect(_object(durable['controller'])['reservedEvidence'], isEmpty);
        await unchangedWrites(writes);
        final finalStatus = await status();
        expect(finalStatus['cases'], 1);
        expect(finalStatus['evidence'], 0);
        expect(finalStatus['derivedRows'], 0);
        expect(tester.takeException(), isNull);
        clean = true;
        binding.reportData = {
          'scope': 'installed_iOS_process_death_with_fictional_pending_capture',
          'differentOsProcess': true,
          'nativeKeychainEncryptedFiles': true,
          'durableIntentBeforeAdapter': true,
          'plannedIdsReused': true,
          'originalPhotoAndMeasurementEqual': true,
          'automaticCaptureReplay': false,
          'automaticAttachments': 0,
          'remoteWritesAfterInitialCreate': 0,
          'explicitProductionChoosePhotoAction': true,
          'physicalCameraOrNativePicker': 'not_exercised',
        };
        debugPrint('LOCAL_CAPTURE_RESTART_PASSED');
      } catch (_) {
        clean = false;
        if (readyForTermination) {
          try {
            final retained = await h.services?.store.readJson(checkpointKey);
            if (retained != null && retained['runId'] == config.runId) {
              await h.services!.store.writeJson(checkpointKey, {
                ...retained,
                'phase': 'failed_before_termination',
              });
            }
          } catch (_) {
            // ignore: empty_catches
          }
        }
        debugPrint('LOCAL_CAPTURE_RESTART_FAILED: private checkpoint retained');
        rethrow;
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        assessment?.dispose();
        await h.close(clear: clean);
        h.session.dispose();
      }
    },
    timeout: const Timeout(Duration(minutes: 12)),
  );
}
