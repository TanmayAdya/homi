import 'package:flutter/foundation.dart';

import '../../../shared/models/contracts.dart';
import '../../../shared/models/evidence.dart';
import '../../../shared/services/matching_api_client.dart';
import '../domain/export/export_selection_draft.dart';
import 'case_evidence_gateway.dart';

class ExportReview extends ChangeNotifier {
  ExportReview({
    required CaseEvidenceGateway gateway,
    required CaseSnapshot Function() currentCase,
  }) : _gateway = gateway,
       _currentCase = currentCase;

  final CaseEvidenceGateway _gateway;
  final CaseSnapshot Function() _currentCase;
  final ExportSelectionDraft draft = ExportSelectionDraft();

  EvidenceCatalog? _catalog;
  final Map<String, ({int revision, Uint8List bytes})> _pixels = {};
  final Set<String> _loadingPixels = {};
  bool _loading = false;
  String? _errorCode;
  String? _errorMessage;
  List<String> _lastDropped = const [];
  int _generation = 0;
  bool _disposed = false;

  EvidenceCatalog? get catalog => _catalog;
  bool get isLoading => _loading;
  String? get errorCode => _errorCode;
  String? get errorMessage => _errorMessage;

  List<String> get lastDropped => _lastDropped;

  bool get isStale {
    final EvidenceCatalog? c = _catalog;
    if (c == null) return false;
    final CaseSnapshot saved = _currentCase();
    return c.caseId != saved.caseId || c.caseRevision != saved.revision;
  }

  List<ExportCandidate> get candidates => _catalog == null || isStale
      ? const []
      : ExportCandidate.fromCatalog(_catalog!, _currentCase());

  Uint8List? pixelsFor(String evidenceId) {
    final cached = _pixels[evidenceId];
    final EvidenceDescriptor? item = _descriptor(evidenceId);
    if (cached == null || item == null) return null;
    return cached.revision == item.evidenceRevision ? cached.bytes : null;
  }

  bool isLoadingPixels(String evidenceId) =>
      _loadingPixels.contains(evidenceId);

  List<EvidenceSelection> get selections => draft.toEvidenceSelections();

  Future<void> load() async {
    if (_loading) return;
    final int gen = ++_generation;
    final CaseSnapshot saved = _currentCase();
    final EvidenceCatalog? previous = _catalog?.caseRevision == saved.revision
        ? _catalog
        : null;
    _loading = true;
    _errorCode = null;
    _errorMessage = null;
    _notify();
    try {
      final EvidenceCatalog result = await _gateway.listEvidence(
        saved,
        currentCase: () => _live(gen, _currentCase()),
        currentCatalog: () => _live(gen, previous),
      );
      if (gen != _generation) return;
      _catalog = result;
      _lastDropped = draft.reconcile(
        ExportCandidate.fromCatalog(result, saved),
      );
      _pixels.removeWhere(
        (id, p) => _descriptor(id)?.evidenceRevision != p.revision,
      );
    } on MatchingApiException catch (e) {
      if (gen != _generation) return;
      _errorCode = e.code;
      _errorMessage = e.message;
    } finally {
      if (gen == _generation) _loading = false;
      _notify();
    }
  }

  Future<void> showPhoto(String evidenceId) async {
    final EvidenceCatalog? catalog = _catalog;
    final EvidenceDescriptor? item = _descriptor(evidenceId);
    if (catalog == null || item == null || isStale) return;
    if (pixelsFor(evidenceId) != null || !_loadingPixels.add(evidenceId)) {
      return;
    }
    final int gen = _generation;
    _notify();
    try {
      final List<int> bytes = await _gateway.downloadEvidence(
        _currentCase(),
        catalog: catalog,
        evidence: item,
        currentCase: () => _live(gen, _currentCase()),
        currentCatalog: () => _live(gen, catalog),
      );
      if (gen != _generation) return;
      _pixels[evidenceId] = (
        revision: item.evidenceRevision,
        bytes: Uint8List.fromList(bytes),
      );
    } on MatchingApiException catch (e) {
      if (gen != _generation) return;
      _errorCode = e.code;
      _errorMessage = e.message;
    } finally {
      _loadingPixels.remove(evidenceId);
      _notify();
    }
  }

  bool markChecked(String evidenceId) {
    final EvidenceDescriptor? item = _descriptor(evidenceId);
    if (item == null || pixelsFor(evidenceId) == null) return false;
    final bool ok = draft.markReviewed(evidenceId, item.evidenceRevision);
    _notify();
    return ok;
  }

  SelectionRejection? include(String evidenceId) {
    final SelectionRejection? rejection = draft.add(evidenceId);
    _notify();
    return rejection;
  }

  bool exclude(String evidenceId) {
    final bool removed = draft.remove(evidenceId);
    _notify();
    return removed;
  }

  void move(int from, int to) {
    draft.move(from, to);
    _notify();
  }

  void clear() {
    _generation++;
    _catalog = null;
    _pixels.clear();
    _loadingPixels.clear();
    _loading = false;
    _errorCode = null;
    _errorMessage = null;
    _lastDropped = const [];
    draft.clear();
    _notify();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  EvidenceDescriptor? _descriptor(String evidenceId) =>
      _catalog?.evidence.where((e) => e.evidenceId == evidenceId).firstOrNull;

  T _live<T>(int gen, T value) {
    if (gen != _generation) throw StateError('superseded');
    return value;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }
}
