import 'export_contract_values.dart';

class RequestUpdate {
  factory RequestUpdate({
    required String updateId,
    required String status,
    required String occurredOn,
    required String source,
    String? note,
    String? nextAction,
    String? responsibleParty,
    String? followUpOn,
  }) => RequestUpdate.fromJson({
    'updateId': updateId,
    'status': status,
    'occurredOn': occurredOn,
    'source': source,
    'note': note,
    'nextAction': nextAction,
    'responsibleParty': responsibleParty,
    'followUpOn': followUpOn,
  });
  factory RequestUpdate.fromJson(Object? json) {
    final value = ExportContractValues.object(json, _updateKeys);
    final id = value['updateId'];
    if (id is! String ||
        RegExp(
              r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
            ).stringMatch(id) !=
            id) {
      ExportContractValues.invalid();
    }
    final status = _choice(value['status'], {
      'preparing',
      'submitted',
      'received',
      'needs_information',
      'approved',
      'denied',
      'withdrawn',
    });
    final source = _choice(value['source'], {
      'self_report',
      'program_contact',
      'document',
    });
    final occurred = _date(value['occurredOn']);
    final note = _text(value['note'], 500),
        action = _text(value['nextAction'], 250);
    final party = value['responsibleParty'] == null
        ? null
        : _choice(value['responsibleParty'], {
            'resident',
            'caregiver',
            'program',
            'clinician',
            'contractor',
            'other',
          });
    final follow = value['followUpOn'] == null
        ? null
        : _date(value['followUpOn']);
    if ((action == null) != (party == null) ||
        (follow != null && action == null)) {
      ExportContractValues.invalid();
    }
    return RequestUpdate._(
      id,
      status,
      occurred,
      source,
      note,
      action,
      party,
      follow,
    );
  }
  const RequestUpdate._(
    this.updateId,
    this.status,
    this.occurredOn,
    this.source,
    this.note,
    this.nextAction,
    this.responsibleParty,
    this.followUpOn,
  );
  final String updateId, status, occurredOn, source;
  final String? note, nextAction, responsibleParty, followUpOn;
  Map<String, Object?> toJson() => {
    'updateId': updateId,
    'status': status,
    'occurredOn': occurredOn,
    'source': source,
    'note': note,
    'nextAction': nextAction,
    'responsibleParty': responsibleParty,
    'followUpOn': followUpOn,
  };
  bool sameContent(RequestUpdate other) =>
      _updateKeys.every((key) => toJson()[key] == other.toJson()[key]);
}

const _updateKeys = {
  'updateId',
  'status',
  'occurredOn',
  'source',
  'note',
  'nextAction',
  'responsibleParty',
  'followUpOn',
};

class ReadRequestHistoryRequest {
  factory ReadRequestHistoryRequest({
    required String caseId,
    required int expectedCaseRevision,
    required String programId,
  }) => ReadRequestHistoryRequest.fromJson({
    'schemaVersion': '1',
    'caseId': caseId,
    'expectedCaseRevision': expectedCaseRevision,
    'programId': programId,
  });
  factory ReadRequestHistoryRequest.fromJson(Object? json) {
    final value = ExportContractValues.object(json, {
      'schemaVersion',
      'caseId',
      'expectedCaseRevision',
      'programId',
    });
    if (value['schemaVersion'] != '1') ExportContractValues.invalid();
    return ReadRequestHistoryRequest._(
      ExportContractValues.id(value['caseId']),
      ExportContractValues.integer(value['expectedCaseRevision']),
      ExportContractValues.id(value['programId']),
    );
  }
  const ReadRequestHistoryRequest._(
    this.caseId,
    this.expectedCaseRevision,
    this.programId,
  );
  final String caseId, programId;
  final int expectedCaseRevision;
  Map<String, Object?> toJson() => {
    'schemaVersion': '1',
    'caseId': caseId,
    'expectedCaseRevision': expectedCaseRevision,
    'programId': programId,
  };
}

class PendingRequestUpdate {
  factory PendingRequestUpdate({
    required ReadRequestHistoryRequest request,
    required int expectedRequestRevision,
    required RequestUpdate update,
  }) => PendingRequestUpdate.fromJson({
    ...request.toJson(),
    'expectedRequestRevision': expectedRequestRevision,
    'update': update.toJson(),
  });
  factory PendingRequestUpdate.fromJson(Object? json) {
    final value = ExportContractValues.object(json, {
      'schemaVersion',
      'caseId',
      'expectedCaseRevision',
      'programId',
      'expectedRequestRevision',
      'update',
    });
    return PendingRequestUpdate._(
      ReadRequestHistoryRequest.fromJson({
        for (final key in [
          'schemaVersion',
          'caseId',
          'expectedCaseRevision',
          'programId',
        ])
          key: value[key],
      }),
      ExportContractValues.integer(
        value['expectedRequestRevision'],
        min: 0,
        max: 50,
      ),
      RequestUpdate.fromJson(value['update']),
    );
  }
  const PendingRequestUpdate._(
    this.request,
    this.expectedRequestRevision,
    this.update,
  );
  final ReadRequestHistoryRequest request;
  final int expectedRequestRevision;
  final RequestUpdate update;
  Map<String, Object?> toJson() => {
    ...request.toJson(),
    'expectedRequestRevision': expectedRequestRevision,
    'update': update.toJson(),
  };
}

class RequestEvent {
  factory RequestEvent.fromJson(Object? json) {
    final value = ExportContractValues.object(json, {
      ..._updateKeys,
      'revision',
      'caseRevision',
      'recordedAt',
    });
    final recorded = ExportContractValues.instant(value['recordedAt']);
    if (RegExp(
          r'^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3}Z$',
        ).stringMatch(recorded) !=
        recorded) {
      ExportContractValues.invalid();
    }
    final update = RequestUpdate.fromJson({
      for (final key in _updateKeys) key: value[key],
    });
    if (update.occurredOn.compareTo(recorded.substring(0, 10)) > 0) {
      ExportContractValues.invalid();
    }
    return RequestEvent._(
      update,
      ExportContractValues.integer(value['revision'], max: 50),
      ExportContractValues.integer(value['caseRevision']),
      recorded,
    );
  }
  const RequestEvent._(
    this.update,
    this.revision,
    this.caseRevision,
    this.recordedAt,
  );
  final RequestUpdate update;
  final int revision, caseRevision;
  final String recordedAt;
  Map<String, Object?> toJson() => {
    ...update.toJson(),
    'revision': revision,
    'caseRevision': caseRevision,
    'recordedAt': recordedAt,
  };
}

class RequestHistory {
  factory RequestHistory.fromJson(Object? json) {
    final value = ExportContractValues.object(json, {
      'schemaVersion',
      'caseId',
      'caseRevision',
      'programId',
      'requestRevision',
      'provenance',
      'events',
    });
    if (value['schemaVersion'] != '1' ||
        value['provenance'] != 'user_reported') {
      ExportContractValues.invalid();
    }
    final caseId = ExportContractValues.id(value['caseId']),
        programId = ExportContractValues.id(value['programId']);
    final caseRevision = ExportContractValues.integer(value['caseRevision']);
    final revision = ExportContractValues.integer(
      value['requestRevision'],
      min: 0,
      max: 50,
    );
    final events = ExportContractValues.list(
      value['events'],
      RequestEvent.fromJson,
      50,
    );
    if (events.length != revision) ExportContractValues.invalid();
    ExportContractValues.unique(events.map((event) => event.update.updateId));
    for (var i = 0; i < events.length; i++) {
      if (events[i].revision != i + 1 ||
          events[i].caseRevision > caseRevision ||
          (i > 0 &&
              (events[i].caseRevision < events[i - 1].caseRevision ||
                  events[i].recordedAt.compareTo(events[i - 1].recordedAt) <
                      0))) {
        ExportContractValues.invalid();
      }
    }
    return RequestHistory._(caseId, caseRevision, programId, revision, events);
  }
  const RequestHistory._(
    this.caseId,
    this.caseRevision,
    this.programId,
    this.requestRevision,
    this.events,
  );
  final String caseId, programId;
  final int caseRevision, requestRevision;
  final List<RequestEvent> events;
  String get provenance => 'user_reported';

  RequestEvent? get latest => events.isEmpty ? null : events.last;
  bool acknowledges(PendingRequestUpdate pending) {
    final position = pending.expectedRequestRevision;
    return caseId == pending.request.caseId &&
        programId == pending.request.programId &&
        position < events.length &&
        events[position].revision == position + 1 &&
        events[position].caseRevision == pending.request.expectedCaseRevision &&
        events[position].update.sameContent(pending.update);
  }

  Map<String, Object?> toJson() => {
    'schemaVersion': '1',
    'caseId': caseId,
    'caseRevision': caseRevision,
    'programId': programId,
    'requestRevision': requestRevision,
    'provenance': provenance,
    'events': events.map((event) => event.toJson()).toList(),
  };
}

String _choice(Object? value, Set<String> choices) {
  if (value is! String || !choices.contains(value)) {
    ExportContractValues.invalid();
  }
  return value;
}

String _date(Object? value) {
  if (value is! String ||
      RegExp(r'^(?!0000)[0-9]{4}-[0-9]{2}-[0-9]{2}$').stringMatch(value) !=
          value) {
    ExportContractValues.invalid();
  }
  final parsed = DateTime.tryParse('${value}T00:00:00.000Z');
  if (parsed == null || parsed.toIso8601String().substring(0, 10) != value) {
    ExportContractValues.invalid();
  }
  return value;
}

String? _text(Object? value, int max) {
  if (value == null) return null;
  if (value is! String ||
      value.isEmpty ||
      value.trim() != value ||
      value.runes.length > max ||
      RegExp(r'[\x00-\x09\x0b-\x1f\x7f-\x9f\u2028\u2029]').hasMatch(value) ||
      value.runes.any((rune) => rune >= 0xd800 && rune <= 0xdfff)) {
    ExportContractValues.invalid();
  }
  return value;
}
