import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'local_private_store.dart';
import 'token_availability.dart';

bool acceptsAuthCallback(Uri uri, Uri expected) =>
    uri.scheme == expected.scheme &&
    uri.host == expected.host &&
    uri.path == expected.path &&
    uri.userInfo.isEmpty &&
    !uri.hasPort &&
    uri.fragment.isEmpty &&
    uri.toString().length <= 4096 &&
    uri.queryParametersAll.values.every((values) => values.length == 1) &&
    !uri.queryParameters.containsKey('access_token') &&
    !uri.queryParameters.containsKey('refresh_token');

final _secureStorageTails = <String, Future<void>>{};
Future<T> _secureStorageOperation<T>(
  String namespace,
  Future<T> Function() action,
) {
  final work = (_secureStorageTails[namespace] ?? Future<void>.value()).then(
    (_) => action(),
  );
  _secureStorageTails[namespace] = work.then<void>(
    (_) {},
    onError: (Object _, StackTrace stack) {},
  );
  return work;
}

class SecureSessionStorage extends LocalStorage {
  SecureSessionStorage(this.secrets, this.namespace);
  final SecretValueStore secrets;
  final String namespace;
  bool _recoveryReadsAllowed = true;
  String get _key => '$namespace.session';

  void stopRecoveryReads() => _recoveryReadsAllowed = false;

  @override
  Future<void> initialize() async {}
  @override
  Future<String?> accessToken() async {
    if (!_recoveryReadsAllowed) return null;
    final value = await _secureStorageOperation(
      namespace,
      () => _recoveryReadsAllowed ? secrets.read(_key) : Future.value(null),
    );
    return _recoveryReadsAllowed ? value : null;
  }

  @override
  Future<bool> hasAccessToken() async => await accessToken() != null;
  @override
  Future<void> persistSession(String persistSessionString) =>
      _secureStorageOperation(
        namespace,
        () => secrets.write(_key, persistSessionString),
      );
  @override
  Future<void> removePersistedSession() =>
      _secureStorageOperation(namespace, () => secrets.delete(_key));
}

class SecurePkceStorage extends GotrueAsyncStorage {
  SecurePkceStorage(this.secrets, this.namespace);
  final SecretValueStore secrets;
  final String namespace;
  String get _index => '$namespace.pkce-index';
  Future<List<String>> _keys() async {
    final encoded = await secrets.read(_index);
    return encoded == null
        ? []
        : List<String>.from(jsonDecode(encoded) as List);
  }

  @override
  Future<String?> getItem({required String key}) => _secureStorageOperation(
    namespace,
    () => secrets.read('$namespace.pkce.$key'),
  );
  @override
  Future<void> setItem({required String key, required String value}) =>
      _secureStorageOperation(namespace, () async {
        final keys = await _keys();
        if (!keys.contains(key)) keys.add(key);
        await secrets.write(_index, jsonEncode(keys));
        await secrets.write('$namespace.pkce.$key', value);
      });

  @override
  Future<void> removeItem({required String key}) =>
      _secureStorageOperation(namespace, () async {
        await secrets.delete('$namespace.pkce.$key');
        final keys = await _keys();
        keys.remove(key);
        if (keys.isEmpty) {
          await secrets.delete(_index);
        } else {
          await secrets.write(_index, jsonEncode(keys));
        }
      });

  Future<void> clear() => _secureStorageOperation(namespace, () async {
    for (final key in await _keys()) {
      await secrets.delete('$namespace.pkce.$key');
    }
    await secrets.delete(_index);
  });
}

abstract class SessionService extends ChangeNotifier {
  Future<void> _authTail = Future<void>.value();
  Future<void>? _accountCleanup;
  Future<void> Function()? _failedCleanup;
  int _cleanupRevision = 0;
  bool _lifecycleDisposed = false;

  bool get cleaningUp => _accountCleanup != null;
  bool get cleanupRequired => _failedCleanup != null;
  int get cleanupRevision => _cleanupRevision;
  String? get callbackNotice => null;

  Future<void> waitForAccountCleanup() =>
      (_accountCleanup ?? Future<void>.value()).then<void>(
        (_) {},
        onError: (Object _, StackTrace stack) {},
      );

  @protected
  Future<T> authOperation<T>(Future<T> Function() action) =>
      _queueAuthOperation(action);

  Future<T> _queueAuthOperation<T>(
    Future<T> Function() action, {
    bool cleanupRetry = false,
  }) {
    final work = _authTail.then((_) {
      if (_lifecycleDisposed) throw StateError('The session is closed.');
      if (cleanupRequired && !cleanupRetry) {
        throw StateError('Finish the requested private cleanup first.');
      }
      return action();
    });
    _authTail = work.then<void>(
      (_) {},
      onError: (Object _, StackTrace stack) {},
    );
    return work;
  }

  Future<void> signOutAndClear(
    Future<void> Function() clear, {
    bool Function()? isCurrent,
  }) {
    if (isCurrent != null && !isCurrent()) {
      return Future.error(StateError('The account changed before sign-out.'));
    }
    final existing = _accountCleanup;
    if (existing != null) return existing;
    if (cleanupRequired) {
      return Future.error(
        StateError('Finish the requested private cleanup first.'),
      );
    }
    final completion = Completer<void>();
    _accountCleanup = completion.future;
    final work = authOperation(() async {
      if (isCurrent != null && !isCurrent()) {
        throw StateError('The account changed before sign-out.');
      }
      try {
        await signOutProvider();
      } finally {
        try {
          await clear();
        } catch (_) {
          _failedCleanup = clear;
          _cleanupRevision++;
          rethrow;
        }
      }
    });
    _finishCleanup(work, completion);
    notifyListeners();
    return completion.future;
  }

  Future<void> retryAccountCleanup({required int expectedRevision}) {
    final retry = _failedCleanup;
    if (retry == null || expectedRevision != _cleanupRevision) {
      return Future.error(
        StateError('This cleanup request is no longer current.'),
      );
    }
    final existing = _accountCleanup;
    if (existing != null) return existing;
    final completion = Completer<void>();
    _accountCleanup = completion.future;
    final work = _queueAuthOperation(() async {
      if (!identical(_failedCleanup, retry) ||
          expectedRevision != _cleanupRevision) {
        throw StateError('This cleanup request is no longer current.');
      }
      await retry();
      _failedCleanup = null;
      _cleanupRevision++;
    }, cleanupRetry: true);
    _finishCleanup(work, completion);
    notifyListeners();
    return completion.future;
  }

  void _finishCleanup(Future<void> work, Completer<void> completion) {
    work.then<void>(
      (_) {
        _accountCleanup = null;
        completion.complete();
        if (!_lifecycleDisposed) notifyListeners();
      },
      onError: (Object error, StackTrace stack) {
        _accountCleanup = null;
        completion.completeError(error, stack);
        if (!_lifecycleDisposed) notifyListeners();
      },
    );
  }

  @protected
  Future<void> signOutProvider() => signOut();

  String? get userId;
  int get epoch;
  bool get recoveryRequired;
  Future<String?> accessToken();
  Future<void> signIn(String email, String password);
  Future<void> reauthenticate(String password);
  Future<void> signOut();
  Future<void> requestRecovery(String email);
  Future<void> updatePassword(String password);

  @override
  void dispose() {
    _lifecycleDisposed = true;
    _failedCleanup = null;
    super.dispose();
  }
}

class SupabaseSessionService extends SessionService {
  SupabaseSessionService(
    this.client, {
    required this.callback,
    required this.emailDeliveryEnabled,
    required this.reauthenticationClient,
    this.persistedSessionStorage,
  }) {
    _userId = client.auth.currentUser?.id;
    _subscription = client.auth.onAuthStateChange.listen(
      (change) {
        final next = change.session?.user.id;
        if (next != _userId ||
            change.event == AuthChangeEvent.signedOut ||
            change.event == AuthChangeEvent.signedIn ||
            change.event == AuthChangeEvent.passwordRecovery) {
          _epoch++;
          _confirmedToken = null;
          _tokenRefresh = null;
        }
        _userId = next;
        if (change.event == AuthChangeEvent.passwordRecovery) _recovery = true;
        if (next == null) _recovery = false;
        notifyListeners();
      },
      onError: (Object _) {
        notifyListeners();
      },
    );
  }
  final SupabaseClient client;
  final Uri callback;
  final bool emailDeliveryEnabled;
  final GoTrueClient Function() reauthenticationClient;
  final SecureSessionStorage? persistedSessionStorage;
  ({String token, DateTime expires})? _confirmedToken;
  Future<void>? _tokenRefresh;
  bool _disposed = false;
  late final StreamSubscription<AuthState> _subscription;
  String? _userId;
  int _epoch = 0;
  bool _recovery = false;
  String? _callbackNotice;
  final _callbacks = <Uri, Future<void>>{};
  @override
  String? get callbackNotice => _callbackNotice;

  Future<void> handleCallback(Uri uri) {
    if (_disposed || !acceptsAuthCallback(uri, callback)) {
      return Future<void>.value();
    }
    final existing = _callbacks[uri];
    if (existing != null) return existing;
    if (_callbacks.length >= 4) {
      _callbackNotice =
          'Another sign-in link is being checked. Try this link again shortly.';
      notifyListeners();
      return Future<void>.value();
    }
    final work =
        authOperation(() async {
          _callbackNotice = null;
          notifyListeners();
          await client.auth.getSessionFromUrl(uri);
        }).then<void>(
          (_) {},
          onError: (Object _, StackTrace stack) {
            if (!_disposed) {
              _callbackNotice =
                  'This sign-in link could not be completed. Open a fresh recovery link or sign in again.';
              notifyListeners();
            }
          },
        );
    _callbacks[uri] = work;
    unawaited(work.then((_) => _callbacks.remove(uri)));
    return work;
  }

  @override
  String? get userId => _userId;
  @override
  int get epoch => _epoch;
  @override
  bool get recoveryRequired => _recovery;
  @override
  Future<String?> accessToken() async {
    final owner = _userId;
    final generation = _epoch;
    if (_disposed || cleaningUp || cleanupRequired || owner == null) {
      return null;
    }
    final confirmed = _confirmedToken;
    if (confirmed != null && DateTime.now().isBefore(confirmed.expires)) {
      return confirmed.token;
    }
    _confirmedToken = null;
    final session = client.auth.currentSession;
    if (session == null) return null;
    if (session.isExpired) {
      bool retained() =>
          !_disposed &&
          !cleaningUp &&
          !cleanupRequired &&
          _epoch == generation &&
          _userId == owner &&
          identical(client.auth.currentSession, session) &&
          session.user.id == owner;
      try {
        var refresh = _tokenRefresh;
        if (refresh == null) {
          refresh = authOperation(() async {
            if (!cleaningUp &&
                !cleanupRequired &&
                _epoch == generation &&
                _userId == owner &&
                client.auth.currentSession?.isExpired == true) {
              await client.auth.refreshSession();
            }
          });
          _tokenRefresh = refresh;
          final owned = refresh;
          void release() {
            if (identical(_tokenRefresh, owned)) _tokenRefresh = null;
          }

          unawaited(
            refresh.then<void>(
              (_) => release(),
              onError: (Object _, StackTrace stack) => release(),
            ),
          );
        }
        await refresh.timeout(const Duration(seconds: 12));
      } on AuthRetryableFetchException {
        if (retained()) throw const RetryableTokenUnavailableException();
        return null;
      } on TimeoutException {
        if (retained()) throw const RetryableTokenUnavailableException();
        return null;
      }
    }
    if (_disposed ||
        cleaningUp ||
        cleanupRequired ||
        _epoch != generation ||
        _userId != owner) {
      return null;
    }
    final current = client.auth.currentSession;
    return current == null || current.isExpired ? null : current.accessToken;
  }

  @override
  Future<void> signIn(String email, String password) => authOperation(() async {
    await client.auth.signInWithPassword(
      email: email.trim(),
      password: password,
    );
  });

  @override
  Future<void> reauthenticate(String password) async {
    await waitForAccountCleanup();
    final owner = _userId;
    final generation = _epoch;
    final email = client.auth.currentUser?.email;
    if (cleanupRequired || owner == null || email == null || password.isEmpty) {
      throw StateError('The current account must sign in again.');
    }
    final verifier = reauthenticationClient();
    try {
      final result = await verifier
          .signInWithPassword(email: email, password: password)
          .timeout(const Duration(seconds: 15));
      final verified = result.session;
      if (_disposed ||
          cleaningUp ||
          cleanupRequired ||
          _epoch != generation ||
          _userId != owner ||
          verified == null ||
          verified.user.id != owner ||
          verified.expiresAt == null ||
          verified.isExpired) {
        throw StateError('The account changed during password confirmation.');
      }
      final expiry = DateTime.fromMillisecondsSinceEpoch(
        verified.expiresAt! * 1000,
      );
      final confirmationLimit = DateTime.now().add(const Duration(minutes: 9));
      _confirmedToken = (
        token: verified.accessToken,
        expires: expiry.isBefore(confirmationLimit)
            ? expiry
            : confirmationLimit,
      );
    } finally {
      verifier.dispose();
    }
  }

  @override
  Future<void> signOut() => signOutAndClear(() async {});

  @override
  Future<void> signOutProvider() async {
    persistedSessionStorage?.stopRecoveryReads();
    _epoch++;
    _confirmedToken = null;
    _userId = null;
    _recovery = false;
    notifyListeners();
    await client.auth.signOut(scope: SignOutScope.local);
  }

  @override
  Future<void> requestRecovery(String email) => authOperation(() async {
    if (!emailDeliveryEnabled) {
      throw StateError('Email recovery has not been enabled for this beta.');
    }
    await client.auth.resetPasswordForEmail(
      email.trim(),
      redirectTo: callback.toString(),
    );
  });

  @override
  Future<void> updatePassword(String password) {
    final owner = _userId;
    final generation = _epoch;
    return authOperation(() async {
      if (!_recovery ||
          owner == null ||
          _userId != owner ||
          _epoch != generation) {
        throw StateError('Open a valid password recovery link first.');
      }
      await client.auth.updateUser(UserAttributes(password: password));
      _recovery = false;
      notifyListeners();
    });
  }

  @override
  void dispose() {
    _disposed = true;
    _epoch++;
    _confirmedToken = null;
    unawaited(_subscription.cancel());
    super.dispose();
  }
}
