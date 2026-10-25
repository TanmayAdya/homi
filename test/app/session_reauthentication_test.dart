import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:safe_at_home/shared/services/session_service.dart';

Session fictionalSession(String owner, String token) => Session(
  accessToken: token,
  refreshToken: 'fictional-refresh',
  tokenType: 'bearer',
  expiresIn: 3600,
  user: User(
    id: owner,
    appMetadata: {},
    userMetadata: {},
    aud: 'authenticated',
    createdAt: '2026-10-22T00:00:00Z',
    email: '$owner@example.invalid',
  ),
)..expiresAt = DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600;

class ControlledAuth extends GoTrueClient {
  ControlledAuth({this.session}) : super(autoRefreshToken: false);
  Session? session;
  final changes = StreamController<AuthState>.broadcast(sync: true);
  Completer<AuthResponse>? pending;
  bool disposed = false;
  int passwordCalls = 0;
  @override
  Session? get currentSession => session;
  @override
  User? get currentUser => session?.user;
  @override
  Stream<AuthState> get onAuthStateChange => changes.stream;
  @override
  Future<AuthResponse> signInWithPassword({
    String? email,
    String? phone,
    required String password,
    String? captchaToken,
  }) async {
    passwordCalls++;
    final response = await pending!.future;
    session = response.session;
    if (!disposed) changes.add(AuthState(AuthChangeEvent.signedIn, session));
    return response;
  }

  void switchTo(Session? next) {
    session = next;
    changes.add(
      AuthState(
        next == null ? AuthChangeEvent.signedOut : AuthChangeEvent.signedIn,
        next,
      ),
    );
  }

  @override
  Future<void> signOut({SignOutScope scope = SignOutScope.local}) async =>
      switchTo(null);
  @override
  void dispose() {
    disposed = true;
    unawaited(changes.close());
    super.dispose();
  }
}

class ControlledClient extends SupabaseClient {
  ControlledClient(this.controlled)
    : super(
        'https://fictional.supabase.co',
        'fictional-publishable',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
      );
  final ControlledAuth controlled;
  @override
  GoTrueClient get auth => controlled;
}

void main() {
  late ControlledAuth shared, verifier;
  late ControlledClient client;
  late SupabaseSessionService service;
  setUp(() {
    shared = ControlledAuth(
      session: fictionalSession('first', 'original-token'),
    );
    verifier = ControlledAuth()..pending = Completer<AuthResponse>();
    client = ControlledClient(shared);
    service = SupabaseSessionService(
      client,
      callback: Uri.parse('safeathome://auth/callback'),
      emailDeliveryEnabled: false,
      reauthenticationClient: () => verifier,
    );
  });
  tearDown(() async {
    service.dispose();
    await client.dispose();
    shared.dispose();
  });
  test(
    'confirmation supplies fresh proof without replacing the persistent session',
    () async {
      final attempt = service.reauthenticate('fictional-password');
      verifier.pending!.complete(
        AuthResponse(session: fictionalSession('first', 'fresh-token')),
      );
      await attempt;
      expect(await service.accessToken(), 'fresh-token');
      expect(shared.currentSession!.accessToken, 'original-token');
      expect(shared.passwordCalls, 0);
      expect(verifier.disposed, true);
      await service.signOut();
      expect(await service.accessToken(), isNull);
    },
  );
  test('late confirmation cannot restore a signed-out account', () async {
    final attempt = service.reauthenticate('fictional-password');
    final rejected = expectLater(attempt, throwsStateError);
    await service.signOut();
    verifier.pending!.complete(
      AuthResponse(session: fictionalSession('first', 'late-token')),
    );
    await rejected;
    expect(shared.currentSession, isNull);
    expect(service.userId, isNull);
    expect(await service.accessToken(), isNull);
    expect(verifier.disposed, true);
  });
  test(
    'late confirmation cannot replace another account or its bearer',
    () async {
      final attempt = service.reauthenticate('fictional-password');
      final rejected = expectLater(attempt, throwsStateError);
      shared.switchTo(fictionalSession('second', 'second-token'));
      verifier.pending!.complete(
        AuthResponse(session: fictionalSession('first', 'late-token')),
      );
      await rejected;
      expect(service.userId, 'second');
      expect(await service.accessToken(), 'second-token');
      expect(shared.currentSession!.user.id, 'second');
    },
  );
  testWidgets(
    'stalled confirmation times out without adopting its late token',
    (tester) async {
      final attempt = service.reauthenticate('fictional-password');
      final rejected = expectLater(attempt, throwsA(isA<TimeoutException>()));
      await tester.pump(const Duration(seconds: 16));
      await rejected;
      expect(verifier.disposed, true);
      verifier.pending!.complete(
        AuthResponse(session: fictionalSession('first', 'late-token')),
      );
      await tester.pump();
      expect(await service.accessToken(), 'original-token');
      expect(shared.currentSession!.accessToken, 'original-token');
    },
  );
}
