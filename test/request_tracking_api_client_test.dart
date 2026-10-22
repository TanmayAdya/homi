import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/shared/models/contracts.dart';
import 'package:safe_at_home/shared/models/request_tracking.dart';
import 'package:safe_at_home/shared/services/matching_api_client.dart';
import 'package:safe_at_home/shared/services/request_tracking_api_client.dart';

import 'case_discovery_api_client_test.dart'
    show FakeTransport, jsonResponse, apiError, failure, snapshot;
import 'request_tracking_test.dart';

RequestTrackingApiClient clientFor(
  MatchingTransport transport, {
  MatchingTokenProvider? tokenProvider,
  Duration timeout = const Duration(seconds: 15),
  String origin = 'https://fictional.example',
  bool loopback = false,
}) => RequestTrackingApiClient(
  readHistoryEndpoint: Uri.parse('$origin/v1/read-request-history'),
  appendUpdateEndpoint: Uri.parse('$origin/v1/append-request-update'),
  tokenProvider: tokenProvider ?? () async => 'fictional-token',
  transport: transport,
  timeout: timeout,
  allowInsecureLoopback: loopback,
);
Future<RequestHistory> read(
  RequestTrackingApiClient client, {
  CaseSnapshot Function()? currentCase,
  String Function()? currentProgramId,
  RequestHistory? Function()? currentHistory,
  bool Function()? isCurrent,
}) => client.readHistory(
  historyRequest(),
  currentCase: currentCase ?? () => snapshot(),
  currentProgramId: currentProgramId ?? () => 'program-a',
  currentHistory: currentHistory ?? () => null,
  isCurrent: isCurrent ?? () => true,
);
Future<RequestHistory> append(
  RequestTrackingApiClient client, {
  PendingRequestUpdate? pending,
  CaseSnapshot Function()? currentCase,
  String Function()? currentProgramId,
  RequestHistory? Function()? currentHistory,
  bool Function()? isCurrent,
}) => client.appendUpdate(
  pending ?? pendingUpdate(),
  currentCase: currentCase ?? () => snapshot(),
  currentProgramId: currentProgramId ?? () => 'program-a',
  currentHistory: currentHistory ?? () => null,
  isCurrent: isCurrent ?? () => true,
);
void main() {
  test(
    'read and append use exact immutable envelopes and fresh tokens with bounded responses',
    () async {
      var token = 0;
      final transport = FakeTransport(
        (request) async => jsonResponse(
          historyJson(count: request.endpoint.path.contains('append') ? 1 : 0),
        ),
      );
      final client = clientFor(
        transport,
        tokenProvider: () async => 'token-${++token}',
      );
      expect((await read(client)).events, isEmpty);
      final result = await append(client);
      expect(result.acknowledges(pendingUpdate()), isTrue);
      expect(
        jsonDecode(utf8.decode(transport.requests[0].body)),
        historyRequest().toJson(),
      );
      expect(
        jsonDecode(utf8.decode(transport.requests[1].body)),
        pendingUpdate().toJson(),
      );
      expect(transport.requests.map((r) => r.bearerToken), [
        'token-1',
        'token-2',
      ]);
      expect(
        transport.requests.every((r) => r.maxResponseBytes == 256 * 1024),
        isTrue,
      );
      expect(transport.cancellations, 2);
    },
  );
  test(
    'initial selection account history or case mismatches stop before token lookup',
    () async {
      var tokens = 0;
      final transport = FakeTransport((_) async => jsonResponse(historyJson()));
      final client = clientFor(
        transport,
        tokenProvider: () async {
          tokens++;
          return 'token';
        },
      );
      for (final action in <Future<RequestHistory> Function()>[
        () => read(client, isCurrent: () => false),
        () => read(client, isCurrent: () => throw StateError('private')),
        () => read(client, currentCase: () => snapshot(revision: 3)),
        () => read(client, currentCase: () => snapshot(caseId: 'other')),
        () => read(client, currentProgramId: () => 'other'),
        () => read(
          client,
          currentHistory: () =>
              RequestHistory.fromJson({...historyJson(), 'programId': 'other'}),
        ),
      ]) {
        await expectLater(action(), throwsA(failure('STALE_RESPONSE')));
      }
      expect(tokens, 0);
      expect(transport.requests, isEmpty);
    },
  );
  test(
    'account program case revision and request epoch changes during success or failure discard late results',
    () async {
      for (final change in ['account', 'program', 'case', 'generation']) {
        for (final fails in [false, true]) {
          var current = true, program = 'program-a', caseRevision = 2;
          final reply = Completer<MatchingHttpResponse>();
          final transport = FakeTransport((_) => reply.future);
          final checked = expectLater(
            read(
              clientFor(transport),
              currentCase: () => snapshot(revision: caseRevision),
              currentProgramId: () => program,
              isCurrent: () => current,
            ),
            throwsA(failure('STALE_RESPONSE')),
          );
          await transport.started.future;
          switch (change) {
            case 'program':
              program = 'other';
            case 'case':
              caseRevision = 3;
            default:
              current = false;
          }
          if (fails) {
            reply.completeError(StateError('private'));
          } else {
            reply.complete(jsonResponse(historyJson()));
          }
          await checked;
          expect(transport.cancellations, 1);
        }
      }
    },
  );
  test('token lookup races are guarded on both failure and success', () async {
    for (final fails in [false, true]) {
      var current = true;
      final token = Completer<String?>();
      final transport = FakeTransport((_) async => jsonResponse(historyJson()));
      final checked = expectLater(
        append(
          clientFor(transport, tokenProvider: () => token.future),
          isCurrent: () => current,
        ),
        throwsA(failure('STALE_RESPONSE')),
      );
      current = false;
      if (fails) {
        token.completeError(StateError('private'));
      } else {
        token.complete('token');
      }
      await checked;
      expect(transport.requests, isEmpty);
    }
  });
  test(
    'reads never regress history including a high revision observed before local clear',
    () async {
      RequestHistory? local = RequestHistory.fromJson(historyJson(count: 3));
      final reply = Completer<MatchingHttpResponse>();
      final transport = FakeTransport((_) => reply.future);
      final checked = expectLater(
        read(clientFor(transport), currentHistory: () => local),
        throwsA(failure('STALE_RESPONSE')),
      );
      await transport.started.future;
      local = null;
      reply.complete(jsonResponse(historyJson(count: 2)));
      await checked;
    },
  );
  test(
    'current history can refresh an older case envelope without losing its revision floor',
    () async {
      final transport = FakeTransport(
        (_) async => jsonResponse(historyJson(count: 2, caseRevision: 3)),
      );
      final loaded = await clientFor(transport).readHistory(
        historyRequest(caseRevision: 3),
        currentCase: () => snapshot(revision: 3),
        currentProgramId: () => 'program-a',
        currentHistory: () => RequestHistory.fromJson(historyJson(count: 1)),
        isCurrent: () => true,
      );
      expect(loaded.caseRevision, 3);
      expect(loaded.requestRevision, 2);
    },
  );
  test(
    'history advancing during an append cannot be overwritten by an older acknowledgement',
    () async {
      var local = RequestHistory.fromJson(historyJson());
      final reply = Completer<MatchingHttpResponse>();
      final transport = FakeTransport((_) => reply.future);
      final checked = expectLater(
        append(clientFor(transport), currentHistory: () => local),
        throwsA(failure('STALE_RESPONSE')),
      );
      await transport.started.future;
      local = RequestHistory.fromJson(historyJson(count: 2));
      reply.complete(jsonResponse(historyJson(count: 1)));
      await checked;
    },
  );
  test(
    'append retry accepts exact original acknowledgement followed by later events',
    () async {
      final transport = FakeTransport(
        (_) async => jsonResponse(historyJson(count: 3)),
      );
      final result = await append(
        clientFor(transport),
        currentHistory: () => RequestHistory.fromJson(historyJson(count: 2)),
      );
      expect(result.requestRevision, 3);
      expect(result.acknowledges(pendingUpdate()), isTrue);
      expect(transport.requests, hasLength(1));
    },
  );
  test(
    'append acknowledgement mismatch stays uncertain and retained pending data is untouched',
    () async {
      final pending = pendingUpdate();
      final retained = jsonEncode(pending.toJson());
      for (final mutation in <void Function(Map<String, Object?>)>[
        (j) => j['events'] = <Object>[],
        (j) => ((j['events'] as List)[0] as Map)['note'] = 'changed',
        (j) => ((j['events'] as List)[0] as Map)['caseRevision'] = 1,
        (j) => ((j['events'] as List)[0] as Map)['updateId'] =
            '12345678-1234-4123-8123-000000000002',
      ]) {
        final body = historyJson(count: 1);
        mutation(body);
        await expectLater(
          append(
            clientFor(FakeTransport((_) async => jsonResponse(body))),
            pending: pending,
          ),
          throwsA(failure('REQUEST_UPDATE_UNCERTAIN')),
        );
        expect(jsonEncode(pending.toJson()), retained);
      }
    },
  );
  test(
    'lost write response never auto retries and explicit read reconciles original content',
    () async {
      var calls = 0;
      final transport = FakeTransport((_) async {
        calls++;
        if (calls == 1) {
          throw const MatchingTransportException(
            MatchingTransportFailure.network,
          );
        }
        return jsonResponse(historyJson(count: 1));
      });
      final client = clientFor(transport), pending = pendingUpdate();
      await expectLater(
        append(client, pending: pending),
        throwsA(failure('REQUEST_UPDATE_UNCERTAIN')),
      );
      expect(calls, 1);
      expect((await read(client)).acknowledges(pending), isTrue);
      expect(calls, 2);
    },
  );
  test(
    'expected server conflicts are sanitized but server and malformed response failures leave append uncertain',
    () async {
      for (final (code, status) in [
        ('REQUEST_REVISION_MISMATCH', 409),
        ('REQUEST_UPDATE_CONFLICT', 409),
        ('REQUEST_HISTORY_FULL', 409),
        ('CASE_REVISION_MISMATCH', 409),
        ('CASE_NOT_FOUND', 404),
        ('PROGRAM_NOT_FOUND', 404),
        ('UNAUTHENTICATED', 401),
        ('INVALID_REQUEST', 400),
      ]) {
        final transport = FakeTransport((_) async => apiError(code, status));
        try {
          await append(clientFor(transport));
          fail('Expected rejection');
        } on MatchingApiException catch (error) {
          expect(error.code, code);
          expect(error.statusCode, status);
          expect(error.toString(), isNot(contains('Private')));
        }
        expect(transport.requests, hasLength(1));
      }
      for (final response in [
        apiError('INTERNAL_ERROR', 500),
        apiError('SERVICE_UNAVAILABLE', 503),
        apiError('UNAUTHENTICATED', 500),
        jsonResponse({'bad': 'private'}),
        MatchingHttpResponse(
          statusCode: 200,
          contentType: 'text/html',
          body: [],
        ),
      ]) {
        await expectLater(
          append(clientFor(FakeTransport((_) async => response))),
          throwsA(failure('REQUEST_UPDATE_UNCERTAIN')),
        );
      }
    },
  );
  test(
    'deadlines invalid tokens bounds and redirects are enforced without automatic retries',
    () async {
      for (final token in [
        null,
        '',
        'token\n',
        'x y',
        List.filled(4097, 'x').join(),
      ]) {
        final transport = FakeTransport(
          (_) async => jsonResponse(historyJson()),
        );
        await expectLater(
          read(clientFor(transport, tokenProvider: () async => token)),
          throwsA(failure('UNAUTHENTICATED')),
        );
        expect(transport.requests, isEmpty);
      }
      final token = Completer<String?>();
      final transport = FakeTransport((_) async => jsonResponse(historyJson()));
      await expectLater(
        append(
          clientFor(
            transport,
            tokenProvider: () => token.future,
            timeout: const Duration(milliseconds: 10),
          ),
        ),
        throwsA(failure('TIMEOUT')),
      );
      expect(transport.requests, isEmpty);
      for (final (response, code) in [
        (
          MatchingHttpResponse(
            statusCode: 200,
            contentType: 'application/json',
            body: List.filled(requestTrackingMaxResponseBytes + 1, 0),
          ),
          'RESPONSE_TOO_LARGE',
        ),
        (
          MatchingHttpResponse(
            statusCode: 302,
            contentType: 'application/json',
            body: [],
          ),
          'REDIRECT_BLOCKED',
        ),
        (
          MatchingHttpResponse(
            statusCode: 200,
            contentType: 'application/json',
            body: [0xc3, 0x28],
          ),
          'UNEXPECTED_RESPONSE',
        ),
      ]) {
        await expectLater(
          read(clientFor(FakeTransport((_) async => response))),
          throwsA(failure(code)),
        );
      }
      final never = Completer<MatchingHttpResponse>();
      final slow = FakeTransport((_) => never.future);
      await expectLater(
        append(clientFor(slow, timeout: const Duration(milliseconds: 10))),
        throwsA(failure('REQUEST_UPDATE_UNCERTAIN')),
      );
      expect(slow.requests, hasLength(1));
      expect(slow.cancellations, 1);
    },
  );
  test(
    'fixed same-origin HTTPS endpoints require explicit local-only HTTP opt in',
    () {
      final transport = FakeTransport((_) async => jsonResponse(historyJson()));
      expect(
        () => clientFor(transport, origin: 'http://127.0.0.1'),
        throwsArgumentError,
      );
      expect(
        () =>
            clientFor(transport, origin: 'http://192.168.0.1', loopback: true),
        throwsArgumentError,
      );
      expect(
        () => clientFor(transport, origin: 'http://127.0.0.1', loopback: true),
        returnsNormally,
      );
      for (final readUri in [
        'https://fictional.example/v1/read-request-history?x=1',
        'https://u:p@fictional.example/v1/read-request-history',
        'https://fictional.example/wrong',
        'https://other.example/v1/read-request-history',
      ]) {
        expect(
          () => RequestTrackingApiClient(
            readHistoryEndpoint: Uri.parse(readUri),
            appendUpdateEndpoint: Uri.parse(
              'https://fictional.example/v1/append-request-update',
            ),
            tokenProvider: () async => 'token',
            transport: transport,
          ),
          throwsArgumentError,
        );
      }
      for (final timeout in [Duration.zero, const Duration(seconds: 16)]) {
        expect(
          () => clientFor(transport, timeout: timeout),
          throwsArgumentError,
        );
      }
    },
  );
}
