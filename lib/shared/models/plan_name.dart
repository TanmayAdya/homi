import 'export_contract_values.dart';

String? normalizePlanName(String? value) {
  if (value == null) return null;
  if (RegExp(
        r'[\x00-\x1f\x7f-\x9f\u2028\u2029\u202a-\u202e\u2066-\u2069]',
      ).hasMatch(value) ||
      value.runes.any((rune) => rune >= 0xd800 && rune <= 0xdfff)) {
    throw const FormatException('Use a single-line plan name.');
  }
  final name = value.trim();
  if (name.isEmpty) return null;
  if (name.runes.length > 80) {
    throw const FormatException('Use a plan name of 80 characters or fewer.');
  }
  return name;
}

class PlanName {
  factory PlanName({required String caseId, required String name}) {
    storageKey(caseId);
    final normalized = normalizePlanName(name);
    if (normalized == null) {
      throw const FormatException('A stored plan name cannot be empty.');
    }
    return PlanName._(caseId, normalized);
  }

  factory PlanName.fromJson(Object? value) {
    final record = ExportContractValues.object(value, {
      'schemaVersion',
      'caseId',
      'name',
    });
    if (record['schemaVersion'] != '1' || record['name'] is! String) {
      throw const FormatException('Invalid local plan name.');
    }
    final parsed = PlanName(
      caseId: ExportContractValues.id(record['caseId']),
      name: record['name'] as String,
    );
    if (parsed.name != record['name']) {
      throw const FormatException('Invalid local plan name.');
    }
    return parsed;
  }

  const PlanName._(this.caseId, this.name);
  final String caseId, name;

  static String storageKey(String caseId) {
    ExportContractValues.id(caseId);
    final key = 'plan-name.$caseId';
    if (!RegExp(r'^[A-Za-z0-9_.:-]{1,512}$').hasMatch(key)) {
      throw const FormatException('Unsupported private plan identifier.');
    }
    return key;
  }

  Map<String, Object?> toJson() => {
    'schemaVersion': '1',
    'caseId': caseId,
    'name': name,
  };
}
