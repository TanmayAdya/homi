import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/app/theme.dart';
import 'package:safe_at_home/features/auth/login_screen.dart';
import 'package:safe_at_home/features/cases/case_home_screen.dart';
import 'package:safe_at_home/features/cases/profile_editor_screen.dart';
import 'package:safe_at_home/features/settings/account_settings_screen.dart';
import 'case_coordinator_test.dart' show FakeSession, FakeTransport;
import 'live_workflows_test.dart' show MemoryPrivateStore, services, input;
import '../services/case_evidence_api_client_test.dart' as http;

class PendingSignIn extends FakeSession {
  final completion = Completer<void>();
  @override
  Future<void> signIn(String email, String password) => completion.future;
}

void narrowLargeText(WidgetTester tester, {double scale = 2}) {
  tester.view.physicalSize = const Size(320, 700);
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
    tester.platformDispatcher.clearTextScaleFactorTestValue();
  });
}

Future<void> reveal(WidgetTester tester, Finder finder) async {
  await tester.pumpAndSettle();
  await tester.scrollUntilVisible(
    finder,
    200,
    scrollable: find.byType(Scrollable).first,
    maxScrolls: 100,
  );
  await tester.pumpAndSettle();
}

double contrast(Color a, Color b) {
  final x = a.computeLuminance(), y = b.computeLuminance();
  return ((x > y ? x : y) + .05) / ((x < y ? x : y) + .05);
}

void main() {
  test('text and notice colors meet normal-text contrast', () {
    final theme = SafeAtHomeTheme.light();
    final scheme = theme.colorScheme;
    for (final pair in [
      (scheme.onSurface, theme.scaffoldBackgroundColor),
      (scheme.onSurfaceVariant, theme.scaffoldBackgroundColor),
      (scheme.onPrimary, scheme.primary),
      (scheme.onPrimaryContainer, scheme.primaryContainer),
      (scheme.onTertiaryContainer, scheme.tertiaryContainer),
      (scheme.onErrorContainer, scheme.errorContainer),
    ]) {
      expect(contrast(pair.$1, pair.$2), greaterThanOrEqualTo(4.5));
    }
  });

  test(
    'unfocused input and outlined-button boundaries meet nontext contrast',
    () {
      final theme = SafeAtHomeTheme.light();
      final input = theme.inputDecorationTheme.enabledBorder!;
      final button = theme.outlinedButtonTheme.style!.side!.resolve({})!;
      expect(
        contrast(input.borderSide.color, theme.inputDecorationTheme.fillColor!),
        greaterThanOrEqualTo(3),
      );
      expect(
        contrast(button.color, theme.scaffoldBackgroundColor),
        greaterThanOrEqualTo(3),
      );
    },
  );

  testWidgets('password visibility remains reachable at double text size', (
    tester,
  ) async {
    narrowLargeText(tester);
    final session = FakeSession();
    addTearDown(session.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: SafeAtHomeTheme.light(),
        home: LoginScreen(session: session, emailDeliveryEnabled: false),
      ),
    );
    await reveal(tester, input('Password'));
    final toggle = find.widgetWithIcon(IconButton, Icons.visibility_outlined);
    expect(tester.getSize(toggle).shortestSide, greaterThanOrEqualTo(48));
    expect(tester.widget<TextField>(input('Password')).obscureText, true);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(input('Password')).obscureText, false);
    expect(find.byTooltip('Hide password'), findsOneWidget);
    await reveal(tester, find.byKey(const ValueKey('auth-sign-in')));
    expect(
      tester.getSize(find.byKey(const ValueKey('auth-sign-in'))).height,
      greaterThanOrEqualTo(48),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'sign-in completion after navigation cannot revive the login screen',
    (tester) async {
      final session = PendingSignIn();
      addTearDown(session.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: SafeAtHomeTheme.light(),
          home: LoginScreen(session: session, emailDeliveryEnabled: false),
        ),
      );
      await reveal(tester, find.byKey(const ValueKey('auth-sign-in')));
      await tester.tap(find.byKey(const ValueKey('auth-sign-in')));
      await tester.pump();
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: Text('Authenticated workspace')),
        ),
      );
      session.completion.complete();
      await tester.pumpAndSettle();
      expect(find.text('Authenticated workspace'), findsOneWidget);
      expect(find.byType(LoginScreen), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'large-text journey retains details when automatic sync is rate limited',
    (tester) async {
      narrowLargeText(tester);
      final transport = FakeTransport((request) async {
        if (request.endpoint.path == '/v1/create-case') {
          return http.apiError('RATE_LIMITED', 429);
        }
        expect(request.endpoint.path, '/v2/list-cases');
        return http.jsonResponse({
          'schemaVersion': '2',
          'cases': [],
          'nextAfterCaseId': null,
        });
      });
      final app = services(MemoryPrivateStore(), transport);
      addTearDown(app.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: SafeAtHomeTheme.light(),
          home: CaseHomeScreen(services: app),
        ),
      );
      await tester.pumpAndSettle();
      await reveal(tester, find.byKey(const ValueKey('case-start')));
      await tester.tap(find.byKey(const ValueKey('case-start')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const ValueKey('plan-name-save')));
      await tester.tap(find.byKey(const ValueKey('plan-name-save')));
      await tester.pumpAndSettle();
      await reveal(tester, find.byKey(const ValueKey('case-profile')));
      await tester.tap(find.byKey(const ValueKey('case-profile')));
      await tester.pumpAndSettle();
      final city = find.widgetWithText(TextFormField, 'City');
      await reveal(tester, city);
      await tester.enterText(city, 'Fictional City');
      await reveal(tester, find.byKey(const ValueKey('profile-keep-edits')));
      await tester.tap(find.byKey(const ValueKey('profile-keep-edits')));
      await tester.pumpAndSettle();
      expect(app.coordinator.draft!.profile.city, 'Fictional City');
      expect(app.coordinator.draft!.profile.annualIncomeUsd, isNull);
      expect(app.coordinator.snapshot, isNull);
      expect(find.byKey(const ValueKey('case-next-step')), findsNothing);
      tester
          .state<ScrollableState>(find.byType(Scrollable).first)
          .position
          .jumpTo(0);
      await tester.pumpAndSettle();
      await reveal(tester, find.byKey(const ValueKey('case-save-online')));
      expect(find.byKey(const ValueKey('case-save-online')), findsOneWidget);
      await reveal(tester, find.text('1 of 8 answered'));
      expect(find.text('1 of 8 answered'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('plan-tab-help')));
      await tester.pumpAndSettle();
      expect(
        find.text(
          'Sync your plan before checking assistance. Local contacts are still available.',
        ),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('program-refresh')), findsNothing);
      expect(transport.requests.map((r) => r.endpoint.path), [
        '/v2/list-cases',
        '/v1/create-case',
        '/v2/list-cases',
        '/v1/create-case',
      ]);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('large-text sign-out confirmation can be read and cancelled', (
    tester,
  ) async {
    narrowLargeText(tester);
    final transport = FakeTransport(
      (_) async => throw StateError('No network expected'),
    );
    final app = services(MemoryPrivateStore(), transport);
    addTearDown(app.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: SafeAtHomeTheme.light(),
        home: AccountSettingsScreen(services: app),
      ),
    );
    await tester.pumpAndSettle();
    await reveal(tester, find.byKey(const ValueKey('account-privacy')));
    await tester.tap(find.byKey(const ValueKey('account-privacy')));
    await tester.pumpAndSettle();
    await reveal(tester, find.byKey(const ValueKey('settings-sign-out')));
    await tester.tap(find.byKey(const ValueKey('settings-sign-out')));
    await tester.pumpAndSettle();
    expect(find.text('Sign out and clear this device?'), findsOneWidget);
    final dialogScroll = find.descendant(
      of: find.byType(Dialog),
      matching: find.byType(SingleChildScrollView),
    );
    expect(dialogScroll, findsOneWidget);
    final guidance = find.descendant(
      of: dialogScroll,
      matching: find.text(
        'Names saved to your account will stay available on your other devices. Local drafts and staged photos will be removed. Unsynced names must finish syncing first.',
      ),
    );
    expect(guidance, findsOneWidget);
    await tester.ensureVisible(guidance);
    await tester.pumpAndSettle();
    expect(
      tester.renderObject<RenderParagraph>(guidance).didExceedMaxLines,
      false,
    );
    final cancel = find.descendant(
      of: dialogScroll,
      matching: find.text('Cancel'),
    );
    await tester.ensureVisible(cancel);
    await tester.pumpAndSettle();
    expect(cancel.hitTestable(), findsOneWidget);
    await tester.tap(cancel);
    await tester.pumpAndSettle();
    expect(app.session.userId, 'fictional-owner');
    expect(transport.requests, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'housing choices remain usable at largest text without replacing unknown values',
    (tester) async {
      narrowLargeText(tester, scale: 3.2);
      final transport = FakeTransport(
        (request) async =>
            http.jsonResponse({...http.requestJson(request), 'revision': 1}),
      );
      final app = services(MemoryPrivateStore(), transport);
      addTearDown(app.dispose);
      await app.coordinator.createDraft();
      await tester.pumpWidget(
        MaterialApp(
          theme: SafeAtHomeTheme.light(),
          home: ProfileEditorScreen(services: app),
        ),
      );
      await tester.pumpAndSettle();
      final choice = find.byKey(const ValueKey('profile-tenure-renter'));
      await reveal(tester, choice);
      await tester.tap(choice);
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(app.coordinator.draft!.profile.tenure, 'renter');
      expect(app.coordinator.draft!.profile.ownerConsentReported, isNull);
      expect(app.coordinator.draft!.profile.annualIncomeUsd, isNull);
      expect(transport.requests, hasLength(1));
      expect(app.coordinator.snapshot!.profile.tenure, 'renter');
      expect(tester.takeException(), isNull);
    },
  );
}
