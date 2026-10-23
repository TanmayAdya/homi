import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/shared/models/contracts.dart';
import 'package:safe_at_home/shared/services/matching_api_client.dart';

import '../contracts/schema_fixtures_test.dart' show validate;

List<dynamic> fixtureData() =>
    jsonDecode(File('contracts/v1/fixtures/scenarios.json').readAsStringSync())
        as List<dynamic>;

CaseSnapshot fixtureCase([int index = 0]) =>
    CaseSnapshot.fromJson(fixtureData()[index]['case']);

Map<String, dynamic> fixtureMatch([int index = 0]) =>
    fixtureData()[index]['match'] as Map<String, dynamic>;

MatchingHttpResponse jsonResponse(Object? data, {int status = 200}) =>
    MatchingHttpResponse(
      statusCode: status,
      contentType: 'application/json',
      body: utf8.encode(jsonEncode(data)),
    );

TypeMatcher<MatchingApiException> apiFailure(String code) =>
    isA<MatchingApiException>().having((e) => e.code, 'code', code);

MatchingApiClient makeClient(
  MatchingTransport transport, {
  MatchingTokenProvider? tokenProvider,
  Duration timeout = const Duration(seconds: 15),
  int maxResponseBytes = 1024 * 1024,
}) => MatchingApiClient(
  endpoint: Uri.parse('https://example.org/v1/match-case'),
  tokenProvider: tokenProvider ?? () async => 'test-token',
  transport: transport,
  timeout: timeout,
  maxResponseBytes: maxResponseBytes,
);

void main() {
  test(
    'API request rejects blank/long IDs and unsafe revisions before token I/O',
    () async {
      var tokenCalls = 0;
      final transport = _FakeTransport(
        (_) async => jsonResponse(fixtureMatch()),
      );
      final client = makeClient(
        transport,
        tokenProvider: () async {
          tokenCalls++;
          return 'token';
        },
      );
      for (final changes in <Map<String, Object>>[
        {'caseId': ' \n\t'},
        {'caseId': List.filled(201, 'a').join()},
        {'caseId': List.filled(201, '😀').join()},
        {'revision': 9007199254740992},
      ]) {
        final input = fixtureData().first['case'] as Map<String, dynamic>;
        input.addAll(changes);
        final snapshot = CaseSnapshot.fromJson(input);
        await expectLater(
          client.matchCase(snapshot, currentCase: () => snapshot),
          throwsA(apiFailure('INVALID_REQUEST')),
        );
      }
      expect(tokenCalls, 0);
      expect(transport.requests, isEmpty);
    },
  );

  test(
    'API case ID bound counts Unicode code points and accepts safe revision maximum',
    () async {
      final input = fixtureData().first['case'] as Map<String, dynamic>;
      input['caseId'] = List.filled(200, '😀').join();
      input['revision'] = 9007199254740991;
      final snapshot = CaseSnapshot.fromJson(input);
      final response = fixtureMatch()
        ..['caseId'] = snapshot.caseId
        ..['caseRevision'] = snapshot.revision;
      final transport = _FakeTransport((_) async => jsonResponse(response));
      final result = await makeClient(
        transport,
      ).matchCase(snapshot, currentCase: () => snapshot);
      expect(result.caseId.runes.length, 200);
      expect(result.caseRevision, 9007199254740991);
    },
  );

  test(
    'sends only the shared request fields and a freshly obtained token',
    () async {
      final transport = _FakeTransport(
        (_) async => jsonResponse(fixtureMatch()),
      );
      var tokenCalls = 0;
      final client = makeClient(
        transport,
        tokenProvider: () async => 'token-${++tokenCalls}',
      );
      final snapshot = fixtureCase();
      await client.matchCase(snapshot, currentCase: () => snapshot);
      await client.matchCase(snapshot, currentCase: () => snapshot);
      expect(transport.requests.map((r) => r.bearerToken), [
        'token-1',
        'token-2',
      ]);
      expect(transport.requests.first.endpoint.path, '/v1/match-case');
      final body = jsonDecode(utf8.decode(transport.requests.first.body));
      expect(body, {
        'schemaVersion': '1',
        'caseId': snapshot.caseId,
        'expectedCaseRevision': 1,
      });
      final schema =
          jsonDecode(
                File(
                  'contracts/v1/match-request.schema.json',
                ).readAsStringSync(),
              )
              as Map<String, dynamic>;
      validate(body, schema);
      expect(transport.cancellations, 2);
    },
  );

  test(
    'all three typed outcomes pass through without Dart eligibility decisions',
    () async {
      for (var i = 0; i < 3; i++) {
        final transport = _FakeTransport(
          (_) async => jsonResponse(fixtureMatch(i)),
        );
        final snapshot = fixtureCase(i);
        final result = await makeClient(
          transport,
        ).matchCase(snapshot, currentCase: () => snapshot);
        expect(
          result.matches.single.status,
          fixtureMatch(i)['matches'][0]['status'],
        );
      }
    },
  );

  test(
    'null, empty, whitespace and unsafe tokens fail before any I/O',
    () async {
      for (final token in [
        null,
        '',
        ' ',
        '\n',
        'token\r\nInjected: value',
        'a b',
      ]) {
        final transport = _FakeTransport(
          (_) async => jsonResponse(fixtureMatch()),
        );
        final snapshot = fixtureCase();
        final client = makeClient(transport, tokenProvider: () async => token);
        await expectLater(
          client.matchCase(snapshot, currentCase: () => snapshot),
          throwsA(apiFailure('UNAUTHENTICATED')),
        );
        expect(transport.requests, isEmpty);
      }
    },
  );

  test('token-provider failures omit sensitive details', () async {
    final transport = _FakeTransport((_) async => jsonResponse(fixtureMatch()));
    final snapshot = fixtureCase();
    final client = makeClient(
      transport,
      tokenProvider: () async => throw StateError('secret-token'),
    );
    await expectLater(
      client.matchCase(snapshot, currentCase: () => snapshot),
      throwsA(
        apiFailure('UNAUTHENTICATED').having(
          (e) => e.toString(),
          'safe text',
          isNot(contains('secret-token')),
        ),
      ),
    );
    expect(transport.requests, isEmpty);
  });

  test(
    'token timeout cannot start a request after a late token arrives',
    () async {
      final token = Completer<String?>();
      final transport = _FakeTransport(
        (_) async => jsonResponse(fixtureMatch()),
      );
      final snapshot = fixtureCase();
      final client = makeClient(
        transport,
        tokenProvider: () => token.future,
        timeout: const Duration(milliseconds: 25),
      );
      await expectLater(
        client.matchCase(snapshot, currentCase: () => snapshot),
        throwsA(apiFailure('TIMEOUT')),
      );
      token.complete('late-token');
      await Future<void>.delayed(Duration.zero);
      expect(transport.requests, isEmpty);
    },
  );

  test('network timeout explicitly cancels the exchange', () async {
    final response = Completer<MatchingHttpResponse>();
    final transport = _FakeTransport((_) => response.future);
    final snapshot = fixtureCase();
    final client = makeClient(
      transport,
      timeout: const Duration(milliseconds: 25),
    );
    await expectLater(
      client.matchCase(snapshot, currentCase: () => snapshot),
      throwsA(apiFailure('TIMEOUT')),
    );
    expect(transport.cancellations, 1);
    response.complete(jsonResponse(fixtureMatch()));
  });

  test('unknown transport errors are safe network failures', () async {
    final transport = _FakeTransport(
      (_) async => throw StateError('token-and-private-response'),
    );
    final snapshot = fixtureCase();
    await expectLater(
      makeClient(transport).matchCase(snapshot, currentCase: () => snapshot),
      throwsA(
        apiFailure('NETWORK_ERROR').having(
          (e) => e.toString(),
          'safe text',
          isNot(contains('token-and-private-response')),
        ),
      ),
    );
    expect(transport.cancellations, 1);
  });

  test('response case ID and revision must match the request', () async {
    for (final change in [('caseId', 'another-case'), ('caseRevision', 2)]) {
      final response = fixtureMatch()..[change.$1] = change.$2;
      final transport = _FakeTransport((_) async => jsonResponse(response));
      final snapshot = fixtureCase();
      await expectLater(
        makeClient(transport).matchCase(snapshot, currentCase: () => snapshot),
        throwsA(apiFailure('STALE_RESPONSE')),
      );
    }
  });

  test('a newer active case supersedes an otherwise valid response', () async {
    final response = Completer<MatchingHttpResponse>();
    final transport = _FakeTransport((_) => response.future);
    final snapshot = fixtureCase();
    var activeCase = snapshot;
    final result = makeClient(
      transport,
    ).matchCase(snapshot, currentCase: () => activeCase);
    await Future<void>.delayed(Duration.zero);
    final newer = fixtureData().first['case'] as Map<String, dynamic>;
    newer['revision'] = 2;
    activeCase = CaseSnapshot.fromJson(newer);
    response.complete(jsonResponse(fixtureMatch()));
    await expectLater(result, throwsA(apiFailure('STALE_RESPONSE')));
  });

  test(
    'a changed case during token acquisition is rejected before I/O',
    () async {
      final snapshot = fixtureCase();
      final transport = _FakeTransport(
        (_) async => jsonResponse(fixtureMatch()),
      );
      await expectLater(
        makeClient(
          transport,
        ).matchCase(snapshot, currentCase: () => fixtureCase(1)),
        throwsA(apiFailure('STALE_RESPONSE')),
      );
      expect(transport.requests, isEmpty);
    },
  );

  test(
    'malformed JSON, invalid UTF-8, non-JSON and contract drift fail closed',
    () async {
      final wrongType = fixtureMatch()..['caseRevision'] = '1';
      final malformed = [
        MatchingHttpResponse(
          statusCode: 200,
          contentType: 'application/json',
          body: utf8.encode('{private raw body'),
        ),
        MatchingHttpResponse(
          statusCode: 200,
          contentType: 'application/json',
          body: [0xff],
        ),
        MatchingHttpResponse(
          statusCode: 200,
          contentType: 'text/html',
          body: utf8.encode('private html'),
        ),
        jsonResponse(wrongType),
        jsonResponse({'wrong': true}),
        jsonResponse(fixtureMatch(), status: 201),
      ];
      final snapshot = fixtureCase();
      for (final response in malformed) {
        final transport = _FakeTransport((_) async => response);
        await expectLater(
          makeClient(
            transport,
          ).matchCase(snapshot, currentCase: () => snapshot),
          throwsA(
            apiFailure('UNEXPECTED_RESPONSE').having(
              (e) => e.toString(),
              'safe text',
              isNot(contains('private')),
            ),
          ),
        );
      }
    },
  );

  test(
    'known API errors use status/code pairs and safe local messages',
    () async {
      final schema =
          jsonDecode(
                File('contracts/v1/api-error.schema.json').readAsStringSync(),
              )
              as Map<String, dynamic>;
      for (final pair in [
        (400, 'INVALID_REQUEST'),
        (401, 'UNAUTHENTICATED'),
        (404, 'CASE_NOT_FOUND'),
        (404, 'NOT_FOUND'),
        (409, 'CASE_REVISION_MISMATCH'),
        (413, 'PAYLOAD_TOO_LARGE'),
        (415, 'UNSUPPORTED_MEDIA_TYPE'),
        (405, 'METHOD_NOT_ALLOWED'),
        (500, 'INTERNAL_ERROR'),
        (503, 'SERVICE_UNAVAILABLE'),
      ]) {
        final envelope = {
          'schemaVersion': '1',
          'error': {'code': pair.$2, 'message': 'private-server-detail'},
        };
        validate(envelope, schema);
        final transport = _FakeTransport(
          (_) async => jsonResponse(envelope, status: pair.$1),
        );
        final snapshot = fixtureCase();
        await expectLater(
          makeClient(
            transport,
          ).matchCase(snapshot, currentCase: () => snapshot),
          throwsA(
            apiFailure(pair.$2).having(
              (e) => e.toString(),
              'safe text',
              isNot(contains('private-server-detail')),
            ),
          ),
        );
      }
    },
  );

  test(
    'mismatched codes, unknown statuses and extra error fields are unexpected',
    () async {
      for (final response in [
        jsonResponse({
          'schemaVersion': '1',
          'error': {'code': 'INTERNAL_ERROR', 'message': 'detail'},
        }, status: 401),
        jsonResponse({
          'schemaVersion': '1',
          'error': {
            'code': 'UNAUTHENTICATED',
            'message': 'detail',
            'stack': 'secret',
          },
        }, status: 401),
        jsonResponse({
          'schemaVersion': '1',
          'error': {'code': 'UNAUTHENTICATED', 'message': 'detail'},
        }, status: 418),
      ]) {
        final transport = _FakeTransport((_) async => response);
        final snapshot = fixtureCase();
        await expectLater(
          makeClient(
            transport,
          ).matchCase(snapshot, currentCase: () => snapshot),
          throwsA(apiFailure('UNEXPECTED_RESPONSE')),
        );
      }
    },
  );

  test(
    'client also enforces size and redirect restrictions for injected transports',
    () async {
      final snapshot = fixtureCase();
      final tooLarge = _FakeTransport(
        (_) async => MatchingHttpResponse(
          statusCode: 200,
          contentType: 'application/json',
          body: List.filled(11, 32),
        ),
      );
      await expectLater(
        makeClient(
          tooLarge,
          maxResponseBytes: 10,
        ).matchCase(snapshot, currentCase: () => snapshot),
        throwsA(apiFailure('RESPONSE_TOO_LARGE')),
      );
      final redirect = _FakeTransport(
        (_) async =>
            MatchingHttpResponse(statusCode: 303, contentType: null, body: []),
      );
      await expectLater(
        makeClient(redirect).matchCase(snapshot, currentCase: () => snapshot),
        throwsA(apiFailure('REDIRECT_BLOCKED')),
      );
    },
  );

  test(
    'production endpoints reject HTTP, credentials, query, fragments and path drift',
    () {
      final transport = _FakeTransport(
        (_) async => jsonResponse(fixtureMatch()),
      );
      for (final endpoint in [
        'http://example.org/v1/match-case',
        'http://127.0.0.1/v1/match-case',
        'https://secret-token@example.org/v1/match-case',
        'https://example.org/v1/match-case?token=secret-token',
        'https://example.org/v1/match-case#secret-token',
        'https://example.org/v1/match-case?',
        'https://example.org/v1/match-case#',
        'https://example.org/other',
        'file:///v1/match-case',
      ]) {
        expect(
          () => MatchingApiClient(
            endpoint: Uri.parse(endpoint),
            tokenProvider: () async => 'token',
            transport: transport,
          ),
          throwsA(
            isA<ArgumentError>().having(
              (e) => e.toString(),
              'safe configuration error',
              isNot(contains('secret-token')),
            ),
          ),
        );
      }
    },
  );

  test(
    'insecure development is restricted to exact explicit loopback hosts',
    () {
      final transport = _FakeTransport(
        (_) async => jsonResponse(fixtureMatch()),
      );
      for (final host in ['127.0.0.1', 'localhost', '[::1]']) {
        expect(
          () => MatchingApiClient(
            endpoint: Uri.parse('http://$host:8080/v1/match-case'),
            tokenProvider: () async => 'token',
            transport: transport,
            allowInsecureLoopback: true,
          ),
          returnsNormally,
        );
      }
      for (final host in [
        'example.org',
        'localhost.example.org',
        '127.0.0.2',
        '192.168.1.2',
        '10.0.2.2',
      ]) {
        expect(
          () => MatchingApiClient(
            endpoint: Uri.parse('http://$host:8080/v1/match-case'),
            tokenProvider: () async => 'token',
            transport: transport,
            allowInsecureLoopback: true,
          ),
          throwsArgumentError,
        );
      }
      expect(
        () => MatchingApiClient(
          endpoint: Uri.parse('http://10.0.2.2:8080/v1/match-case'),
          tokenProvider: () async => 'token',
          transport: transport,
          allowInsecureLoopback: true,
          allowAndroidEmulatorLoopback: true,
        ),
        returnsNormally,
      );
    },
  );
}

class _FakeTransport implements MatchingTransport {
  _FakeTransport(this.send);
  final Future<MatchingHttpResponse> Function(MatchingHttpRequest) send;
  final requests = <MatchingHttpRequest>[];
  var cancellations = 0;

  @override
  MatchingExchange post(MatchingHttpRequest request) {
    requests.add(request);
    return MatchingExchange(
      response: send(request),
      cancel: () => cancellations++,
    );
  }
}
