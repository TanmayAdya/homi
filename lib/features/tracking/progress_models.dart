import '../local_help/local_help_record.dart';
import '../../shared/models/export_contract_values.dart';
import '../../shared/models/request_tracking.dart';

const taskStates = [
  'pending',
  'in_progress',
  'blocked',
  'completed',
  'cancelled',
];
const taskKinds = [
  'profile',
  'room_review',
  'documents',
  'contact',
  'draft_review',
  'follow_up',
  'other',
];
String progressDate(Object? value) {
  if (value is! String ||
      !RegExp(r'^[0-9]{4}-[0-9]{2}-[0-9]{2}$').hasMatch(value)) {
    ExportContractValues.invalid();
  }
  final date = DateTime.tryParse(value);
  if (date == null ||
      date.year < 1 ||
      date.toIso8601String().substring(0, 10) != value) {
    ExportContractValues.invalid();
  }
  return value;
}

class NextStepTask {
  NextStepTask.fromJson(Object? raw) {
    final v = ExportContractValues.object(raw, {
      if (raw is Map && raw.containsKey('referral')) 'referral',
      'id',
      'programId',
      'findingId',
      'formId',
      'title',
      'kind',
      'state',
      'responsiblePerson',
      'dueOn',
      'basedOnCaseRevision',
      'basedOnRuleVersion',
      'revision',
      'sourceEventId',
      'needsReview',
    });
    for (final key in ['id', 'title']) {
      ExportContractValues.id(v[key]);
    }
    for (final key in [
      'programId',
      'findingId',
      'formId',
      'responsiblePerson',
      'basedOnRuleVersion',
      'sourceEventId',
    ]) {
      if (v[key] != null) ExportContractValues.id(v[key]);
    }
    if (!taskStates.contains(v['state']) ||
        !taskKinds.contains(v['kind']) ||
        v['needsReview'] is! bool) {
      ExportContractValues.invalid();
    }
    if (v['dueOn'] != null) progressDate(v['dueOn']);
    ExportContractValues.integer(v['basedOnCaseRevision']);
    ExportContractValues.integer(v['revision']);
    if ((v['title'] as String).runes.length > 200 ||
        (v['responsiblePerson'] as String? ?? '').runes.length > 100) {
      ExportContractValues.invalid();
    }
    if (v.containsKey('referral')) {
      final ref = ExportContractValues.object(v['referral'], {
        'providerId',
        if (v['referral'] is Map &&
            (v['referral'] as Map).containsKey('imported'))
          'imported',
      });
      ExportContractValues.id(ref['providerId']);
      if (ref.containsKey('imported')) {
        final imported = ExportContractValues.object(ref['imported'], {
          'sourceTaskId',
          'sourceHash',
          'contactNote',
          'original',
        });
        ExportContractValues.id(imported['sourceTaskId']);
        ExportContractValues.digest(imported['sourceHash']);
        helpText(imported['contactNote'], empty: true);
        final original = HelpFollowUp.fromJson(imported['original']);
        if (original.id != imported['sourceTaskId'] ||
            original.providerId != ref['providerId'] ||
            hashReferralOriginal(original.toJson()) != imported['sourceHash']) {
          ExportContractValues.invalid();
        }
        ref['imported'] = Map<String, Object?>.unmodifiable({
          ...imported,
          'original': Map<String, Object?>.unmodifiable(original.toJson()),
        });
      }
      v['referral'] = Map<String, Object?>.unmodifiable(ref);
    }
    data = Map.unmodifiable(v);
  }
  late final Map<String, Object?> data;
  Map<String, Object?>? get referral =>
      data['referral'] as Map<String, Object?>?;
  String? get referralId => referral?['providerId'] as String?;
  String get id => data['id'] as String;
  String get title => data['title'] as String;
  String get state => data['state'] as String;
  String get kind => data['kind'] as String;
  String? get programId => data['programId'] as String?;
  String? get dueOn => data['dueOn'] as String?;
  String? get responsiblePerson => data['responsiblePerson'] as String?;
  int get revision => data['revision'] as int;
  bool get needsReview => data['needsReview'] as bool;
  bool get open => !{'completed', 'cancelled'}.contains(state);
  Map<String, Object?> toJson() => {...data}..remove('needsReview');
}

class TrackedProgram {
  TrackedProgram.fromJson(Object? raw) {
    final v = ExportContractValues.object(raw, {
      'programId',
      'name',
      'trackedAt',
      'trackedBy',
      'latest',
      'proposal',
      'retired',
      'ruleVersion',
      'unresolvedRequirements',
      'requirements',
    });
    id = ExportContractValues.id(v['programId']);
    name = ExportContractValues.id(v['name']);
    if (v['retired'] is! bool ||
        v['trackedAt'] is! String ||
        v['trackedBy'] is! String) {
      ExportContractValues.invalid();
    }
    retired = v['retired'] as bool;
    ruleVersion = v['ruleVersion'] == null
        ? null
        : ExportContractValues.id(v['ruleVersion']);
    unresolved = ExportContractValues.integer(
      v['unresolvedRequirements'],
      min: 0,
      max: 128,
    );
    requirements = v['requirements'] == null
        ? null
        : ExportContractValues.list(v['requirements'], (r) {
            final c = ExportContractValues.object(r, {
              'id',
              'status',
              'explanation',
            });
            ExportContractValues.id(c['id']);
            ExportContractValues.id(c['explanation']);
            if (!{'fail', 'unknown'}.contains(c['status'])) {
              ExportContractValues.invalid();
            }
            return Map<String, Object?>.unmodifiable(c);
          }, 64);
    latest = v['latest'] == null ? null : parseProgressReport(v['latest']);
    proposal = v['proposal'] == null
        ? null
        : Map<String, Object?>.unmodifiable(v['proposal'] as Map);
  }
  late final String id, name;
  late final bool retired;
  late final String? ruleVersion;
  late final int unresolved;
  late final List<Map<String, Object?>>? requirements;
  late final Map<String, Object?>? latest, proposal;
}

class ProgressPage {
  ProgressPage.fromJson(Object? raw) {
    final v = ExportContractValues.object(raw, {
      'schemaVersion',
      'caseId',
      'caseRevision',
      'revision',
      'programs',
      'tasks',
      'nextOffset',
      'acknowledgedMutationId',
      'historyVersion',
    });
    if (v['schemaVersion'] != '3') ExportContractValues.invalid();
    caseId = ExportContractValues.id(v['caseId']);
    historyVersion = ExportContractValues.digest(v['historyVersion']);
    caseRevision = ExportContractValues.integer(v['caseRevision']);
    revision = ExportContractValues.integer(v['revision'], min: 0, max: 500);
    programs = ExportContractValues.list(
      v['programs'],
      TrackedProgram.fromJson,
      20,
    );
    tasks = ExportContractValues.list(v['tasks'], NextStepTask.fromJson, 20);
    nextOffset = v['nextOffset'] == null
        ? null
        : ExportContractValues.integer(v['nextOffset'], max: 500);
    acknowledgement = v['acknowledgedMutationId'] == null
        ? null
        : ExportContractValues.id(v['acknowledgedMutationId']);
    ExportContractValues.unique(programs.map((p) => p.id));
    ExportContractValues.unique(tasks.map((t) => t.id));
    json = Map.unmodifiable(v);
  }
  late final String caseId, historyVersion;
  late final int caseRevision, revision;
  late final int? nextOffset;
  late final String? acknowledgement;
  late final List<TrackedProgram> programs;
  late final List<NextStepTask> tasks;
  late final Map<String, Object?> json;
}

Map<String, Object?> parseProgressReport(Object? raw) {
  final v = ExportContractValues.object(raw, {
    'updateId',
    'status',
    'occurredOn',
    'source',
    'note',
    'nextAction',
    'responsibleParty',
    'followUpOn',
    'revision',
    'caseRevision',
    'recordedAt',
    'recordedBy',
  });
  RequestUpdate.fromJson({
    for (final key in [
      'updateId',
      'status',
      'occurredOn',
      'source',
      'note',
      'nextAction',
      'responsibleParty',
      'followUpOn',
    ])
      key: v[key],
  });
  ExportContractValues.integer(v['revision'], max: 500);
  ExportContractValues.integer(v['caseRevision']);
  ExportContractValues.instant(v['recordedAt']);
  if (v['recordedBy'] != null) ExportContractValues.id(v['recordedBy']);
  return Map.unmodifiable(v);
}
