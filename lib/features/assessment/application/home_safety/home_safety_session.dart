import 'dart:convert';
import 'package:flutter/foundation.dart';
import '../../../../app/live_app.dart';
import '../../../../shared/models/case_draft.dart';
import '../../../../shared/models/contracts.dart';
import '../../../../shared/services/home_safety_api_client.dart';
import '../../../../shared/services/matching_api_client.dart';
import '../../domain/home_safety/home_safety.dart';
import '../../domain/assessment_location.dart';
import '../../domain/local_place_rooms.dart';
import '../live_assessment_session.dart';
import '../bathroom_scan_session.dart';
import '../whole_home_session.dart';

class HomeSafetySession extends ChangeNotifier {
  HomeSafetySession({required this.services, required this.catalog}) {
    caseId = services.coordinator.currentCase().caseId;
    _generation = services.coordinator.generation;
    api = HomeSafetyApiClient(
      baseUri: services.config.apiOrigin,
      tokenProvider: () async {
        guard();
        final token = await services.session.accessToken();
        guard();
        return token;
      },
      transport: services.transport,
      catalog: catalog,
    );
    services.coordinator.addListener(_coordinatorChanged);
  }
  final AppServices services;
  final HomeSafetyCatalog catalog;
  late final String caseId;
  late final int _generation;
  late final HomeSafetyApiClient api;
  late HomeSafetyState baseline;
  late SafetyDocument document;
  late CaseSnapshot snapshot;
  List<SafetyMutation> _pending = [];
  List<SafetyMutation> get pending => List.unmodifiable(_pending);
  HomeSafetyState? conflict;
  bool initialized = false,
      busy = false,
      needsReconcile = false,
      offline = false,
      localSaveFailed = false,
      _disposed = false;
  String get localKey => 'home-safety.$caseId';
  bool get isCurrent =>
      !_disposed &&
      services.coordinator.isCurrent &&
      services.coordinator.generation == _generation;
  bool get caseWriteBlocked =>
      services.coordinator.hasUnsavedChanges ||
      services.coordinator.uncertain ||
      services.coordinator.conflict;
  bool get hasPending => _pending.isNotEmpty;
  bool get pendingRoomDeletion =>
      _pending.any((r) => r.operation['type'] == 'delete_room');
  Iterable<Map<String, Object?>> get operations => [
    ...baseline.history.map(
      (e) => Map<String, Object?>.from(e['operation'] as Map),
    ),
    ..._pending.map((r) => r.operation),
  ];
  Future<void> setAddressed(FindingRoom link, bool addressed) => edit({
    'type': 'set_addressed',
    'roomId': link.roomId,
    'findingId': link.findingId,
    'findingFingerprint': safetyHash(
      snapshot.findings.firstWhere((f) => f.id == link.findingId).toJson(),
    ),
    'answerRevision': concernAnswerRevision(document, link),
    'addressed': addressed,
    if (baseline.evidenceCatalogRevision != null)
      'evidenceCatalogRevision': baseline.evidenceCatalogRevision,
  });
  void guard() {
    if (!isCurrent) throw MatchingApiException.forCode('STALE_RESPONSE');
  }

  void _coordinatorChanged() {
    if (!_disposed) notifyListeners();
  }

  Future<void> _persist(
    HomeSafetyState base,
    List<SafetyMutation> queue,
  ) async {
    guard();
    final value = <String, Object?>{
      'version': 1,
      'caseId': caseId,
      'baseline': base.toJson(),
      'pending': queue.map((r) => r.toJson()).toList(),
    };
    if (utf8.encode(jsonEncode(value)).length > 512 * 1024) {
      throw StateError('Private checklist limit reached.');
    }
    try {
      await services.store.writeJson(localKey, value);
      guard();
      localSaveFailed = false;
    } catch (_) {
      localSaveFailed = true;
      rethrow;
    }
  }

  ({SafetyDocument document, CaseSnapshot snapshot}) _project(
    HomeSafetyState base,
    List<SafetyMutation> queue,
  ) {
    var result = (document: base.document, snapshot: base.snapshot);
    for (final request in queue) {
      result = projectSafety(
        result.document,
        result.snapshot,
        request.operation,
        catalog,
      );
    }
    return result;
  }

  void _publish(HomeSafetyState base, List<SafetyMutation> queue) {
    final result = _project(base, queue);
    baseline = base;
    _pending = List.of(queue);
    document = result.document;
    snapshot = result.snapshot;
  }

  bool _queueFits(HomeSafetyState base, List<SafetyMutation> queue) {
    var caseRevision = base.snapshot.revision, safetyRevision = base.revision;
    for (final request in queue) {
      if (request.caseId != caseId ||
          request.caseRevision != caseRevision ||
          request.safetyRevision != safetyRevision) {
        return false;
      }
      safetyRevision++;
      if (request.operation['type'] == 'review_concern') caseRevision++;
    }
    return true;
  }

  Future<void> initialize() async {
    final local = await services.store.readJson(localKey);
    guard();
    if (local != null) {
      if (local.length != 4 ||
          local['version'] != 1 ||
          local['caseId'] != caseId ||
          utf8.encode(jsonEncode(local)).length > 512 * 1024) {
        throw const FormatException('Invalid saved checklist.');
      }
      final base = HomeSafetyState.fromJson(local['baseline'], catalog);
      if (base.snapshot.caseId != caseId) {
        throw const FormatException('Invalid checklist case.');
      }
      final queue = V.list(
        local['pending'],
        (r) => SafetyMutation.fromJson(r, catalog),
        100,
      );
      if (!_queueFits(base, queue)) {
        throw const FormatException('Invalid checklist journal.');
      }
      V.unique(queue.map((r) => r.id));
      _publish(base, queue);
      await _cleanDeletedModels(base);
    }
    try {
      final fresh = await api.read(caseId, isCurrent: () => isCurrent);
      guard();
      await _acceptFresh(fresh, hasLocal: local != null);
    } on MatchingApiException catch (error) {
      if (!{
        'NETWORK_ERROR',
        'TIMEOUT',
        'SERVICE_UNAVAILABLE',
        'NOT_FOUND',
      }.contains(error.code)) {
        rethrow;
      }
      offline = true;
      if (local == null) {
        final saved = services.coordinator.currentCase();
        _publish(
          HomeSafetyState.fromJson({
            'schemaVersion': '3',
            'case': saved.toJson(),
            'safety': {
              'schemaVersion': '3',
              'caseId': caseId,
              'revision': 0,
              'document': SafetyDocument.empty().toJson(),
              'history': <Object>[],
            },
            'acknowledgedMutationId': null,
          }, catalog),
          [],
        );
      }
      await _persist(baseline, _pending);
    }
    initialized = true;
    notifyListeners();
  }

  Future<void> _cleanDeletedModels(HomeSafetyState state) async {
    for (final event in state.history) {
      final op = event['operation'] as Map;
      if (op['type'] != 'delete_room') continue;
      final id = op['roomId'] as String;
      final room = RoomInstance(
        id: id,
        type: AssessmentLocation.bathroom,
        name: null,
      );
      final key = BathroomScanSession.storageKey(caseId, room: room);
      for (final suffix in ['', ':sync', ':upload']) {
        guard();
        await services.store.delete('$key$suffix');
        guard();
      }
      await WholeHomeSession.purgeForRoomDeletion(
        services.store,
        caseId,
        id,
        isCurrent: () => isCurrent,
      );
      guard();
    }
  }

  Future<void> _acceptFresh(
    HomeSafetyState fresh, {
    required bool hasLocal,
  }) async {
    guard();
    if (fresh.snapshot.revision < services.coordinator.currentCase().revision) {
      throw MatchingApiException.forCode('STALE_RESPONSE');
    }
    final queue = hasLocal
        ? List<SafetyMutation>.of(_pending)
        : <SafetyMutation>[];
    while (queue.isNotEmpty && fresh.acknowledges(queue.first)) {
      queue.removeAt(0);
    }
    if (!_queueFits(fresh, queue)) {
      conflict = fresh;
      needsReconcile = true;
      offline = false;
      return;
    }
    _project(fresh, queue);
    await _cleanDeletedModels(fresh);
    await _persist(fresh, queue);
    guard();
    _publish(fresh, queue);
    conflict = null;
    needsReconcile = false;
    offline = false;
    await services.coordinator.adoptRemoteSnapshot(fresh.snapshot);
    guard();
  }

  Future<void> _run(Future<void> Function() action) async {
    guard();
    if (busy) throw StateError('Checklist operation already running.');
    busy = true;
    notifyListeners();
    try {
      await action();
    } finally {
      busy = false;
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> edit(Map<String, Object?> operation) => _run(() async {
    if (!initialized ||
        conflict != null ||
        needsReconcile ||
        _pending.length >= 100 ||
        baseline.revision + _pending.length >= 500) {
      throw StateError('Review saved checklist first.');
    }
    if (operation['type'] == 'add_room' &&
        baseline.history.any((e) {
          final op = e['operation'] as Map;
          return op['type'] == 'add_room' &&
              (op['room'] as Map)['id'] == (operation['room'] as Map)['id'];
        })) {
      throw StateError('Room identifiers cannot be reused.');
    }
    final request = SafetyMutation.fromJson({
      'schemaVersion': '3',
      'caseId': caseId,
      'expectedCaseRevision': snapshot.revision,
      'expectedSafetyRevision': baseline.revision + _pending.length,
      'mutationId': newUuidV4(),
      'operation': operation,
    }, catalog);
    final queue = [..._pending, request];
    _project(baseline, queue);
    await _persist(baseline, queue);
    guard();
    _publish(baseline, queue);
  });

  Future<int> recoverScanRoomLinks() async {
    guard();
    if (!initialized ||
        busy ||
        conflict != null ||
        needsReconcile ||
        caseWriteBlocked) {
      return 0;
    }
    final bindings = await LiveAssessmentSession.savedScanRoomBindings(
      services.store,
      caseId,
    );
    guard();
    var added = 0;
    for (final binding in bindings.entries) {
      if (LocalPlaceRooms.containsId(binding.value) ||
          !document.activeRooms.any((r) => r.id == binding.value) ||
          !snapshot.findings.any((f) => f.id == binding.key) ||
          document.findingRooms.any((l) => l.findingId == binding.key)) {
        continue;
      }
      await edit({
        'type': 'assign_finding',
        'roomId': binding.value,
        'findingId': binding.key,
      });
      added++;
    }
    return added;
  }

  Future<void> refresh() => _run(
    () => services.coordinator.serialize(() async {
      final fresh = await api.read(caseId, isCurrent: () => isCurrent);
      guard();
      await _acceptFresh(fresh, hasLocal: true);
    }),
  );
  Future<void> save() => _run(
    () => services.coordinator.serialize(() async {
      guard();
      if (caseWriteBlocked || conflict != null || needsReconcile) {
        throw StateError('Reconcile the case and checklist first.');
      }
      final fresh = await api.read(caseId, isCurrent: () => isCurrent);
      guard();
      await _acceptFresh(fresh, hasLocal: true);
      if (conflict != null) return;
      while (_pending.isNotEmpty) {
        guard();
        if (caseWriteBlocked) throw StateError('Resident details changed.');
        final request = _pending.first;
        try {
          needsReconcile = true;
          final saved = await api.save(request, isCurrent: () => isCurrent);
          guard();
          await _acceptFresh(saved, hasLocal: true);
          if (conflict != null) return;
        } catch (error) {
          needsReconcile = true;
          if (error is MatchingApiException &&
              {400, 409, 507}.contains(error.statusCode)) {
            conflict = await api.read(caseId, isCurrent: () => isCurrent);
            guard();
          }
          rethrow;
        }
      }
      offline = false;
    }),
  );

  Future<void> resolve({required bool keepDevice}) => _run(
    () => services.coordinator.serialize(() async {
      if (keepDevice && pendingRoomDeletion) {
        throw StateError('Room deletion requires a fresh confirmation.');
      }
      final reviewed = conflict;
      if (reviewed == null) {
        throw StateError('Review the saved checklist first.');
      }
      final fresh = await api.read(caseId, isCurrent: () => isCurrent);
      guard();
      if (fresh.revision != reviewed.revision ||
          fresh.snapshot.revision != reviewed.snapshot.revision) {
        conflict = fresh;
        needsReconcile = true;
        return;
      }
      final queue = <SafetyMutation>[];
      var preview = (document: fresh.document, snapshot: fresh.snapshot);
      if (keepDevice) {
        for (final prior in _pending) {
          if (fresh.acknowledges(prior)) continue;
          final next = SafetyMutation.fromJson({
            'schemaVersion': '3',
            'caseId': caseId,
            'expectedCaseRevision': preview.snapshot.revision,
            'expectedSafetyRevision': fresh.revision + queue.length,
            'mutationId': newUuidV4(),
            'operation': prior.operation,
          }, catalog);
          preview = projectSafety(
            preview.document,
            preview.snapshot,
            next.operation,
            catalog,
          );
          queue.add(next);
        }
      }
      await _cleanDeletedModels(fresh);
      await _persist(fresh, queue);
      guard();
      _publish(fresh, queue);
      conflict = null;
      needsReconcile = false;
      offline = false;
      await services.coordinator.adoptRemoteSnapshot(fresh.snapshot);
      guard();
    }),
  );
  @override
  void dispose() {
    services.coordinator.removeListener(_coordinatorChanged);
    _disposed = true;
    super.dispose();
  }
}
