import 'dart:convert';

import 'export_contract_values.dart';

class CaseListRequest {
  factory CaseListRequest({int limit = 20, String? afterCaseId}) =>
      CaseListRequest.fromJson({
        'schemaVersion': '1',
        'limit': limit,
        'afterCaseId': afterCaseId,
      });

  factory CaseListRequest.fromJson(Object? json) {
    final value = ExportContractValues.object(json, {
      'schemaVersion',
      'limit',
      'afterCaseId',
    });
    if (value['schemaVersion'] != '1') ExportContractValues.invalid();
    return CaseListRequest._(
      ExportContractValues.integer(value['limit'], max: 20),
      value['afterCaseId'] == null
          ? null
          : ExportContractValues.id(value['afterCaseId']),
    );
  }
  const CaseListRequest._(this.limit, this.afterCaseId);
  final int limit;
  final String? afterCaseId;
  String get schemaVersion => '1';
  Map<String, Object?> toJson() => {
    'schemaVersion': schemaVersion,
    'limit': limit,
    'afterCaseId': afterCaseId,
  };
}

class CaseSummary {
  factory CaseSummary.fromJson(Object? json) {
    final value = ExportContractValues.object(json, {'caseId', 'caseRevision'});
    return CaseSummary._(
      ExportContractValues.id(value['caseId']),
      ExportContractValues.integer(value['caseRevision']),
    );
  }
  const CaseSummary._(this.caseId, this.caseRevision);
  final String caseId;
  final int caseRevision;
  Map<String, Object?> toJson() => {
    'caseId': caseId,
    'caseRevision': caseRevision,
  };
}

class CaseListPage {
  factory CaseListPage.fromJson(
    Object? json, {
    required CaseListRequest request,
  }) {
    final value = ExportContractValues.object(json, {
      'schemaVersion',
      'cases',
      'nextAfterCaseId',
    });
    if (value['schemaVersion'] != '1') ExportContractValues.invalid();
    final cases = ExportContractValues.list(
      value['cases'],
      CaseSummary.fromJson,
      request.limit,
    );
    final next = value['nextAfterCaseId'] == null
        ? null
        : ExportContractValues.id(value['nextAfterCaseId']);
    String? previous = request.afterCaseId;
    for (final summary in cases) {
      if (previous != null && _compareUtf8(previous, summary.caseId) >= 0) {
        ExportContractValues.invalid();
      }
      previous = summary.caseId;
    }
    if (next != null &&
        (cases.length != request.limit ||
            cases.isEmpty ||
            next != cases.last.caseId)) {
      ExportContractValues.invalid();
    }
    return CaseListPage._(cases, next);
  }
  const CaseListPage._(this.cases, this.nextAfterCaseId);
  final List<CaseSummary> cases;
  final String? nextAfterCaseId;
  String get schemaVersion => '1';
  Map<String, Object?> toJson() => {
    'schemaVersion': schemaVersion,
    'cases': cases.map((value) => value.toJson()).toList(),
    'nextAfterCaseId': nextAfterCaseId,
  };
}

int _compareUtf8(String left, String right) {
  final a = utf8.encode(left), b = utf8.encode(right);
  final length = a.length < b.length ? a.length : b.length;
  for (var index = 0; index < length; index++) {
    final difference = a[index] - b[index];
    if (difference != 0) return difference;
  }
  return a.length - b.length;
}
