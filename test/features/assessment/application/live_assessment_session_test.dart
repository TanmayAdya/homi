import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/app/live_app.dart';
import 'package:safe_at_home/features/assessment/application/live_assessment_session.dart';
import 'package:safe_at_home/features/assessment/application/assessment_controller.dart';
import 'package:safe_at_home/features/assessment/application/assessment_flow.dart';
import 'package:safe_at_home/features/assessment/application/assessment_sync.dart';
import 'package:safe_at_home/features/assessment/application/local_evidence_index.dart';
import 'package:safe_at_home/features/assessment/application/encrypted_staging_store.dart';
import 'package:safe_at_home/features/assessment/domain/image/image_validator.dart';
import 'package:safe_at_home/features/assessment/domain/capture/capture_adapter.dart';
import 'package:safe_at_home/features/assessment/domain/capture/photo_capture_coordinator.dart';
import 'package:safe_at_home/features/assessment/domain/capture/staging_store.dart';
import 'package:safe_at_home/features/assessment/domain/measurement/length_unit.dart';
import 'package:safe_at_home/features/assessment/presentation/live_assessment_screen.dart';
import 'package:safe_at_home/shared/models/case_draft.dart';
import 'package:safe_at_home/shared/models/contracts.dart';
import 'package:safe_at_home/shared/services/local_private_store.dart';
import 'package:safe_at_home/shared/services/matching_api_client.dart';
import 'package:safe_at_home/shared/services/token_availability.dart';
import '../../../app/case_coordinator_test.dart'
    show FakeSession, FakeTransport;
import '../../../app/local_private_store_test.dart' show MemorySecrets;
import '../../../contracts/draft_export_test.dart' as fixture;
import '../fakes/image_bytes.dart';
import '../fakes/fakes.dart';

class _DraftFailStore extends LocalPrivateStore {
  _DraftFailStore({
    required super.directory,
    required super.accountId,
    required super.secrets,
  });
  bool failDraftWrites = false, failPhotoDeletion = false;
  VoidCallback? onDraftWrite;
  bool Function(Map<String, Object?>)? rejectDraft;
  final List<Uint8List> acceptedDrafts = [];
  Completer<void>? photoReadEntered, releasePhotoRead;
  @override
  Future<void> writeBytes(String key, Uint8List bytes) {
    if (key.endsWith(':draft')) onDraftWrite?.call();
    if (key.endsWith(':draft')) {
      if (failDraftWrites ||
          (rejectDraft?.call(
                Map<String, Object?>.from(
                  jsonDecode(utf8.decode(bytes)) as Map,
                ),
              ) ??
              false)) {
        return Future.error(StateError('Synthetic disk full'));
      }
      acceptedDrafts.add(Uint8List.fromList(bytes));
    }
    return super.writeBytes(key, bytes);
  }

  @override
  Future<Uint8List?> readBytes(String key) async {
    if (key.contains(':photo:') && photoReadEntered != null) {
      if (!photoReadEntered!.isCompleted) photoReadEntered!.complete();
      await releasePhotoRead!.future;
    }
    return super.readBytes(key);
  }

  @override
  Future<void> delete(String key) {
    if (failPhotoDeletion && key.contains(':photo:')) {
      return Future.error(StateError('Synthetic interrupted cleanup'));
    }
    return super.delete(key);
  }
}

class _Capture implements CaptureAdapter {
  Future<CaptureResult> Function(CaptureRequest)? result;
  final List<CaptureRequest> requests = [];
  @override
  Future<CaptureResult> capture(CaptureRequest request) async {
    requests.add(request);
    return result == null ? const CaptureCancelled() : await result!(request);
  }
}

void expectCoherentDrafts(Iterable<Uint8List> snapshots) {
  for (final bytes in snapshots) {
    final json = jsonDecode(utf8.decode(bytes)) as Map;
    final evidence = json['evidence'] as Map;
    final controller = AssessmentController(ids: SequentialIdFactory());
    final staging = InMemoryStagingStore();
    final index = LocalEvidenceIndex();
    final flow = AssessmentFlow(
      controller: controller,
      evidence: index,
      staging: staging,
      capture: PhotoCaptureCoordinator(adapter: _Capture(), staging: staging),
    );
    try {
      controller.restoreLocal(Map<String, Object?>.from(json['controller']));
      index.restoreLocal(Map<String, Object?>.from(evidence));
      expect(
        () => flow.restoreLocal(Map<String, Object?>.from(json['flow'])),
        returnsNormally,
      );
      for (final finding in controller.drafts) {
        for (final photo in finding.evidence) {
          if (photo.version.startsWith('local:')) {
            expect(evidence[photo.evidenceId], isNotNull);
            expect(
              photo.version,
              'local:${(evidence[photo.evidenceId] as Map)['key']}',
            );
          }
        }
      }
    } finally {
      flow.dispose();
      controller.dispose();
    }
  }
}

class _DelayedSecrets extends MemorySecrets {
  Completer<void>? _release;
  Completer<void>? _entered;

  Future<void> blockNextRead() {
    _release = Completer<void>();
    _entered = Completer<void>();
    return _entered!.future;
  }

  void release() => _release!.complete();

  @override
  Future<String?> read(String key) async {
    final entered = _entered;
    if (entered != null) {
      _entered = null;
      entered.complete();
      await _release!.future;
    }
    return super.read(key);
  }
}

class _TokenSession extends FakeSession {
  Future<String?> Function()? token;
  @override
  Future<String?> accessToken() => token?.call() ?? super.accessToken();
}

Object? sorted(Object? value) {
  if (value is Map) {
    return SplayTreeMap<String, Object?>.from({
      for (final e in value.entries) e.key as String: sorted(e.value),
    });
  }
  if (value is List) return value.map(sorted).toList();
  return value;
}

String hash(Object? value) =>
    sha256.convert(utf8.encode(jsonEncode(sorted(value)))).toString();
MatchingHttpResponse response(Object? json) => MatchingHttpResponse(
  statusCode: 200,
  contentType: 'application/json',
  body: utf8.encode(jsonEncode(json)),
);
void main() {
  late Directory directory;
  late AppServices services;
  late FakeTransport transport;
  late _TokenSession session;
  late _DelayedSecrets secrets;
  late _Capture capture;
  late Map<String, Object?> saved;
  late Map<String, Object?> metadata;
  late List<Map<String, Object?>> history;
  LiveAssessmentSession? active;
  var offline = false;
  var assessmentReadStatus = 200;
  Future<void> Function()? beforeRead;
  Future<MatchingHttpResponse?> Function(MatchingHttpRequest)? extraResponse;
  setUp(() async {
    active = null;
    directory = await Directory.systemTemp.createTemp(
      'sah-live-assessment-test-',
    );
    saved = fixture.snapshot().toJson()..['findings'] = <Object>[];
    metadata = {'measurements': <Object>[], 'reviews': <Object>[]};
    history = [];
    offline = false;
    assessmentReadStatus = 200;
    beforeRead = null;
    extraResponse = null;
    Map<String, Object?> state() => {
      'schemaVersion': '2',
      'case': saved,
      'caseFingerprint': hash(saved),
      'catalogRevision': 0,
      'assessment': {
        'schemaVersion': '2',
        'caseId': saved['caseId'],
        'caseRevision': history.isEmpty
            ? saved['revision']
            : history.last['caseRevision'],
        'assessmentRevision': history.length,
        'metadata': metadata,
        'history': history,
      },
      'acknowledgedMutationId': null,
    };
    transport = FakeTransport((request) async {
      if (offline) {
        throw const MatchingTransportException(
          MatchingTransportFailure.network,
        );
      }
      final extra = await extraResponse?.call(request);
      if (extra != null) return extra;
      final body =
          jsonDecode(utf8.decode(request.body)) as Map<String, dynamic>;
      switch (request.endpoint.path) {
        case '/v2/read-assessment':
          final hook = beforeRead;
          beforeRead = null;
          await hook?.call();
          if (assessmentReadStatus == 401) {
            return MatchingHttpResponse(
              statusCode: 401,
              contentType: 'application/json',
              body: utf8.encode(
                jsonEncode({
                  'schemaVersion': '2',
                  'error': {
                    'code': 'UNAUTHENTICATED',
                    'message': 'Fictional rejected session',
                  },
                }),
              ),
            );
          }
          return response(state());
        case '/v1/list-evidence':
          return response({
            'schemaVersion': '1',
            'caseId': saved['caseId'],
            'caseRevision': saved['revision'],
            'catalogRevision': 0,
            'evidence': <Object>[],
          });
        case '/v2/save-assessment':
          saved = {
            ...body['draft'] as Map<String, dynamic>,
            'revision': (saved['revision'] as int) + 1,
          };
          metadata = Map<String, Object?>.from(body['metadata'] as Map);
          history.add({
            'mutationId': body['mutationId'],
            'requestHash': hash(body),
            'caseRevision': saved['revision'],
            'assessmentRevision': history.length + 1,
            'recordedAt': '2026-10-22T20:00:00.000Z',
            'recordedBy': 'fictional-owner',
            'changes': <Object>[],
          });
          throw const MatchingTransportException(
            MatchingTransportFailure.network,
          );
        default:
          throw StateError('Unexpected test route');
      }
    });
    session = _TokenSession();
    secrets = _DelayedSecrets();
    capture = _Capture();
    services = AppServices(
      config: LiveAppConfig(
        apiOrigin: Uri.parse('https://example.org'),
        supabaseUrl: Uri.parse('https://project.supabase.co'),
        publishableKey: 'fictional',
      ),
      session: session,
      store: _DraftFailStore(
        directory: directory,
        accountId: session.userId!,
        secrets: secrets,
      ),
      transport: transport,
      captureAdapterFactory: (_) => capture,
    );
    services.coordinator.snapshot = CaseSnapshot.fromJson(saved);
    services.coordinator.draft = CaseDraft.fromSnapshot(
      services.coordinator.snapshot!,
    );
  });
  tearDown(() async {
    active?.dispose();
    services.dispose();
    services.session.dispose();
    for (var attempt = 0; await directory.exists(); attempt++) {
      try {
        await directory.delete(recursive: true);
      } on FileSystemException {
        if (attempt >= 20) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
  });
  LiveAssessmentSession make() => active = LiveAssessmentSession(
    services: services,
    context: () => throw UnimplementedError(),
    transport: transport,
  );

  Future<String> stagePhoto(LiveAssessmentSession current) async {
    final bytes = pngHeader(width: 800, height: 600);
    final staged = await current.staging.put(
      bytes,
      const ImageValidator().check(bytes) as ImageAccepted,
    );
    final id = current.controller.startFinding(AssessmentArea.entrance);
    current.controller.setObservation(id, 'Fictional entrance');
    final evidenceId = current.controller.addEvidence(
      id,
      version: localEvidenceVersion(staged.key),
    );
    current.evidence.put(evidenceId, staged);
    current.flow.openFinding(id);
    await current.flush();
    return evidenceId;
  }

  test(
    'every accepted capture, retake, remove and discard snapshot reopens',
    () async {
      final current = make();
      await current.initialize();
      capture.result = (_) async =>
          CaptureSucceeded(pngHeader(width: 800, height: 600));
      current.flow.chooseArea(AssessmentArea.entrance);
      await current.flow.openCamera();
      final first = current.flow.previewEvidenceId!;
      current.flow.continueFromPreview();
      current.flow.setObservationText('Fictional entrance');
      current.flow.setMeasurementText('thresholdHeight', ' 02.50 ');
      expect(current.flow.saveDetails(), isTrue);
      current.flow.openPhoto(first);
      await current.flow.openCamera(retake: true);
      current.flow.addCloseUp();
      await current.flow.openCamera();
      current.flow.continueFromPreview();
      expect(current.flow.saveDetails(), isTrue);
      current.flow.openPhoto(first);
      await current.flow.removePreviewPhoto();
      await current.flow.discardFinding();
      await current.flush();
      final snapshots = (services.store as _DraftFailStore).acceptedDrafts;
      expect(snapshots.length, greaterThan(12));
      expectCoherentDrafts(snapshots);
    },
  );

  test(
    'capture intent is durable before the adapter and allocates no fake links',
    () async {
      final current = make();
      await current.initialize();
      capture.result = (_) async {
        final bytes = await services.store.readBytes(current.localKey);
        final draft = jsonDecode(utf8.decode(bytes!)) as Map;
        final intent = draft['flow']['captureAttempt'] as Map;
        expect(draft['caseId'], current.caseId);
        expect(intent['source'], 'library');
        expect(intent['area'], 'bathroom');
        expect(intent['newFinding'], isTrue);
        expect(draft['controller']['drafts'], isEmpty);
        expect(draft['evidence'], isEmpty);
        expect(draft['controller']['reservedFindings'], [intent['findingId']]);
        expect(draft['controller']['reservedEvidence'], [intent['evidenceId']]);
        return const CaptureCancelled();
      };
      current.flow.chooseArea(AssessmentArea.bathroom);
      await current.flow.openCamera(source: CaptureSource.library);
      expect(capture.requests, hasLength(1));
      expect(current.controller.drafts, isEmpty);
      expect(current.flow.isBusy, isFalse);
      expect(current.flow.toLocalJson()['captureAttempt'], isNull);
      expectCoherentDrafts((services.store as _DraftFailStore).acceptedDrafts);
    },
  );

  test(
    'failed prelaunch checkpoint keeps old photo and never opens the adapter',
    () async {
      final current = make();
      await current.initialize();
      final evidenceId = await stagePhoto(current);
      current.flow.openPhoto(evidenceId);
      await current.flush();
      final old = current.evidence[evidenceId]!;
      final store = services.store as _DraftFailStore;
      store.failDraftWrites = true;
      await current.flow.openCamera(
        retake: true,
        source: CaptureSource.library,
      );
      expect(capture.requests, isEmpty);
      expect(current.flow.isBusy, isFalse);
      expect(current.flow.notice, isA<PrivatePhotoSaveFailedNotice>());
      expect(current.evidence[evidenceId]!.key, old.key);
      expect(await current.staging.read(old.key), isNotNull);
      store.failDraftWrites = false;
      await current.flush();
    },
  );

  test(
    'complete attachment is durable before a delayed preview read and reopens idle',
    () async {
      final current = make();
      await current.initialize();
      final store = services.store as _DraftFailStore;
      store.photoReadEntered = Completer<void>();
      store.releasePhotoRead = Completer<void>();
      final photo = pngHeader(width: 800, height: 600);
      capture.result = (_) async => CaptureSucceeded(photo);
      current.flow.chooseArea(AssessmentArea.entrance);
      final taking = current.flow.openCamera();
      await store.photoReadEntered!.future;
      await store.flush();
      final evidenceId = current.flow.previewEvidenceId!;
      final key = current.evidence[evidenceId]!.key;
      expect(current.flow.isBusy, isTrue);
      expectCoherentDrafts(store.acceptedDrafts);
      final durable =
          jsonDecode(utf8.decode((await store.readBytes(current.localKey))!))
              as Map;
      expect(durable['flow']['step'], 'preview');
      expect(durable['flow']['captureAttempt'], isNull);
      current.dispose();
      active = null;
      final restored = make();
      await restored.initialize();
      expect(restored.flow.isBusy, isFalse);
      expect(restored.flow.previewEvidenceId, evidenceId);
      expect(restored.evidence[evidenceId]!.key, key);
      store.releasePhotoRead!.complete();
      await taking;
      expect(await restored.staging.read(key), photo);
      expect(capture.requests, hasLength(1));
    },
  );

  test(
    'first complete attachment write survives later failure and restores exact pixels',
    () async {
      final current = make();
      await current.initialize();
      final store = services.store as _DraftFailStore;
      var wroteAttachment = false;
      store.rejectDraft = (draft) {
        if ((draft['evidence'] as Map).isEmpty) return false;
        if (wroteAttachment) return true;
        wroteAttachment = true;
        return false;
      };
      final photo = pngHeader(width: 800, height: 600);
      capture.result = (_) async => CaptureSucceeded(photo);
      current.flow.chooseArea(AssessmentArea.entrance);
      await current.flow.openCamera();
      expect(wroteAttachment, isTrue);
      expect(current.flow.notice, isA<PrivatePhotoSaveFailedNotice>());
      expect(current.flow.isBusy, isFalse);
      await store.flush();
      expectCoherentDrafts(store.acceptedDrafts);
      final evidenceId = current.flow.previewEvidenceId!;
      final key = current.evidence[evidenceId]!.key;
      current.dispose();
      active = null;
      store.rejectDraft = null;
      final restored = make();
      await restored.initialize();
      expect(restored.flow.previewEvidenceId, evidenceId);
      expect(await restored.staging.read(key), photo);
      expect(capture.requests, hasLength(1));
    },
  );

  for (final expired in [false, true]) {
    test(
      'late capture after ${expired ? 'scope expiry' : 'controller replacement'} attaches nothing',
      () async {
        final current = make();
        await current.initialize();
        final evidenceId = await stagePhoto(current);
        current.flow.openPhoto(evidenceId);
        await current.flush();
        (services.store as _DraftFailStore).acceptedDrafts.clear();
        final old = current.evidence[evidenceId]!.key;
        final entered = Completer<void>();
        final result = Completer<CaptureResult>();
        capture.result = (_) {
          entered.complete();
          return result.future;
        };
        final taking = current.flow.openCamera(retake: true);
        await entered.future;
        if (expired) {
          await session.signOut();
        } else {
          current.controller.replaceEvidence(
            current.flow.findingId!,
            evidenceId,
            version: 'server:2:fictional',
          );
        }
        result.complete(CaptureSucceeded(pngHeader(width: 400, height: 300)));
        await taking;
        expect(current.flow.isBusy, isFalse);
        expect(current.evidence[evidenceId]!.key, old);
        expect(await current.staging.read(old), isNotNull);
        if (!expired) {
          expect(current.flow.notice, isA<PhotoTargetChangedNotice>());
          await current.flush();
          expectCoherentDrafts(
            (services.store as _DraftFailStore).acceptedDrafts,
          );
        }
      },
    );
  }

  for (final privacy in [false, true]) {
    for (final alternative in ['remove', 'closer', 'another']) {
      test(
        'restored ${privacy ? 'privacy' : 'retake'} checkpoint remains recoverable after $alternative',
        () async {
          final first = make();
          await first.initialize();
          final evidenceId = await stagePhoto(first);
          first.flow.openPhoto(evidenceId);
          await first.flush();
          final store = services.store as _DraftFailStore;
          store.acceptedDrafts.clear();
          Completer<CaptureResult>? result;
          Future<void>? taking;
          if (privacy) {
            expect(await first.flow.beginPrivacyEdit(evidenceId), isNotNull);
          } else {
            result = Completer<CaptureResult>();
            final entered = Completer<void>();
            capture.result = (_) {
              entered.complete();
              return result!.future;
            };
            taking = first.flow.openCamera(retake: true);
            await entered.future;
          }
          final old = first.evidence[evidenceId]!.key;
          first.dispose();
          active = null;
          final restored = make();
          await restored.initialize();
          expect(restored.flow.isBusy, isFalse);
          expect(
            restored.flow.notice,
            privacy
                ? isA<InterruptedPrivacyNotice>()
                : isA<InterruptedCaptureNotice>(),
          );
          expect(await restored.staging.read(old), isNotNull);
          expect(capture.requests.length, privacy ? 0 : 1);
          switch (alternative) {
            case 'remove':
              await restored.flow.removePreviewPhoto();
            case 'closer':
              restored.flow.addCloseUp();
              expect(restored.flow.view, CaptureView.closeUp);
            case 'another':
              restored.flow.startAnother();
          }
          await restored.flush();
          expectCoherentDrafts(store.acceptedDrafts);
          expect(restored.flow.toLocalJson()['captureAttempt'], isNull);
          expect(restored.flow.toLocalJson()['privacyAttempt'], isNull);
          if (result != null) {
            result.complete(const CaptureCancelled());
            await taking;
          }
        },
      );
    }
  }

  test(
    'explicit retry reuses valid planned IDs but never the interrupted native result',
    () async {
      final first = make();
      await first.initialize();
      final entered = Completer<void>();
      final interruptedResult = Completer<CaptureResult>();
      capture.result = (_) {
        entered.complete();
        return interruptedResult.future;
      };
      first.flow.chooseArea(AssessmentArea.bathroom);
      final interrupted = first.flow.openCamera(source: CaptureSource.library);
      await entered.future;
      final planned = first.flow.toLocalJson()['captureAttempt'] as Map;
      first.dispose();
      active = null;
      final restored = make();
      await restored.initialize();
      expect(restored.controller.drafts, isEmpty);
      expect(restored.flow.isBusy, isFalse);
      expect(capture.requests, hasLength(1));
      final selectedNow = pngHeader(width: 320, height: 200);
      capture.result = (_) async => CaptureSucceeded(selectedNow);
      await restored.flow.openCamera(source: CaptureSource.library);
      expect(restored.flow.findingId, planned['findingId']);
      expect(restored.flow.previewEvidenceId, planned['evidenceId']);
      final staged = restored.evidence[planned['evidenceId']]!;
      expect(await restored.staging.read(staged.key), selectedNow);
      interruptedResult.complete(
        CaptureSucceeded(pngHeader(width: 800, height: 600)),
      );
      await interrupted;
      expect(restored.evidence[planned['evidenceId']]!.key, staged.key);
      expect(capture.requests, hasLength(2));
      expectCoherentDrafts((services.store as _DraftFailStore).acceptedDrafts);
    },
  );

  test(
    'capture reservation limit is recoverable and never launches native work',
    () async {
      final current = make();
      await current.initialize();
      current.controller.restoreLocal({
        ...current.controller.toLocalJson(),
        'issuedFindings': [for (var i = 0; i < 4096; i++) 'retired-finding-$i'],
      });
      current.flow.chooseArea(AssessmentArea.entrance);
      await current.flow.openCamera();
      expect(capture.requests, isEmpty);
      expect(current.flow.isBusy, isFalse);
      expect(current.flow.notice, isA<PhotoCaptureLimitNotice>());
      expect(current.controller.drafts, isEmpty);
      expect(current.controller.toLocalJson()['reservedFindings'], isEmpty);
      await current.flush();
      current.flow.continueWithoutPhoto();
      expect(current.flow.step, AssessmentStep.details);
      await current.flush();
    },
  );

  test(
    'late privacy result cannot replace a different current version',
    () async {
      final current = make();
      await current.initialize();
      final evidenceId = await stagePhoto(current);
      current.flow.openPhoto(evidenceId);
      await current.flush();
      final store = services.store as _DraftFailStore;
      store.acceptedDrafts.clear();
      final old = current.evidence[evidenceId]!.key;
      final attempt = await current.flow.beginPrivacyEdit(evidenceId);
      expect(attempt, isNotNull);
      current.controller.replaceEvidence(
        current.flow.findingId!,
        evidenceId,
        version: 'server:3:fictional',
      );
      await current.flow.finishPrivacyEdit(
        attempt!,
        pngHeader(width: 400, height: 300),
      );
      await current.flush();
      expect(current.flow.isBusy, isFalse);
      expect(current.flow.notice, isA<PhotoTargetChangedNotice>());
      expect(current.flow.toLocalJson()['privacyAttempt'], isNull);
      expect(current.evidence[evidenceId]!.key, old);
      expectCoherentDrafts(store.acceptedDrafts);
    },
  );

  test(
    'discarding local conflict publishes only coherent replacement snapshots',
    () async {
      final current = make();
      await current.initialize();
      final evidenceId = await stagePhoto(current);
      current.flow.openPhoto(evidenceId);
      await current.flush();
      final store = services.store as _DraftFailStore;
      store.acceptedDrafts.clear();
      current.localConflict = true;
      await current.resolveLocalConflict(keepLocal: false);
      expect(current.controller.drafts, isEmpty);
      expect(current.flow.step, AssessmentStep.chooseArea);
      expect(current.evidence.evidenceIds, isEmpty);
      expect(store.acceptedDrafts, isNotEmpty);
      expectCoherentDrafts(store.acceptedDrafts);
    },
  );

  test(
    'choosing saved assessment reloads saved marks instead of deleting them',
    () async {
      final finding = Map<String, Object?>.from(
        (fixture.snapshot().toJson()['findings'] as List).single as Map,
      )..['evidenceIds'] = ['fictional-evidence'];
      saved['findings'] = [finding];
      metadata = {
        'measurements': <Object>[],
        'reviews': [
          {'findingId': finding['id'], 'state': 'confirmed', 'note': null},
        ],
      };
      services.coordinator.snapshot = CaseSnapshot.fromJson(saved);
      services.coordinator.draft = CaseDraft.fromSnapshot(
        services.coordinator.snapshot!,
      );
      final descriptor = fixture.descriptorJson();
      final originalMarks = <Map<String, Object?>>[
        {
          'id': 'saved-threshold-box',
          'rect': [250000, 250000, 500000, 500000],
          'label': 'Fictional threshold',
        },
      ];
      var remoteMarks = originalMarks;
      var annotationRevision = 1;
      var catalogRevision = 1;
      final annotationWrites = <Object?>[];
      Map<String, Object?> annotationState() => {
        'schemaVersion': '2',
        'caseId': saved['caseId'],
        'caseRevision': saved['revision'],
        'catalogRevision': catalogRevision,
        'annotation': {
          'schemaVersion': '2',
          'caseId': saved['caseId'],
          'evidenceId': descriptor['evidenceId'],
          'annotationRevision': annotationRevision,
          'evidenceRevision': descriptor['evidenceRevision'],
          'imageSha256': descriptor['sha256'],
          'imageWidth': descriptor['width'],
          'imageHeight': descriptor['height'],
          'coordinateSpace': 'normalized-top-left-1e6',
          'marks': remoteMarks,
          'reviewState': 'needs_review',
          'reviewedCaseRevision': null,
          'reviewedAt': null,
          'reviewedBy': null,
        },
      };
      extraResponse = (request) async {
        switch (request.endpoint.path) {
          case '/v1/list-evidence':
            return response({
              ...fixture.catalogJson(),
              'caseRevision': saved['revision'],
              'catalogRevision': catalogRevision,
            });
          case '/v1/download-evidence':
            return MatchingHttpResponse(
              statusCode: 200,
              contentType: 'image/png',
              body: fixture.png,
            );
          case '/v2/read-evidence-annotations':
            return response(annotationState());
          case '/v2/save-evidence-annotations':
            final body = jsonDecode(utf8.decode(request.body)) as Map;
            annotationWrites.add(body['marks']);
            remoteMarks = (body['marks'] as List)
                .map((mark) => Map<String, Object?>.from(mark as Map))
                .toList();
            annotationRevision++;
            catalogRevision++;
            return response(annotationState());
          default:
            return null;
        }
      };
      final current = make();
      await current.initialize();
      await current.loadSavedImage('fictional-evidence');
      expect(current.annotations.all.single.label, 'Fictional threshold');
      await current.flush();
      saved = {
        ...saved,
        'revision': (saved['revision'] as int) + 1,
        'profile': {
          ...saved['profile'] as Map,
          'city': 'Fictional other-device correction',
        },
      };
      await current.save();
      expect(current.localConflict, isTrue);
      current.annotationConflictId = 'fictional-evidence';
      current.annotationNotice = 'Earlier device mark conflict';
      final store = services.store as _DraftFailStore;
      store.acceptedDrafts.clear();
      await current.resolveLocalConflict(keepLocal: false);
      current.flow.openFinding('fictional-finding');
      current.flow.openPhoto('fictional-evidence');
      await current.flow.loadBytes('fictional-evidence');
      await current.save();
      expect(annotationWrites, isEmpty);
      expect(remoteMarks, originalMarks);
      expect(current.annotations.all.single.label, 'Fictional threshold');
      expect(current.annotationConflictId, isNull);
      expect(current.annotationNotice, isNull);
      expectCoherentDrafts(store.acceptedDrafts);
      await current.flush();
    },
  );

  test('older local drafts without media checkpoints still restore', () async {
    final first = make();
    await first.initialize();
    final evidenceId = await stagePhoto(first);
    first.flow.openPhoto(evidenceId);
    await first.flush();
    final json =
        jsonDecode(
              utf8.decode((await services.store.readBytes(first.localKey))!),
            )
            as Map;
    (json['flow'] as Map)
      ..remove('captureAttempt')
      ..remove('privacyAttempt');
    (json['controller'] as Map)
      ..remove('reservedFindings')
      ..remove('reservedEvidence');
    await services.store.writeBytes(
      first.localKey,
      Uint8List.fromList(utf8.encode(jsonEncode(json))),
    );
    first.dispose();
    active = null;
    final restored = make();
    await restored.initialize();
    expect(restored.flow.previewEvidenceId, evidenceId);
    expect(restored.flow.isBusy, isFalse);
    expect(restored.flow.notice, isNull);
  });

  for (final explicitClear in [false, true]) {
    test(
      explicitClear
          ? 'explicit cleanup deletes accepted assessment writes after draining them'
          : 'expiry drains accepted assessment edits before closing encrypted work',
      () async {
        final current = make();
        await current.initialize();
        final evidenceId = await stagePhoto(current);
        final photo = current.evidence[evidenceId]!;
        final originalBytes = await current.staging.read(photo.key);
        current.flow.edit();
        await current.flush();

        final entered = secrets.blockNextRead();
        current.flow.setObservationText('Earlier fictional observation');
        await entered;
        current.flow.setObservationText('Latest fictional observation');
        current.flow.setMeasurementText('thresholdHeight', '  02.50  ');
        current.flow.setMeasurementUnit(
          'thresholdHeight',
          LengthUnit.centimetre,
        );
        final latest = current.flush();
        final accepted = expectLater(latest, completes);

        await session.signOut();
        expect(
          current.flush,
          throwsA(
            isA<MatchingApiException>().having(
              (e) => e.code,
              'code',
              'STALE_RESPONSE',
            ),
          ),
        );
        final closed = explicitClear
            ? services.store.clear()
            : services.store.close();
        current.dispose();
        active = null;
        secrets.release();
        await Future.wait([accepted, closed]);

        final reopened = LocalPrivateStore(
          directory: directory,
          accountId: 'fictional-owner',
          secrets: secrets,
        );
        final reopenedPhotos = EncryptedStagingStore(
          reopened,
          caseId: current.caseId,
        );
        if (explicitClear) {
          expect(await reopened.readBytes(current.localKey), isNull);
          expect(await reopenedPhotos.read(photo.key), isNull);
          expect(secrets.values, isEmpty);
        } else {
          final durable =
              jsonDecode(
                    utf8.decode((await reopened.readBytes(current.localKey))!),
                  )
                  as Map;
          expect(
            durable['flow']['observation'],
            'Latest fictional observation',
          );
          expect(durable['flow']['entries']['thresholdHeight'], {
            'text': '  02.50  ',
            'unit': 'centimetre',
            'method': 'manual',
          });
          expect(durable['evidence'][evidenceId]['key'], photo.key.value);
          expect(await reopenedPhotos.read(photo.key), originalBytes);
        }
        await reopened.close();
      },
    );
  }

  for (final backendDenial in [false, true]) {
    test(
      backendDenial
          ? 'backend authentication rejection never opens the cached assessment'
          : 'unclassified token failure never opens the cached assessment',
      () async {
        final first = make();
        await first.initialize();
        await stagePhoto(first);
        final durable = await services.store.readBytes(first.localKey);
        first.dispose();
        active = null;
        if (backendDenial) {
          assessmentReadStatus = 401;
        } else {
          session.token = () async =>
              throw StateError('Fictional auth failure');
        }
        final restored = make();
        await expectLater(
          restored.initialize(),
          throwsA(
            isA<MatchingApiException>().having(
              (e) => e.code,
              'code',
              'UNAUTHENTICATED',
            ),
          ),
        );
        expect(restored.controller.findings, isEmpty);
        expect(restored.evidence.evidenceIds, isEmpty);
        expect(restored.resumeNotice, isNull);
        expect(await services.store.readBytes(first.localKey), durable);
      },
    );
  }

  test(
    'accepted save checkpoint cannot publish to a disposed assessment',
    () async {
      final current = make();
      await current.initialize();
      await stagePhoto(current);
      current.flow.edit();
      await current.flush();
      final entered = secrets.blockNextRead();
      current.flow.setObservationText('');
      await entered;
      final save = current.save();
      final rejected = expectLater(
        save,
        throwsA(
          isA<MatchingApiException>().having(
            (e) => e.code,
            'code',
            'STALE_RESPONSE',
          ),
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(current.flow.errors.observationMissing, isTrue);
      await session.signOut();
      final closed = services.store.close();
      current.dispose();
      active = null;
      secrets.release();
      await Future.wait([rejected, closed]);
      final reopened = LocalPrivateStore(
        directory: directory,
        accountId: 'fictional-owner',
        secrets: secrets,
      );
      final durable =
          jsonDecode(utf8.decode((await reopened.readBytes(current.localKey))!))
              as Map;
      expect(durable['flow']['observation'], '');
      expect(
        transport.requests.where(
          (r) => r.endpoint.path == '/v2/save-assessment',
        ),
        isEmpty,
      );
      await reopened.close();
    },
  );

  testWidgets(
    'background callback after expiry observes synchronous stale flush failure',
    (tester) async {
      final checkpoint = Completer<void>();
      (services.store as _DraftFailStore).onDraftWrite = () {
        if (!checkpoint.isCompleted) checkpoint.complete();
      };
      await tester.pumpWidget(
        MaterialApp(home: LiveAssessmentScreen(services: services)),
      );
      Future<void> settleUntil(bool Function() done) async {
        for (var attempt = 0; attempt < 200 && !done(); attempt++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump();
        }
        expect(done(), isTrue, reason: 'Bounded private checkpoint completed');
      }

      await settleUntil(() => checkpoint.isCompleted);
      var persisted = false;
      services.store.flush().then((_) => persisted = true);
      await settleUntil(() => persisted);
      final localKey = 'assessment:${saved['caseId']}:draft';
      final original = await tester.runAsync(
        () => services.store.readBytes(localKey),
      );
      expect(original, isNotNull);
      final dispatched = transport.requests.length;
      await session.signOut();

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      expect(tester.takeException(), isNull);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(transport.requests, hasLength(dispatched));
      expect(
        await tester.runAsync(() => services.store.readBytes(localKey)),
        original,
      );
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  test(
    'retryable token unavailability resumes only current-owner encrypted assessment',
    () async {
      final first = make();
      await first.initialize();
      final evidenceId = await stagePhoto(first);
      final photo = first.evidence[evidenceId]!;
      final photoBytes = await first.staging.read(photo.key);
      first.flow.edit();
      first.flow.setObservationText('Fictional offline entrance');
      first.flow.setMeasurementText('thresholdHeight', '  02.50  ');
      first.flow.setMeasurementUnit('thresholdHeight', LengthUnit.centimetre);
      await first.flush();
      first.dispose();
      active = null;
      final dispatched = transport.requests.length;
      session.token = () async =>
          throw const RetryableTokenUnavailableException();
      final restored = make();
      await restored.initialize();
      expect(restored.resumeNotice, contains('this device'));
      expect(restored.flow.observationText, 'Fictional offline entrance');
      expect(restored.flow.entryFor('thresholdHeight').text, '  02.50  ');
      expect(
        restored.flow.entryFor('thresholdHeight').unit,
        LengthUnit.centimetre,
      );
      expect(restored.evidence[evidenceId]!.key, photo.key);
      expect(await restored.staging.read(photo.key), photoBytes);
      expect(transport.requests, hasLength(dispatched));
      await expectLater(
        restored.save(),
        throwsA(
          isA<MatchingApiException>().having(
            (e) => e.code,
            'code',
            'NETWORK_ERROR',
          ),
        ),
      );
      expect(transport.requests, hasLength(dispatched));
      await restored.flush();
    },
  );

  test(
    'failed draft write and restart preserve the old persisted photo attachment',
    () async {
      final current = make();
      await current.initialize();
      final evidenceId = await stagePhoto(current);
      final old = current.evidence[evidenceId]!;
      final store = services.store as _DraftFailStore;
      store.failDraftWrites = true;
      await expectLater(
        current.flow.applyProcessedPhoto(
          evidenceId,
          pngHeader(width: 400, height: 300),
        ),
        throwsStateError,
      );
      await expectLater(current.flush(), throwsStateError);
      expect(current.localSaveFailed, isTrue);
      expect(await current.staging.read(old.key), isNotNull);
      expect(current.evidence[evidenceId]!.key, isNot(old.key));
      final durable =
          jsonDecode(utf8.decode((await store.readBytes(current.localKey))!))
              as Map;
      expect(durable['evidence'][evidenceId]['key'], old.key.value);
      current.dispose();
      active = null;
      store.failDraftWrites = false;
      final restored = make();
      await restored.initialize();
      expect(restored.evidence[evidenceId]!.key, old.key);
      expect(await restored.staging.read(old.key), isNotNull);
      expect(await restored.staging.keys(), hasLength(2));
    },
  );

  test(
    'restart finishes only journaled deletion after the replacement index is durable',
    () async {
      final current = make();
      await current.initialize();
      final evidenceId = await stagePhoto(current);
      final old = current.evidence[evidenceId]!;
      final store = services.store as _DraftFailStore;
      final otherCase = EncryptedStagingStore(
        store,
        caseId: 'another-fictional-case',
      );
      final bytes = pngHeader(width: 400, height: 300);
      final otherPhoto = await otherCase.put(
        bytes,
        const ImageValidator().check(bytes) as ImageAccepted,
      );
      store.failPhotoDeletion = true;
      await current.flow.applyProcessedPhoto(evidenceId, bytes);
      await current.flush();
      final replacement = current.evidence[evidenceId]!;
      final durable =
          jsonDecode(utf8.decode((await store.readBytes(current.localKey))!))
              as Map;
      expect(durable['evidence'][evidenceId]['key'], replacement.key.value);
      expect(durable['discardedPhotos'], contains(old.key.value));
      expect(await current.staging.read(old.key), isNotNull);
      current.dispose();
      active = null;
      store.failPhotoDeletion = false;
      final restored = make();
      await restored.initialize();
      expect(await restored.staging.read(old.key), isNull);
      expect(await restored.staging.read(replacement.key), isNotNull);
      expect(await otherCase.read(otherPhoto.key), isNotNull);
    },
  );

  test(
    'an uncertain upload journal retains its photo through later replacement and flush',
    () async {
      final current = make();
      await current.initialize();
      final evidenceId = await stagePhoto(current);
      final old = current.evidence[evidenceId]!;
      current.sync.restoreLocal({
        ...current.sync.toLocalJson(),
        'phase': 'uncertain',
        'pendingUpload': {
          'evidenceId': evidenceId,
          'version': localEvidenceVersion(old.key),
          'expected': 0,
        },
      });
      await current.flow.applyProcessedPhoto(
        evidenceId,
        pngHeader(width: 400, height: 300),
      );
      await current.flush();
      expect(await current.staging.read(old.key), isNotNull);
      current.sync.restoreLocal({
        ...current.sync.toLocalJson(),
        'phase': 'idle',
        'pendingUpload': null,
      });
      await current.flush();
      expect(await current.staging.read(old.key), isNull);
    },
  );

  test(
    'restart recognizes exact atomic mutation receipt without duplicate write',
    () async {
      final first = make();
      await first.initialize();
      final id = first.controller.startFinding(AssessmentArea.entrance);
      first.controller.setObservation(id, 'Fictional threshold');
      await first.save();
      expect(first.sync.phase, SyncPhase.uncertain);
      expect(first.pendingRequest, isNotNull);
      await first.flush();
      first.dispose();
      active = null;
      final restored = make();
      await restored.initialize();
      expect(restored.localConflict, false);
      expect(restored.pendingRequest, isNull);
      expect(restored.sync.phase, SyncPhase.idle);
      expect(restored.sync.savedCase.revision, 3);
      expect(
        transport.requests.where(
          (r) => r.endpoint.path == '/v2/save-assessment',
        ),
        hasLength(1),
      );
    },
  );

  test(
    'a separate writer on restart requires explicit local-cloud choice',
    () async {
      final first = make();
      await first.initialize();
      final id = first.controller.startFinding(AssessmentArea.bathroom);
      first.controller.setObservation(id, 'Unsaved local observation');
      await first.flush();
      first.dispose();
      active = null;
      saved = {...saved, 'revision': 3};
      final restored = make();
      await restored.initialize();
      expect(restored.localConflict, true);
      expect(
        restored.controller.findings.single.observation,
        'Unsaved local observation',
      );
      await expectLater(restored.save(), throwsStateError);
      expect(
        transport.requests.where(
          (r) => r.endpoint.path == '/v2/save-assessment',
        ),
        isEmpty,
      );
    },
  );

  Future<void> editProfile(String city) => services.coordinator.updateDraft(
    CaseDraft.fromJson({
      ...services.coordinator.currentDraft().toJson(),
      'profile': {
        ...services.coordinator.currentDraft().profile.toJson(),
        'city': city,
      },
    }),
  );

  test(
    'offline first assessment preserves profile edits and staged photos across restart',
    () async {
      await editProfile('Fictional offline city');
      offline = true;
      final first = make();
      await first.initialize();
      expect(first.state, isNull);
      expect(first.caseWriteBlocked, true);
      final id = first.controller.startFinding(AssessmentArea.entrance);
      first.controller.setObservation(id, 'Offline threshold note');
      final bytes = Uint8List.fromList(
        utf8.encode('fictional normalized photo bytes'),
      );
      final staged = await first.staging.put(
        bytes,
        ImageAccepted(
          format: SupportedImageFormat.jpeg,
          width: 20,
          height: 20,
          byteLength: bytes.length,
        ),
        capturedAt: '2026-10-22T20:00:00.000Z',
        orientationNormalized: true,
      );
      final evidenceId = first.controller.addEvidence(
        id,
        version: localEvidenceVersion(staged.key),
      );
      first.evidence.put(evidenceId, staged);
      await first.flush();
      await expectLater(first.save(), throwsStateError);
      first.dispose();
      active = null;
      final restored = make();
      await restored.initialize();
      expect(
        restored.controller.findings.single.observation,
        'Offline threshold note',
      );
      expect(
        await restored.staging.read(restored.evidence[evidenceId]!.key),
        bytes,
      );
      expect(
        services.coordinator.currentDraft().profile.city,
        'Fictional offline city',
      );
      expect(restored.caseWriteBlocked, true);
      expect(
        transport.requests.where(
          (r) => r.endpoint.path != '/v2/read-assessment',
        ),
        isEmpty,
      );
      await restored.flush();
    },
  );

  test(
    'profile edits arriving during assessment preflight prevent every remote mutation',
    () async {
      final current = make();
      await current.initialize();
      final id = current.controller.startFinding(AssessmentArea.bathroom);
      current.controller.setObservation(id, 'Keep this finding locally');
      beforeRead = () => editProfile('Concurrent profile edit');
      await expectLater(current.save(), throwsStateError);
      expect(current.caseWriteBlocked, true);
      expect(
        services.coordinator.currentDraft().profile.city,
        'Concurrent profile edit',
      );
      expect(
        current.controller.findings.single.observation,
        'Keep this finding locally',
      );
      expect(
        transport.requests.where(
          (r) =>
              r.endpoint.path.contains('save-') ||
              r.endpoint.path.contains('upload-') ||
              r.endpoint.path.contains('delete-'),
        ),
        isEmpty,
      );
      await current.flush();
    },
  );

  test(
    'unsaved profile blocks assessment reconciliation until the profile choice is explicit',
    () async {
      final current = make();
      await current.initialize();
      final id = current.controller.startFinding(AssessmentArea.entrance);
      current.controller.setObservation(id, 'Retained offline finding');
      await editProfile('Pending profile');
      await expectLater(
        current.resolveLocalConflict(keepLocal: true),
        throwsStateError,
      );
      await expectLater(current.recover(), throwsStateError);
      expect(
        services.coordinator.currentDraft().profile.city,
        'Pending profile',
      );
      expect(
        current.controller.findings.single.observation,
        'Retained offline finding',
      );
      await current.flush();
    },
  );

  test(
    'first offline opening preserves remote original units for untouched measurements on reconnect',
    () async {
      saved['findings'] = [
        {
          'id': 'finding-from-device-a',
          'room': 'entrance',
          'observation': 'Threshold',
          'reviewState': 'needs_review',
          'evidenceIds': <Object>[],
          'measurements': [
            {
              'type': 'thresholdHeight',
              'value': 15,
              'unit': 'mm',
              'method': 'manual',
              'confirmed': false,
            },
          ],
        },
      ];
      metadata = {
        'measurements': [
          {
            'findingId': 'finding-from-device-a',
            'type': 'thresholdHeight',
            'originalText': '1,5',
            'originalUnit': 'cm',
            'decimalSeparator': 'comma',
            'source': 'manual',
            'recorder': 'helper',
            'recordedAt': '2026-10-22T18:00:00.000Z',
          },
        ],
        'reviews': [
          {
            'findingId': 'finding-from-device-a',
            'state': 'needs_review',
            'note': 'Check the height again',
          },
        ],
      };
      services.coordinator.snapshot = CaseSnapshot.fromJson(saved);
      services.coordinator.draft = CaseDraft.fromSnapshot(
        services.coordinator.snapshot!,
      );
      offline = true;
      final current = make();
      await current.initialize();
      expect(
        current.controller
            .draftOf('finding-from-device-a')!
            .measurementOf('thresholdHeight')!
            .originalInputKnown,
        false,
      );
      final id = current.controller.startFinding(AssessmentArea.bathroom);
      current.controller.setObservation(id, 'A new offline finding');
      offline = false;
      await current.save();
      final request = transport.requests.singleWhere(
        (r) => r.endpoint.path == '/v2/save-assessment',
      );
      final body = jsonDecode(utf8.decode(request.body)) as Map;
      final original = (body['metadata']['measurements'] as List).single;
      expect(original['originalText'], '1,5');
      expect(original['originalUnit'], 'cm');
      expect(original['recorder'], 'helper');
      final oldReview = (body['metadata']['reviews'] as List).singleWhere(
        (r) => r['findingId'] == 'finding-from-device-a',
      );
      expect(oldReview['note'], 'Check the height again');
      await current.flush();
    },
  );

  test(
    'older sidecar does not claim original units for an equal-valued v1 measurement',
    () async {
      saved['findings'] = [
        {
          'id': 'finding-from-earlier-revision',
          'room': 'entrance',
          'observation': 'Fictional threshold',
          'reviewState': 'needs_review',
          'evidenceIds': <Object>[],
          'measurements': [
            {
              'type': 'thresholdHeight',
              'value': 15,
              'unit': 'mm',
              'method': 'manual',
              'confirmed': false,
            },
          ],
        },
      ];
      metadata = {
        'measurements': [
          {
            'findingId': 'finding-from-earlier-revision',
            'type': 'thresholdHeight',
            'originalText': '1,5',
            'originalUnit': 'cm',
            'decimalSeparator': 'comma',
            'source': 'manual',
            'recorder': 'helper',
            'recordedAt': '2026-10-22T18:00:00.000Z',
          },
        ],
        'reviews': [
          {
            'findingId': 'finding-from-earlier-revision',
            'state': 'needs_review',
            'note': null,
          },
        ],
      };
      history.add({
        'mutationId': 'earlier-mutation',
        'requestHash': '0' * 64,
        'caseRevision': 1,
        'assessmentRevision': 1,
        'recordedAt': '2026-10-22T18:00:00.000Z',
        'recordedBy': 'fictional-owner',
        'changes': <Object>[],
      });
      services.coordinator.snapshot = CaseSnapshot.fromJson(saved);
      services.coordinator.draft = CaseDraft.fromSnapshot(
        services.coordinator.snapshot!,
      );
      final current = make();
      await current.initialize();
      final measurement = current.controller
          .draftOf('finding-from-earlier-revision')!
          .measurementOf('thresholdHeight')!;
      expect(measurement.input.millimetres, 15);
      expect(measurement.originalInputKnown, false);
      expect(measurement.recorder, 'unknown');
      expect(measurement.recordedAt, isNull);
      final wire =
          (current.metadataFor(current.sync.replacementFindings)['measurements']
                      as List)
                  .single
              as Map;
      expect(wire['source'], 'legacy_unknown');
      expect(wire['originalText'], isNull);
    },
  );

  test(
    'explicit reconciliation saves retained findings using the newly saved profile',
    () async {
      final first = make();
      await first.initialize();
      final id = first.controller.startFinding(AssessmentArea.entrance);
      first.controller.setObservation(id, 'Retain this local finding');
      await editProfile('Profile chosen by resident');
      await first.flush();
      first.dispose();
      active = null;
      saved = {
        ...services.coordinator.currentDraft().toJson(),
        'revision': (saved['revision'] as int) + 1,
      };
      services.coordinator.snapshot = CaseSnapshot.fromJson(saved);
      services.coordinator.draft = CaseDraft.fromSnapshot(
        services.coordinator.snapshot!,
      );
      final restored = make();
      await restored.initialize();
      expect(restored.localConflict, true);
      expect(restored.caseWriteBlocked, false);
      await restored.resolveLocalConflict(keepLocal: true);
      expect(restored.localConflict, false);
      await restored.save();
      final request = transport.requests.singleWhere(
        (r) => r.endpoint.path == '/v2/save-assessment',
      );
      final body = jsonDecode(utf8.decode(request.body)) as Map;
      expect(body['draft']['profile']['city'], 'Profile chosen by resident');
      expect(
        (body['draft']['findings'] as List).single['observation'],
        'Retain this local finding',
      );
      expect(body['expectedCaseRevision'], 3);
      await restored.flush();
    },
  );

  test(
    'an exact lost-save receipt cannot authorize overwriting a later writer',
    () async {
      final first = make();
      await first.initialize();
      final id = first.controller.startFinding(AssessmentArea.entrance);
      first.controller.setObservation(id, 'Earlier local observation');
      await first.save();
      expect(first.pendingRequest, isNotNull);
      await first.flush();
      first.dispose();
      active = null;
      saved = {
        ...saved,
        'revision': 4,
        'findings': [
          for (final raw in saved['findings'] as List)
            {
              ...raw as Map,
              'observation': 'Later observation from another device',
            },
        ],
      };
      final restored = make();
      await restored.initialize();
      expect(restored.localConflict, true);
      expect(restored.pendingRequest, isNotNull);
      expect(
        restored.controller.findings.single.observation,
        'Earlier local observation',
      );
      await expectLater(restored.save(), throwsStateError);
      expect(
        transport.requests.where(
          (r) => r.endpoint.path == '/v2/save-assessment',
        ),
        hasLength(1),
      );
      await restored.flush();
    },
  );
}
