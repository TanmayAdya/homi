import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/features/assessment/application/assessment_controller.dart';
import 'package:safe_at_home/features/assessment/application/assessment_sync.dart';
import 'package:safe_at_home/features/assessment/application/export_review.dart';
import 'package:safe_at_home/features/assessment/application/local_evidence_index.dart';
import 'package:safe_at_home/features/assessment/domain/capture/capture_adapter.dart';
import 'package:safe_at_home/features/assessment/domain/capture/staging_store.dart';
import 'package:safe_at_home/features/assessment/domain/export/export_selection_draft.dart';
import 'package:safe_at_home/features/assessment/domain/image/image_validator.dart';
import 'package:safe_at_home/shared/models/contracts.dart';
import 'package:safe_at_home/shared/models/evidence.dart';

import '../fakes/fake_case_server.dart';
import '../fakes/fakes.dart';
import '../fakes/image_bytes.dart';

class Fixture {
  Fixture._(
    this.server,
    this.controller,
    this.staging,
    this.evidence,
    this.sync,
  );

  static Future<Fixture> create() async {
    final server = FakeCaseServer(
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
        'findings': <Object>[],
      }),
    );
    final controller = AssessmentController(ids: SequentialIdFactory());
    final staging = InMemoryStagingStore();
    final evidence = LocalEvidenceIndex();
    final sync = AssessmentSync(
      gateway: server,
      controller: controller,
      evidence: evidence,
      staging: staging,
      savedCase: server.serverCase,
    );
    return Fixture._(server, controller, staging, evidence, sync);
  }

  final FakeCaseServer server;
  final AssessmentController controller;
  final InMemoryStagingStore staging;
  final LocalEvidenceIndex evidence;
  final AssessmentSync sync;

  Future<String> photo(String findingId) async {
    final Uint8List bytes = jpegHeader(width: 1200, height: 900);
    final StagedImage image = await staging.put(
      bytes,
      ImageAccepted(
        format: SupportedImageFormat.jpeg,
        width: 1200,
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

  Future<({String confirmed, String unconfirmed, List<String> photos})>
  seed() async {
    final String a = controller.startFinding(AssessmentArea.entrance);
    controller.setObservation(a, 'I notice a raised threshold.');
    final String p1 = await photo(a);
    final String p2 = await photo(a);
    controller.confirm(a);
    final String b = controller.startFinding(AssessmentArea.bathroom);
    controller.setObservation(b, 'I notice a raised tub edge.');
    final String p3 = await photo(b);
    await sync.save();
    return (confirmed: a, unconfirmed: b, photos: [p1, p2, p3]);
  }
}

void main() {
  late Fixture fx;
  late ExportReview review;
  late List<String> photos;

  setUp(() async {
    fx = await Fixture.create();
    photos = (await fx.seed()).photos;
    review = ExportReview(
      gateway: fx.server,
      currentCase: () => fx.sync.savedCase,
    );
    await review.load();
  });

  test('candidates come from the catalog and the saved review state', () {
    expect(review.candidates.map((c) => (c.evidenceId, c.findingConfirmed)), [
      (photos[0], true),
      (photos[1], true),
      (photos[2], false),
    ]);
  });

  test('a photo must be shown before it can be checked', () async {
    expect(review.markChecked(photos[0]), isFalse);
    expect(review.include(photos[0]), SelectionRejection.notReviewed);

    await review.showPhoto(photos[0]);
    expect(review.pixelsFor(photos[0]), isNotNull);
    expect(review.markChecked(photos[0]), isTrue);
    expect(review.include(photos[0]), isNull);

    final List<EvidenceSelection> s = review.selections;
    expect(s.single.evidenceId, photos[0]);
    expect(s.single.expectedEvidenceRevision, 1);
    expect(s.single.reviewedForExport, isTrue);
  });

  test('photos of unconfirmed findings cannot be included', () async {
    await review.showPhoto(photos[2]);
    review.markChecked(photos[2]);
    expect(review.include(photos[2]), SelectionRejection.findingNotConfirmed);
  });

  test('a replaced photo drops out and must be checked again', () async {
    await review.showPhoto(photos[0]);
    review.markChecked(photos[0]);
    review.include(photos[0]);

    final Uint8List bytes = jpegHeader(width: 800, height: 600);
    final StagedImage image = await fx.staging.put(
      bytes,
      ImageAccepted(
        format: SupportedImageFormat.jpeg,
        width: 800,
        height: 600,
        byteLength: bytes.length,
      ),
    );
    final String finding = fx.controller.drafts.first.id;
    fx.controller.replaceEvidence(
      finding,
      photos[0],
      version: localEvidenceVersion(image.key),
    );
    fx.evidence.put(photos[0], image);
    fx.controller.confirm(finding);
    await fx.sync.save();

    await review.load();
    expect(review.lastDropped, [photos[0]]);
    expect(review.selections, isEmpty);
    expect(review.pixelsFor(photos[0]), isNull);
    expect(review.draft.isReviewed(photos[0]), isFalse);
  });

  test('a case change makes the list stale until reloaded', () async {
    final String finding = fx.controller.drafts.first.id;
    fx.controller.setObservation(finding, 'Changed text.');
    await fx.sync.save();
    expect(review.isStale, isTrue);
    expect(review.candidates, isEmpty);
    await review.load();
    expect(review.isStale, isFalse);
  });

  test('clear forgets photos and the selection', () async {
    await review.showPhoto(photos[0]);
    review.markChecked(photos[0]);
    review.include(photos[0]);
    review.clear();
    expect(review.catalog, isNull);
    expect(review.selections, isEmpty);
    expect(review.pixelsFor(photos[0]), isNull);
  });
}
