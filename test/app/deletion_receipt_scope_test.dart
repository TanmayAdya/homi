import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/app/live_app.dart';
import 'package:safe_at_home/features/settings/account_settings_screen.dart';
import 'package:safe_at_home/shared/services/matching_api_client.dart';
import 'case_coordinator_test.dart' show FakeSession, FakeTransport;
import 'live_workflows_test.dart' show MemoryPrivateStore;
import '../services/case_evidence_api_client_test.dart' show jsonResponse;

class ReceiptServices extends AppServices {
  ReceiptServices(MatchingTransport transport)
    : super(
        config: LiveAppConfig(
          apiOrigin: Uri.parse('https://example.org'),
          supabaseUrl: Uri.parse('https://example.supabase.co'),
          publishableKey: 'fictional',
        ),
        session: FakeSession(),
        store: MemoryPrivateStore(),
        transport: transport,
      );
  int cleanups = 0;
  @override
  Future<void> signOutAfterAccountDeletion() => signOut();
  @override
  Future<void> signOut() async {
    cleanups++;
    await session.signOut();
  }
}

void main() {
  const originalOwner = 'fictional-owner';
  const otherOwner = 'another-fictional-owner';
  void receipt(String owner) => FlutterSecureStorage.setMockInitialValues({
    'sah.deletion.example.org': 'a' * 64,
    'sah.deletion-owner.example.org': owner,
  });
  Future<void> open(WidgetTester tester, ReceiptServices app) async {
    await tester.pumpWidget(
      MaterialApp(
        home: DeletionReceiptScreen(config: app.config, services: app),
      ),
    );
    await tester.pump();
  }

  for (final change in [
    'different owner',
    'same owner new session',
    'disposed',
  ]) {
    testWidgets('late deletion receipt cannot clean up $change', (
      tester,
    ) async {
      receipt(originalOwner);
      final response = Completer<MatchingHttpResponse>();
      final transport = FakeTransport((_) => response.future);
      final app = ReceiptServices(transport);
      addTearDown(() {
        app.dispose();
        app.session.dispose();
      });
      await open(tester, app);
      expect(
        transport.requests.single.endpoint.path,
        '/v1/account-deletion-status',
      );
      final session = app.session as FakeSession;
      if (change == 'disposed') {
        await tester.pumpWidget(
          const MaterialApp(home: Text('Different screen')),
        );
      } else {
        session.owner = change == 'different owner'
            ? otherOwner
            : originalOwner;
        session.generation++;
        receipt(session.owner!);
      }
      response.complete(
        jsonResponse({
          'schemaVersion': '1',
          'status': 'auth_pending',
          'applicationDataDeleted': true,
          'providerIdentityDeleted': false,
        }),
      );
      await tester.pumpAndSettle();
      expect(app.cleanups, 0);
      expect(
        session.userId,
        change == 'different owner' ? otherOwner : originalOwner,
      );
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('current matching receipt can clean up its own account', (
    tester,
  ) async {
    receipt(originalOwner);
    final transport = FakeTransport(
      (_) async => jsonResponse({
        'schemaVersion': '1',
        'status': 'auth_pending',
        'applicationDataDeleted': true,
        'providerIdentityDeleted': false,
      }),
    );
    final app = ReceiptServices(transport);
    addTearDown(() {
      app.dispose();
      app.session.dispose();
    });
    await open(tester, app);
    await tester.pumpAndSettle();
    expect(app.cleanups, 1);
    expect(app.session.userId, isNull);
    expect(
      find.text(
        'Application data is deleted. Provider account cleanup is still pending.',
      ),
      findsOneWidget,
    );
  });

  testWidgets(
    'receipt for a different account never clears the signed-in account',
    (tester) async {
      receipt(otherOwner);
      final transport = FakeTransport(
        (_) async => jsonResponse({
          'schemaVersion': '1',
          'status': 'complete',
          'applicationDataDeleted': true,
          'providerIdentityDeleted': true,
        }),
      );
      final app = ReceiptServices(transport);
      addTearDown(() {
        app.dispose();
        app.session.dispose();
      });
      await open(tester, app);
      await tester.pumpAndSettle();
      expect(app.cleanups, 0);
      expect(app.session.userId, originalOwner);
      expect(
        find.text('Application data and the provider account were deleted.'),
        findsOneWidget,
      );
    },
  );
}
