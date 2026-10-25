import 'dart:convert';
import 'package:flutter/widgets.dart';
import '../../l10n/app_localizations.dart';

import '../../shared/models/case_draft.dart';
import '../../shared/models/contracts.dart';

String homePlanTitle(CaseDraft? draft, {BuildContext? context}) {
  final city = draft?.profile.city?.trim();
  if (context == null) {
    return city == null || city.isEmpty
        ? 'Home safety plan'
        : '$city home plan';
  }
  return city == null || city.isEmpty
      ? context.tr('Home safety plan')
      : context.tr('{city} home plan', {'city': city});
}

String homePlanReference(String caseId, {BuildContext? context}) {
  final reference = caseId.length > 8 ? caseId.substring(0, 8) : caseId;
  return context?.tr('Reference {reference}', {'reference': reference}) ??
      'Reference $reference';
}

class CaseDisplayDetails {
  const CaseDisplayDetails({
    required this.draft,
    required this.snapshot,
    required this.uncertain,
    required this.conflict,
  });

  factory CaseDisplayDetails.fromRecord(
    String caseId,
    Map<String, Object?> record,
  ) {
    if (record['version'] != 1) {
      throw const FormatException('Unsupported local case');
    }
    final draft = CaseDraft.fromJson(record['draft']);
    final snapshot = record['snapshot'] == null
        ? null
        : parseCurrentCase(record['snapshot']);
    if (draft.caseId != caseId ||
        (snapshot != null && snapshot.caseId != caseId)) {
      throw const FormatException('Local case identity does not match');
    }
    return CaseDisplayDetails(
      draft: draft,
      snapshot: snapshot,
      uncertain: record['uncertain'] == true,
      conflict: record['conflict'] == true,
    );
  }

  final CaseDraft draft;
  final CaseSnapshot? snapshot;
  final bool uncertain, conflict;

  String get title => homePlanTitle(draft);

  String get status {
    if (conflict) return 'Changes need review';
    if (uncertain) return 'Check whether changes saved';
    if (snapshot == null) return 'Saved on this device';
    if (jsonEncode(draft.toJson()) !=
        jsonEncode(CaseDraft.fromSnapshot(snapshot!).toJson())) {
      return 'Device changes waiting to sync';
    }
    return 'Saved online';
  }

  String description({int? onlineRevision, BuildContext? context}) {
    final isOlder =
        onlineRevision != null &&
        snapshot != null &&
        snapshot!.revision < onlineRevision;
    final label = isOlder ? 'Newer version online' : status;
    return '${context?.tr(label) ?? label} · '
        '${homePlanReference(draft.caseId, context: context)}';
  }
}
