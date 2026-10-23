import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../../shared/models/case_draft.dart';
import '../../../shared/models/contracts.dart';
import '../../../shared/models/evidence.dart';
import '../../../shared/services/matching_api_client.dart';
import '../domain/capture/staging_store.dart';
import 'assessment_controller.dart';
import 'case_evidence_gateway.dart';
import 'local_evidence_index.dart';

enum SyncPhase { idle, working, uncertain, needsReload, signInNeeded, failed }

final class SyncReport {
  const SyncReport({
    this.caseSaved = false,
    this.uploaded = const [],
    this.deleted = const [],
    this.skippedIncomplete = const [],
    this.errorCode,
  });

  final bool caseSaved;
  final List<String> uploaded;
  final List<String> deleted;

  final List<String> skippedIncomplete;

  final String? errorCode;
}

class AssessmentSync extends ChangeNotifier {
  AssessmentSync({
    required CaseEvidenceGateway gateway,
    required AssessmentController controller,
    required LocalEvidenceIndex evidence,
    required StagingStore staging,
    required CaseSnapshot savedCase,
    this.onCaseSaved,
  }) : _gateway = gateway,
       _controller = controller,
       _evidence = evidence,
       _staging = staging,
       _saved = savedCase {
    _controller.addListener(notifyListeners);
  }

  final CaseEvidenceGateway _gateway;
  final AssessmentController _controller;
  final LocalEvidenceIndex _evidence;
  final StagingStore _staging;

  final void Function(CaseSnapshot saved)? onCaseSaved;

  CaseSnapshot _saved;
  EvidenceCatalog? _catalog;
  SyncPhase _phase = SyncPhase.idle;
  String? _errorCode;
  String? _errorMessage;
  int _generation = 0;

  final Map<String, String> _uploadedVersion = {};

  ({String evidenceId, String version, int expected})? _pendingUpload;

  CaseSnapshot get savedCase => _saved;
  EvidenceCatalog? get catalog => _catalog;
  SyncPhase get phase => _phase;
  String? get errorCode => _errorCode;

  String? get errorMessage => _errorMessage;

  bool get canSave => _phase == SyncPhase.idle || _phase == SyncPhase.failed;

  bool get hasUnsavedWork =>
      _replacementJson() != _findingsJson(_saved.findings) ||
      _pendingUploads().isNotEmpty;

  bool isSaved(String findingId) {
    final Finding? local = _controller.toFinding(findingId);
    if (local == null) return false;
    final Finding? saved = _saved.findings
        .where((f) => f.id == findingId)
        .firstOrNull;
    if (saved == null ||
        jsonEncode(saved.toJson()) != jsonEncode(local.toJson())) {
      return false;
    }
    return _pendingUploads().every((u) => u.findingId != findingId);
  }

  Future<SyncReport> save() async {
    if (!canSave) {
      return SyncReport(errorCode: _errorCode ?? 'BUSY');
    }
    final int gen = _generation;
    _setPhase(SyncPhase.working);
    final deleted = <String>[];
    final uploaded = <String>[];
    var caseSaved = false;
    final List<String> skipped = _controller.incompleteFindingIds;

    try {
      await _ensureCatalog(gen);
      final Map<String, String> keptLinks = _replacementLinks();
      for (final EvidenceDescriptor item in List.of(_catalog!.evidence)) {
        if (keptLinks[item.evidenceId] == item.findingId) continue;
        await _gateway.deleteEvidence(
          _saved,
          catalog: _catalog!,
          evidence: item,
          currentCase: () => _live(gen, _saved),
          currentCatalog: () => _live(gen, _catalog!),
        );
        _check(gen);
        _uploadedVersion.remove(item.evidenceId);
        deleted.add(item.evidenceId);
        await _relistCatalog(gen);
      }

      if (_replacementJson() != _findingsJson(_saved.findings)) {
        final CaseDraft draft;
        try {
          draft = _replacementDraft();
        } on FormatException {
          return _fail(gen, 'CASE_TOO_LARGE_OR_INVALID', deleted: deleted);
        }
        final CaseSnapshot result = await _gateway.saveCase(
          _saved,
          replacement: draft,
          currentCase: () => _live(gen, _saved),
          currentDraft: () => _live(gen, draft),
        );
        _check(gen);
        _adopt(result);
        caseSaved = true;
        await _relistCatalog(gen);
      }

      for (final pending in _pendingUploads()) {
        final StagedImage? staged = _evidence[pending.evidenceId];
        if (staged == null) continue;
        final bytes = await _staging.read(staged.key);
        _check(gen);
        if (bytes == null) continue;
        final EvidenceDescriptor? existing = _catalog!.evidence
            .where((e) => e.evidenceId == pending.evidenceId)
            .firstOrNull;
        final int expected = existing?.evidenceRevision ?? 0;
        _pendingUpload = (
          evidenceId: pending.evidenceId,
          version: pending.version,
          expected: expected,
        );
        await _gateway.uploadEvidence(
          _saved,
          catalog: _catalog!,
          evidenceId: pending.evidenceId,
          expectedEvidenceRevision: expected,
          findingId: pending.findingId,
          capturedAt: null,
          imageBytes: bytes,
          currentCase: () => _live(gen, _saved),
          currentCatalog: () => _live(gen, _catalog!),
        );
        _check(gen);
        _pendingUpload = null;
        await _markUploaded(pending.evidenceId, pending.version);
        uploaded.add(pending.evidenceId);
        await _relistCatalog(gen);
      }
    } on _Superseded {
      return const SyncReport(errorCode: 'STALE_RESPONSE');
    } on MatchingApiException catch (e) {
      return _fail(
        gen,
        e.code,
        message: e.message,
        caseSaved: caseSaved,
        uploaded: uploaded,
        deleted: deleted,
      );
    }

    _errorCode = null;
    _errorMessage = null;
    _setPhase(SyncPhase.idle);
    return SyncReport(
      caseSaved: caseSaved,
      uploaded: uploaded,
      deleted: deleted,
      skippedIncomplete: skipped,
    );
  }

  Future<bool> recover() async {
    if (_phase == SyncPhase.working) return false;
    final int gen = _generation;
    _setPhase(SyncPhase.working);
    try {
      final CaseSnapshot reloaded = await _gateway.reloadCase(
        _saved.caseId,
        currentCaseId: () => _live(gen, _saved.caseId),
        currentCase: () => _live(gen, _saved),
      );
      _check(gen);
      _adopt(reloaded);
      _catalog = null;
      await _ensureCatalog(gen);

      final pending = _pendingUpload;
      if (pending != null) {
        final EvidenceDescriptor? item = _catalog!.evidence
            .where((e) => e.evidenceId == pending.evidenceId)
            .firstOrNull;
        if (item != null && item.evidenceRevision == pending.expected + 1) {
          await _markUploaded(pending.evidenceId, pending.version);
        }
        _pendingUpload = null;
      }
    } on _Superseded {
      return false;
    } on MatchingApiException catch (e) {
      _fail(gen, e.code, message: e.message);
      return false;
    }
    _errorCode = null;
    _errorMessage = null;
    _setPhase(SyncPhase.idle);
    return true;
  }

  void reset(CaseSnapshot savedCase) {
    _generation++;
    _saved = savedCase;
    _catalog = null;
    _uploadedVersion.clear();
    _pendingUpload = null;
    _errorCode = null;
    _errorMessage = null;
    _setPhase(SyncPhase.idle);
  }

  @override
  void dispose() {
    _generation++;
    _controller.removeListener(notifyListeners);
    super.dispose();
  }

  List<({String findingId, String evidenceId, String version})>
  _pendingUploads() => [
    for (final FindingDraft draft in _controller.drafts)
      if (_controller.toFinding(draft.id) != null)
        for (final e in draft.evidence)
          if (_evidence[e.evidenceId] != null &&
              _uploadedVersion[e.evidenceId] != e.version)
            (findingId: draft.id, evidenceId: e.evidenceId, version: e.version),
  ];

  List<Finding> _replacementFindings() {
    final Map<String, Finding> local = {
      for (final Finding f in _controller.findings) f.id: f,
    };
    final Set<String> removed = _controller.removedFindingIds;
    final Set<String> incomplete = _controller.incompleteFindingIds.toSet();
    final List<Finding> result = [];
    for (final Finding saved in _saved.findings) {
      if (removed.contains(saved.id)) continue;
      result.add(
        incomplete.contains(saved.id) ? saved : local[saved.id] ?? saved,
      );
      local.remove(saved.id);
    }
    result.addAll(local.values);
    return result;
  }

  Map<String, String> _replacementLinks() => {
    for (final Finding f in _replacementFindings())
      for (final String id in f.evidenceIds) id: f.id,
  };

  String _replacementJson() => _findingsJson(_replacementFindings());

  static String _findingsJson(List<Finding> findings) =>
      jsonEncode([for (final Finding f in findings) f.toJson()]);

  CaseDraft _replacementDraft() {
    final Map<String, Object?> json = _saved.toJson()..remove('revision');
    json['findings'] = [for (final f in _replacementFindings()) f.toJson()];
    return CaseDraft.fromJson(json);
  }

  Future<void> _ensureCatalog(int gen) async {
    if (_catalog != null && _catalog!.belongsTo(_saved)) return;
    await _relistCatalog(gen);
  }

  Future<void> _relistCatalog(int gen) async {
    final EvidenceCatalog? previous = _catalog?.caseRevision == _saved.revision
        ? _catalog
        : null;
    final EvidenceCatalog result = await _gateway.listEvidence(
      _saved,
      currentCase: () => _live(gen, _saved),
      currentCatalog: () => _live(gen, previous),
    );
    _check(gen);
    _catalog = result;
  }

  Future<void> _markUploaded(String evidenceId, String version) async {
    _uploadedVersion[evidenceId] = version;
    final StagedImage? staged = _evidence[evidenceId];
    if (staged != null && localEvidenceVersion(staged.key) == version) {
      _evidence.remove(evidenceId);
      try {
        await _staging.discard(staged.key);
      } catch (_) {
        // ignore: empty_catches
      }
    }
  }

  void _adopt(CaseSnapshot saved) {
    _saved = saved;
    onCaseSaved?.call(saved);
  }

  SyncReport _fail(
    int gen,
    String code, {
    String? message,
    bool caseSaved = false,
    List<String> uploaded = const [],
    List<String> deleted = const [],
  }) {
    if (gen != _generation) return SyncReport(errorCode: code);
    _errorCode = code;
    _errorMessage = message;
    _setPhase(switch (code) {
      'CASE_SAVE_UNCERTAIN' || 'EVIDENCE_SAVE_UNCERTAIN' => SyncPhase.uncertain,
      'UNAUTHENTICATED' => SyncPhase.signInNeeded,
      'CASE_REVISION_MISMATCH' ||
      'EVIDENCE_CONFLICT' ||
      'STALE_RESPONSE' ||
      'CASE_NOT_FOUND' => SyncPhase.needsReload,
      _ => SyncPhase.failed,
    });
    return SyncReport(
      caseSaved: caseSaved,
      uploaded: uploaded,
      deleted: deleted,
      errorCode: code,
    );
  }

  T _live<T>(int gen, T value) {
    if (gen != _generation) throw const _Superseded();
    return value;
  }

  void _check(int gen) {
    if (gen != _generation) throw const _Superseded();
  }

  void _setPhase(SyncPhase phase) {
    _phase = phase;
    notifyListeners();
  }
}

final class _Superseded implements Exception {
  const _Superseded();
}
