import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/features/assessment/application/assessment_controller.dart';
import 'package:safe_at_home/features/assessment/application/assessment_flow.dart';
import 'package:safe_at_home/features/assessment/domain/annotation/box_annotation.dart';
import 'package:safe_at_home/features/assessment/domain/capture/capture_adapter.dart';
import 'package:safe_at_home/features/assessment/domain/capture/photo_capture_coordinator.dart';
import 'package:safe_at_home/features/assessment/domain/capture/staging_store.dart';
import 'package:safe_at_home/features/assessment/presentation/assessment_copy.dart';
import 'package:safe_at_home/features/assessment/presentation/assessment_flow_screen.dart';
import 'package:safe_at_home/shared/models/contracts.dart';

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

  Future<void> pumpScreen(WidgetTester tester, {double textScale = 1}) async {
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
          child: AssessmentFlowScreen(flow: flow),
        ),
      ),
    );
  }

  Future<void> tap(WidgetTester tester, Finder finder) async {
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  Future<void> tapText(WidgetTester tester, String text) =>
      tap(tester, find.text(text));

  CaptureSucceeded photo() =>
      CaptureSucceeded(jpegHeader(width: 4032, height: 3024));

  Future<void> toPreview(WidgetTester tester, AssessmentArea area) async {
    await pumpScreen(tester);
    await tap(tester, find.byKey(ValueKey('area-${area.name}')));
    adapter.enqueue(photo());
    await tapText(tester, 'Open camera');
  }

  testWidgets('a full bathroom finding: photo, details, confirm', (
    tester,
  ) async {
    final SemanticsHandle semantics = tester.ensureSemantics();
    await toPreview(tester, AssessmentArea.bathroom);
    expect(find.text('Check the photo'), findsOneWidget);
    expect(find.bySemanticsLabel('The photo you just took'), findsOneWidget);
    expect(find.text(AssessmentCopy.privacyCheck), findsOneWidget);

    await tapText(tester, 'Continue');
    await tester.enterText(
      find.byKey(const ValueKey('observation')),
      'I notice a raised edge where you step into the tub.',
    );
    await tester.enterText(
      find.byKey(const ValueKey('measurement-curbHeight')),
      '45',
    );
    await tap(tester, find.text('cm').first);
    await tapText(tester, 'Review');

    expect(find.text('Needs your review'), findsOneWidget);
    expect(find.textContaining('450 mm (you entered 45 cm)'), findsOneWidget);
    expect(find.text(AssessmentCopy.notSavedYet), findsOneWidget);

    await tapText(tester, 'Confirm this finding');
    expect(find.text('Confirmed by you'), findsOneWidget);

    final Finding finding = controller.findings.single;
    expect(finding.room, 'bathroom');
    expect(finding.reviewState, 'confirmed');
    expect(finding.measurements.single.value, 450);
    expect(finding.evidenceIds, hasLength(1));
    semantics.dispose();
  });

  testWidgets('cancelling the camera explains and offers to continue', (
    tester,
  ) async {
    await pumpScreen(tester);
    await tap(tester, find.byKey(const ValueKey('area-entrance')));
    adapter.enqueue(const CaptureCancelled());
    await tapText(tester, 'Open camera');

    expect(
      find.text(AssessmentCopy.notice(const CaptureCancelledNotice())!),
      findsOneWidget,
    );
    await tapText(tester, 'Continue without a photo');
    expect(find.byKey(const ValueKey('observation')), findsOneWidget);
  });

  testWidgets('a permanent denial replaces the camera button', (tester) async {
    await pumpScreen(tester);
    await tap(tester, find.byKey(const ValueKey('area-entrance')));
    adapter.enqueue(const CapturePermissionDenied(canAskAgain: false));
    await tapText(tester, 'Open camera');

    expect(find.text('Open camera'), findsNothing);
    expect(find.text('I changed the setting'), findsOneWidget);
    expect(
      find.text(
        AssessmentCopy.notice(const PermissionNotice(canAskAgain: false))!,
      ),
      findsOneWidget,
    );

    await tapText(tester, 'I changed the setting');
    expect(adapter.requests, hasLength(1));
    expect(find.text('Open camera'), findsOneWidget);
  });

  testWidgets('an unusable photo is explained in plain words', (tester) async {
    await pumpScreen(tester);
    await tap(tester, find.byKey(const ValueKey('area-entrance')));
    adapter.enqueue(CaptureSucceeded(ftypHeader('heic')));
    await tapText(tester, 'Open camera');
    expect(find.textContaining('HEIC format'), findsOneWidget);
    expect(find.text('Photo'), findsOneWidget);
  });

  testWidgets('retaking a photo keeps typed measurements', (tester) async {
    await toPreview(tester, AssessmentArea.entrance);
    await tapText(tester, 'Continue');
    await tester.enterText(
      find.byKey(const ValueKey('measurement-thresholdHeight')),
      '1.5',
    );
    await tap(tester, find.byTooltip('Back'));

    adapter.enqueue(photo());
    await tapText(tester, 'Retake');
    await tapText(tester, 'Continue');

    final TextField field = tester.widget(
      find.byKey(const ValueKey('measurement-thresholdHeight')),
    );
    expect(field.controller!.text, '1.5');
    expect(controller.drafts.single.evidence, hasLength(1));
  });

  testWidgets('remove asks first, then detaches the photo', (tester) async {
    await toPreview(tester, AssessmentArea.entrance);
    await tapText(tester, 'Remove');
    expect(find.text('Remove this photo?'), findsOneWidget);
    await tapText(tester, 'Cancel');
    expect(controller.drafts.single.evidence, hasLength(1));

    await tapText(tester, 'Remove');
    await tap(tester, find.widgetWithText(TextButton, 'Remove'));
    expect(controller.drafts.single.evidence, isEmpty);
    expect(find.text('Photo removed.'), findsOneWidget);
    expect(await staging.keys(), isEmpty);
  });

  testWidgets('invalid measurements and a missing observation are shown', (
    tester,
  ) async {
    await toPreview(tester, AssessmentArea.entrance);
    await tapText(tester, 'Continue');
    await tester.enterText(
      find.byKey(const ValueKey('measurement-clearOpening')),
      '1,500',
    );
    await tapText(tester, 'Review');
    expect(find.text(AssessmentCopy.observationRequired), findsOneWidget);
    expect(find.textContaining('no thousands separator'), findsOneWidget);
    expect(controller.findings, isEmpty);
  });

  testWidgets('a zero is kept and questioned where implausible', (
    tester,
  ) async {
    await toPreview(tester, AssessmentArea.entrance);
    await tapText(tester, 'Continue');
    await tester.enterText(
      find.byKey(const ValueKey('observation')),
      'I notice a narrow doorway.',
    );
    await tester.enterText(
      find.byKey(const ValueKey('measurement-clearOpening')),
      '0',
    );
    await tapText(tester, 'Review');
    expect(find.text(AssessmentCopy.zeroCheck), findsOneWidget);
    expect(controller.findings.single.measurements.single.value, 0);
  });

  testWidgets('review actions: another photo, dismiss and restore', (
    tester,
  ) async {
    await toPreview(tester, AssessmentArea.entrance);
    await tapText(tester, 'Continue');
    await tester.enterText(
      find.byKey(const ValueKey('observation')),
      'I notice a raised threshold.',
    );
    await tapText(tester, 'Review');

    await tapText(tester, 'Request another photo');
    expect(find.text('Photo'), findsOneWidget);
    expect(
      find.text(
        AssessmentCopy.viewPrompt(AssessmentArea.entrance, CaptureView.closeUp),
      ),
      findsOneWidget,
    );
    await tap(tester, find.byTooltip('Back'));
    expect(find.text(AssessmentCopy.anotherViewRequested), findsOneWidget);

    await tapText(tester, 'Dismiss');
    expect(find.text('Dismissed'), findsOneWidget);
    expect(find.text('Confirm this finding'), findsNothing);
    await tapText(tester, 'Restore');
    expect(find.text('Needs your review'), findsOneWidget);
  });

  testWidgets('rebuilding the screen (e.g. rotation) keeps entered text', (
    tester,
  ) async {
    await toPreview(tester, AssessmentArea.bathroom);
    await tapText(tester, 'Continue');
    await tester.enterText(
      find.byKey(const ValueKey('observation')),
      'I notice a raised edge.',
    );

    tester.view.physicalSize = const Size(2400, 1080);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(const SizedBox());
    await pumpScreen(tester);

    final TextField field = tester.widget(
      find.byKey(const ValueKey('observation')),
    );
    expect(field.controller!.text, 'I notice a raised edge.');
  });

  testWidgets('large text does not break the details step', (tester) async {
    await toPreview(tester, AssessmentArea.entrance);
    await tapText(tester, 'Continue');
    await pumpScreen(tester, textScale: 2);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.enterText(
      find.byKey(const ValueKey('observation')),
      'I notice a raised threshold.',
    );
    await tapText(tester, 'Review');
    expect(find.text('Needs your review'), findsOneWidget);
  });

  group('accessibility guidelines', () {
    Future<void> check(WidgetTester tester) async {
      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      await expectLater(tester, meetsGuideline(iOSTapTargetGuideline));
      await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
      await expectLater(tester, meetsGuideline(textContrastGuideline));
    }

    testWidgets('area choice', (tester) async {
      final SemanticsHandle handle = tester.ensureSemantics();
      await pumpScreen(tester);
      await check(tester);
      handle.dispose();
    });

    testWidgets('photo prompt', (tester) async {
      final SemanticsHandle handle = tester.ensureSemantics();
      await pumpScreen(tester);
      await tap(tester, find.byKey(const ValueKey('area-bathroom')));
      await check(tester);
      handle.dispose();
    });

    testWidgets('review', (tester) async {
      final SemanticsHandle handle = tester.ensureSemantics();
      await toPreview(tester, AssessmentArea.entrance);
      await tapText(tester, 'Continue');
      await tester.enterText(
        find.byKey(const ValueKey('observation')),
        'I notice a raised threshold.',
      );
      await tapText(tester, 'Review');
      await check(tester);
      expect(find.bySemanticsLabel('Step 5 of 5'), findsOneWidget);
      handle.dispose();
    });
  });

  group('marking the area', () {
    setUp(() {
      var n = 0;
      flow = AssessmentFlow(
        controller: controller,
        capture: PhotoCaptureCoordinator(adapter: adapter, staging: staging),
        staging: staging,
        annotations: AnnotationStore(newId: () => 'box-${++n}'),
      );
    });

    testWidgets('a JPEG explains marking comes after saving', (tester) async {
      await toPreview(tester, AssessmentArea.entrance);
      expect(find.text(AssessmentCopy.markAfterSaving), findsOneWidget);
      expect(find.text('Mark the area on this photo'), findsNothing);
    });

    testWidgets('a PNG opens the editor and the mark is kept', (tester) async {
      await pumpScreen(tester);
      await tap(tester, find.byKey(const ValueKey('area-entrance')));
      adapter.enqueue(CaptureSucceeded(pngHeader(width: 1200, height: 900)));
      await tapText(tester, 'Open camera');

      await tapText(tester, 'Mark the area on this photo');
      expect(find.text('Mark the area'), findsOneWidget);
      await tapText(tester, 'Add a box');
      await tapText(tester, 'Done');

      expect(find.text('Change the mark'), findsOneWidget);
      expect(flow.annotations!.all, hasLength(1));
    });
  });

  group('reopening and history', () {
    Future<String> finishOne(WidgetTester tester) async {
      await toPreview(tester, AssessmentArea.entrance);
      await tapText(tester, 'Continue');
      await tester.enterText(
        find.byKey(const ValueKey('observation')),
        'I notice a raised threshold.',
      );
      await tester.enterText(
        find.byKey(const ValueKey('measurement-thresholdHeight')),
        '2',
      );
      await tap(
        tester,
        find.descendant(
          of: find.byKey(const ValueKey('unit-thresholdHeight')),
          matching: find.text('cm'),
        ),
      );
      await tapText(tester, 'Review');
      await tapText(tester, 'Done, add another finding');
      return controller.drafts.single.id;
    }

    testWidgets('the list reopens a finding with its typed values', (
      tester,
    ) async {
      final String id = await finishOne(tester);
      expect(find.text('Your findings'), findsOneWidget);
      await tap(tester, find.byKey(ValueKey('finding-$id')));
      expect(find.text('Needs your review'), findsOneWidget);

      await tapText(tester, 'Edit');
      final TextField field = tester.widget(
        find.byKey(const ValueKey('measurement-thresholdHeight')),
      );
      expect(field.controller!.text, '2');

      await tap(tester, find.byTooltip('Back'));
      await tap(tester, find.byTooltip('Back'));
      expect(find.text('Choose an area'), findsOneWidget);
    });

    testWidgets('a corrected value shows what it was before', (tester) async {
      final String id = await finishOne(tester);
      await tap(tester, find.byKey(ValueKey('finding-$id')));
      await tapText(tester, 'Edit');
      await tester.enterText(
        find.byKey(const ValueKey('measurement-thresholdHeight')),
        '25',
      );
      await tap(
        tester,
        find.descendant(
          of: find.byKey(const ValueKey('unit-thresholdHeight')),
          matching: find.text('mm'),
        ),
      );
      await tapText(tester, 'Review');
      expect(find.text('Threshold height: 25 mm'), findsOneWidget);
      expect(find.text('Earlier: 20 mm (you entered 2 cm)'), findsOneWidget);

      await tapText(tester, 'Edit');
      await tester.enterText(
        find.byKey(const ValueKey('measurement-thresholdHeight')),
        '',
      );
      await tapText(tester, 'Review');
      expect(find.text('Threshold height: not recorded now'), findsOneWidget);
      expect(
        find.text('Earlier: 20 mm (you entered 2 cm), then 25 mm'),
        findsOneWidget,
      );
    });

    testWidgets('tapping a photo on review opens it for retake or removal', (
      tester,
    ) async {
      final SemanticsHandle handle = tester.ensureSemantics();
      final String id = await finishOne(tester);
      await tap(tester, find.byKey(ValueKey('finding-$id')));
      final String evidenceId =
          controller.drafts.single.evidence.single.evidenceId;
      expect(
        find.bySemanticsLabel('Photo 1 of 1, open to retake or remove'),
        findsOneWidget,
      );
      await tap(tester, find.byKey(ValueKey('review-photo-$evidenceId')));
      expect(find.text('Check the photo'), findsOneWidget);
      expect(find.text('Retake'), findsOneWidget);
      handle.dispose();
    });

    testWidgets('an uploaded photo says it is saved instead of loading', (
      tester,
    ) async {
      final String id = await finishOne(tester);
      final String evidenceId =
          controller.drafts.single.evidence.single.evidenceId;
      await staging.discard(flow.evidence.remove(evidenceId)!.key);
      await tap(tester, find.byKey(ValueKey('finding-$id')));
      expect(find.text('Saved to your case'), findsOneWidget);
      expect(find.text('Loading photo'), findsNothing);
    });
  });
}
