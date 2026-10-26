import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/shared/models/request_tracking.dart';

import 'support/contract_schema.dart';

Map<String, Object?> updateJson({
  int number = 1,
  String status = 'preparing',
  String occurredOn = '2026-10-17',
}) => {
  'updateId': '12345678-1234-4123-8123-${number.toString().padLeft(12, '0')}',
  'status': status,
  'occurredOn': occurredOn,
  'source': 'self_report',
  'note': null,
  'nextAction': null,
  'responsibleParty': null,
  'followUpOn': null,
};
Map<String, Object?> eventJson({
  int number = 1,
  int caseRevision = 2,
  String status = 'preparing',
  String occurredOn = '2026-10-17',
}) => {
  ...updateJson(number: number, status: status, occurredOn: occurredOn),
  'revision': number,
  'caseRevision': caseRevision,
  'recordedAt': '2026-10-18T10:00:00.000Z',
};
Map<String, Object?> historyJson({int count = 0, int caseRevision = 2}) => {
  'schemaVersion': '1',
  'caseId': 'case-a',
  'caseRevision': caseRevision,
  'programId': 'program-a',
  'requestRevision': count,
  'provenance': 'user_reported',
  'events': [
    for (var i = 1; i <= count; i++)
      eventJson(number: i, caseRevision: caseRevision),
  ],
};
ReadRequestHistoryRequest historyRequest({int caseRevision = 2}) =>
    ReadRequestHistoryRequest(
      caseId: 'case-a',
      expectedCaseRevision: caseRevision,
      programId: 'program-a',
    );
PendingRequestUpdate pendingUpdate({int number = 1, int caseRevision = 2}) =>
    PendingRequestUpdate(
      request: historyRequest(caseRevision: caseRevision),
      expectedRequestRevision: number - 1,
      update: RequestUpdate.fromJson(updateJson(number: number)),
    );

void main() {
  test(
    'all statuses and source labels remain user reported with immutable exact roundtrip',
    () {
      for (final status in [
        'preparing',
        'submitted',
        'received',
        'needs_information',
        'approved',
        'denied',
        'withdrawn',
      ]) {
        for (final source in ['self_report', 'program_contact', 'document']) {
          final json = updateJson(status: status)..['source'] = source;
          expect(RequestUpdate.fromJson(json).toJson(), json);
        }
      }
      final json = historyJson(count: 2);
      final history = RequestHistory.fromJson(json);
      expect(history.toJson(), json);
      expect(history.provenance, 'user_reported');
      expect(history.latest!.revision, 2);
      expect(() => history.events.clear(), throwsUnsupportedError);
      (json['events'] as List).clear();
      expect(history.events, hasLength(2));
      expect(RequestHistory.fromJson(historyJson()).latest, isNull);
      expect(
        PendingRequestUpdate.fromJson(pendingUpdate().toJson()).toJson(),
        pendingUpdate().toJson(),
      );
    },
  );
  test('strict fields and scalar lengths reject malformed update text', () {
    for (final value in [
      null,
      [],
      {},
      {...updateJson(), 'private': true},
      {...updateJson()}..remove('note'),
    ]) {
      expect(() => RequestUpdate.fromJson(value), throwsFormatException);
    }
    for (final key in ['note', 'nextAction']) {
      for (final text in [
        '',
        ' ',
        ' text',
        'text ',
        'x\tq',
        'x\rq',
        'x\u0085q',
        'x\u2028q',
        'x\u2029q',
        '\ud800',
        List.filled(key == 'note' ? 501 : 251, '😀').join(),
      ]) {
        final json = updateJson()..[key] = text;
        if (key == 'nextAction') json['responsibleParty'] = 'resident';
        expect(
          () => RequestUpdate.fromJson(json),
          throwsFormatException,
          reason: '$key text boundary',
        );
      }
    }
    final json = updateJson()
      ..['note'] = List.filled(500, '😀').join()
      ..['nextAction'] = 'Call\nprogram'
      ..['responsibleParty'] = 'caregiver'
      ..['followUpOn'] = '2027-01-01';
    expect(RequestUpdate.fromJson(json).toJson(), json);
  });
  test('dates UUIDs enums and action dependencies are strict', () {
    for (final (key, bad) in <(String, Object?)>[
      ('updateId', '12345678-1234-5123-8123-000000000001'),
      ('updateId', '12345678-1234-4123-A123-000000000001'),
      ('updateId', '12345678-1234-4123-8123-000000000001\n'),
      ('status', 'verified'),
      ('source', 'agency_verified'),
      ('responsibleParty', 'unknown_role'),
      for (final date in [
        '0000-01-01',
        '2026-02-29',
        '2026-04-31',
        '2026-13-01',
        '2026-1-01',
        '2026-10-17\n',
      ])
        ('occurredOn', date),
      ('followUpOn', '2026-02-30'),
      ('followUpOn', '2027-01-01'),
      ('nextAction', 'Call'),
      ('responsibleParty', 'resident'),
    ]) {
      expect(
        () => RequestUpdate.fromJson({...updateJson(), key: bad}),
        throwsFormatException,
        reason: key,
      );
    }
    expect(
      RequestUpdate.fromJson({
        ...updateJson(),
        'occurredOn': '2024-02-29',
      }).occurredOn,
      '2024-02-29',
    );
  });
  test(
    'request envelopes use exact keys safe revisions and valid identifiers',
    () {
      for (final value in [0, 1.2, 9007199254740992, '2', null]) {
        expect(
          () => ReadRequestHistoryRequest.fromJson({
            ...historyRequest().toJson(),
            'expectedCaseRevision': value,
          }),
          throwsFormatException,
        );
      }
      for (final value in [-1, 51, 1.5, '1', null]) {
        expect(
          () => PendingRequestUpdate.fromJson({
            ...pendingUpdate().toJson(),
            'expectedRequestRevision': value,
          }),
          throwsFormatException,
        );
      }
      for (final id in ['', ' case', 'case\n', '\ud800']) {
        expect(
          () => ReadRequestHistoryRequest.fromJson({
            ...historyRequest().toJson(),
            'caseId': id,
          }),
          throwsFormatException,
        );
      }
      expect(
        () => ReadRequestHistoryRequest.fromJson({
          ...historyRequest().toJson(),
          'ownerId': 'private',
        }),
        throwsFormatException,
      );
      expect(
        () => PendingRequestUpdate.fromJson({
          ...pendingUpdate().toJson(),
          'recordedAt': '2026-10-18T00:00:00.000Z',
        }),
        throwsFormatException,
      );
    },
  );
  test(
    'history enforces contiguous revisions unique IDs times and case revision monotonicity',
    () {
      final mutations = <void Function(Map<String, Object?>)>[
        (j) => j['schemaVersion'] = '2',
        (j) => j['provenance'] = 'verified',
        (j) => j['requestRevision'] = 1,
        (j) => j['privateOwner'] = 'hidden',
        (j) => j['events'] = List.filled(51, eventJson()),
        (j) => (j['events'] as List)[1] = eventJson(number: 1),
        (j) => ((j['events'] as List)[1] as Map)['revision'] = 3,
        (j) => ((j['events'] as List)[1] as Map)['caseRevision'] = 1,
        (j) => ((j['events'] as List)[1] as Map)['caseRevision'] = 3,
        (j) => ((j['events'] as List)[1] as Map)['recordedAt'] =
            '2026-10-17T10:00:00.000Z',
        (j) => ((j['events'] as List)[0] as Map)['recordedAt'] =
            '2026-10-18T10:00:00Z',
        (j) => ((j['events'] as List)[0] as Map)['recordedAt'] =
            '2026-10-18T24:00:00.000Z',
        (j) => ((j['events'] as List)[0] as Map)['occurredOn'] = '2026-10-19',
      ];
      for (final mutate in mutations) {
        final json = historyJson(count: 2);
        mutate(json);
        expect(() => RequestHistory.fromJson(json), throwsFormatException);
      }
      final backdated = historyJson(count: 2);
      (backdated['events'] as List)[1] = eventJson(
        number: 2,
        status: 'needs_information',
        occurredOn: '2026-09-01',
      );
      expect(
        RequestHistory.fromJson(backdated).latest!.update.status,
        'needs_information',
      );
    },
  );
  test(
    'acknowledgement binds exact ID content position case and program even after later case edits',
    () {
      final pending = pendingUpdate();
      final json = historyJson(count: 2, caseRevision: 3);
      ((json['events'] as List)[0] as Map)['caseRevision'] = 2;
      final history = RequestHistory.fromJson(json);
      expect(history.acknowledges(pending), isTrue);
      for (final field in ['status', 'note', 'source']) {
        final update = updateJson()
          ..[field] = switch (field) {
            'status' => 'submitted',
            'source' => 'document',
            _ => 'different',
          };
        expect(
          history.acknowledges(
            PendingRequestUpdate(
              request: historyRequest(),
              expectedRequestRevision: 0,
              update: RequestUpdate.fromJson(update),
            ),
          ),
          isFalse,
        );
      }
      expect(history.acknowledges(pendingUpdate(caseRevision: 3)), isFalse);
      expect(
        RequestHistory.fromJson({
          ...historyJson(count: 1),
          'programId': 'other',
        }).acknowledges(pending),
        isFalse,
      );
      expect(
        RequestHistory.fromJson(historyJson()).acknowledges(pending),
        isFalse,
      );
    },
  );
  test(
    'shared API error schema includes exact request-history conflict codes',
    () {
      final schema =
          jsonDecode(
                File('contracts/v1/api-error.schema.json').readAsStringSync(),
              )
              as Map<String, dynamic>;
      for (final code in [
        'REQUEST_REVISION_MISMATCH',
        'REQUEST_UPDATE_CONFLICT',
        'REQUEST_HISTORY_FULL',
      ]) {
        final envelope = {
          'schemaVersion': '1',
          'error': {'code': code, 'message': 'Safe local example'},
        };
        expect(acceptsContract(envelope, schema, {}, schema), isTrue);
        expect(
          acceptsContract(
            {
              'schemaVersion': '1',
              'error': {
                'code': 'REQUEST_UPDATE_UNCERTAIN',
                'message': 'Local only',
              },
            },
            schema,
            {},
            schema,
          ),
          isFalse,
        );
      }
    },
  );
  test(
    'published schemas accept valid Unicode and reject structural or text violations',
    () {
      final schemas = <String, Map<String, dynamic>>{};
      for (final name in [
        'request-tracking-read-request.schema.json',
        'request-tracking-append-request.schema.json',
        'request-tracking.schema.json',
      ]) {
        schemas[name] =
            jsonDecode(File('contracts/v1/$name').readAsStringSync())
                as Map<String, dynamic>;
      }
      final entries = {
        'request-tracking-read-request.schema.json': historyRequest().toJson(),
        'request-tracking-append-request.schema.json': pendingUpdate().toJson(),
        'request-tracking.schema.json': historyJson(count: 2),
      };
      for (final entry in entries.entries) {
        final schema = schemas[entry.key]!;
        expect(
          acceptsContract(entry.value, schema, schemas, schema),
          isTrue,
          reason: entry.key,
        );
        expect(
          acceptsContract(
            {...entry.value, 'extra': true},
            schema,
            schemas,
            schema,
          ),
          isFalse,
        );
      }
      final schema = schemas['request-tracking-append-request.schema.json']!;
      for (final text in ['Valid\nmultiline', List.filled(500, '😀').join()]) {
        final json = pendingUpdate().toJson();
        (json['update'] as Map)['note'] = text;
        expect(acceptsContract(json, schema, schemas, schema), isTrue);
      }
      for (final text in [
        ' invalid',
        'invalid\ttext',
        '\ud800',
        List.filled(501, '😀').join(),
      ]) {
        final json = pendingUpdate().toJson();
        (json['update'] as Map)['note'] = text;
        expect(acceptsContract(json, schema, schemas, schema), isFalse);
      }
    },
  );
}
