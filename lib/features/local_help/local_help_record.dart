import 'dart:convert';
import 'referral_geography.dart';
import 'package:crypto/crypto.dart';
import '../../shared/models/export_contract_values.dart';

String helpText(Object? value, {int max = 500, bool empty = false}) {
  if (value is! String ||
      value.trim() != value ||
      (!empty && value.isEmpty) ||
      value.runes.length > max ||
      RegExp(r'[\x00-\x1f\x7f-\x9f]').hasMatch(value)) {
    throw const FormatException('Invalid local help text.');
  }
  return value;
}

String hashReferralOriginal(Map<String, Object?> original) => sha256
    .convert(
      utf8.encode(
        jsonEncode({
          for (final key in original.keys.toList()..sort()) key: original[key],
        }),
      ),
    )
    .toString();

String helpDate(Object? value) {
  if (value is! String ||
      !RegExp(r'^[0-9]{4}-[0-9]{2}-[0-9]{2}$').hasMatch(value)) {
    throw const FormatException('Invalid follow-up date.');
  }
  final date = DateTime.tryParse(value);
  if (date == null ||
      date.year < 2000 ||
      date.year > 2200 ||
      date.toIso8601String().substring(0, 10) != value) {
    throw const FormatException('Invalid follow-up date.');
  }
  return value;
}

class HelpLocation {
  HelpLocation({
    required this.city,
    required this.county,
    required this.zip,
    this.stateCode,
    this.countyFips,
  }) {
    if (stateCode != null &&
        (referralState(stateCode) == null ||
            stateCode != stateCode!.toUpperCase())) {
      throw const FormatException('Invalid state.');
    }
    if (countyFips != null &&
        (stateCode == null ||
            !RegExp(r'^[0-9]{5}$').hasMatch(countyFips!) ||
            !countyFips!.startsWith(referralState(stateCode)!.fips))) {
      throw const FormatException('Invalid state/county FIPS.');
    }
    if (stateCode != null && countyFips != null) {
      final normalized = county.trim().toLowerCase().replaceFirst(
        RegExp(r'\s+county$'),
        '',
      );
      final known = referralCountyFips[stateCode]?.entries
          .where((entry) => entry.key.toLowerCase() == normalized)
          .firstOrNull
          ?.value;
      if (known != null && known != countyFips) {
        throw const FormatException('County name and FIPS disagree.');
      }
    }
    helpText(city, max: 100, empty: true);
    helpText(county, max: 100, empty: true);
    if (zip != null && !RegExp(r'^[0-9]{5}(-[0-9]{4})?$').hasMatch(zip!)) {
      throw const FormatException('Invalid ZIP.');
    }
  }
  final String city, county;
  final String? zip, stateCode, countyFips;
  Map<String, Object?> toJson() => {
    'city': city,
    'county': county,
    'zip': zip,
    if (stateCode != null) 'stateCode': stateCode,
    if (countyFips != null) 'countyFips': countyFips,
  };
  factory HelpLocation.fromJson(Object? raw) {
    final v = ExportContractValues.object(raw, {
      'city',
      'county',
      'zip',
      if (raw is Map && raw.containsKey('stateCode')) 'stateCode',
      if (raw is Map && raw.containsKey('countyFips')) 'countyFips',
    });
    return HelpLocation(
      city: v['city'] as String,
      county: v['county'] as String,
      zip: v['zip'] as String?,
      stateCode: v['stateCode'] as String?,
      countyFips: v['countyFips'] as String?,
    );
  }
}

class SavedHelpContact {
  SavedHelpContact({
    required this.providerId,
    required this.note,
    required this.savedAt,
  }) {
    ExportContractValues.id(providerId);
    helpText(note, empty: true);
    ExportContractValues.instant(savedAt);
  }
  final String providerId, note, savedAt;
  Map<String, Object?> toJson() => {
    'providerId': providerId,
    'note': note,
    'savedAt': savedAt,
  };
  factory SavedHelpContact.fromJson(Object? raw) {
    final v = ExportContractValues.object(raw, {
      'providerId',
      'note',
      'savedAt',
    });
    return SavedHelpContact(
      providerId: v['providerId'] as String,
      note: v['note'] as String,
      savedAt: v['savedAt'] as String,
    );
  }
}

class HelpFollowUp {
  HelpFollowUp({
    required this.id,
    required this.providerId,
    required this.title,
    required this.responsible,
    required this.dueDate,
    required this.createdAt,
    this.findingId,
    this.completedAt,
  }) {
    ExportContractValues.id(id);
    ExportContractValues.id(providerId);
    helpText(title, max: 160);
    helpText(responsible, max: 100, empty: true);
    if (dueDate != null) helpDate(dueDate);
    if (findingId != null) ExportContractValues.id(findingId);
    ExportContractValues.instant(createdAt);
    if (completedAt != null) ExportContractValues.instant(completedAt);
  }
  final String id, providerId, title, responsible, createdAt;
  final String? dueDate, findingId, completedAt;
  bool overdue(DateTime now) =>
      completedAt == null &&
      dueDate != null &&
      dueDate!.compareTo(
            '${now.year.toString().padLeft(4, '0')}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}',
          ) <
          0;
  Map<String, Object?> toJson() => {
    'id': id,
    'providerId': providerId,
    'title': title,
    'responsible': responsible,
    'dueDate': dueDate,
    'findingId': findingId,
    'createdAt': createdAt,
    'completedAt': completedAt,
  };
  factory HelpFollowUp.fromJson(Object? raw) {
    final v = ExportContractValues.object(raw, {
      'id',
      'providerId',
      'title',
      'responsible',
      'dueDate',
      'findingId',
      'createdAt',
      'completedAt',
    });
    return HelpFollowUp(
      id: v['id'] as String,
      providerId: v['providerId'] as String,
      title: v['title'] as String,
      responsible: v['responsible'] as String,
      dueDate: v['dueDate'] as String?,
      findingId: v['findingId'] as String?,
      createdAt: v['createdAt'] as String,
      completedAt: v['completedAt'] as String?,
    );
  }
}

class LocalHelpRecord {
  LocalHelpRecord({
    required this.caseId,
    this.revision = 0,
    this.location,
    List<SavedHelpContact> contacts = const [],
    List<HelpFollowUp> tasks = const [],
  }) : contacts = List.unmodifiable(contacts),
       tasks = List.unmodifiable(tasks) {
    ExportContractValues.id(caseId);
    ExportContractValues.integer(revision, min: 0);
    if (contacts.length > 30 || tasks.length > 100) {
      throw const FormatException('Local help capacity reached.');
    }
    ExportContractValues.unique(contacts.map((c) => c.providerId));
    ExportContractValues.unique(tasks.map((t) => t.id));
  }
  final String caseId;
  final int revision;
  final HelpLocation? location;
  final List<SavedHelpContact> contacts;
  final List<HelpFollowUp> tasks;
  Map<String, Object?> toJson() => {
    'schemaVersion': '1',
    'caseId': caseId,
    'revision': revision,
    'location': location?.toJson(),
    'contacts': contacts.map((c) => c.toJson()).toList(),
    'tasks': tasks.map((t) => t.toJson()).toList(),
  };
  factory LocalHelpRecord.fromJson(Object? raw) {
    final v = ExportContractValues.object(raw, {
      'schemaVersion',
      'caseId',
      'revision',
      'location',
      'contacts',
      'tasks',
    });
    if (v['schemaVersion'] != '1') {
      throw const FormatException('Unsupported local help record.');
    }
    return LocalHelpRecord(
      caseId: v['caseId'] as String,
      revision: ExportContractValues.integer(v['revision'], min: 0),
      location: v['location'] == null
          ? null
          : HelpLocation.fromJson(v['location']),
      contacts: ExportContractValues.list(
        v['contacts'],
        SavedHelpContact.fromJson,
        30,
      ),
      tasks: ExportContractValues.list(v['tasks'], HelpFollowUp.fromJson, 100),
    );
  }
}
