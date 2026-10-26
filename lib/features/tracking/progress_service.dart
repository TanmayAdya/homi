import 'dart:async';
import 'package:flutter/widgets.dart';
import '../../shared/services/local_private_store.dart';
import '../../shared/services/progress_api_client.dart';
import '../../shared/services/matching_api_client.dart';
import '../../shared/models/case_draft.dart';
import 'device_reminders.dart';
import 'progress_models.dart';

class ProgressSnapshot {
  ProgressSnapshot(this.pages) {
    if (pages.isEmpty ||
        pages.any(
          (p) =>
              p.caseId != pages.first.caseId ||
              p.revision != pages.first.revision ||
              p.caseRevision != pages.first.caseRevision ||
              p.historyVersion != pages.first.historyVersion,
        )) {
      throw const FormatException();
    }
    ExportUnique.check(programs.map((p) => p.id));
    ExportUnique.check(tasks.map((t) => t.id));
  }
  final List<ProgressPage> pages;
  int get revision => pages.first.revision;
  int get caseRevision => pages.first.caseRevision;
  String get caseId => pages.first.caseId;
  List<TrackedProgram> get programs => pages.expand((p) => p.programs).toList();
  List<NextStepTask> get tasks => pages.expand((p) => p.tasks).toList();
}

class ExportUnique {
  static void check(Iterable<String> ids) {
    final list = ids.toList();
    if (list.toSet().length != list.length) throw const FormatException();
  }
}

class ProgressService extends ChangeNotifier with WidgetsBindingObserver {
  ProgressService({
    required this.api,
    required this.store,
    required this.reminders,
    required this.isCurrent,
  });
  final ProgressApiClient api;
  final LocalPrivateStore store;
  final DeviceReminders reminders;
  final bool Function() isCurrent;
  final Map<String, ProgressSnapshot> cached = {};
  final Map<String, Map<String, Object?>> pending = {};
  Future<void> _tail = Future.value();
  bool _active = true;
  String? feedback;
  Future<T> _serial<T>(Future<T> Function() work) {
    final next = _tail.then((_) {
      _guard();
      return work();
    });
    _tail = next.then<void>((_) {}, onError: (Object _) {});
    return next;
  }

  bool get current => _active && isCurrent();
  void _guard() {
    if (!current) throw MatchingApiException.forCode('STALE_RESPONSE');
  }

  Future<void> initialize() async {
    WidgetsBinding.instance.addObserver(this);
    try {
      await reminders.initialize();
    } catch (_) {
      reminders.feedback ??=
          'A reminder could not be scheduled. Your task is still saved.';
    }
    _guard();
    for (final key in await store.keys()) {
      _guard();
      if (key.startsWith('progress-cache.')) {
        final value = await store.readJson(key);
        _guard();
        if (value != null) {
          final snapshot = ProgressSnapshot(
            (value['pages'] as List).map(ProgressPage.fromJson).toList(),
          );
          cached[snapshot.caseId] = snapshot;
        }
      } else if (key.startsWith('progress-pending.')) {
        final value = await store.readJson(key);
        _guard();
        if (value != null) pending[value['caseId'] as String] = value;
      }
    }
    await refreshAll();
  }

  Future<ProgressSnapshot> _fetch(String caseId) async {
    final pages = <ProgressPage>[];
    int offset = 0;
    do {
      final page = await api.read(
        caseId,
        isCurrent: () => current,
        offset: offset,
        revision: pages.firstOrNull?.revision,
        caseRevision: pages.firstOrNull?.caseRevision,
        historyVersion: pages.firstOrNull?.historyVersion,
      );
      _guard();
      pages.add(page);
      if (page.nextOffset == null) break;
      offset = page.nextOffset!;
    } while (pages.length <= 8);
    if (pages.last.nextOffset != null) throw const FormatException();
    final snapshot = ProgressSnapshot(pages);
    await store.writeJson('progress-cache.$caseId', {
      'pages': pages.map((p) => p.json).toList(),
    });
    _guard();
    cached[caseId] = snapshot;
    return snapshot;
  }

  Future<ProgressSnapshot> refresh(String caseId) => _serial(() async {
    try {
      final result = await _fetch(caseId);
      feedback = null;
      await _reconcile();
      _guard();
      notifyListeners();
      return result;
    } on MatchingApiException catch (e) {
      if (e.code == 'CASE_NOT_FOUND') await _forget(caseId);
      rethrow;
    }
  });
  Future<void> refreshAll() => _serial(() async {
    feedback = null;
    for (final id in cached.keys.toList()) {
      try {
        await _fetch(id);
      } on MatchingApiException catch (e) {
        if (e.code == 'CASE_NOT_FOUND') {
          await _forget(id);
        } else {
          feedback = 'Offline copy. Refresh before changing tasks.';
        }
      }
    }
    await _reconcile();
    _guard();
    notifyListeners();
  });
  Future<void> _reconcile() async {
    try {
      await reminders.reconcile({
        for (final entry in cached.entries) entry.key: entry.value.tasks,
      });
    } catch (_) {
      reminders.feedback =
          'A reminder could not be scheduled. Your task is still saved.';
    }
  }

  Future<void> reconcileReminders() => _serial(() async {
    await _reconcile();
    _guard();
    notifyListeners();
  });
  Future<void> _forget(String caseId) async {
    cached.remove(caseId);
    pending.remove(caseId);
    await reminders.forgetCase(caseId);
    _guard();
    await store.delete('progress-cache.$caseId');
    await store.delete('progress-pending.$caseId');
  }

  Future<void> forget(String caseId) => _serial(() async {
    await _forget(caseId);
    await _reconcile();
  });
  Future<ProgressSnapshot> mutate(
    String caseId,
    int caseRevision,
    Map<String, Object?> operation,
  ) => _serial(() async {
    if (pending.containsKey(caseId)) {
      throw StateError('Review the pending save first.');
    }
    final state = cached[caseId];
    if (state == null || state.caseRevision != caseRevision) {
      throw MatchingApiException.forCode('STALE_RESPONSE');
    }
    final request = <String, Object?>{
      'schemaVersion': '3',
      if (api.includeReferrals) 'includeReferrals': true,
      'caseId': caseId,
      'expectedCaseRevision': caseRevision,
      'expectedProgressRevision': state.revision,
      'mutationId': newUuidV4(),
      'operation': operation,
    };
    await store.writeJson('progress-pending.$caseId', request);
    _guard();
    pending[caseId] = request;
    return _send(request);
  });
  Future<ProgressSnapshot> retry(String caseId) => _serial(() async {
    return _send(pending[caseId]!);
  });
  Future<ProgressSnapshot> _send(Map<String, Object?> request) async {
    final ack = await api.save(request, isCurrent: () => current);
    _guard();
    final state = await _fetch(ack.caseId);
    _guard();
    await store.delete('progress-pending.${ack.caseId}');
    _guard();
    pending.remove(ack.caseId);
    await _reconcile();
    _guard();
    notifyListeners();
    return state;
  }

  Future<void> discard(String caseId) => _serial(() async {
    await _fetch(caseId);
    _guard();
    await store.delete('progress-pending.$caseId');
    pending.remove(caseId);
    notifyListeners();
  });
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && current) {
      unawaited(
        refreshAll().catchError((Object _) {
          if (current) {
            feedback =
                'A reminder could not be scheduled. Your task is still saved.';
            notifyListeners();
          }
        }),
      );
    }
  }

  Future<void> stop() {
    _active = false;
    WidgetsBinding.instance.removeObserver(this);
    return reminders.stop();
  }

  @override
  void dispose() {
    unawaited(stop().catchError((Object _) {}));
    super.dispose();
  }
}
