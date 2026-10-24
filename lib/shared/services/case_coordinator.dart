import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import '../models/case_draft.dart';
import '../models/case_list.dart';
import '../models/contracts.dart';
import 'case_discovery_api_client.dart';
import 'case_evidence_api_client.dart';
import 'local_private_store.dart';
import 'matching_api_client.dart';
import 'session_service.dart';

class CaseCoordinator extends ChangeNotifier {
  CaseCoordinator({
    required this.session,
    required this.store,
    required this.cases,
    required this.discovery,
  }) {
    _accountEpoch = session.epoch;
  }
  final SessionService session;
  final LocalPrivateStore store;
  final CaseEvidenceApiClient cases;
  final CaseDiscoveryApiClient discovery;
  late final int _accountEpoch;
  CaseSnapshot? snapshot;
  CaseDraft? draft;
  bool uncertain = false, conflict = false, busy = false;
  bool localWritePending = false, localSaveFailed = false;
  String? notice;
  int _selection = 0, _edit = 0, _localWriteVersion = 0;
  Future<void> _tail = Future.value();
  bool _disposed = false;
  int get generation => _selection;
  bool get isCurrent =>
      !_disposed &&
      session.epoch == _accountEpoch &&
      session.userId == store.accountId;
  bool get hasUndurableEdits => localWritePending || localSaveFailed;
  void _guardCaseSelection() {
    _guard();
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

  Future<T> serialize<T>(Future<T> Function() action) {
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

  Future<void> _persist() async {
    if (draft == null) return;
    _guard();
    final selected = _selection, write = ++_localWriteVersion;
    final key = 'case.${draft!.caseId}';
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
      await store.writeJson(key, value);
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
  Future<void> createDraft() async {
    _guardCaseSelection();
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
    draft = loaded;
    snapshot = value['snapshot'] == null
        ? null
        : parseCurrentCase(value['snapshot']);
    if (snapshot != null && snapshot!.caseId != caseId) {
      throw const FormatException('Invalid local snapshot.');
    }
    uncertain = value['uncertain'] == true;
    conflict = value['conflict'] == true;
    notice = 'Restored on this device. Check saved state before continuing.';
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
    notice = null;
    uncertain = false;
    conflict = false;
    _changed();
    final local = await store.readJson('case.${summary.caseId}');
    _guard(generation);
    if (local != null) {
      draft = CaseDraft.fromJson(local['draft']);
      snapshot = local['snapshot'] == null
          ? null
          : parseCurrentCase(local['snapshot']);
      uncertain = local['uncertain'] == true;
      conflict = local['conflict'] == true;
    }
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
  }

  Future<void> updateDraft(CaseDraft value) async {
    _guard();
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
                return currentDraft();
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
                return currentDraft();
              },
            );
      _guard(generation);
      snapshot = result;
      if (_edit == edit) draft = CaseDraft.fromSnapshot(result);
      uncertain = false;
      notice = 'Saved online.';
      _changed();
      await _persist();
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
    uncertain = false;
    conflict = false;
    notice = null;
    _changed();
    final next = _tail.then((_) async {
      try {
        _guard(generation);
        if (id != null) {
          for (final key in await store.keys()) {
            _guard(generation);
            if (key.split('.').contains(id) ||
                key.startsWith('assessment:$id:')) {
              await store.delete(key);
            }
          }
        }
      } finally {
        busy = false;
        _changed();
      }
    });
    _tail = next.then<void>((_) {}, onError: (Object _, StackTrace stack) {});
    await next;
  }

  @override
  void dispose() {
    _disposed = true;
    _selection++;
    super.dispose();
  }
}
