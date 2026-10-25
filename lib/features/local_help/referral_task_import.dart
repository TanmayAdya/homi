import 'dart:convert';
import 'package:crypto/crypto.dart';
import '../../app/live_app.dart';
import '../../features/tracking/progress_models.dart';
import '../../shared/models/export_contract_values.dart';
import 'local_help_record.dart';
import 'local_help_repository.dart';

String referralSourceHash(HelpFollowUp source) =>
    hashReferralOriginal(source.toJson());
String referralImportTaskId(String caseId, String sourceId) =>
    'referral-import-${sha256.convert(utf8.encode('$caseId\u0000$sourceId'))}';

class ReferralTaskImport {
  ReferralTaskImport(this.services, this.local);
  final AppServices services;
  final LocalHelpRepository local;
  String get receiptKey => 'referral-import.${local.caseId}';
  void _guard() {
    if (!services.config.localHelpEnabled ||
        !local.isCurrent ||
        services.coordinator.hasUnsavedChanges ||
        services.coordinator.uncertain ||
        services.coordinator.conflict ||
        services.coordinator.snapshot?.caseId != local.caseId ||
        services.progress == null ||
        !services.progress!.api.includeReferrals) {
      throw StateError('Save and reconcile this plan before importing.');
    }
  }

  Future<Map<String, Object?>> receipts() async {
    if (!local.isCurrent) throw StateError('Plan changed.');
    final raw = await services.store.readJson(receiptKey);
    if (!local.isCurrent) throw StateError('Plan changed.');
    if (raw == null) return {};
    final value = ExportContractValues.object(raw, {
      'schemaVersion',
      'caseId',
      'receipts',
    });
    if (value['schemaVersion'] != '1' ||
        value['caseId'] != local.caseId ||
        value['receipts'] is! Map) {
      throw const FormatException('Invalid referral import receipt.');
    }
    final result = Map<String, Object?>.from(value['receipts'] as Map);
    if (result.length > 100) throw const FormatException();
    for (final entry in result.entries) {
      ExportContractValues.id(entry.key);
      final receipt = ExportContractValues.object(entry.value, {
        'taskId',
        'sourceHash',
      });
      ExportContractValues.id(receipt['taskId']);
      ExportContractValues.digest(receipt['sourceHash']);
    }
    return result;
  }

  Future<NextStepTask> import(
    HelpFollowUp source, {
    required bool keepDueDate,
    String? confirmedContactNote,
  }) => services.coordinator.serialize(() async {
    _guard();
    await services.progressReady;
    _guard();
    final raw = await services.store.readJson(local.key);
    _guard();
    if (raw == null) throw StateError('Local follow-up no longer exists.');
    final saved = LocalHelpRecord.fromJson(raw);
    final current = saved.tasks.where((t) => t.id == source.id).firstOrNull;
    final hash = referralSourceHash(source);
    if (saved.caseId != local.caseId ||
        current == null ||
        referralSourceHash(current) != hash) {
      throw StateError('Local follow-up changed. Reopen it before importing.');
    }
    final currentNote =
        saved.contacts
            .where((c) => c.providerId == source.providerId)
            .firstOrNull
            ?.note ??
        '';
    if (confirmedContactNote != null && confirmedContactNote != currentNote) {
      throw StateError('The contact note changed. Review the import again.');
    }
    final progress = services.progress!;
    var state = await progress.refresh(local.caseId);
    _guard();
    NextStepTask? received() => state.tasks
        .where(
          (t) =>
              t.referral?['imported'] is Map &&
              (t.referral!['imported'] as Map)['sourceTaskId'] == source.id,
        )
        .firstOrNull;
    var task = received();
    final taskId = referralImportTaskId(local.caseId, source.id);
    final pending = progress.pending[local.caseId];
    if (pending != null) {
      final operation = pending['operation'] as Map?;
      final candidate = operation?['task'] as Map?;
      final referral = candidate?['referral'] as Map?;
      final imported = referral?['imported'] as Map?;
      if (operation?['type'] != 'put_task' ||
          candidate?['id'] != taskId ||
          imported?['sourceHash'] != hash) {
        throw StateError('Review the pending task save in My next steps.');
      }
      state = await progress.retry(local.caseId);
      _guard();
      task = received();
    }
    if (task == null) {
      final findingPresent = services.coordinator.currentCase().findings.any(
        (f) => f.id == source.findingId,
      );
      final note = confirmedContactNote ?? '';
      state = await progress.mutate(
        local.caseId,
        services.coordinator.currentCase().revision,
        {
          'type': 'put_task',
          'expectedTaskRevision': 0,
          'task': {
            'id': taskId,
            'programId': null,
            'findingId': findingPresent ? source.findingId : null,
            'formId': null,
            'title': source.title,
            'kind': 'follow_up',
            'state': source.completedAt == null ? 'pending' : 'completed',
            'responsiblePerson': source.responsible.isEmpty
                ? null
                : source.responsible,
            'dueOn': keepDueDate ? source.dueDate : null,
            'basedOnCaseRevision': services.coordinator.currentCase().revision,
            'basedOnRuleVersion': null,
            'revision': 1,
            'sourceEventId': null,
            'referral': {
              'providerId': source.providerId,
              'imported': {
                'sourceTaskId': source.id,
                'sourceHash': hash,
                'original': source.toJson(),
                'contactNote': note,
              },
            },
          },
        },
      );
      _guard();
      task = received();
    }
    if (task == null ||
        (task.referral!['imported'] as Map)['sourceHash'] != hash) {
      throw StateError('An earlier import differs. Review the saved task.');
    }
    final previous = await receipts();
    _guard();
    await services.store.writeJson(receiptKey, {
      'schemaVersion': '1',
      'caseId': local.caseId,
      'receipts': {
        ...previous,
        source.id: {'taskId': task.id, 'sourceHash': hash},
      },
    });
    _guard();
    return task;
  });
}
