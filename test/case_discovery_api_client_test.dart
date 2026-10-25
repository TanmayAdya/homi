import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/shared/models/case_draft.dart';
import 'package:safe_at_home/shared/models/contracts.dart';
import 'package:safe_at_home/shared/services/case_discovery_api_client.dart';
import 'package:safe_at_home/shared/services/matching_api_client.dart';

import 'case_list_test.dart' show pageJson;

class FakeTransport implements MatchingTransport {
  FakeTransport(this.reply);
  final Future<MatchingHttpResponse> Function(MatchingHttpRequest) reply;
  final requests = <MatchingHttpRequest>[];
  final started = Completer<void>();
  int cancellations = 0;
  bool failCancellation = false;
  @override
  MatchingExchange post(MatchingHttpRequest request) {
    requests.add(request);
    if (!started.isCompleted) started.complete();
    return MatchingExchange(
      response: reply(request),
      cancel: () {
        cancellations++;
        if (failCancellation) throw StateError('Private cleanup data');
      },
    );
  }
}

MatchingHttpResponse jsonResponse(Object? value, {int status = 200}) =>
    MatchingHttpResponse(
      statusCode: status,
      contentType: 'application/json; charset=utf-8',
      body: utf8.encode(jsonEncode(value)),
    );
MatchingHttpResponse apiError(String code, int status) => jsonResponse({
  'schemaVersion': '1',
  'error': {'code': code, 'message': 'Private server data and fictional-token'},
}, status: status);
TypeMatcher<MatchingApiException> failure(String code) =>
    isA<MatchingApiException>().having((value) => value.code, 'code', code);
CaseDiscoveryApiClient clientFor(
  MatchingTransport transport, {
  MatchingTokenProvider? tokenProvider,
  Duration timeout = const Duration(seconds: 15),
  String origin = 'https://fictional.example',
  bool allowLoopback = false,
  bool allowEmulator = false,
}) => CaseDiscoveryApiClient(
  listCasesEndpoint: Uri.parse('$origin/v1/list-cases'),
  caseEndpoint: Uri.parse('$origin/v1/read-case'),
  tokenProvider: tokenProvider ?? () async => 'fictional-token',
  transport: transport,
  timeout: timeout,
  allowInsecureLoopback: allowLoopback,
  allowAndroidEmulatorLoopback: allowEmulator,
);
CaseSnapshot snapshot({String caseId = 'case-a', int revision = 2}) =>
    parseCurrentCase({
      'schemaVersion': '1',
      'caseId': caseId,
      'revision': revision,
      'profile': {
        'city': null,
        'county': null,
        'healthPlan': null,
        'tenure': null,
        'ageYears': null,
        'householdSize': null,
        'annualIncomeUsd': null,
        'ownerConsentReported': null,
      },
      'unresolvedFields': <String>[],
      'findings': <Object>[],
    });
Map<String, dynamic> requestJson(MatchingHttpRequest request) =>
    jsonDecode(utf8.decode(request.body)) as Map<String, dynamic>;
Future<CaseSnapshot> resume(
  CaseDiscoveryApiClient client, {
  int minimumCaseRevision = 1,
  CaseSnapshot? Function()? currentCase,
  String Function()? currentCaseId,
  bool Function()? isCurrent,
}) => client.resumeCase(
  'case-a',
  minimumCaseRevision: minimumCaseRevision,
  currentCaseId: currentCaseId ?? () => 'case-a',
  currentCase: currentCase ?? () => null,
  isCurrent: isCurrent ?? () => true,
);

void main() {
  test(
    'list and resume send minimal exact requests with a fresh bounded token each time',
    () async {
      var tokenNumber = 0;
      final transport = FakeTransport(
        (request) async => jsonResponse(
          request.endpoint.path == '/v1/list-cases'
              ? pageJson(['case-a'])
              : snapshot().toJson(),
        ),
      );
      final client = clientFor(
        transport,
        tokenProvider: () async => 'token-${++tokenNumber}',
      );
      final page = await client.listCases(
        limit: 2,
        afterCaseId: 'case-0',
        isCurrent: () => true,
      );
      final selected = page.cases.single;
      final loaded = await resume(
        client,
        minimumCaseRevision: selected.caseRevision,
      );
      expect(loaded.revision, 2);
      expect(transport.requests.map((value) => value.bearerToken), [
        'token-1',
        'token-2',
      ]);
      expect(requestJson(transport.requests[0]), {
        'schemaVersion': '1',
        'limit': 2,
        'afterCaseId': 'case-0',
      });
      expect(requestJson(transport.requests[1]), {
        'schemaVersion': '1',
        'caseId': 'case-a',
      });
      expect(
        transport.requests.every(
          (value) => value.maxResponseBytes == caseDiscoveryMaxResponseBytes,
        ),
        isTrue,
      );
      expect(transport.cancellations, 2);
    },
  );

  test(
    'invalid request values and initially stale callbacks stop before token or transport work',
    () async {
      var tokens = 0;
      final transport = FakeTransport((_) async => jsonResponse(pageJson([])));
      final client = clientFor(
        transport,
        tokenProvider: () async {
          tokens++;
          return 'token';
        },
      );
      for (final limit in [0, 21]) {
        await expectLater(
          client.listCases(limit: limit, isCurrent: () => true),
          throwsA(failure('INVALID_REQUEST')),
        );
      }
      await expectLater(
        client.listCases(afterCaseId: ' case', isCurrent: () => true),
        throwsA(failure('INVALID_REQUEST')),
      );
      await expectLater(
        resume(client, minimumCaseRevision: 0),
        throwsA(failure('INVALID_REQUEST')),
      );
      await expectLater(
        client.listCases(isCurrent: () => false),
        throwsA(failure('STALE_RESPONSE')),
      );
      await expectLater(
        resume(client, currentCaseId: () => 'other'),
        throwsA(failure('STALE_RESPONSE')),
      );
      await expectLater(
        resume(client, currentCase: () => snapshot(caseId: 'other')),
        throwsA(failure('STALE_RESPONSE')),
      );
      await expectLater(
        client.listCases(isCurrent: () => throw StateError('private')),
        throwsA(failure('STALE_RESPONSE')),
      );
      expect(tokens, 0);
      expect(transport.requests, isEmpty);
    },
  );

  test(
    'empty, malformed and failed token lookup never reach transport',
    () async {
      for (final token in [
        null,
        '',
        ' ',
        'token\n',
        'token\r\n',
        'token with space',
        List.filled(4097, 'x').join(),
      ]) {
        final transport = FakeTransport(
          (_) async => jsonResponse(pageJson([])),
        );
        await expectLater(
          clientFor(
            transport,
            tokenProvider: () async => token,
          ).listCases(isCurrent: () => true),
          throwsA(failure('UNAUTHENTICATED')),
        );
        expect(transport.requests, isEmpty);
      }
      final transport = FakeTransport((_) async => jsonResponse(pageJson([])));
      await expectLater(
        clientFor(
          transport,
          tokenProvider: () async =>
              throw StateError('private provider secret'),
        ).listCases(isCurrent: () => true),
        throwsA(failure('UNAUTHENTICATED')),
      );
      expect(transport.requests, isEmpty);
    },
  );

  test(
    'account/session changes while token lookup succeeds or fails discard the result',
    () async {
      for (final providerFails in [false, true]) {
        var current = true;
        final token = Completer<String?>();
        final transport = FakeTransport(
          (_) async => jsonResponse(pageJson([])),
        );
        final pending = clientFor(
          transport,
          tokenProvider: () => token.future,
        ).listCases(isCurrent: () => current);
        final checked = expectLater(
          pending,
          throwsA(failure('STALE_RESPONSE')),
        );
        current = false;
        if (providerFails) {
          token.completeError(StateError('private'));
        } else {
          token.complete('token');
        }
        await checked;
        expect(transport.requests, isEmpty);
      }
    },
  );

  test('a superseded list generation cannot replace the newest list', () async {
    final replies = [
      Completer<MatchingHttpResponse>(),
      Completer<MatchingHttpResponse>(),
    ];
    var index = 0, generation = 1;
    final transport = FakeTransport((_) => replies[index++].future);
    final client = clientFor(transport);
    final first = client.listCases(isCurrent: () => generation == 1);
    final stale = expectLater(first, throwsA(failure('STALE_RESPONSE')));
    await transport.started.future;
    generation = 2;
    final second = client.listCases(isCurrent: () => generation == 2);
    replies[1].complete(jsonResponse(pageJson(['new-case'])));
    expect((await second).cases.single.caseId, 'new-case');
    replies[0].complete(jsonResponse(pageJson(['old-case'])));
    await stale;
    expect(transport.cancellations, 2);
  });

  test(
    'late API or network failures after account switch are reported as stale',
    () async {
      for (final networkFailure in [false, true]) {
        var current = true;
        final reply = Completer<MatchingHttpResponse>();
        final transport = FakeTransport((_) => reply.future);
        final checked = expectLater(
          clientFor(transport).listCases(isCurrent: () => current),
          throwsA(failure('STALE_RESPONSE')),
        );
        await transport.started.future;
        current = false;
        if (networkFailure) {
          reply.completeError(StateError('private network data'));
        } else {
          reply.complete(apiError('UNAUTHENTICATED', 401));
        }
        await checked;
        expect(transport.cancellations, 1);
      }
    },
  );

  test(
    'synchronous transport supersession cancels and consumes late transport errors',
    () async {
      var current = true;
      final reply = Completer<MatchingHttpResponse>();
      final transport = FakeTransport((_) {
        current = false;
        return reply.future;
      });
      await expectLater(
        clientFor(transport).listCases(isCurrent: () => current),
        throwsA(failure('STALE_RESPONSE')),
      );
      reply.completeError(StateError('Private late failure'));
      await Future<void>.delayed(Duration.zero);
      expect(transport.cancellations, 1);
    },
  );

  test(
    'resume enforces selected-list and observed local revision without a local case',
    () async {
      for (final revision in [1, 2]) {
        final transport = FakeTransport(
          (_) async => jsonResponse(snapshot(revision: revision).toJson()),
        );
        await expectLater(
          resume(clientFor(transport), minimumCaseRevision: 3),
          throwsA(failure('STALE_RESPONSE')),
        );
      }
      final transport = FakeTransport(
        (_) async => jsonResponse(snapshot(revision: 3).toJson()),
      );
      expect(
        (await resume(clientFor(transport), minimumCaseRevision: 3)).revision,
        3,
      );
    },
  );

  test(
    'resume rejects case selection changes, local revision advances, and wrong-case responses',
    () async {
      for (final change in ['selection', 'local-revision', 'account']) {
        var selected = 'case-a', currentAccount = true;
        CaseSnapshot? local = snapshot();
        final reply = Completer<MatchingHttpResponse>();
        final transport = FakeTransport((_) => reply.future);
        final checked = expectLater(
          resume(
            clientFor(transport),
            currentCaseId: () => selected,
            currentCase: () => local,
            isCurrent: () => currentAccount,
          ),
          throwsA(failure('STALE_RESPONSE')),
        );
        await transport.started.future;
        if (change == 'selection') selected = 'case-b';
        if (change == 'local-revision') local = snapshot(revision: 4);
        if (change == 'account') currentAccount = false;
        reply.complete(jsonResponse(snapshot(revision: 3).toJson()));
        await checked;
      }
      await expectLater(
        resume(
          clientFor(
            FakeTransport(
              (_) async => jsonResponse(snapshot(caseId: 'other').toJson()),
            ),
          ),
        ),
        throwsA(failure('STALE_RESPONSE')),
      );
    },
  );

  test(
    'highest locally observed revision persists even if local state later clears',
    () async {
      CaseSnapshot? local = snapshot(revision: 5);
      final reply = Completer<MatchingHttpResponse>();
      final transport = FakeTransport((_) => reply.future);
      final checked = expectLater(
        resume(clientFor(transport), currentCase: () => local),
        throwsA(failure('STALE_RESPONSE')),
      );
      await transport.started.future;
      local = null;
      reply.complete(jsonResponse(snapshot(revision: 4).toJson()));
      await checked;
    },
  );

  test(
    'resume uses strict current-case validation and never exposes malformed private content',
    () async {
      for (final mutate in <void Function(Map<String, Object?>)>[
        (json) => json['privateOwner'] = 'private',
        (json) => json['revision'] = 9007199254740992,
        (json) => (json['profile'] as Map)['ownerConsentReported'] = 'false',
        (json) => json['findings'] = [null],
      ]) {
        final body = snapshot().toJson();
        mutate(body);
        await expectLater(
          resume(clientFor(FakeTransport((_) async => jsonResponse(body)))),
          throwsA(failure('UNEXPECTED_RESPONSE')),
        );
      }
    },
  );

  test(
    'malformed JSON, UTF-8, content type, redirects and oversized responses are rejected',
    () async {
      final responses = <(MatchingHttpResponse, String)>[
        (
          MatchingHttpResponse(
            statusCode: 200,
            contentType: 'application/json',
            body: [0x7b],
          ),
          'UNEXPECTED_RESPONSE',
        ),
        (
          MatchingHttpResponse(
            statusCode: 200,
            contentType: 'application/json',
            body: [0xc3, 0x28],
          ),
          'UNEXPECTED_RESPONSE',
        ),
        (
          MatchingHttpResponse(
            statusCode: 200,
            contentType: 'text/html',
            body: [],
          ),
          'UNEXPECTED_RESPONSE',
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
            body: List.filled(caseDiscoveryMaxResponseBytes + 1, 0),
          ),
          'RESPONSE_TOO_LARGE',
        ),
        (jsonResponse(pageJson(['b', 'a'])), 'UNEXPECTED_RESPONSE'),
        (jsonResponse(pageJson(['a'], next: 'a')), 'UNEXPECTED_RESPONSE'),
      ];
      for (final (response, code) in responses) {
        final transport = FakeTransport((_) async => response);
        await expectLater(
          clientFor(transport).listCases(isCurrent: () => true),
          throwsA(failure(code)),
        );
        expect(transport.cancellations, 1);
      }
    },
  );

  test(
    'recognized API failures are sanitized and status/code contradictions fail closed',
    () async {
      const errors = {
        400: 'INVALID_REQUEST',
        401: 'UNAUTHENTICATED',
        404: 'CASE_NOT_FOUND',
        405: 'METHOD_NOT_ALLOWED',
        413: 'PAYLOAD_TOO_LARGE',
        415: 'UNSUPPORTED_MEDIA_TYPE',
        500: 'INTERNAL_ERROR',
        503: 'SERVICE_UNAVAILABLE',
      };
      for (final entry in errors.entries) {
        final transport = FakeTransport(
          (_) async => apiError(entry.value, entry.key),
        );
        try {
          await resume(clientFor(transport));
          fail('Expected a safe API error');
        } on MatchingApiException catch (error) {
          expect(error.code, entry.value);
          expect(error.statusCode, entry.key);
          expect(error.toString(), isNot(contains('Private')));
          expect(error.toString(), isNot(contains('fictional-token')));
        }
        expect(transport.requests, hasLength(1));
      }
      for (final response in [
        apiError('UNAUTHENTICATED', 500),
        apiError('UNKNOWN_PRIVATE_DETAIL', 404),
        jsonResponse({
          'schemaVersion': '1',
          'error': {'code': 'CASE_NOT_FOUND', 'message': ''},
        }, status: 404),
      ]) {
        await expectLater(
          resume(clientFor(FakeTransport((_) async => response))),
          throwsA(failure('UNEXPECTED_RESPONSE')),
        );
      }
    },
  );

  test(
    'transport errors and token/response deadlines are bounded, cancelled and never retried',
    () async {
      for (final (reason, code) in [
        (MatchingTransportFailure.network, 'NETWORK_ERROR'),
        (MatchingTransportFailure.responseTooLarge, 'RESPONSE_TOO_LARGE'),
        (MatchingTransportFailure.redirectBlocked, 'REDIRECT_BLOCKED'),
      ]) {
        final transport = FakeTransport(
          (_) async => throw MatchingTransportException(reason),
        );
        await expectLater(
          clientFor(transport).listCases(isCurrent: () => true),
          throwsA(failure(code)),
        );
        expect(transport.requests, hasLength(1));
        expect(transport.cancellations, 1);
      }
      final blockedToken = Completer<String?>();
      final beforeIo = FakeTransport((_) async => jsonResponse(pageJson([])));
      await expectLater(
        clientFor(
          beforeIo,
          tokenProvider: () => blockedToken.future,
          timeout: const Duration(milliseconds: 10),
        ).listCases(isCurrent: () => true),
        throwsA(failure('TIMEOUT')),
      );
      blockedToken.complete('late-token');
      expect(beforeIo.requests, isEmpty);
      final blockedResponse = Completer<MatchingHttpResponse>();
      final afterIo = FakeTransport((_) => blockedResponse.future)
        ..failCancellation = true;
      await expectLater(
        clientFor(
          afterIo,
          timeout: const Duration(milliseconds: 10),
        ).listCases(isCurrent: () => true),
        throwsA(failure('TIMEOUT')),
      );
      blockedResponse.complete(jsonResponse(pageJson(['late'])));
      expect(afterIo.requests, hasLength(1));
      expect(afterIo.cancellations, 1);
    },
  );

  test(
    'endpoints reject origin changes, credentials, query, fragment and implicit insecure access',
    () {
      final transport = FakeTransport((_) async => jsonResponse(pageJson([])));
      for (final endpoint in [
        'https://other.example/v1/read-case',
        'https://user:secret@fictional.example/v1/read-case',
        'https://fictional.example/v1/read-case?x=1',
        'https://fictional.example/v1/read-case#x',
        'https://fictional.example/v1/other',
        'http://fictional.example/v1/read-case',
      ]) {
        expect(
          () => CaseDiscoveryApiClient(
            listCasesEndpoint: Uri.parse(
              'https://fictional.example/v1/list-cases',
            ),
            caseEndpoint: Uri.parse(endpoint),
            tokenProvider: () async => 'token',
            transport: transport,
          ),
          throwsArgumentError,
        );
      }
      for (final origin in [
        'http://localhost',
        'http://127.0.0.1:8788',
        'http://[::1]:8788',
      ]) {
        expect(() => clientFor(transport, origin: origin), throwsArgumentError);
        expect(
          () => clientFor(transport, origin: origin, allowLoopback: true),
          returnsNormally,
        );
      }
      expect(
        () => clientFor(
          transport,
          origin: 'http://10.0.2.2:8788',
          allowLoopback: true,
        ),
        throwsArgumentError,
      );
      expect(
        () => clientFor(
          transport,
          origin: 'http://10.0.2.2:8788',
          allowEmulator: true,
        ),
        throwsArgumentError,
      );
      expect(
        () => clientFor(
          transport,
          origin: 'http://10.0.2.2:8788',
          allowLoopback: true,
          allowEmulator: true,
        ),
        returnsNormally,
      );
      expect(
        () => clientFor(
          transport,
          origin: 'http://192.168.1.2',
          allowLoopback: true,
        ),
        throwsArgumentError,
      );
      for (final timeout in [Duration.zero, const Duration(seconds: 16)]) {
        expect(
          () => clientFor(transport, timeout: timeout),
          throwsArgumentError,
        );
      }
    },
  );
}
