import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show AuthException;
import 'package:safe_at_home/features/auth/login_screen.dart';
import 'package:safe_at_home/l10n/app_localizations.dart';
import 'package:safe_at_home/l10n/catalogs/account_access.dart';
import 'package:safe_at_home/app/theme.dart';

import 'case_coordinator_test.dart' show FakeSession;

Widget localized(Locale locale, Widget home) => MaterialApp(
  locale: locale,
  supportedLocales: AppLocalizations.supportedLocales,
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  theme: SafeAtHomeTheme.light(),
  home: home,
);

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

void narrowLargeText(WidgetTester tester, {required double scale}) {
  tester.view.physicalSize = const Size(320, 568);
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
    tester.view.resetViewInsets();
    tester.platformDispatcher.clearTextScaleFactorTestValue();
  });
}

class _Session extends FakeSession {
  int created = 0, resent = 0;
  int passwordUpdates = 0;
  bool recovering = false;
  String? submittedEmail, submittedPassword;
  Object? failure;
  @override
  bool get recoveryRequired => recovering;
  @override
  Future<void> updatePassword(String password) async => passwordUpdates++;
  @override
  Future<void> createAccount(String email, String password) async {
    created++;
    submittedEmail = email;
    submittedPassword = password;
    if (failure != null) throw failure!;
  }

  @override
  Future<void> resendConfirmation(String email) async {
    resent++;
    if (failure != null) throw failure!;
  }

  @override
  Future<void> signIn(String email, String password) async {
    if (failure != null) throw failure!;
  }
}

const emailKey = ValueKey('login-email');
const passwordKey = ValueKey('login-password');
const confirmKey = ValueKey('signup-confirm-password');
const actionKey = ValueKey('auth-sign-in');
const switchKey = ValueKey('auth-switch-mode');
const resendKey = ValueKey('auth-resend-confirmation');

Future<void> tap(WidgetTester tester, Key key) async {
  await reveal(tester, find.byKey(key));
  final visible = tester
      .getRect(find.byKey(key))
      .intersect(tester.getRect(find.byType(SingleChildScrollView)));
  expect(visible.isEmpty, false);
  await tester.tapAt(visible.center);
  await tester.pumpAndSettle();
}

Future<void> enter(WidgetTester tester, Key key, String value) async {
  await reveal(tester, find.byKey(key));
  await tester.enterText(find.byKey(key), value);
}

Future<void> fillSignup(WidgetTester tester) async {
  await tap(tester, switchKey);
  await enter(tester, emailKey, 'fictional@example.invalid');
  await enter(tester, passwordKey, 'fictional-password-42');
  await enter(tester, confirmKey, 'fictional-password-42');
}

void main() {
  testWidgets('beta build hides signup and email actions', (tester) async {
    final session = _Session();
    addTearDown(session.dispose);
    await tester.pumpWidget(
      localized(
        const Locale('en'),
        LoginScreen(
          session: session,
          emailDeliveryEnabled: false,
          publicSignupEnabled: false,
        ),
      ),
    );
    expect(find.byKey(switchKey), findsNothing);
    expect(find.text('Forgot password'), findsNothing);
  });

  testWidgets('signup validates email, password length and repeated password', (
    tester,
  ) async {
    final session = _Session();
    addTearDown(session.dispose);
    await tester.pumpWidget(
      localized(
        const Locale('en'),
        LoginScreen(
          session: session,
          emailDeliveryEnabled: true,
          publicSignupEnabled: true,
        ),
      ),
    );
    await fillSignup(tester);
    await enter(tester, emailKey, 'invalid');
    await tap(tester, actionKey);
    expect(find.text('Enter a valid email address.'), findsOneWidget);
    await enter(tester, emailKey, 'fictional@example.invalid');
    await enter(tester, confirmKey, 'does-not-match');
    await tap(tester, actionKey);
    expect(session.created, 0);
    expect(
      find.text(
        'Use at least 12 characters and make sure both passwords match.',
      ),
      findsOneWidget,
    );
    await enter(tester, passwordKey, 'short');
    await enter(tester, confirmKey, 'short');
    await tap(tester, actionKey);
    expect(session.created, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'confirmation waits, resends after cooldown, and returns to sign in',
    (tester) async {
      final session = _Session();
      addTearDown(session.dispose);
      await tester.pumpWidget(
        localized(
          const Locale('en'),
          LoginScreen(
            session: session,
            emailDeliveryEnabled: true,
            publicSignupEnabled: true,
          ),
        ),
      );
      await fillSignup(tester);
      await tap(tester, actionKey);
      expect(session.created, 1);
      expect(session.submittedEmail, 'fictional@example.invalid');
      expect(session.submittedPassword, 'fictional-password-42');
      expect(find.byKey(passwordKey), findsNothing);
      expect(
        tester.widget<TextButton>(find.byKey(resendKey)).onPressed,
        isNull,
      );
      await tester.pump(const Duration(seconds: 61));
      await tap(tester, resendKey);
      expect(session.resent, 1);
      await tap(tester, switchKey);
      expect(
        tester.widget<TextField>(find.byKey(passwordKey)).controller!.text,
        isEmpty,
      );
      expect(find.byKey(confirmKey), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'unconfirmed sign in offers resend and redacts provider details',
    (tester) async {
      final session = _Session()
        ..failure = const AuthException(
          'private-error',
          code: 'email_not_confirmed',
        );
      addTearDown(session.dispose);
      await tester.pumpWidget(
        localized(
          const Locale('en'),
          LoginScreen(
            session: session,
            emailDeliveryEnabled: true,
            publicSignupEnabled: true,
          ),
        ),
      );
      await enter(tester, emailKey, 'fictional@example.invalid');
      await tap(tester, actionKey);
      expect(find.byKey(resendKey), findsOneWidget);
      expect(find.textContaining('private-error'), findsNothing);
      session.failure = null;
      await tap(tester, resendKey);
      expect(session.resent, 1);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'recovery callback supersedes signup and its active email cooldown',
    (tester) async {
      final session = _Session();
      addTearDown(session.dispose);
      Widget screen() => localized(
        const Locale('en'),
        LoginScreen(
          session: session,
          emailDeliveryEnabled: true,
          publicSignupEnabled: true,
        ),
      );
      await tester.pumpWidget(screen());
      await fillSignup(tester);
      await tap(tester, actionKey);
      session.recovering = true;
      await tester.pumpWidget(screen());
      await enter(tester, passwordKey, 'fictional-new-password-42');
      await tap(tester, actionKey);
      expect(session.passwordUpdates, 1);
      expect(session.created, 1);
      expect(find.byKey(confirmKey), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final locale in AppLocalizations.supportedLocales) {
    testWidgets(
      '${locale.toLanguageTag()} signup result stays usable at 320px and 3.2x',
      (tester) async {
        narrowLargeText(tester, scale: 3.2);
        final session = _Session();
        addTearDown(session.dispose);
        final l10n = AppLocalizations(locale);
        await tester.pumpWidget(
          localized(
            locale,
            LoginScreen(
              session: session,
              emailDeliveryEnabled: true,
              publicSignupEnabled: true,
            ),
          ),
        );
        await fillSignup(tester);
        tester.view.viewInsets = const FakeViewPadding(bottom: 250);
        await tap(tester, actionKey);
        final feedback = find.byKey(const ValueKey('auth-action-feedback'));
        expect(tester.getRect(feedback).top, greaterThanOrEqualTo(0));
        expect(tester.getRect(feedback).top, lessThan(568 - 250));
        await tap(tester, switchKey);
        expect(find.text(l10n.text('Sign in')), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        tester.view.resetViewInsets();
      },
    );
  }

  test('new account copy covers every non-English supported locale', () {
    for (final entry in accountAccessTranslations.entries) {
      expect(entry.value.keys.toSet(), {
        'es',
        'zh-Hans',
        'zh-Hant',
        'vi',
        'fil',
      });
      for (final translation in entry.value.values) {
        expect(translation, isNotEmpty);
        if (entry.key.contains('{seconds}')) {
          expect(translation, contains('{seconds}'));
        }
      }
    }
  });
}
