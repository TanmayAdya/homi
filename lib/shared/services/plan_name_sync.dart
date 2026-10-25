import '../models/account_plan_name.dart';
import '../models/case_draft.dart';
import '../models/export_contract_values.dart';
import '../models/plan_name.dart';
import 'local_private_store.dart';
import 'matching_api_client.dart';
import 'plan_names_api_client.dart';

class PlanNameSyncRequired extends StateError {
  PlanNameSyncRequired()
    : super(
        'A plan name is still waiting to sync. Open Plans, choose Rename, and check its sync before signing out.',
      );
}

class PlanNameSync {
  PlanNameSync({
    required this.store,
    required this.api,
    required this.isCurrent,
    required this.changed,
  });
  final LocalPrivateStore store;
  final PlanNamesApiClient api;
  final bool Function() isCurrent;
  final void Function() changed;
  final _records = <String, _NameRecord>{};
  final _tails = <String, Future<void>>{};
  final _errors = <String, String>{};
  final _removed = <String>{};
  bool _signingOut = false;

  static String storageKey(String id) {
    PlanName.storageKey(id);
    return 'plan-name-sync.$id';
  }

  void _guard() {
    if (!isCurrent()) throw MatchingApiException.forCode('STALE_RESPONSE');
  }

  bool contains(String id) => isCurrent() && _records.containsKey(id);
  String? nameFor(String id) => !isCurrent() ? null : _records[id]?.name;
  bool hasConflict(String id) =>
      isCurrent() && (_records[id]?.conflict ?? false);
  AccountPlanName? remoteFor(String id) =>
      isCurrent() ? _records[id]?.confirmed : null;
  bool pendingFor(String id) => isCurrent() && (_records[id]?.pending != null);
  String? statusFor(String id) {
    if (!isCurrent()) return null;
    final record = _records[id];
    if (record == null) return null;
    if (record.conflict) return 'Name changed on another device — review';
    if (record.pending != null) {
      return _errors[id] == 'CASE_NOT_FOUND'
          ? 'Name saved on this device — save the plan to sync'
          : 'Name saved on this device — sync pending';
    }
    return record.confirmed == null ? null : 'Name saved to your account';
  }

  Future<T> _serial<T>(
    String id,
    Future<T> Function() action, {
    bool signingOut = false,
  }) {
    if (_signingOut && !signingOut) {
      return Future.error(StateError('Sign-out is in progress.'));
    }
    storageKey(id);
    final future = (_tails[id] ?? Future<void>.value()).then((_) async {
      _guard();
      if (_removed.contains(id)) throw StateError('This plan was removed.');
      if (await store.readJson('case-delete.$id') != null) {
        throw StateError('Check this plan’s removal before syncing its name.');
      }
      _guard();
      return action();
    });
    final tail = future.then<void>(
      (_) {},
      onError: (Object _, StackTrace s) {},
    );
    _tails[id] = tail;
    tail.then((_) {
      if (identical(_tails[id], tail)) _tails.remove(id);
    });
    return future;
  }

  Future<_NameRecord> _load(String id) async {
    if (_records.containsKey(id)) return _records[id]!;
    final raw = await store.readJson(storageKey(id));
    _guard();
    if (raw != null) {
      final record = _NameRecord.fromJson(raw, id);
      _records[id] = record;
      return record;
    }
    final legacy = await store.readJson(PlanName.storageKey(id));
    _guard();
    final name = legacy == null ? null : PlanName.fromJson(legacy);
    if (name != null && name.caseId != id) {
      throw const FormatException('Invalid local plan name.');
    }
    final record = _NameRecord(
      pending: name == null ? null : _PendingName(name: name.name),
    );
    _records[id] = record;
    return record;
  }

  Future<void> _persist(String id, _NameRecord record) async {
    _guard();
    await store.writeJson(storageKey(id), record.toJson(id));
    _guard();
    _records[id] = record;
    changed();
    try {
      await store.delete(PlanName.storageKey(id));
    } catch (_) {
      _guard();
    }
    _guard();
  }

  Future<String?> load(String id) => _serial(id, () async {
    final record = await _load(id);
    changed();
    return record.name;
  });

  Future<void> retainInitial(String id, String value) => _serial(id, () async {
    final name = normalizePlanName(value);
    if (name == null) throw const FormatException('Invalid initial plan name.');
    final record = await _load(id);
    if (record.pending != null && record.pending!.name != name) {
      throw StateError(
        'Review the two saved names before completing recovery.',
      );
    }
    if (record.pending != null || record.confirmed?.name == name) {
      await _persist(id, record);
    } else {
      await _persist(
        id,
        _NameRecord(
          confirmed: record.confirmed,
          pending: _PendingName(name: name),
        ),
      );
    }
  });

  Future<void> accept(AccountPlanName remote) =>
      _serial(remote.caseId, () async {
        final record = await _load(remote.caseId);
        await _merge(remote, record);
      });

  Future<_NameRecord> _merge(AccountPlanName remote, _NameRecord record) async {
    final prior = record.confirmed;
    if (prior != null && remote.nameRevision < prior.nameRevision) {
      return record;
    }
    if (prior != null &&
        remote.nameRevision == prior.nameRevision &&
        (prior.name != remote.name ||
            prior.lastMutationId != remote.lastMutationId)) {
      throw MatchingApiException.forCode('UNEXPECTED_RESPONSE');
    }
    var pending = record.pending;
    if (pending != null) {
      final request = pending.request;
      final exact =
          request != null &&
          remote.nameRevision == request.expectedNameRevision + 1 &&
          remote.lastMutationId == request.mutationId &&
          remote.name == request.name;
      if (exact || (request == null && remote.name == pending.name)) {
        pending = null;
      }
    }
    final merged = _NameRecord(confirmed: remote, pending: pending);
    await _persist(remote.caseId, merged);
    return merged;
  }

  Future<void> refresh(String id) => _serial(id, () async {
    await _refresh(id);
  });

  Future<void> _refresh(String id) async {
    var record = await _load(id);
    try {
      final remote = await api.readName(
        id,
        minimumNameRevision: record.confirmed?.nameRevision ?? 0,
        currentName: () => _records[id]?.confirmed,
        isCurrent: isCurrent,
      );
      _guard();
      record = await _merge(remote, record);
      if (record.pending != null && !record.conflict) await _send(id, record);
      _errors.remove(id);
      changed();
    } on MatchingApiException catch (error) {
      _guard();
      _errors[id] = error.code;
      changed();
      rethrow;
    }
  }

  Future<void> _send(String id, _NameRecord record) async {
    final pending = record.pending!;
    final request =
        pending.request ??
        PlanNameSaveRequest(
          caseId: id,
          expectedNameRevision: record.confirmed!.nameRevision,
          mutationId: newUuidV4(),
          name: pending.name,
        );
    final journaled = _NameRecord(
      confirmed: record.confirmed,
      pending: _PendingName(name: pending.name, request: request),
    );
    await _persist(id, journaled);
    final response = await api.saveName(
      id,
      expectedNameRevision: request.expectedNameRevision,
      mutationId: request.mutationId,
      name: request.name,
      isCurrent: isCurrent,
    );
    _guard();
    await _merge(response, journaled);
  }

  Future<void> save(String id, String? value) => _serial(id, () async {
    final name = normalizePlanName(value);
    final record = await _load(id);
    if (record.pending?.request != null || record.conflict) {
      throw StateError('Check the pending name before changing it again.');
    }
    if (record.pending == null &&
        record.confirmed?.name == name &&
        record.confirmed != null) {
      return;
    }
    final base = record.confirmed;
    await _persist(
      id,
      _NameRecord(
        confirmed: base,
        pending: _PendingName(
          name: name,
          request: base == null
              ? null
              : PlanNameSaveRequest(
                  caseId: id,
                  expectedNameRevision: base.nameRevision,
                  mutationId: newUuidV4(),
                  name: name,
                ),
        ),
      ),
    );
    try {
      await _refresh(id);
    } on MatchingApiException catch (error) {
      if (error.code == 'STALE_RESPONSE') rethrow;
    }
  });

  Future<void> resolve(
    String id, {
    required bool keepLocal,
    required AccountPlanName reviewedRemote,
  }) => _serial(id, () async {
    final record = await _load(id);
    final remote = record.confirmed;
    if (!record.conflict ||
        remote == null ||
        reviewedRemote.caseId != id ||
        remote.nameRevision != reviewedRemote.nameRevision ||
        remote.name != reviewedRemote.name ||
        remote.lastMutationId != reviewedRemote.lastMutationId) {
      throw StateError('Refresh and review both names before choosing.');
    }
    await _persist(
      id,
      _NameRecord(
        confirmed: remote,
        pending: !keepLocal
            ? null
            : _PendingName(
                name: record.pending!.name,
                request: PlanNameSaveRequest(
                  caseId: id,
                  expectedNameRevision: remote.nameRevision,
                  mutationId: newUuidV4(),
                  name: record.pending!.name,
                ),
              ),
      ),
    );
    if (keepLocal) {
      try {
        await _refresh(id);
      } on MatchingApiException catch (error) {
        if (error.code == 'STALE_RESPONSE') rethrow;
      }
    }
  });

  Future<void> forget(String id) async {
    storageKey(id);
    _removed.add(id);
    await _tails[id];
    _guard();
    await store.delete(storageKey(id));
    _guard();
    _records.remove(id);
    _errors.remove(id);
    changed();
  }

  Future<void> requireSyncedBeforeSignOut() => withSignOut(() async {});

  Future<void> withSignOut(
    Future<void> Function() clearAccount, {
    bool attemptSync = true,
  }) async {
    _guard();
    if (_signingOut) throw StateError('Sign-out is already in progress.');
    _signingOut = true;
    try {
      await Future.wait(_tails.values.toList());
      _guard();
      await _requireSyncedBeforeSignOut(attemptSync: attemptSync);
      _guard();
      await clearAccount();
    } finally {
      _signingOut = false;
    }
  }

  Future<void> _requireSyncedBeforeSignOut({required bool attemptSync}) async {
    final keys = await store.keys();
    _guard();
    final ids = <String>{};
    for (final key in keys) {
      if (key.startsWith('plan-name.')) ids.add(key.substring(10));
      if (key.startsWith('plan-name-sync.')) ids.add(key.substring(15));
      if (key.startsWith('case.')) {
        final value = await store.readJson(key);
        _guard();
        if (value?.containsKey('pendingPlanName') ?? false) {
          throw PlanNameSyncRequired();
        }
      }
    }
    for (final id in ids) {
      await _serial(id, () async {
        await _load(id);
        if (!pendingFor(id) || !attemptSync) return;
        try {
          await _refresh(id);
        } on MatchingApiException catch (_) {
          _guard();
        }
      }, signingOut: true);
      if (pendingFor(id)) {
        throw PlanNameSyncRequired();
      }
    }
  }
}

class _PendingName {
  const _PendingName({required this.name, this.request});
  final String? name;
  final PlanNameSaveRequest? request;
}

class _NameRecord {
  const _NameRecord({this.confirmed, this.pending});
  final AccountPlanName? confirmed;
  final _PendingName? pending;
  String? get name => pending == null ? confirmed?.name : pending!.name;
  bool get conflict {
    if (confirmed == null || pending == null) return false;
    final request = pending!.request;
    return request == null
        ? confirmed!.nameRevision > 0
        : confirmed!.nameRevision != request.expectedNameRevision;
  }

  Map<String, Object?> toJson(String id) => {
    'version': 1,
    'caseId': id,
    'confirmed': confirmed?.toJson(),
    'pending': pending == null
        ? null
        : {'name': pending!.name, 'request': pending!.request?.toJson()},
  };
  factory _NameRecord.fromJson(Map<String, Object?> value, String id) {
    ExportContractValues.object(value, {
      'version',
      'caseId',
      'confirmed',
      'pending',
    });
    if (value['version'] != 1 || value['caseId'] != id) {
      ExportContractValues.invalid();
    }
    final confirmed = value['confirmed'] == null
        ? null
        : AccountPlanName.fromJson(value['confirmed']);
    _PendingName? pending;
    if (value['pending'] != null) {
      final raw = ExportContractValues.object(value['pending'], {
        'name',
        'request',
      });
      final name = raw['name'];
      if (name != null &&
          (name is! String ||
              normalizePlanName(name) != name ||
              name.isEmpty)) {
        ExportContractValues.invalid();
      }
      final request = raw['request'] == null
          ? null
          : PlanNameSaveRequest.fromJson(raw['request']);
      if (request != null &&
          (request.caseId != id ||
              request.name != name ||
              confirmed == null ||
              request.expectedNameRevision > confirmed.nameRevision)) {
        ExportContractValues.invalid();
      }
      pending = _PendingName(name: name as String?, request: request);
    }
    if (confirmed != null && confirmed.caseId != id) {
      ExportContractValues.invalid();
    }
    return _NameRecord(confirmed: confirmed, pending: pending);
  }
}
