import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/shared/models/contracts.dart';
import 'package:safe_at_home/shared/services/io_matching_transport.dart';
import 'package:safe_at_home/shared/services/matching_api_client.dart';

void main() {
  late HttpServer server;
  late CaseSnapshot snapshot;
  late Object? match;

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final fixtures =
        jsonDecode(
              File('contracts/v1/fixtures/scenarios.json').readAsStringSync(),
            )
            as List;
    snapshot = CaseSnapshot.fromJson(fixtures.first['case']);
    match = fixtures.first['match'];
  });
  tearDown(() async => server.close(force: true));

  MatchingApiClient client({
    Duration timeout = const Duration(seconds: 15),
    int maxResponseBytes = 1024 * 1024,
  }) => MatchingApiClient(
    endpoint: Uri.parse('http://127.0.0.1:${server.port}/v1/match-case'),
    tokenProvider: () async => 'io-test-token',
    transport: IoMatchingTransport(),
    allowInsecureLoopback: true,
    timeout: timeout,
    maxResponseBytes: maxResponseBytes,
  );

  test(
    'native transport POSTs JSON and bearer token to the exact endpoint',
    () async {
      final received = Completer<(String, String, String?, Object?)>();
      server.listen((request) async {
        final body = jsonDecode(await utf8.decoder.bind(request).join());
        received.complete((
          request.method,
          request.uri.path,
          request.headers.value(HttpHeaders.authorizationHeader),
          body,
        ));
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode(match));
        await request.response.close();
      });
      final result = await client().matchCase(
        snapshot,
        currentCase: () => snapshot,
      );
      final request = await received.future;
      expect(request.$1, 'POST');
      expect(request.$2, '/v1/match-case');
      expect(request.$3, 'Bearer io-test-token');
      expect(request.$4, {
        'schemaVersion': '1',
        'caseId': snapshot.caseId,
        'expectedCaseRevision': 1,
      });
      expect(result.caseId, snapshot.caseId);
    },
  );

  test(
    'redirects are rejected without sending credentials to the target',
    () async {
      final paths = <String>[];
      server.listen((request) async {
        paths.add(request.uri.path);
        if (request.uri.path == '/v1/match-case') {
          request.response.statusCode = 303;
          request.response.headers.set(
            HttpHeaders.locationHeader,
            'http://127.0.0.1:${server.port}/collect-token',
          );
        }
        await request.response.close();
      });
      await expectLater(
        client().matchCase(snapshot, currentCase: () => snapshot),
        throwsA(
          isA<MatchingApiException>().having(
            (e) => e.code,
            'code',
            'REDIRECT_BLOCKED',
          ),
        ),
      );
      expect(paths, ['/v1/match-case']);
    },
  );

  test(
    'native transport carries one bounded retry hint without retrying',
    () async {
      var requests = 0;
      server.listen((request) async {
        requests++;
        await request.drain<void>();
        request.response.statusCode = 429;
        request.response.headers.contentType = ContentType.json;
        if (requests == 1) {
          request.response.headers.set(HttpHeaders.retryAfterHeader, '7');
        } else {
          request.response.headers.add(HttpHeaders.retryAfterHeader, '7');
          request.response.headers.add(HttpHeaders.retryAfterHeader, '9');
        }
        request.response.write(
          jsonEncode({
            'schemaVersion': '1',
            'error': {
              'code': 'RATE_LIMITED',
              'message': 'Private provider details',
            },
          }),
        );
        await request.response.close();
      });
      for (var attempt = 0; attempt < 2; attempt++) {
        await expectLater(
          client().matchCase(snapshot, currentCase: () => snapshot),
          throwsA(
            isA<MatchingApiException>()
                .having((error) => error.code, 'code', 'RATE_LIMITED')
                .having(
                  (error) => error.retryAfter,
                  'delay',
                  attempt == 0 ? const Duration(seconds: 7) : null,
                )
                .having(
                  (error) => error.message,
                  'safe message',
                  isNot(contains('Private')),
                ),
          ),
        );
        expect(requests, attempt + 1);
      }
    },
  );

  test('declared oversized response is rejected before parsing', () async {
    server.listen((request) async {
      request.response.headers.contentType = ContentType.json;
      request.response.contentLength = 1024;
      request.response.add(List.filled(1024, 32));
      await request.response.close();
    });
    await expectLater(
      client(
        maxResponseBytes: 100,
      ).matchCase(snapshot, currentCase: () => snapshot),
      throwsA(
        isA<MatchingApiException>().having(
          (e) => e.code,
          'code',
          'RESPONSE_TOO_LARGE',
        ),
      ),
    );
  });

  test('chunked body is capped even without a content-length header', () async {
    server.listen((request) async {
      try {
        request.response.headers.contentType = ContentType.json;
        request.response.bufferOutput = false;
        request.response.add(List.filled(60, 32));
        await request.response.flush();
        request.response.add(List.filled(60, 32));
        await request.response.close();
      } on IOException {
        // ignore: empty_catches
      }
    });
    await expectLater(
      client(
        maxResponseBytes: 100,
      ).matchCase(snapshot, currentCase: () => snapshot),
      throwsA(
        isA<MatchingApiException>().having(
          (e) => e.code,
          'code',
          'RESPONSE_TOO_LARGE',
        ),
      ),
    );
  });

  test(
    'overall deadline stops a continually trickling response body',
    () async {
      Timer? trickle;
      addTearDown(() => trickle?.cancel());
      server.listen((request) async {
        request.response.headers.contentType = ContentType.json;
        request.response.bufferOutput = false;
        request.response.write('[');
        await request.response.flush();
        trickle = Timer.periodic(const Duration(milliseconds: 10), (_) {
          request.response.write(' ');
          unawaited(request.response.flush().catchError((Object _) {}));
        });
      });
      final elapsed = Stopwatch()..start();
      await expectLater(
        client(
          timeout: const Duration(milliseconds: 150),
        ).matchCase(snapshot, currentCase: () => snapshot),
        throwsA(
          isA<MatchingApiException>().having((e) => e.code, 'code', 'TIMEOUT'),
        ),
      );
      expect(elapsed.elapsed, lessThan(const Duration(seconds: 2)));
    },
  );

  test('unreachable native endpoint becomes a safe network error', () async {
    final service = client();
    await server.close(force: true);
    await expectLater(
      service.matchCase(snapshot, currentCase: () => snapshot),
      throwsA(
        isA<MatchingApiException>().having(
          (e) => e.code,
          'code',
          'NETWORK_ERROR',
        ),
      ),
    );
  });
}
