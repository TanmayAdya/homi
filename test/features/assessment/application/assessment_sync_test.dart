import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/features/assessment/application/assessment_controller.dart';
import 'package:safe_at_home/features/assessment/application/assessment_sync.dart';
import 'package:safe_at_home/features/assessment/application/local_evidence_index.dart';
import 'package:safe_at_home/features/assessment/domain/capture/capture_adapter.dart';
import 'package:safe_at_home/features/assessment/domain/capture/staging_store.dart';
import 'package:safe_at_home/features/assessment/domain/image/image_validator.dart';
import 'package:safe_at_home/shared/models/contracts.dart';

import '../fakes/fake_case_server.dart';
import '../fakes/fakes.dart';
import '../fakes/image_bytes.dart';

CaseSnapshot _initialCase({List<Map<String, Object?>> findings = const []}) =>
    CaseSnapshot.fromJson({
      'schemaVersion': '1',
      'caseId': 'case-1',
      'revision': 1,
      'profile': {
        'city': null,
        'county': null,
        'healthPlan': null,
        'tenure': null,
        'ageYears': null,
        'householdSize': null,
        'annualIncomeUsd': null,
        'ownerConsentReported': null,
      },
      'unresolvedFields': <String>[],
      'findings': findings,
    });

void main() {
  late FakeCaseServer server;
  late AssessmentController controller;
  late InMemoryStagingStore staging;
  late LocalEvidenceIndex evidence;
  late AssessmentSync sync;
  late List<int> adoptedRevisions;

  AssessmentSync makeSync(CaseSnapshot saved) => AssessmentSync(
    gateway: server,
    controller: controller,
    evidence: evidence,
    staging: staging,
    savedCase: saved,
    onCaseSaved: (c) => adoptedRevisions.add(c.revision),
  );

  setUp(() {
    server = FakeCaseServer(_initialCase());
    controller = AssessmentController(ids: SequentialIdFactory());
    staging = InMemoryStagingStore();
    evidence = LocalEvidenceIndex();
    adoptedRevisions = [];
    sync = makeSync(server.serverCase);
  });

  Future<String> stagePhoto(String findingId, {int width = 1200}) async {
    final Uint8List bytes = jpegHeader(width: width, height: 900);
    final StagedImage image = await staging.put(
      bytes,
      ImageAccepted(
        format: SupportedImageFormat.jpeg,
        width: width,
        height: 900,
        byteLength: bytes.length,
      ),
    );
    final String id = controller.addEvidence(
      findingId,
      version: localEvidenceVersion(image.key),
    );
    evidence.put(id, image);
    return id;
  }

  Future<void> retake(String findingId, String evidenceId) async {
    final Uint8List bytes = jpegHeader(width: 999, height: 900);
    final StagedImage image = await staging.put(
      bytes,
      ImageAccepted(
        format: SupportedImageFormat.jpeg,
        width: 999,
        height: 900,
        byteLength: bytes.length,
      ),
    );
    controller.replaceEvidence(
      findingId,
      evidenceId,
      version: localEvidenceVersion(image.key),
    );
    evidence.put(evidenceId, image);
  }

  String finding({String text = 'I notice a raised threshold.'}) {
    final String id = controller.startFinding(AssessmentArea.entrance);
    controller.setObservation(id, text);
    return id;
  }

  group('first save', () {
    test('saves the link first, then uploads, then cleans staging', () async {
      final String f = finding();
      final String e = await stagePhoto(f);
      expect(sync.hasUnsavedWork, isTrue);
      expect(sync.isSaved(f), isFalse);

      final SyncReport report = await sync.save();

      expect(report.caseSaved, isTrue);
      expect(report.uploaded, [e]);
      expect(report.errorCode, isNull);
      expect(sync.phase, SyncPhase.idle);
      expect(
        server.calls.indexOf('saveCase'),
        lessThan(server.calls.indexOf('uploadEvidence:$e')),
      );
      expect(server.serverCase.revision, 2);
      expect(server.serverCase.findings.single.evidenceIds, [e]);
      expect(server.evidenceRevisions, {e: 1});
      expect(adoptedRevisions, [2]);
      expect(await staging.keys(), isEmpty);
      expect(evidence[e], isNull);
      expect(sync.isSaved(f), isTrue);
      expect(sync.hasUnsavedWork, isFalse);
    });

    test('uploads send no capture time', () async {
      final String f = finding();
      await stagePhoto(f);
      await sync.save();
      expect(server.serverCase.findings.single.evidenceIds, hasLength(1));
    });

    test('a second save with no changes sends no writes', () async {
      final String f = finding();
      await stagePhoto(f);
      await sync.save();
      server.calls.clear();
      final SyncReport report = await sync.save();
      expect(report.caseSaved, isFalse);
      expect(report.uploaded, isEmpty);
      expect(server.calls.where((c) => !c.startsWith('listEvidence')), isEmpty);
    });

    test('findings without an observation are left out and reported', () async {
      final String incomplete = controller.startFinding(
        AssessmentArea.bathroom,
      );
      await stagePhoto(incomplete);
      final String f = finding();
      final SyncReport report = await sync.save();
      expect(report.skippedIncomplete, [incomplete]);
      expect(server.serverCase.findings.map((x) => x.id), [f]);
      expect(server.evidenceRevisions, isEmpty);
    });

    test('saved findings this module does not hold are kept', () async {
      server = FakeCaseServer(
        _initialCase(
          findings: [
            {
              'id': 'older-finding',
              'room': 'bathroom',
              'observation': 'Recorded earlier.',
              'reviewState': 'confirmed',
              'evidenceIds': <String>[],
              'measurements': <Object>[],
            },
          ],
        ),
      );
      sync = makeSync(server.serverCase);
      final String f = finding();
      await sync.save();
      expect(server.serverCase.findings.map((x) => x.id), ['older-finding', f]);
    });
  });

  group('changes after saving', () {
    late String f;
    late String e;

    setUp(() async {
      f = finding();
      e = await stagePhoto(f);
      await sync.save();
      server.calls.clear();
    });

    test('a retake is uploaded as a replacement of the same ID', () async {
      await retake(f, e);
      expect(sync.isSaved(f), isFalse);
      final SyncReport report = await sync.save();
      expect(report.uploaded, [e]);
      expect(server.evidenceRevisions, {e: 2});
      expect(server.evidenceBytes[e]!.length, greaterThan(0));
    });

    test('a removed photo is deleted before its link is saved away', () async {
      controller.removeEvidence(f, e);
      final SyncReport report = await sync.save();
      expect(report.deleted, [e]);
      expect(
        server.calls.indexOf('deleteEvidence:$e'),
        lessThan(server.calls.indexOf('saveCase')),
      );
      expect(server.serverCase.findings.single.evidenceIds, isEmpty);
      expect(server.evidenceRevisions, isEmpty);
    });

    test('a removed finding loses its photos, then leaves the case', () async {
      controller.removeFinding(f);
      await sync.save();
      expect(
        server.calls.indexOf('deleteEvidence:$e'),
        lessThan(server.calls.indexOf('saveCase')),
      );
      expect(server.serverCase.findings, isEmpty);
    });

    test('an edited observation saves a new case revision', () async {
      controller.setObservation(f, 'I notice a raised threshold, about 2 cm.');
      final SyncReport report = await sync.save();
      expect(report.caseSaved, isTrue);
      expect(report.uploaded, isEmpty);
      expect(server.serverCase.revision, 3);
    });
  });

  group('uncertain results', () {
    test('a lost case-save response blocks writes until recovery', () async {
      final String f = finding();
      await stagePhoto(f);
      server.failNext['saveCase'] = (
        'CASE_SAVE_UNCERTAIN',
        FailMode.afterApplying,
      );

      final SyncReport report = await sync.save();
      expect(report.errorCode, 'CASE_SAVE_UNCERTAIN');
      expect(sync.phase, SyncPhase.uncertain);
      expect(sync.canSave, isFalse);
      expect((await sync.save()).caseSaved, isFalse);
      expect(server.calls.where((c) => c == 'saveCase'), hasLength(1));

      expect(await sync.recover(), isTrue);
      expect(sync.savedCase.revision, 2);
      expect(adoptedRevisions, [2]);

      server.calls.clear();
      final SyncReport after = await sync.save();
      expect(after.caseSaved, isFalse, reason: 'already saved; no duplicate');
      expect(after.uploaded, hasLength(1));
    });

    test(
      'lost upload response requires explicit saved-photo review before discarding staging',
      () async {
        final String f = finding();
        final String e = await stagePhoto(f);
        server.failNext['uploadEvidence'] = (
          'EVIDENCE_SAVE_UNCERTAIN',
          FailMode.afterApplying,
        );
        await sync.save();
        expect(sync.phase, SyncPhase.uncertain);
        expect(evidence[e], isNotNull, reason: 'keep staging while unknown');

        expect(await sync.recover(), isFalse);
        expect(evidence[e], isNotNull);
        expect(sync.canSave, isFalse);
        await expectLater(sync.acceptRecoveredEvidence(), throwsStateError);
        expect(await sync.showRecoveredEvidence(), isNotEmpty);
        await sync.acceptRecoveredEvidence();
        expect(evidence[e], isNull);
        server.calls.clear();
        final SyncReport after = await sync.save();
        expect(after.uploaded, isEmpty);
        expect(server.evidenceRevisions, {e: 1});
      },
    );

    test(
      'an upload that did not happen is sent again only after recovery',
      () async {
        final String f = finding();
        final String e = await stagePhoto(f);
        server.failNext['uploadEvidence'] = (
          'EVIDENCE_SAVE_UNCERTAIN',
          FailMode.before,
        );
        await sync.save();
        await sync.recover();
        expect(evidence[e], isNotNull);
        final SyncReport after = await sync.save();
        expect(after.uploaded, [e]);
        expect(server.evidenceRevisions, {e: 1});
      },
    );
  });

  group('durable and concurrent recovery', () {
    test(
      'another device winning the unknown upload never discards this device photo',
      () async {
        final f = finding();
        final e = await stagePhoto(f);
        server.failNext['uploadEvidence'] = (
          'EVIDENCE_SAVE_UNCERTAIN',
          FailMode.before,
        );
        await sync.save();
        final local = sync.toLocalJson();
        final saved = server.serverCase;
        final catalog = await server.listEvidence(
          saved,
          currentCase: () => saved,
          currentCatalog: () => null,
        );
        final otherPixels = jpegHeader(width: 777, height: 555);
        await server.uploadEvidence(
          saved,
          catalog: catalog,
          evidenceId: e,
          expectedEvidenceRevision: 0,
          findingId: f,
          capturedAt: null,
          imageBytes: otherPixels,
          currentCase: () => saved,
          currentCatalog: () => catalog,
        );
        sync.dispose();
        sync = makeSync(saved)..restoreLocal(local);
        expect(await sync.recover(), isFalse);
        expect(evidence[e], isNotNull);
        expect(await sync.showRecoveredEvidence(), otherPixels);
        sync.keepLocalEvidence();
        expect(evidence[e], isNotNull);
        expect((await sync.save()).uploaded, [e]);
        expect(server.evidenceRevisions[e], 2);
      },
    );

    test('a failed durable journal prevents all remote writes', () async {
      finding();
      final guarded = AssessmentSync(
        gateway: server,
        controller: controller,
        evidence: evidence,
        staging: staging,
        savedCase: server.serverCase,
        beforeWrite: () async => throw StateError('disk full'),
      );
      addTearDown(guarded.dispose);
      expect((await guarded.save()).errorCode, 'LOCAL_SAVE_FAILED');
      expect(server.calls, isEmpty);
    });
  });

  test(
    'failed local adoption during recovery stays retryable and blocks writes',
    () async {
      var fail = true;
      final guarded = AssessmentSync(
        gateway: server,
        controller: controller,
        evidence: evidence,
        staging: staging,
        savedCase: server.serverCase,
        onCaseSaved: (_) async {
          if (fail) throw StateError('disk full');
        },
      );
      addTearDown(guarded.dispose);
      expect(await guarded.recover(), isFalse);
      expect(guarded.phase, SyncPhase.uncertain);
      expect(guarded.canSave, isFalse);
      fail = false;
      expect(await guarded.recover(), isTrue);
      expect(guarded.phase, SyncPhase.idle);
    },
  );

  group('other failures', () {
    test('a changed saved case asks for a reload', () async {
      finding();
      server.bumpCaseRevision();
      final SyncReport report = await sync.save();
      expect(report.errorCode, 'CASE_REVISION_MISMATCH');
      expect(sync.phase, SyncPhase.needsReload);
      expect(sync.canSave, isFalse);
      await sync.recover();
      expect(sync.savedCase.revision, 2);
      expect((await sync.save()).caseSaved, isTrue);
    });

    test('an ended session asks to sign in, with a local message', () async {
      finding();
      server.failNext['saveCase'] = ('UNAUTHENTICATED', FailMode.before);
      await sync.save();
      expect(sync.phase, SyncPhase.signInNeeded);
      expect(sync.errorMessage, 'Sign in before continuing.');
    });

    test(
      'other errors can be retried by the resident, never automatically',
      () async {
        finding();
        server.failNext['saveCase'] = ('SERVICE_UNAVAILABLE', FailMode.before);
        await sync.save();
        expect(sync.phase, SyncPhase.failed);
        expect(server.calls.where((c) => c == 'saveCase'), hasLength(1));
        expect(sync.canSave, isTrue);
        expect((await sync.save()).caseSaved, isTrue);
      },
    );
  });

  test('a save in flight is refused a second time', () async {
    finding();
    final hold = Completer<void>();
    server.holdNext['saveCase'] = hold;
    final Future<SyncReport> first = sync.save();
    await Future<void>.delayed(Duration.zero);
    expect(sync.phase, SyncPhase.working);
    expect((await sync.save()).errorCode, 'BUSY');
    hold.complete();
    expect((await first).caseSaved, isTrue);
  });

  test('a response arriving after reset is ignored', () async {
    finding();
    final hold = Completer<void>();
    server.holdNext['saveCase'] = hold;
    final Future<SyncReport> pending = sync.save();
    await Future<void>.delayed(Duration.zero);

    final CaseSnapshot other = _initialCase();
    sync.reset(other);
    hold.complete();
    final SyncReport report = await pending;

    expect(report.errorCode, 'STALE_RESPONSE');
    expect(sync.phase, SyncPhase.idle);
    expect(identical(sync.savedCase, other), isTrue);
    expect(adoptedRevisions, isEmpty);
  });
}
