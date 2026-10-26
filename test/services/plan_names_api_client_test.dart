import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/shared/models/account_plan_name.dart';
import 'package:safe_at_home/shared/models/export_contract_values.dart';
import 'package:safe_at_home/shared/services/matching_api_client.dart';
import 'package:safe_at_home/shared/services/plan_names_api_client.dart';
import 'package:safe_at_home/shared/services/token_availability.dart';

import '../case_discovery_api_client_test.dart'
    show FakeTransport, failure, jsonResponse, requestJson;
import '../models/account_plan_name_test.dart' show nameState, namedPage;

PlanNamesApiClient clientFor(
  MatchingTransport transport, {
  MatchingTokenProvider? tokens,
  Duration timeout = const Duration(seconds: 15),
  String origin = 'https://fictional.example',
  bool local = false,
  bool emulator = false,
}) => PlanNamesApiClient(
  baseUri: Uri.parse(origin),
  tokenProvider: tokens ?? () async => 'fictional-token',
  transport: transport,
  timeout: timeout,
  allowInsecureLoopback: local,
  allowAndroidEmulatorLoopback: emulator,
);

Future<AccountPlanName> save(
  PlanNamesApiClient client, {
  bool Function()? isCurrent,
  int expected = 0,
  String? name = 'Cedar house',
}) => client.saveName(
  'case-a',
  expectedNameRevision: expected,
  mutationId: 'mutation-a',
  name: name,
  isCurrent: isCurrent ?? () => true,
);

MatchingHttpResponse errorResponse(
  String code,
  int status, {
  String schema = '2',
}) => jsonResponse({
  'schemaVersion': schema,
  'error': {'code': code, 'message': 'Private server detail fictional-token'},
}, status: status);

void main() {
  test(
    'read, save and named list use exact bounded requests and fresh tokens',
    () async {
      var token = 0;
      final transport = FakeTransport(
        (request) async => jsonResponse(
          request.endpoint.path == '/v2/list-cases'
              ? namedPage(['case-a'])
              : nameState(),
        ),
      );
      final client = clientFor(
        transport,
        tokens: () async => 'token-${++token}',
      );
      await client.readName('case-a', isCurrent: () => true);
      await save(client);
      final page = await client.listCases(
        limit: 2,
        afterCaseId: 'case-0',
        isCurrent: () => true,
      );
      expect(page.cases.single.name, 'Cedar house');
      expect(transport.requests.map((r) => r.endpoint.path), [
        '/v2/read-plan-name',
        '/v2/save-plan-name',
        '/v2/list-cases',
      ]);
      expect(transport.requests.map((r) => r.bearerToken), [
        'token-1',
        'token-2',
        'token-3',
      ]);
      expect(requestJson(transport.requests[0]), {
        'schemaVersion': '2',
        'caseId': 'case-a',
      });
      expect(requestJson(transport.requests[1]), {
        'schemaVersion': '2',
        'caseId': 'case-a',
        'expectedNameRevision': 0,
        'mutationId': 'mutation-a',
        'name': 'Cedar house',
      });
      expect(requestJson(transport.requests[2]), {
        'schemaVersion': '2',
        'limit': 2,
        'afterCaseId': 'case-0',
      });
      expect(
        transport.requests.every(
          (r) => r.maxResponseBytes == planNamesMaxResponseBytes,
        ),
        true,
      );
      expect(transport.cancellations, 3);
    },
  );

  test(
    'reset acknowledges a new revision with a null name and retained mutation',
    () async {
      final transport = FakeTransport(
        (_) async => jsonResponse(nameState(name: null, revision: 4)),
      );
      final result = await save(clientFor(transport), expected: 3, name: null);
      expect(result.name, isNull);
      expect(result.nameRevision, 4);
      expect(result.lastMutationId, 'mutation-a');
    },
  );

  test('invalid inputs fail before token or transport work', () async {
    var tokens = 0;
    final transport = FakeTransport((_) async => jsonResponse(nameState()));
    final client = clientFor(
      transport,
      tokens: () async {
        tokens++;
        return 'token';
      },
    );
    for (final value in ['', ' Cedar ', 'x' * 81, 'bad\nname']) {
      await expectLater(
        save(client, name: value),
        throwsA(failure('INVALID_REQUEST')),
      );
    }
    await expectLater(
      save(client, expected: ExportContractValues.maxInteger),
      throwsA(failure('INVALID_REQUEST')),
    );
    await expectLater(
      client.readName(' bad', isCurrent: () => true),
      throwsA(failure('INVALID_REQUEST')),
    );
    await expectLater(
      client.readName('case-a', minimumNameRevision: -1, isCurrent: () => true),
      throwsA(failure('INVALID_REQUEST')),
    );
    await expectLater(
      client.listCases(limit: 21, isCurrent: () => true),
      throwsA(failure('INVALID_REQUEST')),
    );
    await expectLater(
      client.listCases(afterCaseId: '', isCurrent: () => true),
      throwsA(failure('INVALID_REQUEST')),
    );
    expect(tokens, 0);
    expect(transport.requests, isEmpty);
  });

  test('stale account during token refresh prevents a save request', () async {
    final token = Completer<String?>();
    var current = true;
    final transport = FakeTransport((_) async => jsonResponse(nameState()));
    final pending = save(
      clientFor(transport, tokens: () => token.future),
      isCurrent: () => current,
    );
    final rejected = expectLater(pending, throwsA(failure('STALE_RESPONSE')));
    current = false;
    token.complete('fictional-token');
    await rejected;
    expect(transport.requests, isEmpty);
  });

  test(
    'late response after account replacement is stale and never adopted',
    () async {
      final response = Completer<MatchingHttpResponse>();
      final transport = FakeTransport((_) => response.future);
      var current = true;
      final result = save(clientFor(transport), isCurrent: () => current);
      final rejected = expectLater(result, throwsA(failure('STALE_RESPONSE')));
      await transport.started.future;
      current = false;
      response.complete(jsonResponse(nameState()));
      await rejected;
      expect(transport.cancellations, 1);
    },
  );

  test(
    'read rejects a regression discovered while the response is in flight',
    () async {
      final response = Completer<MatchingHttpResponse>();
      final transport = FakeTransport((_) => response.future);
      var latest = AccountPlanName.fromJson(nameState(revision: 2));
      final result = clientFor(transport).readName(
        'case-a',
        minimumNameRevision: 1,
        currentName: () => latest,
        isCurrent: () => true,
      );
      final rejected = expectLater(result, throwsA(failure('STALE_RESPONSE')));
      await transport.started.future;
      latest = AccountPlanName.fromJson(
        nameState(revision: 4, mutation: 'newer'),
      );
      response.complete(jsonResponse(nameState(revision: 3)));
      await rejected;
    },
  );

  test(
    'read rejects wrong identity and incompatible same-revision state',
    () async {
      for (final state in [
        nameState(caseId: 'other'),
        nameState(name: 'Other name'),
      ]) {
        final transport = FakeTransport((_) async => jsonResponse(state));
        await expectLater(
          clientFor(transport).readName(
            'case-a',
            currentName: () => AccountPlanName.fromJson(nameState()),
            isCurrent: () => true,
          ),
          throwsA(
            failure(
              state['caseId'] == 'other'
                  ? 'STALE_RESPONSE'
                  : 'UNEXPECTED_RESPONSE',
            ),
          ),
        );
      }
    },
  );

  test(
    'callback exceptions never expose private state or reach transport',
    () async {
      final transport = FakeTransport((_) async => jsonResponse(nameState()));
      await expectLater(
        clientFor(transport).readName(
          'case-a',
          isCurrent: () => throw StateError('private-owner'),
        ),
        throwsA(failure('STALE_RESPONSE')),
      );
      await expectLater(
        clientFor(transport).readName(
          'case-a',
          currentName: () => AccountPlanName.initial('other'),
          isCurrent: () => true,
        ),
        throwsA(failure('STALE_RESPONSE')),
      );
      expect(transport.requests, isEmpty);
    },
  );

  test(
    'uncertain save never retries and retains exact request for explicit retry',
    () async {
      var attempt = 0;
      final transport = FakeTransport((_) async {
        if (++attempt == 1) {
          throw const MatchingTransportException(
            MatchingTransportFailure.network,
          );
        }
        return jsonResponse(nameState());
      });
      final client = clientFor(transport);
      await expectLater(save(client), throwsA(failure('NAME_SAVE_UNCERTAIN')));
      expect(transport.requests, hasLength(1));
      await save(client);
      expect(
        requestJson(transport.requests.first),
        requestJson(transport.requests.last),
      );
      expect(transport.requests, hasLength(2));
    },
  );

  test(
    'save binds acknowledgement to every immutable mutation input',
    () async {
      for (final state in [
        nameState(caseId: 'other'),
        nameState(revision: 2),
        nameState(mutation: 'other'),
        nameState(name: 'Other house'),
        {...nameState(), 'extra': true},
        {...nameState(), 'name': ' Cedar house'},
      ]) {
        final transport = FakeTransport((_) async => jsonResponse(state));
        await expectLater(
          save(clientFor(transport)),
          throwsA(failure('NAME_SAVE_UNCERTAIN')),
        );
        expect(transport.requests, hasLength(1));
      }
    },
  );

  test(
    'known conflict and admission failures stay definite with local messages',
    () async {
      for (final pair in [
        ('PLAN_NAME_CONFLICT', 409),
        ('ACCOUNT_CLOSED', 409),
        ('CASE_NOT_FOUND', 404),
        ('UNAUTHENTICATED', 401),
        ('INVALID_REQUEST', 400),
        ('RATE_LIMITED', 429),
      ]) {
        for (final schema in ['1', '2']) {
          final transport = FakeTransport(
            (_) async => errorResponse(pair.$1, pair.$2, schema: schema),
          );
          try {
            await save(clientFor(transport));
            fail('Expected an explicit error');
          } on MatchingApiException catch (error) {
            expect(error.code, pair.$1);
            expect(error.statusCode, pair.$2);
            expect(error.toString(), isNot(contains('fictional-token')));
            expect(error.toString(), isNot(contains('Private server detail')));
          }
        }
      }
    },
  );

  test(
    'rate-limit advice survives without scheduling another request',
    () async {
      final error = errorResponse('RATE_LIMITED', 429);
      final transport = FakeTransport(
        (_) async => MatchingHttpResponse(
          statusCode: error.statusCode,
          contentType: error.contentType,
          body: error.body,
          retryAfter: '7',
        ),
      );
      await expectLater(
        save(clientFor(transport)),
        throwsA(
          failure('RATE_LIMITED').having(
            (error) => error.retryAfter,
            'retryAfter',
            const Duration(seconds: 7),
          ),
        ),
      );
      expect(transport.requests, hasLength(1));
    },
  );

  test(
    'service and malformed responses become uncertain only for sent writes',
    () async {
      for (final response in [
        errorResponse('INTERNAL_ERROR', 500),
        errorResponse('SERVICE_UNAVAILABLE', 503),
        errorResponse('UNRECOGNIZED_PRIVATE_CODE', 409),
        MatchingHttpResponse(
          statusCode: 200,
          contentType: 'application/json',
          body: utf8.encode('{invalid'),
        ),
        MatchingHttpResponse(
          statusCode: 200,
          contentType: 'text/plain',
          body: [],
        ),
        MatchingHttpResponse(
          statusCode: 302,
          contentType: 'application/json',
          body: [],
        ),
        MatchingHttpResponse(
          statusCode: 200,
          contentType: 'application/json',
          body: List.filled(planNamesMaxResponseBytes + 1, 32),
        ),
      ]) {
        final transport = FakeTransport((_) async => response);
        await expectLater(
          save(clientFor(transport)),
          throwsA(failure('NAME_SAVE_UNCERTAIN')),
        );
        expect(transport.requests, hasLength(1));
        expect(transport.cancellations, 1);
      }
    },
  );

  test(
    'read transport failures and wrong envelopes are bounded and not retried',
    () async {
      final transport = FakeTransport(
        (_) async => MatchingHttpResponse(
          statusCode: 200,
          contentType: 'application/json',
          body: List.filled(planNamesMaxResponseBytes + 1, 32),
        ),
      );
      await expectLater(
        clientFor(transport).readName('case-a', isCurrent: () => true),
        throwsA(failure('RESPONSE_TOO_LARGE')),
      );
      expect(transport.requests, hasLength(1));
      final malformed = FakeTransport(
        (_) async => jsonResponse({
          ...namedPage(['case-a']),
          'schemaVersion': '1',
        }),
      );
      await expectLater(
        clientFor(malformed).listCases(isCurrent: () => true),
        throwsA(failure('UNEXPECTED_RESPONSE')),
      );
    },
  );

  test(
    'token unavailability preserves offline state and makes no write',
    () async {
      final transport = FakeTransport((_) async => jsonResponse(nameState()));
      await expectLater(
        save(
          clientFor(
            transport,
            tokens: () async =>
                throw const RetryableTokenUnavailableException(),
          ),
        ),
        throwsA(failure('NETWORK_ERROR')),
      );
      for (final token in [null, '', 'bad token', 'x' * 4097]) {
        await expectLater(
          save(clientFor(transport, tokens: () async => token)),
          throwsA(failure('UNAUTHENTICATED')),
        );
      }
      expect(transport.requests, isEmpty);
    },
  );

  test(
    'save timeout is uncertain but token timeout has sent nothing',
    () async {
      final transport = FakeTransport(
        (_) => Completer<MatchingHttpResponse>().future,
      );
      await expectLater(
        save(clientFor(transport, timeout: const Duration(milliseconds: 10))),
        throwsA(failure('NAME_SAVE_UNCERTAIN')),
      );
      expect(transport.requests, hasLength(1));
      final token = Completer<String?>();
      final noRequest = FakeTransport((_) async => jsonResponse(nameState()));
      await expectLater(
        save(
          clientFor(
            noRequest,
            tokens: () => token.future,
            timeout: const Duration(milliseconds: 10),
          ),
        ),
        throwsA(failure('TIMEOUT')),
      );
      expect(noRequest.requests, isEmpty);
      token.complete('late-token');
    },
  );

  test(
    'cancellation failures cannot replace a validated successful save',
    () async {
      final transport = FakeTransport((_) async => jsonResponse(nameState()))
        ..failCancellation = true;
      expect((await save(clientFor(transport))).name, 'Cedar house');
      expect(transport.requests, hasLength(1));
    },
  );

  test(
    'endpoint validation rejects insecure, credentialed and variable origins',
    () {
      final transport = FakeTransport((_) async => jsonResponse(nameState()));
      for (final origin in [
        'http://example.org',
        'https://user:secret@example.org',
        'https://example.org/v2',
        'https://example.org?token=secret',
        'https://example.org#fragment',
        'https://example.org:0',
        'http://localhost',
        'http://10.0.2.2',
      ]) {
        expect(() => clientFor(transport, origin: origin), throwsArgumentError);
      }
      expect(
        () =>
            clientFor(transport, origin: 'http://127.0.0.1:8080', local: true),
        returnsNormally,
      );
      expect(
        () => clientFor(
          transport,
          origin: 'http://10.0.2.2:8080',
          local: true,
          emulator: true,
        ),
        returnsNormally,
      );
      expect(
        () => clientFor(transport, timeout: Duration.zero),
        throwsArgumentError,
      );
      expect(
        () => clientFor(transport, timeout: const Duration(seconds: 16)),
        throwsArgumentError,
      );
    },
  );
}
