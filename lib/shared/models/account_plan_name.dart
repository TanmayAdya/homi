import 'case_list.dart';
import 'export_contract_values.dart';
import 'plan_name.dart';

class AccountPlanName {
  factory AccountPlanName({
    required String caseId,
    required String? name,
    required int nameRevision,
    required String? lastMutationId,
  }) => AccountPlanName.fromJson({
    'schemaVersion': '2',
    'caseId': caseId,
    'name': name,
    'nameRevision': nameRevision,
    'lastMutationId': lastMutationId,
  });

  factory AccountPlanName.initial(String caseId) => AccountPlanName(
    caseId: caseId,
    name: null,
    nameRevision: 0,
    lastMutationId: null,
  );

  factory AccountPlanName.fromJson(Object? json) {
    final value = ExportContractValues.object(json, {
      'schemaVersion',
      'caseId',
      'name',
      'nameRevision',
      'lastMutationId',
    });
    if (value['schemaVersion'] != '2') ExportContractValues.invalid();
    final revision = ExportContractValues.integer(
      value['nameRevision'],
      min: 0,
    );
    final name = _canonicalName(value['name']);
    final mutation = value['lastMutationId'] == null
        ? null
        : ExportContractValues.id(value['lastMutationId']);
    if ((revision == 0 && (name != null || mutation != null)) ||
        (revision > 0 && mutation == null)) {
      ExportContractValues.invalid();
    }
    return AccountPlanName._(
      ExportContractValues.id(value['caseId']),
      name,
      revision,
      mutation,
    );
  }

  const AccountPlanName._(
    this.caseId,
    this.name,
    this.nameRevision,
    this.lastMutationId,
  );
  final String caseId;
  final String? name, lastMutationId;
  final int nameRevision;

  Map<String, Object?> toJson() => {
    'schemaVersion': '2',
    'caseId': caseId,
    'name': name,
    'nameRevision': nameRevision,
    'lastMutationId': lastMutationId,
  };
}

class PlanNameSaveRequest {
  factory PlanNameSaveRequest({
    required String caseId,
    required int expectedNameRevision,
    required String mutationId,
    required String? name,
  }) => PlanNameSaveRequest.fromJson({
    'schemaVersion': '2',
    'caseId': caseId,
    'expectedNameRevision': expectedNameRevision,
    'mutationId': mutationId,
    'name': name,
  });

  factory PlanNameSaveRequest.fromJson(Object? json) {
    final value = ExportContractValues.object(json, {
      'schemaVersion',
      'caseId',
      'expectedNameRevision',
      'mutationId',
      'name',
    });
    if (value['schemaVersion'] != '2') ExportContractValues.invalid();
    return PlanNameSaveRequest._(
      ExportContractValues.id(value['caseId']),
      ExportContractValues.integer(
        value['expectedNameRevision'],
        min: 0,
        max: ExportContractValues.maxInteger - 1,
      ),
      ExportContractValues.id(value['mutationId']),
      _canonicalName(value['name']),
    );
  }

  const PlanNameSaveRequest._(
    this.caseId,
    this.expectedNameRevision,
    this.mutationId,
    this.name,
  );
  final String caseId, mutationId;
  final String? name;
  final int expectedNameRevision;

  Map<String, Object?> toJson() => {
    'schemaVersion': '2',
    'caseId': caseId,
    'expectedNameRevision': expectedNameRevision,
    'mutationId': mutationId,
    'name': name,
  };
}

class NamedCaseSummary {
  factory NamedCaseSummary.fromJson(Object? json) {
    final value = ExportContractValues.object(json, {
      'caseId',
      'caseRevision',
      'name',
      'nameRevision',
      'lastMutationId',
    });
    final summary = CaseSummary.fromJson({
      'caseId': value['caseId'],
      'caseRevision': value['caseRevision'],
    });
    final name = AccountPlanName.fromJson({
      'schemaVersion': '2',
      'caseId': value['caseId'],
      'name': value['name'],
      'nameRevision': value['nameRevision'],
      'lastMutationId': value['lastMutationId'],
    });
    return NamedCaseSummary._(summary, name);
  }

  const NamedCaseSummary._(this.summary, this.planName);
  final CaseSummary summary;
  final AccountPlanName planName;
  String get caseId => summary.caseId;
  int get caseRevision => summary.caseRevision;
  String? get name => planName.name;
  int get nameRevision => planName.nameRevision;
  String? get lastMutationId => planName.lastMutationId;

  Map<String, Object?> toJson() => {
    ...summary.toJson(),
    'name': name,
    'nameRevision': nameRevision,
    'lastMutationId': lastMutationId,
  };
}

class NamedCaseListPage {
  factory NamedCaseListPage.fromJson(
    Object? json, {
    int limit = 20,
    String? afterCaseId,
  }) {
    final request = CaseListRequest(limit: limit, afterCaseId: afterCaseId);
    final value = ExportContractValues.object(json, {
      'schemaVersion',
      'cases',
      'nextAfterCaseId',
    });
    if (value['schemaVersion'] != '2') ExportContractValues.invalid();
    final cases = ExportContractValues.list(
      value['cases'],
      NamedCaseSummary.fromJson,
      limit,
    );
    final page = CaseListPage.fromJson({
      'schemaVersion': '1',
      'cases': cases.map((item) => item.summary.toJson()).toList(),
      'nextAfterCaseId': value['nextAfterCaseId'],
    }, request: request);
    return NamedCaseListPage._(cases, page.nextAfterCaseId);
  }

  const NamedCaseListPage._(this.cases, this.nextAfterCaseId);
  final List<NamedCaseSummary> cases;
  final String? nextAfterCaseId;

  Map<String, Object?> toJson() => {
    'schemaVersion': '2',
    'cases': cases.map((item) => item.toJson()).toList(),
    'nextAfterCaseId': nextAfterCaseId,
  };
}

String? _canonicalName(Object? value) {
  if (value == null) return null;
  if (value is! String) ExportContractValues.invalid();
  final name = normalizePlanName(value);
  if (name == null || name != value) ExportContractValues.invalid();
  return name;
}
