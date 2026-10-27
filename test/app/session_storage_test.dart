import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/app/live_app.dart';
import 'package:safe_at_home/shared/services/session_service.dart';
import 'local_private_store_test.dart' show MemorySecrets;

void main() {
  test('session and PKCE persistence are separate secure namespaces', () async {
    final secrets = MemorySecrets();
    final session = SecureSessionStorage(secrets, 'fictional');
    final pkce = SecurePkceStorage(secrets, 'fictional');
    await session.initialize();
    expect(await session.hasAccessToken(), false);
    await session.persistSession('fictional-session-json');
    await pkce.setItem(key: 'verifier', value: 'fictional-pkce');
    expect(await session.accessToken(), 'fictional-session-json');
    expect(await pkce.getItem(key: 'verifier'), 'fictional-pkce');
    await session.removePersistedSession();
    expect(await session.accessToken(), isNull);
    expect(await pkce.getItem(key: 'verifier'), 'fictional-pkce');
    await pkce.removeItem(key: 'verifier');
    expect(secrets.values, isEmpty);
  });
  test(
    'parallel PKCE writes and adapter-reopened cleanup cannot lose index entries',
    () async {
      final secrets = MemorySecrets();
      final first = SecurePkceStorage(secrets, 'race-test');
      final reopened = SecurePkceStorage(secrets, 'race-test');
      await Future.wait([
        first.setItem(key: 'a', value: 'fictional-a'),
        reopened.setItem(key: 'b', value: 'fictional-b'),
        reopened.clear(),
      ]);
      expect(secrets.values, isEmpty);
      await Future.wait([
        first.setItem(key: 'a', value: 'fictional-a'),
        reopened.setItem(key: 'b', value: 'fictional-b'),
        first.removeItem(key: 'a'),
      ]);
      expect(await reopened.getItem(key: 'b'), 'fictional-b');
      await reopened.clear();
      expect(secrets.values, isEmpty);
    },
  );
  test('live configuration rejects insecure and ambiguous origins', () {
    for (final bad in [
      'http://example.org',
      'https://name:secret@example.org',
      'https://example.org/path',
      'https://example.org?secret=value',
    ]) {
      expect(
        () => LiveAppConfig(
          apiOrigin: Uri.parse(bad),
          supabaseUrl: Uri.parse('https://example.supabase.co'),
          publishableKey: 'fictional-key',
        ),
        throwsFormatException,
      );
    }
  });
  test('auth callbacks require exact scheme host and path', () {
    final c = LiveAppConfig(
      apiOrigin: Uri.parse('https://example.org'),
      supabaseUrl: Uri.parse('https://example.supabase.co'),
      publishableKey: 'fictional-key',
    );
    expect(
      c.acceptsCallback(Uri.parse('safeathome://auth/callback?code=fictional')),
      true,
    );
    for (final url in [
      'https://auth/callback?code=x',
      'safeathome://other/callback?code=x',
      'safeathome://auth/other?code=x',
      'safeathome://user@auth/callback?code=x',
      'safeathome://auth:99/callback?code=x',
      'safeathome://auth/callback#access_token=x',
      'safeathome://auth/callback?access_token=x',
      'safeathome://auth/callback?refresh_token=x',
    ]) {
      expect(c.acceptsCallback(Uri.parse(url)), false);
    }
  });
}
