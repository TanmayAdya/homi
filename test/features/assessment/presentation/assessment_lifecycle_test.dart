import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/features/assessment/application/assessment_controller.dart';
import 'package:safe_at_home/features/assessment/application/assessment_flow.dart';
import 'package:safe_at_home/features/assessment/domain/capture/capture_adapter.dart';
import 'package:safe_at_home/features/assessment/domain/capture/photo_capture_coordinator.dart';
import 'package:safe_at_home/features/assessment/domain/capture/staging_store.dart';
import 'package:safe_at_home/features/assessment/presentation/assessment_flow_screen.dart';

import '../fakes/fakes.dart';
import '../fakes/image_bytes.dart';

void main() {
  late ScriptedCaptureAdapter adapter;
  late InMemoryStagingStore staging;
  late AssessmentController controller;
  late AssessmentFlow flow;

  setUp(() {
    adapter = ScriptedCaptureAdapter();
    staging = InMemoryStagingStore();
    controller = AssessmentController(ids: SequentialIdFactory());
    flow = AssessmentFlow(
      controller: controller,
      capture: PhotoCaptureCoordinator(adapter: adapter, staging: staging),
      staging: staging,
    );
  });

  CaptureSucceeded photo() =>
      CaptureSucceeded(jpegHeader(width: 4032, height: 3024));

  Future<void> background(WidgetTester tester) async {
    for (final AppLifecycleState s in [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(s);
      await tester.pump();
    }
  }

  Future<void> resume(WidgetTester tester) async {
    for (final AppLifecycleState s in [
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(s);
      await tester.pump();
    }
  }

  Future<void> tapText(WidgetTester tester, String text) async {
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();
    await tester.ensureVisible(find.text(text));
    await tester.pumpAndSettle();
    await tester.tap(find.text(text));
    await tester.pump();
  }

  Widget app() => MaterialApp(home: AssessmentFlowScreen(flow: flow));

  testWidgets('backgrounding while the camera is open keeps the result', (
    tester,
  ) async {
    await tester.pumpWidget(app());
    await tester.tap(find.byKey(const ValueKey('area-bathroom')));
    await tester.pumpAndSettle();

    final pending = Completer<CaptureResult>();
    adapter.enqueueFuture(pending.future);
    await tapText(tester, 'Open camera');
    expect(find.bySemanticsLabel('Opening camera'), findsOneWidget);

    await background(tester);
    await resume(tester);
    expect(adapter.requests, hasLength(1), reason: 'no relaunch on resume');

    pending.complete(photo());
    await tester.pumpAndSettle();
    expect(find.text('Check the photo'), findsOneWidget);
    expect(controller.drafts.single.evidence, hasLength(1));
  });

  testWidgets('resuming never reopens a camera that was turned off', (
    tester,
  ) async {
    await tester.pumpWidget(app());
    await tester.tap(find.byKey(const ValueKey('area-entrance')));
    await tester.pumpAndSettle();
    adapter.enqueue(const CapturePermissionDenied(canAskAgain: false));
    await tapText(tester, 'Open camera');
    await tester.pumpAndSettle();

    await background(tester);
    await resume(tester);
    await tester.pumpAndSettle();

    expect(adapter.requests, hasLength(1));
    expect(find.text('I changed the setting'), findsOneWidget);
    expect(find.text('Open camera'), findsNothing);
  });

  testWidgets('typed text survives backgrounding', (tester) async {
    await tester.pumpWidget(app());
    await tester.tap(find.byKey(const ValueKey('area-entrance')));
    await tester.pumpAndSettle();
    await tapText(tester, 'Continue without a photo');
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('observation')),
      'I notice a raised threshold.',
    );
    await tapText(tester, 'Add measurements (optional)');
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('measurement-clearOpening')),
      '80',
    );

    await background(tester);
    await resume(tester);
    await tester.pumpAndSettle();

    expect(flow.observationText, 'I notice a raised threshold.');
    final TextField field = tester.widget(
      find.byKey(const ValueKey('measurement-clearOpening')),
    );
    expect(field.controller!.text, '80');
  });

  testWidgets('leaving the screen mid-capture, then returning, shows the '
      'photo', (tester) async {
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => AssessmentFlowScreen(flow: flow),
                  ),
                ),
                child: const Text('Open assessment'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open assessment'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('area-entrance')));
    await tester.pumpAndSettle();

    final pending = Completer<CaptureResult>();
    adapter.enqueueFuture(pending.future);
    await tapText(tester, 'Open camera');

    navigator.currentState!.pop();
    await tester.pumpAndSettle();
    expect(find.byType(AssessmentFlowScreen), findsNothing);

    pending.complete(photo());
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(flow.step, AssessmentStep.preview);

    await tester.tap(find.text('Open assessment'));
    await tester.pumpAndSettle();
    expect(find.text('Check the photo'), findsOneWidget);
  });

  testWidgets('rotating while the camera is open keeps everything', (
    tester,
  ) async {
    addTearDown(tester.view.resetPhysicalSize);
    tester.view.physicalSize = const Size(1080, 2400);
    await tester.pumpWidget(app());
    await tester.tap(find.byKey(const ValueKey('area-bathroom')));
    await tester.pumpAndSettle();

    final pending = Completer<CaptureResult>();
    adapter.enqueueFuture(pending.future);
    await tapText(tester, 'Open camera');

    tester.view.physicalSize = const Size(2400, 1080);
    await tester.pump();
    pending.complete(photo());
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('Check the photo'), findsOneWidget);
  });
}
