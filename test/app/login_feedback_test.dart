import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/app/theme.dart';
import 'package:safe_at_home/features/auth/login_screen.dart';
import 'package:safe_at_home/shared/presentation/sah_components.dart';
import 'case_coordinator_test.dart' show FakeSession;

class ControlledLoginSession extends FakeSession {
  Completer<void> pending = Completer<void>();
  int signInCalls = 0, recoveryCalls = 0;
  @override
  Future<void> signIn(String email, String password) {
    signInCalls++;
    return pending.future;
  }

  @override
  Future<void> requestRecovery(String email) {
    recoveryCalls++;
    return pending.future;
  }
}

const _signInFailure =
    'Sign-in could not be completed. Check your account details and connection.';
const _recoveryResult =
    'If an account can receive email at this address, a password reset link will arrive shortly.';

Finder _input(String label) => find.byWidgetPredicate(
  (widget) =>
      widget is TextField &&
      (widget.decoration?.labelText == label ||
          (widget.decoration?.label is Text &&
              (widget.decoration!.label! as Text).data == label)),
);

Future<void> _show(WidgetTester tester, Finder target) async {
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
}

void main() {
  for (final size in [const Size(320, 568), const Size(932, 430)]) {
    for (final recovery in [false, true]) {
      testWidgets(
        '${recovery ? 'recovery result' : 'sign-in failure'} reveals one notice above keyboard at 3.2x in $size',
        (tester) async {
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = size;
          tester.platformDispatcher.textScaleFactorTestValue = 3.2;
          addTearDown(() {
            tester.view.resetDevicePixelRatio();
            tester.view.resetPhysicalSize();
            tester.view.resetViewInsets();
            tester.platformDispatcher.clearTextScaleFactorTestValue();
          });
          final session = ControlledLoginSession();
          addTearDown(session.dispose);
          await tester.pumpWidget(
            MaterialApp(
              theme: SafeAtHomeTheme.light(),
              home: LoginScreen(
                session: session,
                emailDeliveryEnabled: recovery,
                deletionStatusScreen: const Scaffold(
                  body: Text('Pending deletion status'),
                ),
              ),
            ),
          );
          await _show(tester, _input('Email'));
          await tester.enterText(_input('Email'), 'fictional@example.invalid');
          await _show(tester, _input('Password'));
          await tester.enterText(_input('Password'), 'fictional-password');
          final keyboardHeight = size.width > size.height ? 216.0 : 290.0;
          tester.view.viewInsets = FakeViewPadding(bottom: keyboardHeight);
          await tester.pumpAndSettle();
          final action = recovery
              ? find.text('Forgot password')
              : find.byKey(const ValueKey('auth-sign-in'));
          await _show(tester, action);
          await tester.tap(action);
          await tester.pump();
          expect(find.byType(SahActionFeedback), findsNothing);
          if (recovery) {
            session.pending.complete();
          } else {
            session.pending.completeError(
              StateError('private-provider-response'),
            );
          }
          await tester.pumpAndSettle();
          final feedback = find.byKey(const ValueKey('auth-action-feedback'));
          expect(feedback, findsOneWidget);
          expect(find.byType(SahActionFeedback), findsOneWidget);
          expect(
            find.text(recovery ? _recoveryResult : _signInFailure),
            findsOneWidget,
          );
          expect(tester.getRect(feedback).top, greaterThanOrEqualTo(0));
          expect(
            tester.getRect(feedback).top,
            lessThan(size.height - keyboardHeight),
          );
          expect(session.signInCalls, recovery ? 0 : 1);
          expect(session.recoveryCalls, recovery ? 1 : 0);
          expect(
            find.textContaining('private-provider-response'),
            findsNothing,
          );
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets(
    'editing clears stale login feedback and retry reveals it again',
    (tester) async {
      final session = ControlledLoginSession();
      addTearDown(session.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: SafeAtHomeTheme.light(),
          home: LoginScreen(session: session, emailDeliveryEnabled: false),
        ),
      );
      final action = find.byKey(const ValueKey('auth-sign-in'));
      await _show(tester, action);
      await tester.tap(action);
      await tester.pump();
      session.pending.completeError(StateError('private-provider-response'));
      await tester.pumpAndSettle();
      expect(find.text(_signInFailure), findsOneWidget);
      await _show(tester, _input('Email'));
      await tester.enterText(_input('Email'), 'changed@example.invalid');
      await tester.pump();
      expect(find.text(_signInFailure), findsNothing);
      session.pending = Completer<void>();
      await _show(tester, action);
      await tester.tap(action);
      await tester.pump();
      session.pending.completeError(StateError('private-provider-response'));
      await tester.pumpAndSettle();
      expect(find.text(_signInFailure), findsOneWidget);
      expect(find.byType(SahActionFeedback), findsOneWidget);
      expect(session.signInCalls, 2);
      expect(tester.takeException(), isNull);
    },
  );

  for (final email in [false, true]) {
    testWidgets('sign-in explains invitations; reset only with email: $email', (
      tester,
    ) async {
      final session = FakeSession();
      addTearDown(session.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: SafeAtHomeTheme.light(),
          home: LoginScreen(session: session, emailDeliveryEnabled: email),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Safe at Home'), findsOneWidget);
      expect(find.text('Team beta: use fictional information only.'), findsOne);
      expect(find.text('Private team beta'), findsNothing);
      expect(find.byType(SahStatusBadge), findsNothing);
      expect(find.text('Create account'), findsNothing);
      expect(find.text('Forgot password'), email ? findsOne : findsNothing);
      final help = find.text('How do I get an account?');
      await _show(tester, help);
      await tester.tap(help);
      await tester.pumpAndSettle();
      expect(find.textContaining('creates accounts by invitation'), findsOne);
      expect(
        find.textContaining('Password reset appears here'),
        email ? findsNothing : findsOne,
      );
      expect(tester.takeException(), isNull);
    });
  }
}
