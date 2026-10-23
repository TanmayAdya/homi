import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/shared/models/contracts.dart';
import 'package:safe_at_home/shared/services/matching_api_client.dart';
import 'package:safe_at_home/shared/services/packet_api_client.dart';

import '../contracts/packet_test.dart'
    show packetJson, packetCaseJson, attachmentJson;
import '../contracts/schema_fixtures_test.dart' show validate;

MatchingHttpResponse responseJson(Object? json, {int status = 200}) =>
    MatchingHttpResponse(
      statusCode: status,
      contentType: 'application/json; charset=utf-8',
      body: utf8.encode(jsonEncode(json)),
    );

TypeMatcher<MatchingApiException> failure(String code) =>
    isA<MatchingApiException>().having((error) => error.code, 'code', code);

PacketApiClient clientFor(
  MatchingTransport transport, {
  MatchingTokenProvider? tokenProvider,
  Duration timeout = const Duration(seconds: 15),
  int maxResponseBytes = 1024 * 1024,
}) => PacketApiClient(
  endpoint: Uri.parse('https://example.org/v1/prepare-packet'),
  tokenProvider: tokenProvider ?? () async => 'test-token',
  transport: transport,
  timeout: timeout,
  maxResponseBytes: maxResponseBytes,
);

void main() {
  test(
    'exact schema request preserves retry key and obtains a fresh token per call',
    () async {
      var tokens = 0;
      final transport = _FakeTransport((_) async => responseJson(packetJson()));
      final client = clientFor(
        transport,
        tokenProvider: () async => 'token-${++tokens}',
      );
      final snapshot = CaseSnapshot.fromJson(packetCaseJson());
      for (var i = 0; i < 2; i++) {
        final packet = await client.preparePacket(
          snapshot,
          programId: 'demo-home-support',
          generationKey: 'attempt_0001',
          currentCase: () => snapshot,
        );
        expect(packet.status, 'draft');
      }
      expect(transport.requests.map((request) => request.bearerToken), [
        'token-1',
        'token-2',
      ]);
      expect(transport.requests.first.endpoint.path, '/v1/prepare-packet');
      final schema =
          jsonDecode(
                File(
                  'contracts/v1/packet-request.schema.json',
                ).readAsStringSync(),
              )
              as Map<String, dynamic>;
      for (final request in transport.requests) {
        final body = jsonDecode(utf8.decode(request.body));
        expect(body, {
          'schemaVersion': '1',
          'caseId': snapshot.caseId,
          'expectedCaseRevision': 1,
          'programId': 'demo-home-support',
          'generationKey': 'attempt_0001',
        });
        validate(body, schema);
      }
      expect(transport.cancellations, 2);
    },
  );

  test(
    'request identifiers, safe revision, and generation key validate before token I/O',
    () async {
      var tokens = 0;
      final transport = _FakeTransport((_) async => responseJson(packetJson()));
      final client = clientFor(
        transport,
        tokenProvider: () async {
          tokens++;
          return 'token';
        },
      );
      final snapshot = CaseSnapshot.fromJson(packetCaseJson());
      for (final invalidId in [
        ' ',
        List.filled(201, '😀').join(),
        '\ud800',
        '\udc00',
        'x\ud800y',
      ]) {
        await expectLater(
          client.preparePacket(
            snapshot,
            programId: invalidId,
            generationKey: 'attempt_0001',
            currentCase: () => snapshot,
          ),
          throwsA(failure('INVALID_REQUEST')),
        );
        final invalid = CaseSnapshot.fromJson(
          packetCaseJson()..['caseId'] = invalidId,
        );
        await expectLater(
          client.preparePacket(
            invalid,
            programId: 'demo-home-support',
            generationKey: 'attempt_0001',
            currentCase: () => invalid,
          ),
          throwsA(failure('INVALID_REQUEST')),
        );
      }
      for (final key in [
        '',
        'short',
        List.filled(129, 'a').join(),
        'attempt key',
        'attempt/0001',
        'attempt_0001\n',
        'attempt_0001\r\n',
        'attempt_😀',
      ]) {
        await expectLater(
          client.preparePacket(
            snapshot,
            programId: 'demo-home-support',
            generationKey: key,
            currentCase: () => snapshot,
          ),
          throwsA(failure('INVALID_REQUEST')),
        );
      }
      final unsafe = CaseSnapshot.fromJson(
        packetCaseJson()..['revision'] = 9007199254740992,
      );
      await expectLater(
        client.preparePacket(
          unsafe,
          programId: 'demo-home-support',
          generationKey: 'attempt_0001',
          currentCase: () => unsafe,
        ),
        throwsA(failure('INVALID_REQUEST')),
      );
      expect(tokens, 0);
      expect(transport.requests, isEmpty);
    },
  );

  test('200 Unicode scalars and maximum safe revision are accepted', () async {
    final id = List.filled(200, '😀').join();
    final json = packetCaseJson()
      ..['caseId'] = id
      ..['revision'] = 9007199254740991;
    final snapshot = CaseSnapshot.fromJson(json);
    final result = packetJson()
      ..['caseId'] = id
      ..['programId'] = id
      ..['caseRevision'] = snapshot.revision;
    final transport = _FakeTransport((_) async => responseJson(result));
    final packet = await clientFor(transport).preparePacket(
      snapshot,
      programId: id,
      generationKey: 'a_b-c_12',
      currentCase: () => snapshot,
    );
    expect(packet.caseRevision, 9007199254740991);
    expect(packet.programId.runes.length, 200);
  });

  test(
    'missing, expired, unsafe and failed session providers never expose details',
    () async {
      final snapshot = CaseSnapshot.fromJson(packetCaseJson());
      for (final provider in <MatchingTokenProvider>[
        () async => null,
        () async => '',
        () async => ' ',
        () async => 'a b',
        () async => 'token\r\nInjected: secret',
        () async => throw StateError('private-session'),
      ]) {
        final transport = _FakeTransport(
          (_) async => responseJson(packetJson()),
        );
        await expectLater(
          clientFor(transport, tokenProvider: provider).preparePacket(
            snapshot,
            programId: 'demo-home-support',
            generationKey: 'attempt_0001',
            currentCase: () => snapshot,
          ),
          throwsA(
            failure('UNAUTHENTICATED').having(
              (e) => e.toString(),
              'safe error',
              isNot(contains('private')),
            ),
          ),
        );
        expect(transport.requests, isEmpty);
      }
    },
  );

  test(
    'a token timeout never starts I/O when the provider eventually returns',
    () async {
      final token = Completer<String?>();
      final transport = _FakeTransport((_) async => responseJson(packetJson()));
      final snapshot = CaseSnapshot.fromJson(packetCaseJson());
      await expectLater(
        clientFor(
          transport,
          tokenProvider: () => token.future,
          timeout: const Duration(milliseconds: 25),
        ).preparePacket(
          snapshot,
          programId: 'demo-home-support',
          generationKey: 'attempt_0001',
          currentCase: () => snapshot,
        ),
        throwsA(failure('TIMEOUT')),
      );
      token.complete('late-token');
      await Future<void>.delayed(Duration.zero);
      expect(transport.requests, isEmpty);
    },
  );

  test(
    'network timeout cancels the exchange and retry keeps the same key',
    () async {
      final pending = Completer<MatchingHttpResponse>();
      var attempts = 0;
      final transport = _FakeTransport(
        (_) => ++attempts == 1
            ? pending.future
            : Future.value(responseJson(packetJson())),
      );
      final client = clientFor(
        transport,
        timeout: const Duration(milliseconds: 25),
      );
      final snapshot = CaseSnapshot.fromJson(packetCaseJson());
      Future<Object> prepare() => client.preparePacket(
        snapshot,
        programId: 'demo-home-support',
        generationKey: 'attempt_0001',
        currentCase: () => snapshot,
      );
      await expectLater(prepare(), throwsA(failure('TIMEOUT')));
      expect(transport.cancellations, 1);
      pending.complete(responseJson(packetJson()));
      await prepare();
      expect(transport.cancellations, 2);
      expect(
        transport.requests.map(
          (r) => jsonDecode(utf8.decode(r.body))['generationKey'],
        ),
        ['attempt_0001', 'attempt_0001'],
      );
    },
  );

  test(
    'unrecognized network and cancellation errors never leak transport details',
    () async {
      final transport = _FakeTransport(
        (_) async => throw StateError('private-network-token'),
        cancellationError: StateError('private-cancel-token'),
      );
      final snapshot = CaseSnapshot.fromJson(packetCaseJson());
      await expectLater(
        clientFor(transport).preparePacket(
          snapshot,
          programId: 'demo-home-support',
          generationKey: 'attempt_0001',
          currentCase: () => snapshot,
        ),
        throwsA(
          failure('NETWORK_ERROR').having(
            (e) => e.toString(),
            'safe text',
            isNot(contains('private')),
          ),
        ),
      );
    },
  );

  test(
    'wrong case, revision or program is not accepted as the requested packet',
    () async {
      final snapshot = CaseSnapshot.fromJson(packetCaseJson());
      for (final change in <(String, Object)>[
        ('caseId', 'another-case'),
        ('caseRevision', 2),
        ('programId', 'another-program'),
      ]) {
        final transport = _FakeTransport(
          (_) async => responseJson(packetJson()..[change.$1] = change.$2),
        );
        await expectLater(
          clientFor(transport).preparePacket(
            snapshot,
            programId: 'demo-home-support',
            generationKey: 'attempt_0001',
            currentCase: () => snapshot,
          ),
          throwsA(failure('STALE_RESPONSE')),
        );
      }
    },
  );

  test(
    'case and selected-program changes discard a response that arrives late',
    () async {
      final snapshot = CaseSnapshot.fromJson(packetCaseJson());
      for (final changeCase in [true, false]) {
        var current = snapshot;
        var selected = 'demo-home-support';
        final pending = Completer<MatchingHttpResponse>();
        final transport = _FakeTransport((_) => pending.future);
        final request = clientFor(transport).preparePacket(
          snapshot,
          programId: selected,
          generationKey: 'attempt_0001',
          currentCase: () => current,
          currentProgramId: () => selected,
        );
        await Future<void>.delayed(Duration.zero);
        if (changeCase) {
          current = CaseSnapshot.fromJson(packetCaseJson()..['revision'] = 2);
        } else {
          selected = 'another-program';
        }
        pending.complete(responseJson(packetJson()));
        await expectLater(request, throwsA(failure('STALE_RESPONSE')));
      }
    },
  );

  test(
    'changed or unavailable current context prevents I/O after token acquisition',
    () async {
      final snapshot = CaseSnapshot.fromJson(packetCaseJson());
      final transport = _FakeTransport((_) async => responseJson(packetJson()));
      for (final current in <CaseSnapshot Function()>[
        () => CaseSnapshot.fromJson(packetCaseJson(1)),
        () => throw StateError('private-state'),
      ]) {
        await expectLater(
          clientFor(transport).preparePacket(
            snapshot,
            programId: 'demo-home-support',
            generationKey: 'attempt_0001',
            currentCase: current,
          ),
          throwsA(failure('STALE_RESPONSE')),
        );
      }
      await expectLater(
        clientFor(transport).preparePacket(
          snapshot,
          programId: 'demo-home-support',
          generationKey: 'attempt_0001',
          currentCase: () => snapshot,
          currentProgramId: () => 'another',
        ),
        throwsA(failure('STALE_RESPONSE')),
      );
      expect(transport.requests, isEmpty);
    },
  );

  test(
    'attachments must reference evidence in a confirmed finding of this case',
    () async {
      final snapshot = CaseSnapshot.fromJson(packetCaseJson());
      final good = packetJson()..['attachments'] = [attachmentJson()];
      final transport = _FakeTransport((_) async => responseJson(good));
      final packet = await clientFor(transport).preparePacket(
        snapshot,
        programId: 'demo-home-support',
        generationKey: 'attempt_0001',
        currentCase: () => snapshot,
      );
      expect(packet.attachments, hasLength(1));
      for (final change in <(String, String)>[
        ('findingId', 'another-finding'),
        ('evidenceId', 'another-evidence'),
        ('storageReference', 'https://example.org/public.jpg'),
      ]) {
        final json = packetJson()
          ..['attachments'] = [attachmentJson()..[change.$1] = change.$2];
        final invalid = _FakeTransport((_) async => responseJson(json));
        await expectLater(
          clientFor(invalid).preparePacket(
            snapshot,
            programId: 'demo-home-support',
            generationKey: 'attempt_0001',
            currentCase: () => snapshot,
          ),
          throwsA(failure('UNEXPECTED_RESPONSE')),
        );
      }
      for (final state in ['needs_review', 'dismissed']) {
        final json = packetCaseJson();
        json['findings'][0]['reviewState'] = state;
        final current = CaseSnapshot.fromJson(json);
        await expectLater(
          clientFor(transport).preparePacket(
            current,
            programId: 'demo-home-support',
            generationKey: 'attempt_0001',
            currentCase: () => current,
          ),
          throwsA(failure('UNEXPECTED_RESPONSE')),
        );
      }
    },
  );

  test(
    'malformed bodies, wrong types and invented packet status fail safely',
    () async {
      final snapshot = CaseSnapshot.fromJson(packetCaseJson());
      for (final response in [
        MatchingHttpResponse(
          statusCode: 200,
          contentType: 'application/json',
          body: utf8.encode('{private'),
        ),
        MatchingHttpResponse(
          statusCode: 200,
          contentType: 'application/json',
          body: [0xff],
        ),
        MatchingHttpResponse(
          statusCode: 200,
          contentType: 'text/html',
          body: utf8.encode('private'),
        ),
        responseJson(packetJson()..['status'] = 'approved'),
        responseJson(packetJson()..['isDemo'] = 'true'),
        responseJson(packetJson()..['caseRevision'] = '1'),
        responseJson(packetJson(), status: 201),
        responseJson({'wrong': true}),
      ]) {
        final transport = _FakeTransport((_) async => response);
        await expectLater(
          clientFor(transport).preparePacket(
            snapshot,
            programId: 'demo-home-support',
            generationKey: 'attempt_0001',
            currentCase: () => snapshot,
          ),
          throwsA(
            failure('UNEXPECTED_RESPONSE').having(
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
    'server errors enforce status/code pairs and use only safe local messages',
    () async {
      final snapshot = CaseSnapshot.fromJson(packetCaseJson());
      final schema =
          jsonDecode(
                File('contracts/v1/api-error.schema.json').readAsStringSync(),
              )
              as Map<String, dynamic>;
      for (final pair in [
        (400, 'INVALID_REQUEST'),
        (401, 'UNAUTHENTICATED'),
        (404, 'CASE_NOT_FOUND'),
        (404, 'PROGRAM_NOT_FOUND'),
        (404, 'NOT_FOUND'),
        (409, 'CASE_REVISION_MISMATCH'),
        (409, 'PACKET_GENERATION_CONFLICT'),
        (409, 'FORM_ANSWERS_STALE'),
        (413, 'PAYLOAD_TOO_LARGE'),
        (415, 'UNSUPPORTED_MEDIA_TYPE'),
        (405, 'METHOD_NOT_ALLOWED'),
        (500, 'INTERNAL_ERROR'),
        (503, 'SERVICE_UNAVAILABLE'),
      ]) {
        final json = {
          'schemaVersion': '1',
          'error': {'code': pair.$2, 'message': 'private-server-detail'},
        };
        validate(json, schema);
        final transport = _FakeTransport(
          (_) async => responseJson(json, status: pair.$1),
        );
        await expectLater(
          clientFor(transport).preparePacket(
            snapshot,
            programId: 'demo-home-support',
            generationKey: 'attempt_0001',
            currentCase: () => snapshot,
          ),
          throwsA(
            failure(pair.$2)
                .having((e) => e.statusCode, 'HTTP status', pair.$1)
                .having(
                  (e) => e.toString(),
                  'safe text',
                  isNot(contains('private-server-detail')),
                ),
          ),
        );
      }
      expect(
        MatchingApiException.forCode('PACKET_GENERATION_CONFLICT').message,
        contains('Start a new draft'),
      );
      expect(
        MatchingApiException.forCode('private-unknown-code').toString(),
        isNot(contains('private')),
      );
    },
  );

  test(
    'mismatched codes, unknown statuses and extra error fields are rejected',
    () async {
      final snapshot = CaseSnapshot.fromJson(packetCaseJson());
      for (final response in [
        responseJson({
          'schemaVersion': '1',
          'error': {'code': 'PROGRAM_NOT_FOUND', 'message': 'detail'},
        }, status: 401),
        responseJson({
          'schemaVersion': '1',
          'error': {'code': 'PACKET_GENERATION_CONFLICT', 'message': 'detail'},
        }, status: 418),
        responseJson({
          'schemaVersion': '1',
          'error': {
            'code': 'UNAUTHENTICATED',
            'message': 'detail',
            'stack': 'private',
          },
        }, status: 401),
        responseJson({
          'schemaVersion': '1',
          'error': {'code': 'UNAUTHENTICATED', 'message': ''},
        }, status: 401),
      ]) {
        final transport = _FakeTransport((_) async => response);
        await expectLater(
          clientFor(transport).preparePacket(
            snapshot,
            programId: 'demo-home-support',
            generationKey: 'attempt_0001',
            currentCase: () => snapshot,
          ),
          throwsA(failure('UNEXPECTED_RESPONSE')),
        );
      }
    },
  );

  test(
    'injected transports still enforce byte caps, redirects and safe failures',
    () async {
      final snapshot = CaseSnapshot.fromJson(packetCaseJson());
      for (final pair in [
        (
          MatchingHttpResponse(
            statusCode: 200,
            contentType: 'application/json',
            body: List.filled(11, 32),
          ),
          'RESPONSE_TOO_LARGE',
        ),
        (
          MatchingHttpResponse(statusCode: 303, contentType: null, body: []),
          'REDIRECT_BLOCKED',
        ),
      ]) {
        final transport = _FakeTransport((_) async => pair.$1);
        await expectLater(
          clientFor(transport, maxResponseBytes: 10).preparePacket(
            snapshot,
            programId: 'demo-home-support',
            generationKey: 'attempt_0001',
            currentCase: () => snapshot,
          ),
          throwsA(failure(pair.$2)),
        );
      }
      for (final pair in [
        (MatchingTransportFailure.network, 'NETWORK_ERROR'),
        (MatchingTransportFailure.responseTooLarge, 'RESPONSE_TOO_LARGE'),
        (MatchingTransportFailure.redirectBlocked, 'REDIRECT_BLOCKED'),
      ]) {
        final transport = _FakeTransport(
          (_) async => throw MatchingTransportException(pair.$1),
        );
        await expectLater(
          clientFor(transport).preparePacket(
            snapshot,
            programId: 'demo-home-support',
            generationKey: 'attempt_0001',
            currentCase: () => snapshot,
          ),
          throwsA(failure(pair.$2)),
        );
      }
    },
  );

  test(
    'endpoint and bounds reject credentials, path drift and unsafe origins',
    () {
      final transport = _FakeTransport((_) async => responseJson(packetJson()));
      for (final endpoint in [
        'http://example.org/v1/prepare-packet',
        'http://127.0.0.1/v1/prepare-packet',
        'https://private@example.org/v1/prepare-packet',
        'https://example.org/v1/prepare-packet?private=x',
        'https://example.org/v1/prepare-packet#private',
        'https://example.org/v1/match-case',
        'https://example.org/v1/prepare-packet?',
        'https://example.org/v1/prepare-packet#',
        'file:///v1/prepare-packet',
      ]) {
        expect(
          () => PacketApiClient(
            endpoint: Uri.parse(endpoint),
            tokenProvider: () async => 'token',
            transport: transport,
          ),
          throwsA(
            isA<ArgumentError>().having(
              (e) => e.toString(),
              'safe text',
              isNot(contains('private')),
            ),
          ),
        );
      }
      for (final timeout in [Duration.zero, const Duration(seconds: 16)]) {
        expect(
          () => clientFor(transport, timeout: timeout),
          throwsArgumentError,
        );
      }
      for (final limit in [0, 1024 * 1024 + 1]) {
        expect(
          () => clientFor(transport, maxResponseBytes: limit),
          throwsArgumentError,
        );
      }
    },
  );

  test(
    'only exact loopback hosts are accepted with explicit development flags',
    () {
      final transport = _FakeTransport((_) async => responseJson(packetJson()));
      for (final host in ['localhost', '127.0.0.1', '[::1]']) {
        expect(
          () => PacketApiClient(
            endpoint: Uri.parse('http://$host:8080/v1/prepare-packet'),
            tokenProvider: () async => 'token',
            transport: transport,
            allowInsecureLoopback: true,
          ),
          returnsNormally,
        );
      }
      for (final host in [
        'localhost.example.org',
        '127.0.0.2',
        '192.168.1.2',
        '10.0.2.2',
      ]) {
        expect(
          () => PacketApiClient(
            endpoint: Uri.parse('http://$host:8080/v1/prepare-packet'),
            tokenProvider: () async => 'token',
            transport: transport,
            allowInsecureLoopback: true,
          ),
          throwsArgumentError,
        );
      }
      expect(
        () => PacketApiClient(
          endpoint: Uri.parse('http://10.0.2.2:8080/v1/prepare-packet'),
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
  _FakeTransport(this.send, {this.cancellationError});
  final Future<MatchingHttpResponse> Function(MatchingHttpRequest) send;
  final Object? cancellationError;
  final requests = <MatchingHttpRequest>[];
  var cancellations = 0;

  @override
  MatchingExchange post(MatchingHttpRequest request) {
    requests.add(request);
    return MatchingExchange(
      response: send(request),
      cancel: () {
        cancellations++;
        if (cancellationError != null) throw cancellationError!;
      },
    );
  }
}
