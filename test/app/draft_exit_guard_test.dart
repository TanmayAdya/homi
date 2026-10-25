import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/app/theme.dart';
import 'package:safe_at_home/shared/presentation/draft_exit_guard.dart';
import 'package:safe_at_home/shared/services/draft_save_tracker.dart';

Future<GlobalKey<NavigatorState>> _open(
  WidgetTester tester,
  DraftSaveTracker tracker, {
  double scale = 1,
  double keyboard = 0,
}) async {
  final navigator = GlobalKey<NavigatorState>();
  await tester.pumpWidget(
    MaterialApp(
      navigatorKey: navigator,
      theme: SafeAtHomeTheme.light(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(scale),
          viewInsets: EdgeInsets.only(bottom: keyboard),
        ),
        child: child!,
      ),
      home: Builder(
        builder: (context) => Scaffold(
          body: FilledButton(
            onPressed: () => Navigator.of(context).push<void>(
              MaterialPageRoute(
                builder: (_) => DraftExitGuard(
                  tracker: tracker,
                  builder: (context, exit, exiting) => Scaffold(
                    appBar: AppBar(
                      leading: BackButton(onPressed: exit),
                      title: const Text('Editor'),
                    ),
                    body: Text(
                      exiting ? 'Exit is pending' : 'Latest entries remain',
                    ),
                  ),
                ),
              ),
            ),
            child: const Text('Open editor'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open editor'));
  await tester.pumpAndSettle();
  return navigator;
}

Future<void> _tapDialog(WidgetTester tester, String key) async {
  final target = find.byKey(ValueKey(key));
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
  await tester.tap(target);
  await tester.pumpAndSettle();
}

void main() {
  for (final stale in [false, true]) {
    testWidgets(
      'Back uses the settled scope without another PopScope frame: stale=$stale',
      (tester) async {
        var current = true;
        final tracker = DraftSaveTracker(isCurrent: () => current);
        addTearDown(tracker.dispose);
        await _open(tester, tracker);
        final gate = Completer<void>();
        final work = tracker.track(() => gate.future);
        await tester.pump();
        final back = tester
            .widget<BackButton>(find.byType(BackButton))
            .onPressed!;
        expect(
          tester.widget<PopScope<void>>(find.byType(PopScope<void>)).canPop,
          isFalse,
        );
        if (stale) {
          current = false;
        } else {
          gate.complete();
          await work;
          await tracker.settle();
        }
        back();
        await tester.pumpAndSettle();
        expect(find.text('Open editor'), findsOneWidget);
        expect(find.text('Editor'), findsNothing);
        if (stale) {
          gate.complete();
          await work;
          await tracker.settle();
        }
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'late scope loss during the exit dialog cannot pop a replacement route',
    (tester) async {
      var current = true;
      final tracker = DraftSaveTracker(isCurrent: () => current);
      final navigator = await _open(tester, tracker);
      final gate = Completer<void>();
      final work = tracker.track(() => gate.future);
      await tester.pump();
      await tester.tap(find.byTooltip('Back'));
      await tester.pump();
      expect(find.byKey(const ValueKey('draft-exit-waiting')), findsOneWidget);
      current = false;
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: Text('Replacement account'))),
      );
      tracker.dispose();
      gate.complete();
      await work;
      await tester.pumpAndSettle();
      expect(navigator.currentState, isNull);
      expect(find.text('Replacement account'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'settling an old exit dialog removes only that dialog below a newer route',
    (tester) async {
      var current = true;
      final tracker = DraftSaveTracker(isCurrent: () => current);
      addTearDown(tracker.dispose);
      final navigator = await _open(tester, tracker);
      final gate = Completer<void>();
      final work = tracker.track(() => gate.future);
      await tester.pump();
      await tester.tap(find.byTooltip('Back'));
      await tester.pump();
      expect(find.byKey(const ValueKey('draft-exit-waiting')), findsOneWidget);
      current = false;
      unawaited(
        navigator.currentState!.push<void>(
          MaterialPageRoute(
            builder: (_) => const Scaffold(body: Text('Newer route')),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 400));
      gate.complete();
      await work;
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Newer route'), findsOneWidget);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('draft-exit-waiting'), skipOffstage: false),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    },
  );

  for (final size in [const Size(320, 812), const Size(932, 430)]) {
    testWidgets(
      'failed draft choices stay reachable at 3.2x with keyboard in $size',
      (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final tracker = DraftSaveTracker(isCurrent: () => true);
        addTearDown(tracker.dispose);
        await _open(tester, tracker, scale: 3.2, keyboard: 120);
        await expectLater(
          tracker.track(() => Future<void>.error(StateError('disk'))),
          throwsStateError,
        );
        await tracker.settle();
        await tester.pump();
        await tester.tap(find.byTooltip('Back'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await _tapDialog(tester, 'draft-exit-discard');
        expect(find.text('Leave this editor?'), findsOneWidget);
        expect(
          find.text(
            'Unsaved entries kept only in this editor will be lost. Earlier device-saved entries remain. Changes already applied to the case or saved online are not undone.',
          ),
          findsOneWidget,
        );
        await _tapDialog(tester, 'draft-exit-cancel-discard');
        expect(find.text('Latest entries remain'), findsOneWidget);
        expect(tracker.failed, isTrue);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
