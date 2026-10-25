import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/shared/services/assessment_api_client.dart';
import 'package:safe_at_home/shared/services/matching_api_client.dart';
import 'package:safe_at_home/shared/services/session_service.dart';
import 'package:safe_at_home/shared/services/token_availability.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'session_reauthentication_test.dart'
    show ControlledAuth, ControlledClient, fictionalSession;

class _RefreshAuth extends ControlledAuth {
  _RefreshAuth() : super(session: fictionalSession('first', 'expired-token')) {
    session!.expiresAt = DateTime.now().millisecondsSinceEpoch ~/ 1000 - 60;
  }
  final refresh = Completer<AuthResponse>();
  int refreshCalls = 0;
  @override
  Future<AuthResponse> refreshSession([String? refreshToken]) async {
    refreshCalls++;
    final result = await refresh.future;
    if (result.session != null) {
      session = result.session;
      changes.add(AuthState(AuthChangeEvent.tokenRefreshed, session));
    }
    return result;
  }
}

class _Transport implements MatchingTransport {
  int calls = 0;
  int status = 200;
  @override
  MatchingExchange post(MatchingHttpRequest request) {
    calls++;
    return _Exchange(
      MatchingHttpResponse(
        statusCode: status,
        contentType: 'application/json',
        body: utf8.encode(
          jsonEncode(
            status == 200
                ? <String, Object?>{}
                : {
                    'schemaVersion': '2',
                    'error': {
                      'code': 'UNAUTHENTICATED',
                      'message': 'Sign in again.',
                    },
                  },
          ),
        ),
      ),
    );
  }
}

class _Exchange implements MatchingExchange {
  _Exchange(this.value);
  final MatchingHttpResponse value;
  @override
  Future<MatchingHttpResponse> get response async => value;
  @override
  void cancel() {}
}

Matcher code(String expected) =>
    isA<MatchingApiException>().having((error) => error.code, 'code', expected);

void main() {
  late _RefreshAuth auth;
  late ControlledClient client;
  late SupabaseSessionService service;
  late _Transport transport;
  setUp(() {
    auth = _RefreshAuth();
    client = ControlledClient(auth);
    service = SupabaseSessionService(
      client,
      callback: Uri.parse('safeathome://auth/callback'),
      emailDeliveryEnabled: false,
      reauthenticationClient: () => throw StateError('Unused verifier.'),
    );
    transport = _Transport();
  });
  tearDown(() async {
    service.dispose();
    if (!auth.refresh.isCompleted) {
      auth.refresh.complete(AuthResponse());
    }
    await client.dispose();
    auth.dispose();
  });
  PrivateV2JsonClient api(MatchingTokenProvider tokens) => PrivateV2JsonClient(
    baseUri: Uri.parse('https://fictional.invalid'),
    tokenProvider: tokens,
    transport: transport,
    allowedRoutes: const {'read-assessment', 'save-assessment'},
  );

  test(
    'retained retryable refresh maps to offline without sending a bearer',
    () async {
      final owner = service.userId, epoch = service.epoch;
      final result = api(
        service.accessToken,
      ).post('read-assessment', {}, isCurrent: () => true);
      final check = expectLater(result, throwsA(code('NETWORK_ERROR')));
      auth.refresh.completeError(
        AuthRetryableFetchException(message: 'private detail'),
      );
      await check;
      expect(service.userId, owner);
      expect(service.epoch, epoch);
      expect(transport.calls, 0);
      expect(auth.currentSession!.accessToken, 'expired-token');
    },
  );

  for (final nextOwner in <String?>[null, 'second', 'first']) {
    test(
      'retryable refresh cannot authorize cached state after boundary $nextOwner',
      () async {
        final result = service.accessToken();
        await Future<void>.delayed(Duration.zero);
        auth.switchTo(
          nextOwner == null ? null : fictionalSession(nextOwner, 'new-token'),
        );
        auth.refresh.completeError(AuthRetryableFetchException());
        expect(await result, isNull);
      },
    );
  }

  test(
    'terminal refresh remains unauthenticated and cannot dispatch',
    () async {
      final result = api(
        service.accessToken,
      ).post('read-assessment', {}, isCurrent: () => true);
      final check = expectLater(result, throwsA(code('UNAUTHENTICATED')));
      auth.refresh.completeError(
        const AuthApiException('Revoked', statusCode: '401'),
      );
      await check;
      expect(transport.calls, 0);
    },
  );

  testWidgets(
    'caller timeout keeps the underlying refresh inside the logout barrier',
    (tester) async {
      final result = service.accessToken();
      final check = expectLater(
        result,
        throwsA(isA<RetryableTokenUnavailableException>()),
      );
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump();
      expect(auth.refreshCalls, 1);
      await tester.pump(const Duration(seconds: 13));
      await check;
      final second = expectLater(
        service.accessToken(),
        throwsA(isA<RetryableTokenUnavailableException>()),
      );
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump(const Duration(seconds: 13));
      await second;
      expect(auth.refreshCalls, 1);
      var logoutFinished = false;
      final logout = service.signOut().then((_) => logoutFinished = true);
      await tester.pump();
      expect(service.cleaningUp, true);
      expect(logoutFinished, false);
      expect(auth.currentSession!.accessToken, 'expired-token');
      auth.refresh.complete(
        AuthResponse(session: fictionalSession('first', 'fresh-token')),
      );
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump();
      await logout;
      expect(service.userId, isNull);
      expect(auth.currentSession, isNull);
      expect(service.cleaningUp, false);
      expect(auth.refreshCalls, 1);
    },
  );

  test(
    'successful refresh returns a fresh bearer without rotating owner epoch',
    () async {
      final epoch = service.epoch;
      final result = service.accessToken();
      auth.refresh.complete(
        AuthResponse(session: fictionalSession('first', 'fresh-token')),
      );
      expect(await result, 'fresh-token');
      expect(service.epoch, epoch);
    },
  );

  test(
    'typed token failure is not an uncertain write and stale guard wins',
    () async {
      var current = true;
      final pending = Completer<String?>();
      final result = api(() => pending.future).post(
        'save-assessment',
        {},
        isCurrent: () => current,
        uncertainCode: 'CASE_SAVE_UNCERTAIN',
      );
      final check = expectLater(result, throwsA(code('STALE_RESPONSE')));
      current = false;
      pending.completeError(const RetryableTokenUnavailableException());
      await check;
      await expectLater(
        api(() async => throw const RetryableTokenUnavailableException()).post(
          'save-assessment',
          {},
          isCurrent: () => true,
          uncertainCode: 'CASE_SAVE_UNCERTAIN',
        ),
        throwsA(code('NETWORK_ERROR')),
      );
      expect(transport.calls, 0);
    },
  );

  test(
    'generic provider failure and actual backend 401 stay unauthenticated',
    () async {
      await expectLater(
        api(
          () async => throw StateError('Unavailable'),
        ).post('read-assessment', {}, isCurrent: () => true),
        throwsA(code('UNAUTHENTICATED')),
      );
      expect(transport.calls, 0);
      transport.status = 401;
      await expectLater(
        api(
          () async => 'valid-token',
        ).post('read-assessment', {}, isCurrent: () => true),
        throwsA(code('UNAUTHENTICATED')),
      );
      expect(transport.calls, 1);
    },
  );
}
