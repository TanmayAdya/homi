import 'dart:convert';
import 'dart:math';

import 'contracts.dart';
import 'export_contract_values.dart';

const maxSavedCaseBytes = 12 * 1024;

String newUuidV4() {
  final random = Random.secure();
  final bytes = List.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex = bytes
      .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
      .join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

bool isCaseUuidV4(String value) =>
    RegExp(
      r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
    ).stringMatch(value) ==
    value;

class CaseDraft {
  CaseDraft._(this._snapshot);
  factory CaseDraft.fromJson(Object? json) {
    final value = ExportContractValues.object(json, {
      'schemaVersion',
      'caseId',
      'profile',
      'unresolvedFields',
      'findings',
    });
    return CaseDraft._(parseWritableCase({...value, 'revision': 1}));
  }
  factory CaseDraft.fromSnapshot(CaseSnapshot snapshot) {
    final json = snapshot.toJson()..remove('revision');
    return CaseDraft.fromJson(json);
  }
  final CaseSnapshot _snapshot;
  String get schemaVersion => '1';
  String get caseId => _snapshot.caseId;
  CaseProfile get profile => _snapshot.profile;
  List<String> get unresolvedFields => _snapshot.unresolvedFields;
  List<Finding> get findings => _snapshot.findings;
  Map<String, Object?> toJson() => _snapshot.toJson()..remove('revision');
  CaseSnapshot atRevision(int revision) =>
      parseWritableCase({...toJson(), 'revision': revision});
  Map<String, Object?> toCreateRequest() {
    if (!isCaseUuidV4(caseId)) ExportContractValues.invalid();
    atRevision(1);
    return toJson();
  }

  Map<String, Object?> toSaveRequest(int expectedRevision) {
    ExportContractValues.integer(
      expectedRevision,
      max: ExportContractValues.maxInteger - 1,
    );
    atRevision(expectedRevision + 1);
    return {...toJson(), 'expectedCaseRevision': expectedRevision};
  }
}

CaseSnapshot parseWritableCase(Object? json) =>
    _parseCase(json, maxSavedCaseBytes);

CaseSnapshot parseCurrentCase(Object? json) =>
    _parseCase(json, maxSavedCaseBytes + 15);

CaseSnapshot _parseCase(Object? json, int maximumBytes) {
  final snapshot = CaseSnapshot.fromJson(json);
  ExportContractValues.id(snapshot.caseId);
  ExportContractValues.integer(snapshot.revision);
  for (final value in [
    snapshot.profile.city,
    snapshot.profile.county,
    snapshot.profile.healthPlan,
  ]) {
    if (value != null) _text(value);
  }
  if (snapshot.profile.ageYears != null) {
    ExportContractValues.integer(snapshot.profile.ageYears, min: 0);
  }
  if (snapshot.profile.householdSize != null) {
    ExportContractValues.integer(snapshot.profile.householdSize);
  }
  for (final value in snapshot.unresolvedFields) {
    ExportContractValues.id(value);
  }
  final evidenceIds = <String>{};
  for (final finding in snapshot.findings) {
    ExportContractValues.id(finding.id);
    _text(finding.observation);
    for (final id in finding.evidenceIds) {
      ExportContractValues.id(id);
      if (!evidenceIds.add(id)) ExportContractValues.invalid();
    }
    for (final measurement in finding.measurements) {
      ExportContractValues.id(measurement.type);
    }
  }
  if (utf8.encode(jsonEncode(snapshot.toJson())).length > maximumBytes) {
    ExportContractValues.invalid();
  }
  return snapshot;
}

void _text(String value) {
  if (value.trim().isEmpty ||
      value.contains('\u0000') ||
      value.runes.any((rune) => rune >= 0xd800 && rune <= 0xdfff)) {
    ExportContractValues.invalid();
  }
}
