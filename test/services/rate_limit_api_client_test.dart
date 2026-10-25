import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/shared/models/contracts.dart';
import 'package:safe_at_home/shared/services/matching_api_client.dart';

import '../case_discovery_api_client_test.dart' as discovery;
import '../contracts/case_evidence_test.dart' as cases;
import '../contracts/draft_export_test.dart' as evidence;
import '../contracts/packet_test.dart' as packets;
import '../contracts/schema_fixtures_test.dart' show validate;
import '../request_tracking_api_client_test.dart' as tracking;
import '../request_tracking_test.dart' show pendingUpdate;
import 'case_evidence_api_client_test.dart' as mutations;
import 'draft_export_api_client_test.dart' as exports;
import 'form_answers_api_client_test.dart' as answers;
import 'matching_api_client_test.dart' as matching;
import 'packet_api_client_test.dart' as packet;

MatchingHttpResponse rejection({
  String code = 'RATE_LIMITED',
  int status = 429,
  String? retryAfter = '5',
}) => MatchingHttpResponse(
  statusCode: status,
  contentType: 'application/json',
  retryAfter: retryAfter,
  body: utf8.encode(
    jsonEncode({
      'schemaVersion': '1',
      'error': {'code': code, 'message': 'Private details and secret-token'},
    }),
  ),
);

Future<Object> prepare(MatchingTransport transport) {
  final snapshot = CaseSnapshot.fromJson(packets.packetCaseJson());
  return packet
      .clientFor(transport)
      .preparePacket(
        snapshot,
        programId: 'demo-home-support',
        generationKey: 'attempt_0001',
        currentCase: () => snapshot,
      );
}

void main() {
  final operations = <String, Future<Object?> Function(MatchingTransport)>{
    'match': (transport) {
      final snapshot = matching.fixtureCase();
      return matching
          .makeClient(transport)
          .matchCase(snapshot, currentCase: () => snapshot);
    },
    'packet': prepare,
    'read answers': (transport) => answers.read(answers.clientFor(transport)),
    'save answers': (transport) => answers.save(answers.clientFor(transport)),
    'create case': (transport) {
      final draft = cases.draft();
      return mutations
          .clientFor(transport)
          .createCase(draft, currentDraft: () => draft);
    },
    'save case': (transport) => mutations.save(mutations.clientFor(transport)),
    'reload case': (transport) => mutations
        .clientFor(transport)
        .reloadCase(
          'fictional-case',
          currentCaseId: () => 'fictional-case',
          currentCase: evidence.snapshot,
        ),
    'upload photo': (transport) =>
        mutations.upload(mutations.clientFor(transport)),
    'delete photo': (transport) =>
        mutations.delete(mutations.clientFor(transport)),
    'list photos': (transport) => exports
        .client(transport)
        .listEvidence(
          evidence.snapshot(),
          currentCase: evidence.snapshot,
          currentCatalog: () => null,
        ),
    'download photo': (transport) => exports
        .client(transport)
        .downloadEvidence(
          evidence.snapshot(),
          catalog: evidence.catalog(),
          evidence: evidence.catalog().evidence.single,
          currentCase: evidence.snapshot,
          currentCatalog: evidence.catalog,
        ),
    'create export': (transport) => exports.create(exports.client(transport)),
    'download export': (transport) =>
        exports.download(exports.client(transport)),
    'list cases': (transport) =>
        discovery.clientFor(transport).listCases(isCurrent: () => true),
    'resume case': (transport) =>
        discovery.resume(discovery.clientFor(transport)),
    'read history': (transport) => tracking.read(tracking.clientFor(transport)),
    'append history': (transport) =>
        tracking.append(tracking.clientFor(transport)),
  };
  for (final operation in operations.entries) {
    test(
      '${operation.key} preserves account rejection and delay without retry',
      () async {
        final transport = discovery.FakeTransport((_) async => rejection());
        await expectLater(
          operation.value(transport),
          throwsA(
            isA<MatchingApiException>()
                .having((error) => error.code, 'code', 'RATE_LIMITED')
                .having((error) => error.statusCode, 'status', 429)
                .having(
                  (error) => error.retryAfter,
                  'delay',
                  const Duration(seconds: 5),
                )
                .having(
                  (error) => error.toString(),
                  'safe message',
                  allOf(
                    isNot(contains('Private')),
                    isNot(contains('secret-token')),
                  ),
                ),
          ),
        );
        expect(transport.requests, hasLength(1));
        expect(transport.cancellations, 1);
      },
    );
  }

  test('invalid optional retry headers retain a definite rejection', () async {
    for (final value in <String?>[
      null,
      '',
      '0',
      '-1',
      '+2',
      '01',
      '1.5',
      '1e2',
      ' 5',
      '5 ',
      '5\n',
      '5, 10',
      '3601',
      '999999999999999999999',
      'Wed, 21 Oct 2026 07:28:00 GMT',
    ]) {
      final transport = discovery.FakeTransport(
        (_) async => rejection(retryAfter: value),
      );
      await expectLater(
        tracking.append(tracking.clientFor(transport)),
        throwsA(
          isA<MatchingApiException>()
              .having((error) => error.code, 'code', 'RATE_LIMITED')
              .having((error) => error.retryAfter, 'delay', isNull),
        ),
      );
      expect(transport.requests, hasLength(1));
    }
  });

  test(
    'retry advice is bounded and belongs only to recognized busy responses',
    () {
      for (final status in [429, 503]) {
        final code = status == 429 ? 'RATE_LIMITED' : 'SERVICE_UNAVAILABLE';
        for (final seconds in [1, 3600]) {
          expect(
            MatchingApiException.forCode(
              code,
              statusCode: status,
            ).withRetryAfter('$seconds').retryAfter,
            Duration(seconds: seconds),
          );
        }
      }
      expect(
        MatchingApiException.forCode(
          'UNEXPECTED_RESPONSE',
        ).withRetryAfter('5').retryAfter,
        isNull,
      );
      expect(
        MatchingApiException.forCode(
          'STORAGE_LIMIT_REACHED',
          statusCode: 507,
        ).withRetryAfter('5').retryAfter,
        isNull,
      );
    },
  );

  test(
    'an uncertain earlier append stays pending after a rate-limited retry',
    () async {
      final pending = pendingUpdate(),
          before = jsonEncode(pendingUpdate().toJson());
      var calls = 0;
      final transport = discovery.FakeTransport(
        (_) async => ++calls == 1
            ? rejection(code: 'SERVICE_UNAVAILABLE', status: 503)
            : rejection(),
      );
      final client = tracking.clientFor(transport);
      await expectLater(
        tracking.append(client, pending: pending),
        throwsA(discovery.failure('REQUEST_UPDATE_UNCERTAIN')),
      );
      await expectLater(
        tracking.append(client, pending: pending),
        throwsA(discovery.failure('RATE_LIMITED')),
      );
      expect(jsonEncode(pending.toJson()), before);
      expect(transport.requests, hasLength(2));
      expect(transport.requests[0].body, transport.requests[1].body);
    },
  );

  test(
    'packet capacity rejection is typed and preserves the preparation key',
    () async {
      final transport = discovery.FakeTransport(
        (_) async => rejection(code: 'STORAGE_LIMIT_REACHED', status: 507),
      );
      await expectLater(
        prepare(transport),
        throwsA(
          isA<MatchingApiException>()
              .having((error) => error.code, 'code', 'STORAGE_LIMIT_REACHED')
              .having((error) => error.statusCode, 'status', 507),
        ),
      );
      expect(transport.requests, hasLength(1));
      expect(
        jsonDecode(
          utf8.decode(transport.requests.single.body),
        )['generationKey'],
        'attempt_0001',
      );
    },
  );

  test(
    'new error code validates but contradictory HTTP pairs stay rejected',
    () async {
      final schema =
          jsonDecode(
                File('contracts/v1/api-error.schema.json').readAsStringSync(),
              )
              as Map<String, dynamic>;
      validate(jsonDecode(utf8.decode(rejection().body)), schema);
      for (final response in [
        rejection(status: 400),
        rejection(code: 'UNAUTHENTICATED'),
        rejection(code: 'UNRECOGNIZED_PRIVATE_DETAIL'),
      ]) {
        final transport = discovery.FakeTransport((_) async => response);
        await expectLater(
          prepare(transport),
          throwsA(discovery.failure('UNEXPECTED_RESPONSE')),
        );
        expect(transport.requests, hasLength(1));
      }
    },
  );
}
