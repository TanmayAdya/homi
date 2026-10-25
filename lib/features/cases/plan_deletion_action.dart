import 'dart:convert';

import '../../app/live_app.dart';
import '../../shared/models/contracts.dart';
import '../../shared/models/export_contract_values.dart';
import '../../shared/services/matching_api_client.dart';
import 'case_display_details.dart';

class PlanRemovalStatus {
  const PlanRemovalStatus({
    required this.caseId,
    this.serverDeleted = false,
    this.localOnly = false,
  });

  factory PlanRemovalStatus.fromRecord(
    String caseId,
    Map<String, Object?>? record,
  ) => PlanRemovalStatus(
    caseId: caseId,
    serverDeleted: record?.length == 1 && record?['serverDeleted'] == true,
    localOnly: record?.length == 1 && record?['localOnly'] == true,
  );

  final String caseId;
  final bool serverDeleted, localOnly;
}

Future<Map<String, PlanRemovalStatus>> readPendingPlanRemovals(
  AppServices services,
) async {
  void guard() {
    if (!services.coordinator.isCurrent) {
      throw MatchingApiException.forCode('STALE_RESPONSE');
    }
  }

  guard();
  final keys = await services.store.keys();
  guard();
  final result = <String, PlanRemovalStatus>{};
  for (final key in keys.where((key) => key.startsWith('case-delete.'))) {
    final id = key.substring('case-delete.'.length);
    try {
      ExportContractValues.id(id);
    } on FormatException {
      continue;
    }
    Map<String, Object?>? receipt;
    try {
      receipt = await services.store.readJson(key);
    } catch (_) {
      guard();
      result[id] = PlanRemovalStatus(caseId: id);
      continue;
    }
    guard();
    if (receipt != null) {
      result[id] = PlanRemovalStatus.fromRecord(id, receipt);
    }
  }
  return result;
}

class PlanDeletionAction {
  PlanDeletionAction({
    required this.services,
    required this.caseId,
    this.minimumCaseRevision,
  }) : _generation = services.coordinator.generation {
    ExportContractValues.id(caseId);
    if (minimumCaseRevision != null) {
      ExportContractValues.integer(minimumCaseRevision);
    }
  }

  final AppServices services;
  final String caseId;
  final int? minimumCaseRevision;
  final int _generation;
  bool _disposed = false;
  bool ready = false;
  bool pending = false;
  bool localOnly = false;
  bool absentOnline = false;
  CaseSnapshot? _snapshot;
  String? _localRecord;

  bool get isCurrent =>
      !_disposed &&
      services.coordinator.isCurrent &&
      services.coordinator.generation == _generation;

  void _guard() {
    if (!isCurrent) throw MatchingApiException.forCode('STALE_RESPONSE');
  }

  void dispose() => _disposed = true;

  Future<void> prepare() async {
    _guard();
    ready = false;
    Map<String, Object?>? receipt;
    try {
      receipt = await services.store.readJson('case-delete.$caseId');
    } catch (_) {
      _guard();
      pending = (await services.store.keys()).contains('case-delete.$caseId');
      _guard();
      if (pending) return;
      rethrow;
    }
    _guard();
    pending = receipt != null;
    if (pending) {
      return;
    }
    final record = await services.store.readJson('case.$caseId');
    _guard();
    final details = record == null
        ? null
        : CaseDisplayDetails.fromRecord(caseId, record);
    _localRecord = jsonEncode(record);
    _snapshot = details?.snapshot;
    localOnly =
        details != null &&
        details.snapshot == null &&
        !details.uncertain &&
        !details.conflict &&
        minimumCaseRevision == null;
    if (!localOnly) await _readRemote();
    _guard();
    ready = true;
  }

  Future<void> _readRemote() async {
    var minimum = minimumCaseRevision ?? 1;
    if (_snapshot != null && _snapshot!.revision > minimum) {
      minimum = _snapshot!.revision;
    }
    try {
      _snapshot = await services.discovery.resumeCase(
        caseId,
        minimumCaseRevision: minimum,
        currentCaseId: () => caseId,
        currentCase: () => _snapshot,
        isCurrent: () => isCurrent,
      );
      _guard();
      absentOnline = false;
    } on MatchingApiException catch (error) {
      _guard();
      if (error.code != 'CASE_NOT_FOUND') rethrow;
      absentOnline = true;
      _snapshot = null;
    }
  }

  Future<bool> checkPending() async {
    _guard();
    if (!pending) return false;
    Map<String, Object?>? receipt;
    try {
      receipt = await services.store.readJson('case-delete.$caseId');
    } catch (_) {
      _guard();
    }
    _guard();
    final status = PlanRemovalStatus.fromRecord(caseId, receipt);
    if (status.localOnly || status.serverDeleted) {
      await services.progress?.forget(caseId);
      await services.coordinator.clearCaseLocally(caseId);
      return true;
    }
    await _readRemote();
    _guard();
    if (absentOnline) {
      await services.progress?.forget(caseId);
      await services.coordinator.clearCaseLocally(caseId);
      return true;
    }
    _localRecord = jsonEncode(await services.store.readJson('case.$caseId'));
    _guard();
    await services.store.delete('case-delete.$caseId');
    _guard();
    pending = false;
    ready = true;
    return false;
  }

  Future<void> deleteConfirmed() async {
    _guard();
    if (!ready || pending) {
      throw StateError('Check this plan before removing it.');
    }
    await services.coordinator.serialize(() async {
      _guard();
      if (services.coordinator.hasUndurableEdits) {
        throw StateError('Finish saving device changes first.');
      }
      final current = await services.store.readJson('case.$caseId');
      _guard();
      if (jsonEncode(current) != _localRecord) {
        ready = false;
        throw MatchingApiException.forCode('STALE_RESPONSE');
      }
      if (localOnly || absentOnline) {
        await services.store.writeJson('case-delete.$caseId', {
          'localOnly': true,
        });
        _guard();
        pending = true;
        return;
      }
      final snapshot = _snapshot!;
      final catalog = await services.exports.listEvidence(
        snapshot,
        currentCase: () {
          _guard();
          return snapshot;
        },
        currentCatalog: () => null,
      );
      _guard();
      await services.store.writeJson('case-delete.$caseId', {
        'snapshot': snapshot.toJson(),
        'catalogRevision': catalog.catalogRevision,
      });
      _guard();
      pending = true;
      await services.progress?.forget(caseId);
      await services.lifecycle.deleteCase(
        snapshot,
        expectedCatalogRevision: catalog.catalogRevision,
        isCurrent: () => isCurrent,
      );
      _guard();
      await services.store.writeJson('case-delete.$caseId', {
        'serverDeleted': true,
      });
      _guard();
    });
    _guard();
    await services.progress?.forget(caseId);
    await services.coordinator.clearCaseLocally(caseId);
  }
}
