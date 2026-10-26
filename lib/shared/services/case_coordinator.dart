import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import '../models/case_draft.dart';
import '../models/case_list.dart';
import '../models/contracts.dart';
import '../models/export_contract_values.dart';
import '../models/plan_name.dart';
import '../models/account_plan_name.dart';
import 'case_discovery_api_client.dart';
import 'case_evidence_api_client.dart';
import 'local_private_store.dart';
import 'matching_api_client.dart';
import 'session_service.dart';
import 'plan_name_sync.dart';
import 'plan_names_api_client.dart';

class CaseCoordinator extends ChangeNotifier {
  CaseCoordinator({
    required this.session,
    required this.store,
    required this.cases,
    required this.discovery,
    PlanNamesApiClient? planNames,
  }) {
    _accountEpoch = session.epoch;
    if (planNames != null) {
      nameSync = PlanNameSync(
        store: store,
        api: planNames,
        isCurrent: () => isCurrent,
        changed: _changed,
      );
    }
  }
  final SessionService session;
  final LocalPrivateStore store;
  final CaseEvidenceApiClient cases;
  final CaseDiscoveryApiClient discovery;
  PlanNameSync? nameSync;
  late final int _accountEpoch;
  CaseSnapshot? snapshot;
  CaseDraft? draft;
  bool uncertain = false, conflict = false, busy = false;
  bool localWritePending = false, localSaveFailed = false;
  String? notice;
  int _selection = 0, _edit = 0, _localWriteVersion = 0;
  Future<void> _tail = Future.value();
  final _planNames = <String, String>{};
  final _knownPlanIds = <String>{};
  final _planNameReads = <String, int>{};
  PlanName? _pendingInitialPlanName;
  bool _disposed = false;
  bool _signingOut = false;
  int get generation => _selection;
  bool get isCurrent =>
      !_disposed &&
      session.epoch == _accountEpoch &&
      session.userId == store.accountId;
  bool get hasUndurableEdits => localWritePending || localSaveFailed;
  void _guardCaseSelection() {
    _guard();
    if (_signingOut) throw StateError('Sign-out is in progress.');
    if (busy) throw StateError('Finish the current save first.');
    if (hasUndurableEdits) {
      throw StateError(
        'Keep the current case open until its device save succeeds.',
      );
    }
  }

  bool get hasUnsavedChanges =>
      draft != null &&
      (snapshot == null ||
          jsonEncode(draft!.toJson()) !=
              jsonEncode(CaseDraft.fromSnapshot(snapshot!).toJson()));
  void _guard([int? generation]) {
    if (!isCurrent || (generation != null && generation != _selection)) {
      throw MatchingApiException.forCode('STALE_RESPONSE');
    }
  }

  CaseSnapshot currentCase() {
    _guard();
    if (snapshot == null) throw MatchingApiException.forCode('STALE_RESPONSE');
    return snapshot!;
  }

  CaseDraft currentDraft() {
    _guard();
    if (draft == null) throw MatchingApiException.forCode('STALE_RESPONSE');
    return draft!;
  }

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  String? planNameFor(String caseId) => !isCurrent
      ? null
      : _pendingInitialPlanName?.caseId == caseId
      ? _pendingInitialPlanName!.name
      : nameSync?.contains(caseId) == true
      ? nameSync!.nameFor(caseId)
      : _planNames[caseId];

  String? planNameStatus(String id) =>
      nameSync?.statusFor(id) ??
      (planNameFor(id) == null
          ? null
          : 'Name saved on this device — sync pending');

  Future<void> acceptPlanNames(Iterable<AccountPlanName> names) async {
    for (final name in names) {
      _guard();
      try {
        await nameSync?.accept(name);
      } catch (_) {
        _guard();
      }
    }
  }

  Future<void> syncPlanName(String id) async {
    _guard();
    if (nameSync == null) return;
    await _planNameTarget(id, _selection);
    await nameSync!.refresh(id);
  }

  Future<void> _syncNameAfterCaseSave(String id) async {
    if (nameSync == null) return;
    try {
      await nameSync!.load(id);
      if (nameSync!.pendingFor(id)) await nameSync!.refresh(id);
    } catch (_) {
      _guard();
    }
  }

  void rememberListedCases(Iterable<CaseSummary> summaries) {
    _guard();
    for (final summary in summaries) {
      PlanName.storageKey(summary.caseId);
      _knownPlanIds.add(summary.caseId);
    }
  }

  PlanName? _pendingNameFromRecord(String id, Map<String, Object?>? value) {
    if (value == null || !value.containsKey('pendingPlanName')) return null;
    final name = PlanName.fromJson(value['pendingPlanName']);
    if (name.caseId != id) throw const FormatException('Invalid local plan.');
    return name;
  }

  Future<Map<String, Object?>?> _planNameTarget(
    String id,
    int generation,
  ) async {
    PlanName.storageKey(id);
    _guard(generation);
    final removal = await store.readJson('case-delete.$id');
    _guard(generation);
    if (removal != null) {
      throw StateError('Check this plan’s removal before changing its name.');
    }
    final value = await store.readJson('case.$id');
    _guard(generation);
    if (value != null) {
      if (value['version'] != 1 ||
          CaseDraft.fromJson(value['draft']).caseId != id ||
          (value['snapshot'] != null &&
              parseCurrentCase(value['snapshot']).caseId != id)) {
        throw const FormatException('Invalid local plan.');
      }
    } else if (!_knownPlanIds.contains(id) && draft?.caseId != id) {
      throw StateError('Open or find this plan before naming it.');
    }
    return value;
  }

  Future<String?> _readPlanName(
    String id,
    int generation,
    Map<String, Object?>? local, {
    int? readVersion,
  }) async {
    final request = readVersion ?? _planNameReads[id] ?? 0;
    _guard(generation);
    if ((_planNameReads[id] ?? 0) != request) {
      throw MatchingApiException.forCode('STALE_RESPONSE');
    }
    final raw = await store.readJson(PlanName.storageKey(id));
    _guard(generation);
    if ((_planNameReads[id] ?? 0) != request) {
      throw MatchingApiException.forCode('STALE_RESPONSE');
    }
    final stored = raw == null ? null : PlanName.fromJson(raw);
    if (stored != null && stored.caseId != id) {
      throw const FormatException('Invalid local plan name.');
    }
    final name = _pendingNameFromRecord(id, local)?.name ?? stored?.name;
    if (name == null) {
      _planNames.remove(id);
    } else {
      _planNames[id] = name;
    }
    _changed();
    return name;
  }

  Future<String?> loadPlanName(String caseId) async {
    _guard();
    final generation = _selection;
    final request = _planNameReads[caseId] ?? 0;
    final record = await _planNameTarget(caseId, generation);
    if (nameSync != null && _pendingNameFromRecord(caseId, record) == null) {
      final result = await nameSync!.load(caseId);
      _guard(generation);
      return result;
    }
    return _readPlanName(caseId, generation, record, readVersion: request);
  }

  Future<bool> _restoreOptionalPlanName(
    String id,
    int generation,
    Map<String, Object?>? record,
  ) async {
    try {
      if (nameSync != null && _pendingNameFromRecord(id, record) == null) {
        await nameSync!.load(id);
        _guard(generation);
      } else {
        await _readPlanName(id, generation, record);
      }
      return true;
    } on FormatException {
      _guard(generation);
      _planNames.remove(id);
      return false;
    } on MatchingApiException {
      _guard(generation);
      return true;
    }
  }

  Future<void> savePlanName(String caseId, String? value) async {
    _guard();
    if (hasUndurableEdits) {
      throw StateError('Finish saving device changes before renaming a plan.');
    }
    final key = PlanName.storageKey(caseId);
    final name = normalizePlanName(value);
    final generation = _selection;
    _planNameReads[caseId] = (_planNameReads[caseId] ?? 0) + 1;
    await serialize(() async {
      final record = await _planNameTarget(caseId, generation);
      if (hasUndurableEdits) {
        throw StateError(
          'Finish saving device changes before renaming a plan.',
        );
      }
      if (_pendingNameFromRecord(caseId, record) != null ||
          _pendingInitialPlanName?.caseId == caseId) {
        throw StateError('Finish saving this new plan before renaming it.');
      }
      _guard(generation);
      if (nameSync != null) {
        await nameSync!.save(caseId, name);
        _guard(generation);
        return;
      }
      if (name == null) {
        await store.delete(key);
      } else {
        await store.writeJson(
          key,
          PlanName(caseId: caseId, name: name).toJson(),
        );
      }
      _guard(generation);
      _planNameReads[caseId] = (_planNameReads[caseId] ?? 0) + 1;
      if (name == null) {
        _planNames.remove(caseId);
      } else {
        _planNames[caseId] = name;
      }
      _changed();
    });
  }

  Future<T> serialize<T>(Future<T> Function() action) {
    if (_signingOut) {
      return Future.error(StateError('Sign-out is in progress.'));
    }
    final selected = _selection;
    final next = _tail.then((_) async {
      _guard(selected);
      busy = true;
      _changed();
      try {
        return await action();
      } finally {
        busy = false;
        _changed();
      }
    });
    _tail = next.then<void>((_) {}, onError: (Object _, StackTrace stack) {});
    return next;
  }

  Future<void> withSignOutReservation(Future<void> Function() action) async {
    _guard();
    if (_signingOut || hasUndurableEdits) {
      throw StateError('Finish saving device changes before signing out.');
    }
    _signingOut = true;
    busy = true;
    _changed();
    try {
      await _tail;
      _guard();
      busy = true;
      _changed();
      await action();
    } finally {
      _signingOut = false;
      busy = false;
      _changed();
    }
  }

  Future<void> _persist() async {
    if (draft == null) return;
    _guard();
    final selected = _selection, write = ++_localWriteVersion;
    final key = 'case.${draft!.caseId}';
    final pendingName = _pendingInitialPlanName;
    final value = {
      'version': 1,
      'snapshot': snapshot?.toJson(),
      'draft': draft!.toJson(),
      'uncertain': uncertain,
      'conflict': conflict,
    };
    bool current() =>
        isCurrent && selected == _selection && write == _localWriteVersion;
    localWritePending = true;
    localSaveFailed = false;
    _changed();
    try {
      if (pendingName == null) {
        await store.writeJson(key, value);
      } else {
        await store.writeJson(key, {
          ...value,
          'pendingPlanName': pendingName.toJson(),
        });
        if (!current()) return;
        await store.writeJson(
          PlanName.storageKey(pendingName.caseId),
          pendingName.toJson(),
        );
        if (!current()) return;
        await nameSync?.retainInitial(pendingName.caseId, pendingName.name);
        if (!current()) return;
        await store.writeJson(key, value);
        if (current()) {
          _planNames[pendingName.caseId] = pendingName.name;
          _planNameReads[pendingName.caseId] =
              (_planNameReads[pendingName.caseId] ?? 0) + 1;
          _pendingInitialPlanName = null;
        }
      }
    } catch (_) {
      if (current()) localSaveFailed = true;
      rethrow;
    } finally {
      if (current()) {
        localWritePending = false;
        _changed();
      }
    }
  }

  Future<List<String>> localCaseIds() async => (await store.keys())
      .where((key) => key.startsWith('case.'))
      .map((key) => key.substring(5))
      .toList();
  Future<void> createDraft({String? name}) async {
    _guardCaseSelection();
    final normalizedName = normalizePlanName(name);
    _selection++;
    _edit++;
    localWritePending = false;
    localSaveFailed = false;
    snapshot = null;
    uncertain = false;
    conflict = false;
    notice = null;
    draft = CaseDraft.fromJson({
      'schemaVersion': '1',
      'caseId': newUuidV4(),
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
    });
    _knownPlanIds.add(draft!.caseId);
    _pendingInitialPlanName = normalizedName == null
        ? null
        : PlanName(caseId: draft!.caseId, name: normalizedName);
    _changed();
    await _persist();
  }

  Future<void> restoreLocal(String caseId) async {
    _guardCaseSelection();
    final generation = ++_selection;
    localWritePending = false;
    localSaveFailed = false;
    final value = await store.readJson('case.$caseId');
    _guard(generation);
    if (value == null || value['version'] != 1) {
      throw StateError('The local draft is unavailable.');
    }
    final loaded = CaseDraft.fromJson(value['draft']);
    if (loaded.caseId != caseId) {
      throw const FormatException('Invalid local case.');
    }
    final restoredSnapshot = value['snapshot'] == null
        ? null
        : parseCurrentCase(value['snapshot']);
    if (restoredSnapshot != null && restoredSnapshot.caseId != caseId) {
      throw const FormatException('Invalid local snapshot.');
    }
    final pendingName = _pendingNameFromRecord(caseId, value);
    draft = loaded;
    snapshot = restoredSnapshot;
    uncertain = value['uncertain'] == true;
    conflict = value['conflict'] == true;
    _pendingInitialPlanName = pendingName;
    localSaveFailed = _pendingInitialPlanName != null;
    _knownPlanIds.add(caseId);
    final nameLoaded = await _restoreOptionalPlanName(
      caseId,
      generation,
      value,
    );
    notice = nameLoaded
        ? 'Restored on this device. Check saved state before continuing.'
        : 'Restored on this device. Its custom name could not be loaded.';
    _edit++;
    _changed();
  }

  Future<void> resume(CaseSummary summary) async {
    _guardCaseSelection();
    final generation = ++_selection;
    localWritePending = false;
    localSaveFailed = false;
    snapshot = null;
    draft = null;
    _pendingInitialPlanName = null;
    notice = null;
    uncertain = false;
    conflict = false;
    _changed();
    final local = await store.readJson('case.${summary.caseId}');
    _guard(generation);
    if (local != null) {
      final restoredDraft = CaseDraft.fromJson(local['draft']);
      final restoredSnapshot = local['snapshot'] == null
          ? null
          : parseCurrentCase(local['snapshot']);
      if (local['version'] != 1 ||
          restoredDraft.caseId != summary.caseId ||
          (restoredSnapshot != null &&
              restoredSnapshot.caseId != summary.caseId)) {
        throw const FormatException('Invalid local plan.');
      }
      final pendingName = _pendingNameFromRecord(summary.caseId, local);
      draft = restoredDraft;
      snapshot = restoredSnapshot;
      uncertain = local['uncertain'] == true;
      conflict = local['conflict'] == true;
      _pendingInitialPlanName = pendingName;
    }
    _knownPlanIds.add(summary.caseId);
    final nameLoaded = await _restoreOptionalPlanName(
      summary.caseId,
      generation,
      local,
    );
    if (!nameLoaded) notice = 'This plan’s custom name could not be loaded.';
    final remote = await discovery.resumeCase(
      summary.caseId,
      minimumCaseRevision: summary.caseRevision,
      currentCaseId: () {
        _guard(generation);
        return summary.caseId;
      },
      currentCase: () => snapshot,
      isCurrent: () => isCurrent && generation == _selection,
    );
    _guard(generation);
    final edited = hasUnsavedChanges;
    final oldRevision = snapshot?.revision;
    snapshot = remote;
    if (!edited) {
      draft = CaseDraft.fromSnapshot(remote);
      uncertain = false;
      conflict = false;
    } else if (oldRevision != remote.revision) {
      conflict = true;
      notice =
          'The saved case changed. Compare it with your local edits before saving.';
    }
    _edit++;
    _changed();
    await _persist();
    await _syncNameAfterCaseSave(summary.caseId);
  }

  Future<void> updateDraft(CaseDraft value) async {
    _guard();
    if (_signingOut) throw StateError('Sign-out is in progress.');
    if (draft?.caseId != value.caseId) {
      throw StateError('This draft belongs to another case.');
    }
    draft = CaseDraft.fromJson(value.toJson());
    final edit = ++_edit, selected = _selection;
    notice = 'Saving changes on this device…';
    _changed();
    try {
      await _persist();
      if (isCurrent && selected == _selection && edit == _edit) {
        notice = 'Saved on this device; not yet saved online.';
        _changed();
      }
    } catch (_) {
      if (isCurrent && selected == _selection && edit == _edit) {
        notice =
            'The latest changes were not saved on this device. Keep this screen open and retry.';
        _changed();
      }
      rethrow;
    }
  }

  Future<void> retryDeviceSave() async {
    _guard();
    if (busy || localWritePending || draft == null) {
      throw StateError('Wait for the current case operation.');
    }
    final selected = _selection, edit = _edit;
    await _persist();
    _guard(selected);
    if (_edit != edit || localWritePending || localSaveFailed) return;
    notice = uncertain || conflict
        ? 'Saved on this device. Check the unresolved saved-state result before another online save.'
        : 'Saved on this device.';
    _changed();
  }

  Future<void> save() => serialize(() async {
    if (uncertain || conflict) {
      throw StateError(
        'Check saved state and resolve differences before saving again.',
      );
    }
    final generation = _selection, edit = _edit;
    final input = currentDraft();
    final prior = snapshot;
    uncertain = true;
    notice = 'Saving…';
    _changed();
    await _persist();
    try {
      final result = prior == null
          ? await cases.createCase(
              input,
              currentDraft: () {
                _guard(generation);
                return input;
              },
            )
          : await cases.saveCase(
              prior,
              replacement: input,
              currentCase: () {
                _guard(generation);
                return currentCase();
              },
              currentDraft: () {
                _guard(generation);
                return input;
              },
            );
      _guard(generation);
      snapshot = result;
      if (_edit == edit) draft = CaseDraft.fromSnapshot(result);
      uncertain = false;
      notice = hasUnsavedChanges
          ? 'Earlier changes saved online. Newer edits are kept on this device.'
          : 'Saved online.';
      _changed();
      await _persist();
      await _syncNameAfterCaseSave(input.caseId);
    } on MatchingApiException catch (error) {
      _guard(generation);
      uncertain = error.code == 'CASE_SAVE_UNCERTAIN';
      conflict =
          error.code == 'CASE_REVISION_MISMATCH' ||
          error.code == 'CASE_ID_UNAVAILABLE';
      notice = error.message;
      _changed();
      await _persist();
      rethrow;
    } catch (_) {
      notice =
          'The save could not be confirmed. Check saved state before trying again.';
      _changed();
      rethrow;
    }
  });
  Future<void> reconcile() => serialize(() async {
    final generation = _selection;
    final input = currentDraft();
    try {
      final remote = await cases.reloadCase(
        input.caseId,
        currentCaseId: () {
          _guard(generation);
          return input.caseId;
        },
        currentCase: () => snapshot,
      );
      _guard(generation);
      snapshot = remote;
      final same =
          jsonEncode(CaseDraft.fromSnapshot(remote).toJson()) ==
          jsonEncode(input.toJson());
      uncertain = false;
      conflict = !same;
      notice = same
          ? 'Your changes are saved online.'
          : 'The server and this device differ. Choose which version to keep.';
      if (same) draft = CaseDraft.fromSnapshot(remote);
      _changed();
      await _persist();
      await _syncNameAfterCaseSave(input.caseId);
    } on MatchingApiException catch (error) {
      if (error.code == 'CASE_NOT_FOUND' && snapshot == null) {
        uncertain = false;
        conflict = false;
        notice =
            'No saved case was found. You can retry saving this same draft.';
        _changed();
        await _persist();
        return;
      }
      rethrow;
    }
  });
  Future<void> resolveConflict({required bool keepLocal}) async {
    _guard();
    if (busy || snapshot == null) {
      throw StateError('Reload the saved case first.');
    }
    if (!keepLocal) draft = CaseDraft.fromSnapshot(snapshot!);
    uncertain = false;
    conflict = false;
    _edit++;
    notice = keepLocal
        ? 'Local edits retained. Review and save them explicitly.'
        : 'Using the saved version.';
    _changed();
    await _persist();
  }

  Future<void> adoptRemoteSnapshot(CaseSnapshot value) async {
    _guard();
    if (draft?.caseId != value.caseId ||
        (snapshot != null && value.revision < snapshot!.revision)) {
      throw MatchingApiException.forCode('STALE_RESPONSE');
    }
    final preserveLocal = hasUnsavedChanges;
    snapshot = value;
    if (!preserveLocal) {
      draft = CaseDraft.fromSnapshot(value);
    }
    uncertain = false;
    conflict = preserveLocal;
    if (preserveLocal) {
      notice =
          'A server operation completed while local edits changed. Review both versions.';
    }
    _edit++;
    _changed();
    await _persist();
  }

  Future<void> clearSelected() async {
    _guard();
    if (busy) throw StateError('Finish the current operation first.');
    final id = draft?.caseId;
    final generation = ++_selection;
    busy = true;
    localWritePending = false;
    localSaveFailed = false;
    snapshot = null;
    draft = null;
    _pendingInitialPlanName = null;
    uncertain = false;
    conflict = false;
    notice = null;
    _changed();
    final next = _tail.then((_) async {
      try {
        _guard(generation);
        if (id != null) {
          await _clearLocalCaseRecords(id, generation);
        }
      } finally {
        busy = false;
        _changed();
      }
    });
    _tail = next.then<void>((_) {}, onError: (Object _, StackTrace stack) {});
    await next;
  }

  Future<void> clearCaseLocally(String caseId) async {
    ExportContractValues.id(caseId);
    _guardCaseSelection();
    if (draft?.caseId == caseId) return clearSelected();
    final generation = _selection;
    await serialize(() => _clearLocalCaseRecords(caseId, generation));
  }

  Future<void> _clearLocalCaseRecords(String id, int generation) async {
    _planNameReads[id] = (_planNameReads[id] ?? 0) + 1;
    await nameSync?.forget(id);
    _guard(generation);
    final storedKeys = await store.keys();
    _guard(generation);
    final keys = storedKeys.where((key) => _belongsToCase(key, id)).toList();
    final knownIds = <String>{id};
    for (final key in storedKeys) {
      for (final prefix in [
        'case.',
        'case-delete.',
        'profile-edit.',
        'profile-response.',
        'plan-name.',
        'plan-name-sync.',
      ]) {
        if (key.startsWith(prefix)) knownIds.add(key.substring(prefix.length));
      }
    }
    for (final key in keys) {
      if (knownIds.any((other) => other != id && _belongsToCase(key, other))) {
        throw StateError('Local plan ownership needs recovery before cleanup.');
      }
    }
    keys.sort((a, b) {
      int rank(String key) => key == 'case-delete.$id'
          ? 2
          : key == 'case.$id'
          ? 1
          : 0;
      return rank(a).compareTo(rank(b));
    });
    for (final key in keys) {
      _guard(generation);
      await store.delete(key);
    }
    _guard(generation);
    _planNames.remove(id);
    _knownPlanIds.remove(id);
    _planNameReads[id] = (_planNameReads[id] ?? 0) + 1;
    _changed();
  }

  bool _belongsToCase(String key, String id) {
    if ([
      'case',
      'profile-edit',
      'profile-response',
      'case-delete',
      'plan-name',
      'plan-name-sync',
      'home-safety',
      'progress-cache',
      'progress-pending',
      'progress-edit',
      'local-help',
      'referral-import',
    ].any((prefix) => key == '$prefix.$id')) {
      return true;
    }
    if (key.startsWith('assessment:$id:')) return true;
    if (key.startsWith('assistant-history.$id.')) return true;
    return [
      'form',
      'intake',
      'history',
      'history-edit',
      'export',
      'annotation-review',
    ].any((prefix) => key.startsWith('$prefix.$id.'));
  }

  @override
  void dispose() {
    _disposed = true;
    _selection++;
    super.dispose();
  }
}
