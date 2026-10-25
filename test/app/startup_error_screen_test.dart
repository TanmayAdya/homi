import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/app/theme.dart';
import 'package:safe_at_home/shared/presentation/startup_error_screen.dart';

void main() {
  for (final size in [const Size(320, 568), const Size(932, 430)]) {
    for (final mode in ['startup', 'storage', 'cleanup']) {
      testWidgets('$mode failure stays readable at 3.2x in $size', (
        tester,
      ) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        tester.platformDispatcher.textScaleFactorTestValue = 3.2;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
          tester.platformDispatcher.clearTextScaleFactorTestValue();
        });
        var signOutCalls = 0;
        final screen = mode == 'storage'
            ? StartupErrorScreen.storage(onSignOut: () => signOutCalls++)
            : mode == 'cleanup'
            ? StartupErrorScreen.cleanup(onRetry: () => signOutCalls++)
            : const StartupErrorScreen.startup();
        await tester.pumpWidget(
          MaterialApp(theme: SafeAtHomeTheme.light(), home: screen),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final scroll = tester.state<ScrollableState>(
          find.byType(Scrollable).first,
        );
        expect(scroll.position.maxScrollExtent, greaterThan(0));
        scroll.position.jumpTo(scroll.position.maxScrollExtent);
        await tester.pumpAndSettle();
        final fullMessage = find.text(screen.message);
        expect(fullMessage, findsOneWidget);
        expect(
          tester.getBottomRight(fullMessage).dy,
          lessThanOrEqualTo(size.height),
        );
        final signOut = find.byKey(
          ValueKey(
            mode == 'cleanup' ? 'startup-retry-cleanup' : 'startup-sign-out',
          ),
        );
        if (mode != 'startup') {
          expect(signOut.hitTestable(), findsOneWidget);
          expect(tester.getSize(signOut).height, greaterThanOrEqualTo(48));
          expect(signOutCalls, 0);
          await tester.tap(signOut);
          expect(signOutCalls, 1);
        } else {
          expect(signOut, findsNothing);
          expect(signOutCalls, 0);
        }
        expect(tester.takeException(), isNull);
      });
    }
  }
}
