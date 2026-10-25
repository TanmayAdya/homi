import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/app/live_app.dart';
import 'package:safe_at_home/app/theme.dart';
import 'package:safe_at_home/features/settings/account_settings_screen.dart';
import 'package:safe_at_home/shared/presentation/sah_components.dart';
import 'account_reauthentication_test.dart' show PasswordSession;
import 'case_coordinator_test.dart' show FakeTransport;
import 'live_workflows_test.dart' show MemoryPrivateStore, services;

void main() {
  testWidgets('account deletion failure is visible beside its action at 3.2x', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final transport = FakeTransport(
      (_) async => throw StateError('private-deletion-provider-detail'),
    );
    final session = PasswordSession();
    final app = AppServices(
      config: LiveAppConfig(
        apiOrigin: Uri.parse('https://example.org'),
        supabaseUrl: Uri.parse('https://example.supabase.co'),
        publishableKey: 'fictional',
      ),
      session: session,
      store: MemoryPrivateStore(),
      transport: transport,
    );
    addTearDown(() {
      app.dispose();
      session.dispose();
    });
    await tester.pumpWidget(
      MaterialApp(
        theme: SafeAtHomeTheme.light(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(3.2)),
          child: child!,
        ),
        home: AccountSettingsScreen(services: app),
      ),
    );
    await tester.pumpAndSettle();
    final remove = find.text('Delete account and application data');
    await tester.ensureVisible(remove);
    await tester.pumpAndSettle();
    await tester.tap(remove);
    await tester.pumpAndSettle();
    final password = find.widgetWithText(TextField, 'Current password');
    await tester.ensureVisible(password);
    await tester.pumpAndSettle();
    await tester.enterText(password, 'fictional-password');
    final confirm = find.text('Confirm password');
    await tester.ensureVisible(confirm);
    await tester.pumpAndSettle();
    await tester.tap(confirm);
    await tester.pumpAndSettle();
    expect(session.attempts, 1);
    expect(transport.requests, hasLength(1));
    expect(
      transport.requests.single.endpoint.path,
      '/v1/prepare-account-deletion',
    );
    expect(find.text('Confirm your password'), findsNothing);
    final feedback = find.byType(SahActionFeedback);
    expect(feedback, findsOneWidget);
    final bounds = tester.getRect(feedback);
    expect(bounds.top, greaterThanOrEqualTo(0));
    expect(bounds.top, lessThan(300));
    expect(
      find.textContaining('private-deletion-provider-detail'),
      findsNothing,
    );
    expect(find.text('Delete this account?'), findsNothing);
    expect(tester.takeException(), isNull);
  });
  for (final size in [const Size(932, 430), const Size(320, 568)]) {
    testWidgets(
      'password confirmation keeps cancellation reachable with keyboard at 3.2x in $size',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = size;
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetViewInsets);
        final transport = FakeTransport(
          (_) async => throw StateError('No deletion API call expected'),
        );
        final app = services(MemoryPrivateStore(), transport);
        addTearDown(() {
          app.dispose();
          app.session.dispose();
        });
        await tester.pumpWidget(
          MaterialApp(
            theme: SafeAtHomeTheme.light(),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(3.2)),
              child: child!,
            ),
            home: AccountSettingsScreen(services: app),
          ),
        );
        await tester.pumpAndSettle();
        final remove = find.text('Delete account and application data');
        await tester.scrollUntilVisible(
          remove,
          300,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.ensureVisible(remove);
        await tester.pumpAndSettle();
        await tester.tap(remove);
        await tester.pumpAndSettle();
        final password = find.widgetWithText(TextField, 'Current password');
        await tester.ensureVisible(password);
        await tester.pumpAndSettle();
        await tester.tap(password);
        await tester.enterText(password, 'fictional-never-submitted');
        tester.view.viewInsets = FakeViewPadding(
          bottom: size.width > size.height ? 216 : 290,
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final cancel = find.text('Cancel');
        await tester.ensureVisible(cancel);
        await tester.pumpAndSettle();
        expect(cancel.hitTestable(), findsOneWidget);
        final rect = tester.getRect(cancel);
        expect(
          rect.bottom,
          lessThanOrEqualTo(size.height - tester.view.viewInsets.bottom),
        );
        await tester.tap(cancel);
        await tester.pumpAndSettle();
        expect(find.text('Confirm your password'), findsNothing);
        expect(transport.requests, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
