import '../../../../shared/models/contracts.dart';
import '../../../../shared/models/evidence.dart';

final class ExportCandidate {
  const ExportCandidate({
    required this.evidenceId,
    required this.evidenceRevision,
    required this.findingId,
    required this.sanitizedByteLength,
    required this.findingConfirmed,
  });

  final String evidenceId;

  final int evidenceRevision;

  final String findingId;

  final int sanitizedByteLength;

  final bool findingConfirmed;

  static List<ExportCandidate> fromCatalog(
    EvidenceCatalog catalog,
    CaseSnapshot saved,
  ) {
    if (catalog.caseId != saved.caseId ||
        catalog.caseRevision != saved.revision) {
      return const [];
    }
    return [
      for (final EvidenceDescriptor item in catalog.evidence)
        ExportCandidate(
          evidenceId: item.evidenceId,
          evidenceRevision: item.evidenceRevision,
          findingId: item.findingId,
          sanitizedByteLength: item.byteLength,
          findingConfirmed: saved.findings.any(
            (f) =>
                f.id == item.findingId &&
                f.reviewState == 'confirmed' &&
                f.evidenceIds.contains(item.evidenceId),
          ),
        ),
    ];
  }
}

final class SelectedEvidence {
  const SelectedEvidence({
    required this.evidenceId,
    required this.expectedEvidenceRevision,
  });
  final String evidenceId;
  final int expectedEvidenceRevision;

  EvidenceSelection toEvidenceSelection() => EvidenceSelection.fromJson({
    'evidenceId': evidenceId,
    'expectedEvidenceRevision': expectedEvidenceRevision,
    'reviewedForExport': true,
  });

  @override
  bool operator ==(Object other) =>
      other is SelectedEvidence &&
      other.evidenceId == evidenceId &&
      other.expectedEvidenceRevision == expectedEvidenceRevision;

  @override
  int get hashCode => Object.hash(evidenceId, expectedEvidenceRevision);
}

final class ExportSelectionLimits {
  const ExportSelectionLimits({
    required this.maxImages,
    required this.maxAggregateBytes,
  });

  static const ExportSelectionLimits server = ExportSelectionLimits(
    maxImages: 6,
    maxAggregateBytes: 32 * 1024 * 1024,
  );

  final int maxImages;
  final int maxAggregateBytes;
}

enum SelectionRejection {
  unknownEvidence,

  findingNotConfirmed,

  notReviewed,

  alreadySelected,

  imageLimitReached,

  sizeLimitReached,
}

class ExportSelectionDraft {
  ExportSelectionDraft({this.limits = ExportSelectionLimits.server});

  final ExportSelectionLimits limits;

  final Map<String, ExportCandidate> _candidates = {};
  final Map<String, int> _reviewedRevisions = {};
  final List<SelectedEvidence> _selection = [];

  List<SelectedEvidence> get selection => List.unmodifiable(_selection);

  List<EvidenceSelection> toEvidenceSelections() => EvidenceSelection.parseList(
    _selection.map((s) => s.toEvidenceSelection().toJson()).toList(),
  );

  int get aggregateBytes => _selection.fold(
    0,
    (sum, s) => sum + (_candidates[s.evidenceId]?.sanitizedByteLength ?? 0),
  );

  bool isReviewed(String evidenceId) {
    final ExportCandidate? candidate = _candidates[evidenceId];
    return candidate != null &&
        _reviewedRevisions[evidenceId] == candidate.evidenceRevision;
  }

  List<String> reconcile(Iterable<ExportCandidate> candidates) {
    _candidates
      ..clear()
      ..addEntries(candidates.map((c) => MapEntry(c.evidenceId, c)));

    _reviewedRevisions.removeWhere(
      (id, revision) => _candidates[id]?.evidenceRevision != revision,
    );

    final dropped = <String>[];
    _selection.removeWhere((s) {
      final ExportCandidate? candidate = _candidates[s.evidenceId];
      final bool stale =
          candidate == null ||
          candidate.evidenceRevision != s.expectedEvidenceRevision ||
          !candidate.findingConfirmed;
      if (stale) dropped.add(s.evidenceId);
      return stale;
    });
    return dropped;
  }

  bool markReviewed(String evidenceId, int revision) {
    if (_candidates[evidenceId]?.evidenceRevision != revision) return false;
    _reviewedRevisions[evidenceId] = revision;
    return true;
  }

  SelectionRejection? add(String evidenceId) {
    final ExportCandidate? candidate = _candidates[evidenceId];
    if (candidate == null) return SelectionRejection.unknownEvidence;
    if (!candidate.findingConfirmed) {
      return SelectionRejection.findingNotConfirmed;
    }
    if (!isReviewed(evidenceId)) return SelectionRejection.notReviewed;
    if (_selection.any((s) => s.evidenceId == evidenceId)) {
      return SelectionRejection.alreadySelected;
    }
    if (_selection.length >= limits.maxImages) {
      return SelectionRejection.imageLimitReached;
    }
    if (aggregateBytes + candidate.sanitizedByteLength >
        limits.maxAggregateBytes) {
      return SelectionRejection.sizeLimitReached;
    }
    _selection.add(
      SelectedEvidence(
        evidenceId: evidenceId,
        expectedEvidenceRevision: candidate.evidenceRevision,
      ),
    );
    return null;
  }

  bool remove(String evidenceId) {
    final int before = _selection.length;
    _selection.removeWhere((s) => s.evidenceId == evidenceId);
    return _selection.length != before;
  }

  void move(int from, int to) {
    RangeError.checkValidIndex(from, _selection, 'from');
    RangeError.checkValidIndex(to, _selection, 'to');
    final SelectedEvidence entry = _selection.removeAt(from);
    _selection.insert(to, entry);
  }

  void clear() {
    _candidates.clear();
    _reviewedRevisions.clear();
    _selection.clear();
  }
}
