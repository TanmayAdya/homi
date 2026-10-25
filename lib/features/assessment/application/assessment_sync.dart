import 'dart:convert';
import 'dart:async';

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
    this.beforeWrite,
    this.metadataNeedsSave,
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

  final FutureOr<void> Function(CaseSnapshot saved)? onCaseSaved;

  final Future<void> Function()? beforeWrite;
  final bool Function()? metadataNeedsSave;

  CaseSnapshot _saved;
  EvidenceCatalog? _catalog;
  SyncPhase _phase = SyncPhase.idle;
  String? _errorCode;
  String? _errorMessage;
  int _generation = 0;

  final Map<String, String> _uploadedVersion = {};

  ({String evidenceId, String version, int expected})? _pendingUpload;
  EvidenceDescriptor? _recoveryConflict;
  int? _shownConflictRevision;
  EvidenceDescriptor? get recoveryConflict => _recoveryConflict;

  CaseSnapshot get savedCase => _saved;
  List<Finding> get replacementFindings => _replacementFindings();
  EvidenceCatalog? get catalog => _catalog;
  SyncPhase get phase => _phase;
  String? get errorCode => _errorCode;

  String? get errorMessage => _errorMessage;

  bool get canSave => _phase == SyncPhase.idle || _phase == SyncPhase.failed;

  bool get hasUnsavedWork =>
      _replacementJson() != _findingsJson(_saved.findings) ||
      _pendingUploads().isNotEmpty ||
      (metadataNeedsSave?.call() ?? false);

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
      await beforeWrite?.call();
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

      if (_replacementJson() != _findingsJson(_saved.findings) ||
          (metadataNeedsSave?.call() ?? false)) {
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
        await _adopt(result);
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
        notifyListeners();
        await beforeWrite?.call();
        await _gateway.uploadEvidence(
          _saved,
          catalog: _catalog!,
          evidenceId: pending.evidenceId,
          expectedEvidenceRevision: expected,
          findingId: pending.findingId,
          capturedAt: staged.capturedAt,
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
    } catch (_) {
      return _fail(
        gen,
        'LOCAL_SAVE_FAILED',
        message: 'The private local save could not finish.',
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
      await _adopt(reloaded);
      _catalog = null;
      await _ensureCatalog(gen);

      final pending = _pendingUpload;
      if (pending != null) {
        final EvidenceDescriptor? item = _catalog!.evidence
            .where((e) => e.evidenceId == pending.evidenceId)
            .firstOrNull;
        if (item != null && item.evidenceRevision > pending.expected) {
          _recoveryConflict = item;
          _shownConflictRevision = null;
          _errorCode = 'EVIDENCE_REVIEW_REQUIRED';
          _errorMessage =
              'A photo is saved, but we cannot prove it is your upload. Review it before choosing which version to keep.';
          _setPhase(SyncPhase.needsReload);
          return false;
        }
        _pendingUpload = null;
      }
    } on _Superseded {
      return false;
    } on MatchingApiException catch (e) {
      _fail(gen, e.code, message: e.message);
      return false;
    } catch (_) {
      _errorCode = 'LOCAL_SAVE_FAILED';
      _errorMessage =
          'The saved state could not be recorded privately on this device. Free device space, then check again.';
      _setPhase(SyncPhase.uncertain);
      return false;
    }
    _errorCode = null;
    _errorMessage = null;
    _setPhase(SyncPhase.idle);
    return true;
  }

  Future<Uint8List?> showRecoveredEvidence() async {
    final conflict = _recoveryConflict;
    final catalog = _catalog;
    if (conflict == null || catalog == null) return null;
    final gen = _generation;
    final bytes = await _gateway.downloadEvidence(
      _saved,
      catalog: catalog,
      evidence: conflict,
      currentCase: () => _live(gen, _saved),
      currentCatalog: () => _live(gen, _catalog!),
    );
    _check(gen);
    _shownConflictRevision = conflict.evidenceRevision;
    return Uint8List.fromList(bytes);
  }

  Future<void> acceptRecoveredEvidence() async {
    final conflict = _recoveryConflict;
    final pending = _pendingUpload;
    if (conflict == null ||
        pending == null ||
        _shownConflictRevision != conflict.evidenceRevision) {
      throw StateError('Review the saved photo first');
    }
    await _markUploaded(pending.evidenceId, pending.version);
    final draft = _controller.draftOf(conflict.findingId);
    if (draft?.evidence.any((e) => e.evidenceId == conflict.evidenceId) ??
        false) {
      _controller.replaceEvidence(
        conflict.findingId,
        conflict.evidenceId,
        version: 'server:${conflict.evidenceRevision}:${conflict.sha256}',
      );
    }
    _finishRecoveryChoice();
  }

  void keepLocalEvidence() {
    if (_recoveryConflict == null) return;
    _finishRecoveryChoice();
  }

  void _finishRecoveryChoice() {
    _pendingUpload = null;
    _recoveryConflict = null;
    _shownConflictRevision = null;
    _errorCode = null;
    _errorMessage = null;
    _setPhase(SyncPhase.idle);
  }

  Map<String, Object?> toLocalJson() => {
    'savedCase': _saved.toJson(),
    'phase': _phase.name,
    'uploadedVersions': Map<String, String>.of(_uploadedVersion),
    'pendingUpload': _pendingUpload == null
        ? null
        : {
            'evidenceId': _pendingUpload!.evidenceId,
            'version': _pendingUpload!.version,
            'expected': _pendingUpload!.expected,
          },
  };

  void restoreLocal(Map<String, Object?> value) {
    _saved = CaseSnapshot.fromJson(value['savedCase']);
    _uploadedVersion.addAll(
      Map<String, String>.from(value['uploadedVersions'] as Map),
    );
    final pending = value['pendingUpload'] as Map?;
    _pendingUpload = pending == null
        ? null
        : (
            evidenceId: pending['evidenceId'] as String,
            version: pending['version'] as String,
            expected: pending['expected'] as int,
          );
    final phase = value['phase'] as String;
    _phase = phase == 'idle' || phase == 'failed'
        ? SyncPhase.idle
        : SyncPhase.uncertain;
    if (_pendingUpload != null) _phase = SyncPhase.uncertain;
    notifyListeners();
  }

  void reset(CaseSnapshot savedCase) {
    _generation++;
    _saved = savedCase;
    _catalog = null;
    _uploadedVersion.clear();
    _pendingUpload = null;
    _recoveryConflict = null;
    _shownConflictRevision = null;
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

  Future<void> _adopt(CaseSnapshot saved) async {
    _saved = saved;
    await onCaseSaved?.call(saved);
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
