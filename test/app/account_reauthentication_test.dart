import 'dart:io';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/app/live_app.dart';
import 'package:safe_at_home/features/settings/account_settings_screen.dart';
import 'package:safe_at_home/shared/services/local_private_store.dart';
import 'case_coordinator_test.dart' show FakeSession, FakeTransport;
import 'local_private_store_test.dart' show MemorySecrets;
import '../case_discovery_api_client_test.dart' show jsonResponse;
import '../services/lifecycle_api_client_test.dart' show previewJson;

class PasswordSession extends FakeSession {
  bool reject = false, changeAccount = false;
  int attempts = 0;
  Completer<void>? pending;
  @override
  Future<void> reauthenticate(String password) async {
    attempts++;
    expect(password, 'fictional-password');
    await pending?.future;
    if (reject) throw StateError('Rejected');
    if (changeAccount) {
      owner = 'different-account';
      generation++;
    }
  }
}

void main() {
  late Directory directory;
  late PasswordSession session;
  late FakeTransport transport;
  late AppServices services;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('sah-reauth-');
    session = PasswordSession();
    transport = FakeTransport((_) async => jsonResponse(previewJson()));
    services = AppServices(
      config: LiveAppConfig(
        apiOrigin: Uri.parse('https://fictional.example'),
        supabaseUrl: Uri.parse('https://fictional.supabase.co'),
        publishableKey: 'fictional-publishable',
      ),
      session: session,
      store: LocalPrivateStore(
        directory: directory,
        accountId: session.userId!,
        secrets: MemorySecrets(),
      ),
      transport: transport,
    );
  });
  tearDown(() async {
    services.dispose();
    session.dispose();
    await services.store.close();
    await directory.delete(recursive: true);
  });
  Future<void> open(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(home: AccountSettingsScreen(services: services)),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.scrollUntilVisible(
      find.text('Delete account and application data'),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Delete account and application data'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(transport.requests, isEmpty);
    await tester.enterText(
      find.widgetWithText(TextField, 'Current password'),
      'fictional-password',
    );
    await tester.tap(find.text('Confirm password'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
  }

  testWidgets('failed password confirmation makes no deletion API request', (
    tester,
  ) async {
    session.reject = true;
    await open(tester);
    expect(session.attempts, 1);
    expect(transport.requests, isEmpty);
    expect(find.textContaining('Nothing was deleted'), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      isEmpty,
    );
  });
  testWidgets(
    'successful reauthentication still requires explicit deletion review',
    (tester) async {
      await open(tester);
      expect(session.attempts, 1);
      expect(
        transport.requests.single.endpoint.path,
        '/v1/prepare-account-deletion',
      );
      expect(find.text('Delete this account?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(transport.requests, hasLength(1));
    },
  );
  testWidgets(
    'account change during confirmation cannot prepare or confirm deletion',
    (tester) async {
      session.changeAccount = true;
      await open(tester);
      expect(session.attempts, 1);
      expect(transport.requests, isEmpty);
      expect(find.text('Delete this account?'), findsNothing);
    },
  );
  testWidgets(
    'busy confirmation ignores barrier/back and survives host disposal',
    (tester) async {
      session.pending = Completer<void>();
      await open(tester);
      await tester.tapAt(const Offset(5, 5));
      await tester.pump();
      await tester.binding.handlePopRoute();
      await tester.pump();
      expect(find.text('Confirm your password'), findsOneWidget);
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      session.pending!.complete();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(tester.takeException(), isNull);
      expect(transport.requests, isEmpty);
    },
  );
}
