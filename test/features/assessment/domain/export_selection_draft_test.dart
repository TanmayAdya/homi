import 'package:flutter_test/flutter_test.dart';

import 'package:safe_at_home/features/assessment/domain/export/export_selection_draft.dart';
import 'package:safe_at_home/shared/models/evidence.dart';

ExportCandidate _candidate(
  String id, {
  int revision = 1,
  String findingId = 'finding-1',
  int bytes = 1000,
  bool confirmed = true,
}) => ExportCandidate(
  evidenceId: id,
  evidenceRevision: revision,
  findingId: findingId,
  sanitizedByteLength: bytes,
  findingConfirmed: confirmed,
);

void main() {
  late ExportSelectionDraft draft;

  setUp(() => draft = ExportSelectionDraft());

  void loadReviewed(List<ExportCandidate> candidates) {
    draft.reconcile(candidates);
    for (final c in candidates) {
      draft.markReviewed(c.evidenceId, c.evidenceRevision);
    }
  }

  test('server limits match the documented values', () {
    expect(ExportSelectionLimits.server.maxImages, 6);
    expect(ExportSelectionLimits.server.maxAggregateBytes, 33554432);
  });

  test('an empty selection is valid', () {
    expect(draft.selection, isEmpty);
    expect(draft.aggregateBytes, 0);
  });

  test('a reviewed image of a confirmed finding can be added', () {
    loadReviewed([_candidate('evidence-1', revision: 3)]);
    expect(draft.add('evidence-1'), isNull);
    expect(draft.selection, [
      const SelectedEvidence(
        evidenceId: 'evidence-1',
        expectedEvidenceRevision: 3,
      ),
    ]);
  });

  group('rejections', () {
    test('unknown evidence', () {
      expect(draft.add('evidence-9'), SelectionRejection.unknownEvidence);
    });

    test('image not yet reviewed', () {
      draft.reconcile([_candidate('evidence-1')]);
      expect(draft.add('evidence-1'), SelectionRejection.notReviewed);
    });

    test('reviewing an old revision does not count', () {
      draft.reconcile([_candidate('evidence-1', revision: 2)]);
      expect(draft.markReviewed('evidence-1', 1), isFalse);
      expect(draft.add('evidence-1'), SelectionRejection.notReviewed);
    });

    test('finding not confirmed', () {
      loadReviewed([_candidate('evidence-1', confirmed: false)]);
      expect(draft.add('evidence-1'), SelectionRejection.findingNotConfirmed);
    });

    test('duplicate', () {
      loadReviewed([_candidate('evidence-1')]);
      draft.add('evidence-1');
      expect(draft.add('evidence-1'), SelectionRejection.alreadySelected);
    });

    test('seventh image', () {
      final List<ExportCandidate> candidates = [
        for (var i = 1; i <= 7; i++) _candidate('evidence-$i'),
      ];
      loadReviewed(candidates);
      for (var i = 1; i <= 6; i++) {
        expect(draft.add('evidence-$i'), isNull);
      }
      expect(draft.add('evidence-7'), SelectionRejection.imageLimitReached);
      expect(draft.selection, hasLength(6));
    });

    test('aggregate size over 32 MiB', () {
      const int mib = 1024 * 1024;
      loadReviewed([
        _candidate('evidence-1', bytes: 20 * mib),
        _candidate('evidence-2', bytes: 12 * mib),
        _candidate('evidence-3', bytes: 1),
      ]);
      expect(draft.add('evidence-1'), isNull);
      expect(
        draft.add('evidence-2'),
        isNull,
        reason: 'exactly 32 MiB is allowed',
      );
      expect(draft.add('evidence-3'), SelectionRejection.sizeLimitReached);
      expect(draft.aggregateBytes, 32 * mib);
    });
  });

  test('several images may belong to one finding', () {
    loadReviewed([_candidate('evidence-1'), _candidate('evidence-2')]);
    expect(draft.add('evidence-1'), isNull);
    expect(draft.add('evidence-2'), isNull);
  });

  group('reconcile', () {
    setUp(() {
      loadReviewed([
        _candidate('evidence-1'),
        _candidate('evidence-2', findingId: 'finding-2'),
        _candidate('evidence-3'),
      ]);
      draft
        ..add('evidence-1')
        ..add('evidence-2')
        ..add('evidence-3');
    });

    test('a replaced image is dropped and needs review again', () {
      final List<String> dropped = draft.reconcile([
        _candidate('evidence-1', revision: 2),
        _candidate('evidence-2', findingId: 'finding-2'),
        _candidate('evidence-3'),
      ]);
      expect(dropped, ['evidence-1']);
      expect(draft.isReviewed('evidence-1'), isFalse);
      expect(draft.add('evidence-1'), SelectionRejection.notReviewed);
    });

    test('a deleted image is dropped', () {
      final List<String> dropped = draft.reconcile([
        _candidate('evidence-2', findingId: 'finding-2'),
        _candidate('evidence-3'),
      ]);
      expect(dropped, ['evidence-1']);
    });

    test('an image whose finding is no longer confirmed is dropped', () {
      final List<String> dropped = draft.reconcile([
        _candidate('evidence-1'),
        _candidate('evidence-2', findingId: 'finding-2', confirmed: false),
        _candidate('evidence-3'),
      ]);
      expect(dropped, ['evidence-2']);
      expect(draft.selection.map((s) => s.evidenceId), [
        'evidence-1',
        'evidence-3',
      ]);
    });

    test('unchanged catalog drops nothing and keeps order', () {
      final List<String> dropped = draft.reconcile([
        _candidate('evidence-3'),
        _candidate('evidence-1'),
        _candidate('evidence-2', findingId: 'finding-2'),
      ]);
      expect(dropped, isEmpty);
      expect(draft.selection.map((s) => s.evidenceId), [
        'evidence-1',
        'evidence-2',
        'evidence-3',
      ]);
    });
  });

  test('order can be changed', () {
    loadReviewed([_candidate('a'), _candidate('b'), _candidate('c')]);
    draft
      ..add('a')
      ..add('b')
      ..add('c');
    draft.move(2, 0);
    expect(draft.selection.map((s) => s.evidenceId), ['c', 'a', 'b']);
    draft.move(0, 2);
    expect(draft.selection.map((s) => s.evidenceId), ['a', 'b', 'c']);
    expect(() => draft.move(0, 3), throwsRangeError);
  });

  test('removing keeps the review so the image can be re-added', () {
    loadReviewed([_candidate('evidence-1')]);
    draft.add('evidence-1');
    expect(draft.remove('evidence-1'), isTrue);
    expect(draft.remove('evidence-1'), isFalse);
    expect(draft.add('evidence-1'), isNull);
  });

  test('the exposed selection cannot be modified', () {
    expect(
      () => draft.selection.add(
        const SelectedEvidence(evidenceId: 'x', expectedEvidenceRevision: 1),
      ),
      throwsUnsupportedError,
    );
  });

  test('clear forgets everything', () {
    loadReviewed([_candidate('evidence-1')]);
    draft
      ..add('evidence-1')
      ..clear();
    expect(draft.selection, isEmpty);
    expect(draft.add('evidence-1'), SelectionRejection.unknownEvidence);
  });

  group('shared EvidenceSelection mapping', () {
    test('each entry carries reviewedForExport: true and its revision', () {
      const selected = SelectedEvidence(
        evidenceId: 'evidence-1',
        expectedEvidenceRevision: 3,
      );
      expect(selected.toEvidenceSelection().toJson(), {
        'evidenceId': 'evidence-1',
        'expectedEvidenceRevision': 3,
        'reviewedForExport': true,
      });
    });

    test('the draft maps its selection in export order', () {
      loadReviewed([
        _candidate('evidence-1'),
        _candidate('evidence-2', revision: 4),
      ]);
      draft
        ..add('evidence-1')
        ..add('evidence-2')
        ..move(1, 0);
      final List<EvidenceSelection> mapped = draft.toEvidenceSelections();
      expect(mapped.map((e) => e.evidenceId), ['evidence-2', 'evidence-1']);
      expect(mapped.map((e) => e.expectedEvidenceRevision), [4, 1]);
      expect(mapped.every((e) => e.reviewedForExport), isTrue);
    });

    test('an empty selection maps to an empty list', () {
      expect(draft.toEvidenceSelections(), isEmpty);
    });

    test('values outside the shared bounds are rejected', () {
      for (final SelectedEvidence bad in const [
        SelectedEvidence(evidenceId: '', expectedEvidenceRevision: 1),
        SelectedEvidence(
          evidenceId: ' evidence-1',
          expectedEvidenceRevision: 1,
        ),
        SelectedEvidence(evidenceId: 'evidence-1', expectedEvidenceRevision: 0),
      ]) {
        expect(bad.toEvidenceSelection, throwsFormatException);
      }
    });
  });
}
