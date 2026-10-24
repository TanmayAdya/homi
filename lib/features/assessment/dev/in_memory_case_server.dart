import 'dart:async';

import '../../../shared/models/case_draft.dart';
import '../../../shared/models/contracts.dart';
import '../../../shared/models/evidence.dart';
import '../../../shared/models/evidence_mutation.dart';
import '../../../shared/services/matching_api_client.dart';
import '../application/case_evidence_gateway.dart';

enum FailMode { before, afterApplying }

class InMemoryCaseServer implements CaseEvidenceGateway {
  InMemoryCaseServer(CaseSnapshot initial) : _case = initial;

  CaseSnapshot _case;
  int _catalogRevision = 0;
  final Map<String, _Stored> _evidence = {};
  final Set<String> _tombstones = {};
  final List<String> calls = [];

  final Map<String, (String, FailMode)> failNext = {};

  final Map<String, Completer<void>> holdNext = {};

  CaseSnapshot get serverCase => _case;
  int get catalogRevision => _catalogRevision;
  Map<String, int> get evidenceRevisions => {
    for (final e in _evidence.entries) e.key: e.value.revision,
  };
  Map<String, List<int>> get evidenceBytes => {
    for (final e in _evidence.entries) e.key: e.value.bytes,
  };

  @override
  Future<CaseSnapshot> saveCase(
    CaseSnapshot saved, {
    required CaseDraft replacement,
    required CaseSnapshot Function() currentCase,
    required CaseDraft Function() currentDraft,
  }) async {
    await _enter('saveCase');
    if (saved.revision != _case.revision) _throw('CASE_REVISION_MISMATCH');
    final Set<String> newLinks = {
      for (final f in replacement.findings)
        for (final id in f.evidenceIds) '${f.id}/$id',
    };
    for (final e in _evidence.entries) {
      if (!newLinks.contains('${e.value.findingId}/${e.key}')) {
        _throw('EVIDENCE_CONFLICT');
      }
    }
    return _apply('saveCase', () {
      _case = replacement.atRevision(_case.revision + 1);
      return _case;
    }, () => currentCase());
  }

  @override
  Future<CaseSnapshot> reloadCase(
    String caseId, {
    required String Function() currentCaseId,
    required CaseSnapshot? Function() currentCase,
  }) async {
    await _enter('reloadCase');
    _guard(() => currentCaseId());
    return _case;
  }

  @override
  Future<EvidenceCatalog> listEvidence(
    CaseSnapshot snapshot, {
    required CaseSnapshot Function() currentCase,
    required EvidenceCatalog? Function() currentCatalog,
  }) async {
    await _enter('listEvidence');
    if (snapshot.revision != _case.revision) _throw('CASE_REVISION_MISMATCH');
    _guard(() => currentCase());
    return _catalog();
  }

  @override
  Future<EvidenceUploadResponse> uploadEvidence(
    CaseSnapshot snapshot, {
    required EvidenceCatalog catalog,
    required String evidenceId,
    required int expectedEvidenceRevision,
    required String findingId,
    required String? capturedAt,
    required List<int> imageBytes,
    required CaseSnapshot Function() currentCase,
    required EvidenceCatalog Function() currentCatalog,
  }) async {
    await _enter('uploadEvidence:$evidenceId');
    if (snapshot.revision != _case.revision ||
        catalog.catalogRevision != _catalogRevision) {
      _throw('EVIDENCE_CONFLICT');
    }
    if (!_case.findings.any(
      (f) => f.id == findingId && f.evidenceIds.contains(evidenceId),
    )) {
      _throw('EVIDENCE_CONFLICT');
    }
    if (_tombstones.contains(evidenceId)) _throw('EVIDENCE_CONFLICT');
    final int current = _evidence[evidenceId]?.revision ?? 0;
    if (current != expectedEvidenceRevision) _throw('EVIDENCE_CONFLICT');
    return _apply('uploadEvidence', () {
      _catalogRevision++;
      _evidence[evidenceId] = _Stored(findingId, current + 1, imageBytes);
      return EvidenceUploadResponse.fromJson({
        'schemaVersion': '1',
        'caseId': _case.caseId,
        'caseRevision': _case.revision,
        'catalogRevision': _catalogRevision,
        'evidence': _descriptor(evidenceId).toJson(),
      });
    }, () => currentCatalog());
  }

  @override
  Future<EvidenceDeleteResponse> deleteEvidence(
    CaseSnapshot snapshot, {
    required EvidenceCatalog catalog,
    required EvidenceDescriptor evidence,
    required CaseSnapshot Function() currentCase,
    required EvidenceCatalog Function() currentCatalog,
  }) async {
    await _enter('deleteEvidence:${evidence.evidenceId}');
    final _Stored? stored = _evidence[evidence.evidenceId];
    if (stored == null ||
        stored.revision != evidence.evidenceRevision ||
        catalog.catalogRevision != _catalogRevision) {
      _throw('EVIDENCE_CONFLICT');
    }
    return _apply('deleteEvidence', () {
      _catalogRevision++;
      _evidence.remove(evidence.evidenceId);
      _tombstones.add(evidence.evidenceId);
      return EvidenceDeleteResponse.fromJson({
        'schemaVersion': '1',
        'caseId': _case.caseId,
        'caseRevision': _case.revision,
        'catalogRevision': _catalogRevision,
        'evidenceId': evidence.evidenceId,
        'evidenceRevision': stored.revision + 1,
        'deleted': true,
      });
    }, () => currentCatalog());
  }

  @override
  Future<List<int>> downloadEvidence(
    CaseSnapshot snapshot, {
    required EvidenceCatalog catalog,
    required EvidenceDescriptor evidence,
    required CaseSnapshot Function() currentCase,
    required EvidenceCatalog Function() currentCatalog,
  }) async {
    await _enter('downloadEvidence:${evidence.evidenceId}');
    final _Stored? stored = _evidence[evidence.evidenceId];
    if (stored == null || stored.revision != evidence.evidenceRevision) {
      _throw('ARTIFACT_NOT_FOUND');
    }
    _guard(() => currentCatalog());
    return List.unmodifiable(stored.bytes);
  }

  void bumpCaseRevision() => _case = CaseSnapshot.fromJson(
    _case.toJson()..['revision'] = _case.revision + 1,
  );

  EvidenceCatalog _catalog() => EvidenceCatalog.fromJson({
    'schemaVersion': '1',
    'caseId': _case.caseId,
    'caseRevision': _case.revision,
    'catalogRevision': _catalogRevision,
    'evidence': [for (final id in _evidence.keys) _descriptor(id).toJson()],
  });

  EvidenceDescriptor _descriptor(String id) {
    final _Stored s = _evidence[id]!;
    return EvidenceDescriptor.fromJson({
      'evidenceId': id,
      'evidenceRevision': s.revision,
      'caseId': _case.caseId,
      'findingId': s.findingId,
      'mediaType': 'image/png',
      'byteLength': s.bytes.isEmpty ? 1 : s.bytes.length,
      'sha256': ''.padLeft(64, '${s.revision % 10}'),
      'width': 1200,
      'height': 900,
      'capturedAt': null,
      'preparedAt': '2026-10-18T09:00:00Z',
      'processingVersion': 'evidence-png-v1',
    });
  }

  Future<void> _enter(String name) async {
    calls.add(name);
    final Completer<void>? hold = holdNext.remove(name.split(':').first);
    if (hold != null) await hold.future;
  }

  T _apply<T>(String op, T Function() write, void Function() guard) {
    final (String, FailMode)? fail = failNext.remove(op);
    if (fail != null && fail.$2 == FailMode.before) _throw(fail.$1);
    final T result = write();
    if (fail != null) _throw(fail.$1);
    _guard(guard);
    return result;
  }

  void _guard(void Function() check) {
    try {
      check();
    } catch (_) {
      _throw('STALE_RESPONSE');
    }
  }

  Never _throw(String code) => throw MatchingApiException.forCode(code);
}

class _Stored {
  _Stored(this.findingId, this.revision, this.bytes);
  final String findingId;
  final int revision;
  final List<int> bytes;
}
