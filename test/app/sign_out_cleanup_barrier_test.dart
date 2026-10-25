import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:safe_at_home/app/live_app.dart';
import 'package:safe_at_home/shared/services/local_private_store.dart';
import 'package:safe_at_home/shared/services/session_service.dart';
import 'local_private_store_test.dart' show MemorySecrets;
import 'session_reauthentication_test.dart'
    show ControlledAuth, ControlledClient, fictionalSession;

const _namespace = 'sah.auth.fictional.supabase.co';

class DelayedLogoutAuth extends ControlledAuth {
  DelayedLogoutAuth()
    : super(session: fictionalSession('first', 'original-token'));
  final logout = Completer<void>();
  Completer<AuthSessionUrlResponse>? callback;
  int logoutCalls = 0, recoveryCalls = 0, callbackCalls = 0;
  @override
  Future<AuthSessionUrlResponse> getSessionFromUrl(
    Uri originUrl, {
    bool storeSession = true,
  }) async {
    callbackCalls++;
    final response = await callback!.future;
    switchTo(response.session);
    await SecureSessionStorage(
      DeviceSecretStore(),
      _namespace,
    ).persistSession(response.session.accessToken);
    return response;
  }

  @override
  Future<void> signOut({SignOutScope scope = SignOutScope.local}) async {
    logoutCalls++;
    switchTo(null);
    await logout.future;
  }

  @override
  Future<AuthResponse> signInWithPassword({
    String? email,
    String? phone,
    required String password,
    String? captchaToken,
  }) async {
    final result = await super.signInWithPassword(
      email: email,
      password: password,
    );
    await SecureSessionStorage(
      DeviceSecretStore(),
      _namespace,
    ).persistSession(result.session!.accessToken);
    return result;
  }

  @override
  Future<void> resetPasswordForEmail(
    String email, {
    String? redirectTo,
    String? captchaToken,
  }) async {
    recoveryCalls++;
    await SecurePkceStorage(
      DeviceSecretStore(),
      _namespace,
    ).setItem(key: 'new-recovery', value: 'new-fictional-verifier');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const media = MethodChannel('safe_at_home/private_media');
  late Directory directory;
  late DelayedLogoutAuth auth;
  late ControlledClient client;
  late SupabaseSessionService session;
  late AppServices app;
  Completer<void>? nativeCleanup;
  var nativeCalls = 0;

  Future<void> drain() async {
    for (var i = 0; i < 12; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({
      '$_namespace.session': 'original-persisted-token',
    });
    directory = await Directory.systemTemp.createTemp('sah-logout-barrier-');
    nativeCleanup = null;
    nativeCalls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(media, (call) async {
          if (call.method == 'clearTemporaryMedia') {
            nativeCalls++;
            await nativeCleanup?.future;
          }
          if (call.method == 'privateRootDirectory') return directory.path;
          return null;
        });
    auth = DelayedLogoutAuth()..pending = Completer<AuthResponse>();
    client = ControlledClient(auth);
    session = SupabaseSessionService(
      client,
      callback: Uri.parse('safeathome://auth/callback'),
      emailDeliveryEnabled: true,
      reauthenticationClient: () => ControlledAuth(),
    );
    app = AppServices(
      config: LiveAppConfig(
        apiOrigin: Uri.parse('https://fictional.example'),
        supabaseUrl: Uri.parse('https://fictional.supabase.co'),
        publishableKey: 'fictional',
      ),
      session: session,
      store: LocalPrivateStore(
        directory: Directory('${directory.path}/first'),
        accountId: 'first',
        secrets: MemorySecrets(),
      ),
    );
    await app.store.writeJson('case.original', {'fictional': true});
  });
  tearDown(() async {
    app.dispose();
    session.dispose();
    await client.dispose();
    auth.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(media, null);
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  test(
    'new sign-in waits for provider logout and all native cleanup',
    () async {
      nativeCleanup = Completer<void>();
      final signingOut = app.signOut();
      expect(session.cleaningUp, true);
      final signingIn = session.signIn('first@example.invalid', 'fictional');
      final recovery = session.requestRecovery('first@example.invalid');
      var mayReopen = false;
      final reopen = session.waitForAccountCleanup().then(
        (_) => mayReopen = true,
      );
      await drain();
      expect(session.userId, isNull);
      expect(await session.accessToken(), isNull);
      expect(auth.logoutCalls, 1);
      expect(auth.passwordCalls, 0);
      expect(auth.recoveryCalls, 0);
      expect(nativeCalls, 0);
      auth.logout.complete();
      for (var i = 0; i < 100 && nativeCalls == 0; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }
      expect(nativeCalls, 1);
      expect(mayReopen, false);
      expect(auth.passwordCalls, 0);
      expect(await app.store.directory.exists(), false);
      nativeCleanup!.complete();
      await signingOut;
      await reopen;
      expect(session.cleaningUp, false);
      expect(mayReopen, true);
      auth.pending!.complete(
        AuthResponse(session: fictionalSession('first', 'new-token')),
      );
      await signingIn;
      await recovery;
      final reopened = LocalPrivateStore(
        directory: app.store.directory,
        accountId: 'first',
        secrets: app.store.secrets,
      );
      await reopened.writeJson('case.new', {'fictional': 'new'});
      await drain();
      expect(await reopened.readJson('case.new'), {'fictional': 'new'});
      expect(
        await SecureSessionStorage(
          DeviceSecretStore(),
          _namespace,
        ).accessToken(),
        'new-token',
      );
      expect(
        await SecurePkceStorage(
          DeviceSecretStore(),
          _namespace,
        ).getItem(key: 'new-recovery'),
        'new-fictional-verifier',
      );
      expect(nativeCalls, 1);
      await reopened.close();
    },
  );

  test('public provider sign-out also defers a new sign-in', () async {
    final logout = session.signOut();
    final login = session.signIn('second@example.invalid', 'fictional');
    await drain();
    expect(auth.passwordCalls, 0);
    auth.logout.complete();
    await logout;
    auth.pending!.complete(
      AuthResponse(session: fictionalSession('second', 'second-token')),
    );
    await login;
    expect(session.userId, 'second');
    expect(await session.accessToken(), 'second-token');
  });

  test(
    'earlier pending login settles before stale AppServices may clean up',
    () async {
      final login = session.signIn('second@example.invalid', 'fictional');
      await drain();
      expect(auth.passwordCalls, 1);
      final rejected = expectLater(app.signOut(), throwsStateError);
      expect(session.cleaningUp, true);
      await drain();
      expect(auth.logoutCalls, 0);
      auth.pending!.complete(
        AuthResponse(session: fictionalSession('second', 'second-token')),
      );
      await login;
      await rejected;
      expect(session.userId, 'second');
      expect(auth.logoutCalls, 0);
      expect(nativeCalls, 0);
      expect(await app.store.readJson('case.original'), {'fictional': true});
      expect(
        await SecureSessionStorage(
          DeviceSecretStore(),
          _namespace,
        ).accessToken(),
        'second-token',
      );
    },
  );

  test('already stale AppServices cannot enter destructive cleanup', () async {
    auth.switchTo(fictionalSession('second', 'second-token'));
    await expectLater(app.signOut(), throwsStateError);
    expect(session.cleaningUp, false);
    expect(auth.logoutCalls, 0);
    expect(nativeCalls, 0);
    expect(await app.store.readJson('case.original'), {'fictional': true});
  });

  test(
    'provider logout failure still finishes private cleanup before login',
    () async {
      final rejected = expectLater(app.signOut(), throwsStateError);
      final login = session.signIn('second@example.invalid', 'fictional');
      await drain();
      auth.logout.completeError(StateError('Fictional provider failure'));
      await rejected;
      expect(nativeCalls, 1);
      expect(await app.store.directory.exists(), false);
      auth.pending!.complete(
        AuthResponse(session: fictionalSession('second', 'second-token')),
      );
      await login;
      expect(session.userId, 'second');
      expect(
        await SecureSessionStorage(
          DeviceSecretStore(),
          _namespace,
        ).accessToken(),
        'second-token',
      );
    },
  );

  test(
    'callback exchange is serialized behind private cleanup (fake provider)',
    () async {
      nativeCleanup = Completer<void>();
      auth.callback = Completer<AuthSessionUrlResponse>();
      final logout = app.signOut();
      final uri = Uri.parse('safeathome://auth/callback?code=fictional-code');
      final callback = session.handleCallback(uri);
      final duplicate = session.handleCallback(uri);
      expect(identical(callback, duplicate), true);
      await drain();
      expect(auth.callbackCalls, 0);
      auth.logout.complete();
      for (var i = 0; i < 100 && nativeCalls == 0; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }
      expect(nativeCalls, 1);
      expect(auth.callbackCalls, 0);
      nativeCleanup!.complete();
      await logout;
      auth.callback!.complete(
        AuthSessionUrlResponse(
          session: fictionalSession('second', 'callback-token'),
          redirectType: 'recovery',
        ),
      );
      await callback;
      await duplicate;
      expect(auth.callbackCalls, 1);
      expect(session.userId, 'second');
      expect(
        await SecureSessionStorage(
          DeviceSecretStore(),
          _namespace,
        ).accessToken(),
        'callback-token',
      );
    },
  );

  test(
    'callback already exchanging cannot land after destructive cleanup',
    () async {
      auth.callback = Completer<AuthSessionUrlResponse>();
      final callback = session.handleCallback(
        Uri.parse('safeathome://auth/callback?code=fictional-code'),
      );
      await drain();
      expect(auth.callbackCalls, 1);
      final rejected = expectLater(app.signOut(), throwsStateError);
      await drain();
      expect(auth.logoutCalls, 0);
      auth.callback!.complete(
        AuthSessionUrlResponse(
          session: fictionalSession('second', 'callback-token'),
          redirectType: 'recovery',
        ),
      );
      await callback;
      await rejected;
      expect(session.userId, 'second');
      expect(nativeCalls, 0);
      expect(await app.store.readJson('case.original'), {'fictional': true});
    },
  );

  test('same-owner callback still invalidates old cleanup authority', () async {
    auth.callback = Completer<AuthSessionUrlResponse>();
    final callback = session.handleCallback(
      Uri.parse('safeathome://auth/callback?code=fictional-code'),
    );
    await drain();
    final rejected = expectLater(app.signOut(), throwsStateError);
    auth.callback!.complete(
      AuthSessionUrlResponse(
        session: fictionalSession('first', 'fresh-same-owner-token'),
        redirectType: 'recovery',
      ),
    );
    await callback;
    await rejected;
    expect(session.userId, 'first');
    expect(session.epoch, greaterThan(0));
    expect(auth.logoutCalls, 0);
    expect(nativeCalls, 0);
    expect(await app.store.readJson('case.original'), {'fictional': true});
    expect(
      await SecureSessionStorage(DeviceSecretStore(), _namespace).accessToken(),
      'fresh-same-owner-token',
    );
  });

  test(
    'failed callback exposes only a generic notice and permits explicit retry',
    () async {
      final uri = Uri.parse('safeathome://auth/callback?code=fictional-code');
      auth.callback = Completer<AuthSessionUrlResponse>();
      final callback = session.handleCallback(uri);
      await drain();
      auth.callback!.completeError(
        StateError('private-provider-error-and-code'),
      );
      await callback;
      expect(session.callbackNotice, contains('fresh recovery link'));
      expect(session.callbackNotice, isNot(contains('private-provider')));
      auth.callback = Completer<AuthSessionUrlResponse>();
      final retry = session.handleCallback(uri);
      await drain();
      expect(auth.callbackCalls, 2);
      auth.callback!.complete(
        AuthSessionUrlResponse(
          session: fictionalSession('first', 'callback-token'),
          redirectType: 'recovery',
        ),
      );
      await retry;
      expect(session.callbackNotice, isNull);
    },
  );

  test(
    'callbacks reject unsafe origins, fragments and ambiguous duplicate codes',
    () async {
      for (final value in [
        'https://auth/callback?code=fictional',
        'safeathome://auth/callback?access_token=fictional',
        'safeathome://auth/callback#refresh_token=fictional',
        'safeathome://auth/callback?code=first&code=second',
        'safeathome://auth/callback?code=${'a' * 4096}',
      ]) {
        await session.handleCallback(Uri.parse(value));
      }
      expect(auth.callbackCalls, 0);
      expect(session.userId, 'first');
    },
  );
}
