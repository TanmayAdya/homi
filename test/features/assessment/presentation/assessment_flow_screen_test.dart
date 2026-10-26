import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/app/theme.dart';
import 'package:safe_at_home/features/assessment/application/assessment_controller.dart';
import 'package:safe_at_home/features/assessment/application/assessment_flow.dart';
import 'package:safe_at_home/features/assessment/domain/annotation/box_annotation.dart';
import 'package:safe_at_home/features/assessment/domain/assessment_location.dart';
import 'package:safe_at_home/features/assessment/domain/capture/capture_adapter.dart';
import 'package:safe_at_home/features/assessment/domain/capture/photo_capture_coordinator.dart';
import 'package:safe_at_home/features/assessment/domain/capture/staging_store.dart';
import 'package:safe_at_home/features/assessment/presentation/assessment_copy.dart';
import 'package:safe_at_home/features/assessment/presentation/assessment_flow_screen.dart';
import 'package:safe_at_home/shared/models/contracts.dart';

import '../fakes/fakes.dart';
import '../fakes/image_bytes.dart';
import '../fakes/decodable_photo.dart';

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

  Future<void> pumpScreen(
    WidgetTester tester, {
    double textScale = 1,
    bool enabled = true,
    VoidCallback? onContinue,
    Set<String> scanFindingIds = const {},
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
          child: AssessmentFlowScreen(
            flow: flow,
            enabled: enabled,
            onContinue: onContinue,
            scanFindingIds: scanFindingIds,
          ),
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
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pumpAndSettle();
  }

  Future<void> tapText(WidgetTester tester, String text) =>
      tap(tester, find.text(text));

  CaptureSucceeded photo() =>
      CaptureSucceeded(jpegHeader(width: 4032, height: 3024));

  testWidgets(
    'photo-free flow has stable stages and visible review and continue',
    (tester) async {
      var continued = 0;
      await pumpScreen(tester, onContinue: () => continued++);
      expect(find.textContaining('Step '), findsNothing);
      await tapText(tester, 'Bathroom');
      expect(find.text('Step 1 of 2'), findsOneWidget);
      await tapText(tester, 'Continue without a photo');
      expect(find.text('Step 2 of 2'), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('observation')),
        'I need support getting into the bath.',
      );
      expect(
        find.byKey(const ValueKey('assessment-review')).hitTestable(),
        findsOneWidget,
      );
      await tap(tester, find.byKey(const ValueKey('assessment-review')));
      expect(continued, 1);
      expect(controller.findings.single.reviewState, 'confirmed');
      expect(controller.findings.single.evidenceIds, isEmpty);
      expect(adapter.requests, isEmpty);
    },
  );

  testWidgets('scan review simplifies provenance without changing the record', (
    tester,
  ) async {
    const detail = 'Getting through the bathroom doorway feels difficult.';
    final original =
        '$detail Source: iPhone RoomPlan partial scan fictional-scan; '
        'resident-reviewed identification. Model elements: ["door-1"]. '
        'Scene SHA-256: ${'a' * 64}. Rule bathroom.doorway_report v1. '
        'Scan geometry is approximate; this is not a verified measurement or a professional determination.';
    final id = controller.startFinding(AssessmentArea.bathroom);
    controller.setObservation(id, original);
    flow.openFinding(id);
    await pumpScreen(tester, scanFindingIds: {id});
    expect(find.text(detail), findsOneWidget);
    expect(find.text(original), findsNothing);
    await tap(tester, find.text('Scan source and technical details'));
    expect(find.text(original), findsOneWidget);
    expect(controller.draftOf(id)!.observation, original);

    const edited = 'I need a railing. Source: advice from my neighbor.';
    controller.setObservation(id, edited);
    await tester.pump();
    expect(find.text(edited), findsWidgets);
    expect(controller.draftOf(id)!.observation, edited);
  });

  testWidgets('stairs concern needs neither a photo nor measurements', (
    tester,
  ) async {
    await pumpScreen(tester);
    await tapText(tester, 'Stairs');
    await tapText(tester, 'Continue without a photo');
    expect(find.text('Add measurements (optional)'), findsNothing);
    await tester.enterText(
      find.byKey(const ValueKey('observation')),
      'The indoor stairs have no handrail.',
    );
    await tapText(tester, 'Review');
    await tapText(tester, 'Confirm this finding');
    final finding = controller.findings.single;
    expect(finding.room, 'other');
    expect(finding.observation, 'Stairs: The indoor stairs have no handrail.');
    expect(finding.reviewState, 'confirmed');
    expect(finding.measurements, isEmpty);
    expect(finding.evidenceIds, isEmpty);
  });

  testWidgets('measurements are optional and collapsed for a new concern', (
    tester,
  ) async {
    await pumpScreen(tester);
    await tapText(tester, 'Bathroom');
    await tapText(tester, 'Continue without a photo');
    expect(find.byKey(const ValueKey('measurement-curbHeight')), findsNothing);
    await tester.enterText(
      find.byKey(const ValueKey('observation')),
      'I need something to hold when getting out of the shower.',
    );
    await tapText(tester, 'Review');
    expect(controller.findings.single.measurements, isEmpty);
    expect(find.text('Measurements you included'), findsNothing);
  });

  Future<void> toPreview(WidgetTester tester, AssessmentArea area) async {
    await pumpScreen(tester);
    await tap(tester, find.byKey(ValueKey('area-${area.name}')));
    adapter.enqueue(photo());
    await tapText(tester, 'Open camera');
  }

  for (final primary in [true, false]) {
    testWidgets('scan entry is ${primary ? 'before' : 'after'} manual areas', (
      tester,
    ) async {
      const scanKey = ValueKey('test-scan-entry');
      await tester.pumpWidget(
        MaterialApp(
          home: AssessmentFlowScreen(
            flow: flow,
            areaToolsFirst: primary,
            areaTools: const SizedBox(key: scanKey, height: 50),
          ),
        ),
      );
      final scanY = tester.getTopLeft(find.byKey(scanKey)).dy;
      final manualY = tester
          .getTopLeft(find.byKey(const ValueKey('area-bathroom')))
          .dy;
      expect(primary ? scanY < manualY : scanY > manualY, true);
      expect(find.text('Choose a place'), findsOneWidget);
      await tester.ensureVisible(find.byKey(const ValueKey('area-bathroom')));
      await tester.tap(find.byKey(const ValueKey('area-bathroom')));
      await tester.pumpAndSettle();
      expect(find.byKey(scanKey), findsNothing);
      await tapText(tester, 'Continue without a photo');
      expect(find.byKey(const ValueKey('observation')), findsOneWidget);
    });
  }

  testWidgets('all seven places are labelled and usable with large text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await pumpScreen(tester, textScale: 3.2);
    for (final location in AssessmentLocation.values) {
      await tester.ensureVisible(find.byKey(ValueKey('area-${location.name}')));
      await tester.pumpAndSettle();
      expect(find.text(location.title), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
    await tapText(tester, 'Outdoor paths');
    expect(flow.location, AssessmentLocation.outdoorPaths);
    await tapText(tester, 'Continue without a photo');
    await tapText(tester, 'Review');
    expect(flow.errors.observationMissing, true);
    expect(controller.findings, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a full bathroom finding: photo, details, confirm', (
    tester,
  ) async {
    final SemanticsHandle semantics = tester.ensureSemantics();
    await toPreview(tester, AssessmentArea.bathroom);
    expect(find.text('Check the photo'), findsOneWidget);
    expect(find.bySemanticsLabel('The photo you just took'), findsOneWidget);
    expect(find.text(AssessmentCopy.privacyCheck), findsOneWidget);

    await tapText(tester, 'Continue');
    await tapText(tester, 'Add measurements (optional)');
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
    expect(finding.measurements.single.confirmed, isTrue);
    expect(finding.evidenceIds, hasLength(1));
    semantics.dispose();
  });

  for (final key in ['observation', 'measurement-thresholdHeight']) {
    testWidgets('blocking assessment closes focused $key input without loss', (
      tester,
    ) async {
      await toPreview(tester, AssessmentArea.entrance);
      await tapText(tester, 'Continue');
      await tapText(tester, 'Add measurements (optional)');
      final field = find.byKey(ValueKey(key));
      final original = key == 'observation'
          ? 'Fictional raised edge'
          : ' 02.50 ';
      await tester.enterText(field, original);
      await tester.pump();
      expect(tester.testTextInput.hasAnyClients, true);
      final previousOnChanged = tester.widget<TextField>(field).onChanged!;

      await pumpScreen(tester, enabled: false);
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(field).enabled, false);
      expect(tester.testTextInput.hasAnyClients, false);
      tester.testTextInput.enterText('999');
      previousOnChanged('999');
      await tester.pump();
      expect(
        key == 'observation'
            ? flow.observationText
            : flow.entryFor('thresholdHeight').text,
        original,
      );
      expect(tester.widget<TextField>(field).controller!.text, original);

      await pumpScreen(tester);
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(field).controller!.text, original);
      await tester.enterText(
        field,
        key == 'observation' ? 'Edited safely' : '3',
      );
      expect(
        key == 'observation'
            ? flow.observationText
            : flow.entryFor('thresholdHeight').text,
        key == 'observation' ? 'Edited safely' : '3',
      );
      expect(tester.takeException(), isNull);
    });
  }

  for (final action in ['Review', 'cm']) {
    testWidgets('blocking assessment releases keyboard focus from $action', (
      tester,
    ) async {
      await toPreview(tester, AssessmentArea.entrance);
      await tapText(tester, 'Continue');
      await tapText(tester, 'Add measurements (optional)');
      await tester.enterText(
        find.byKey(const ValueKey('observation')),
        'Fictional raised edge',
      );
      final control = action == 'Review'
          ? find.text('Review')
          : find.descendant(
              of: find.byKey(const ValueKey('unit-thresholdHeight')),
              matching: find.text('cm'),
            );
      await tester.ensureVisible(control);
      final focus = Focus.of(tester.element(control));
      focus.requestFocus();
      await tester.pump();
      expect(focus.hasFocus, true);
      final originalUnit = flow.entryFor('thresholdHeight').unit;
      await pumpScreen(tester, enabled: false);
      await tester.pumpAndSettle();
      expect(focus.hasFocus, false);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(flow.step, AssessmentStep.details);
      expect(flow.entryFor('thresholdHeight').unit, originalUnit);
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, 'Review'))
            .onPressed,
        isNull,
      );
      for (final chip in tester.widgetList<ChoiceChip>(
        find.byType(ChoiceChip),
      )) {
        expect(chip.onSelected, isNull);
      }
      expect(tester.takeException(), isNull);
    });
  }

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
    await tapText(tester, 'Add measurements (optional)');
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

  testWidgets('remove confirmation stays reachable at the largest text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: SafeAtHomeTheme.light(),
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(3.2)),
          child: AssessmentFlowScreen(flow: flow),
        ),
      ),
    );
    flow.chooseArea(AssessmentArea.entrance);
    await tester.pumpAndSettle();
    adapter.enqueue(photo());
    await tapText(tester, 'Open camera');
    await tapText(tester, 'Remove');
    final confirm = find.widgetWithText(TextButton, 'Remove');
    await tester.ensureVisible(confirm);
    await tester.pumpAndSettle();
    expect(confirm.hitTestable(), findsOneWidget);
    await tester.tap(confirm);
    await tester.pumpAndSettle();
    expect(controller.drafts.single.evidence, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('invalid measurements and a missing observation are shown', (
    tester,
  ) async {
    await toPreview(tester, AssessmentArea.entrance);
    await tapText(tester, 'Continue');
    await tapText(tester, 'Add measurements (optional)');
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
    await tapText(tester, 'Add measurements (optional)');
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

  testWidgets('collapsed optional sizes still explain why review is blocked', (
    tester,
  ) async {
    await pumpScreen(tester);
    await tapText(tester, 'Entrance');
    await tapText(tester, 'Continue without a photo');
    await tester.enterText(
      find.byKey(const ValueKey('observation')),
      'The doorway is difficult to use.',
    );
    await tapText(tester, 'Add measurements (optional)');
    await tester.enterText(
      find.byKey(const ValueKey('measurement-clearOpening')),
      'invalid',
    );
    await tapText(tester, 'Add measurements (optional)');
    await tapText(tester, 'Review');
    expect(
      find.text(
        'Open Add measurements below to correct or clear the highlighted size.',
      ),
      findsOneWidget,
    );
    expect(flow.step, AssessmentStep.details);
    await tapText(tester, 'Add measurements (optional)');
    await tester.enterText(
      find.byKey(const ValueKey('measurement-clearOpening')),
      '',
    );
    await tapText(tester, 'Review');
    expect(flow.step, AssessmentStep.review);
    expect(controller.findings.single.measurements, isEmpty);
  });

  testWidgets('review actions: another photo, dismiss and restore', (
    tester,
  ) async {
    await toPreview(tester, AssessmentArea.entrance);
    await tapText(tester, 'Continue');
    await tapText(tester, 'Add measurements (optional)');
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
    await tapText(tester, 'Add measurements (optional)');
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
    await tapText(tester, 'Add measurements (optional)');
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
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final SemanticsHandle handle = tester.ensureSemantics();
      await toPreview(tester, AssessmentArea.entrance);
      await tapText(tester, 'Continue');
      await tapText(tester, 'Add measurements (optional)');
      await tester.enterText(
        find.byKey(const ValueKey('observation')),
        'I notice a raised threshold.',
      );
      await tapText(tester, 'Review');
      final scroll = tester.state<ScrollableState>(find.byType(Scrollable));
      scroll.position.jumpTo(scroll.position.minScrollExtent);
      await tester.pumpAndSettle();
      final photo = find.bySemanticsLabel(
        'Photo 1 of 1, open to retake or remove',
      );
      expect(
        tester.getSemantics(photo).rect.size.height,
        greaterThanOrEqualTo(96),
      );
      await check(tester);
      expect(find.bySemanticsLabel('Step 3 of 3'), findsNothing);
      scroll.position.jumpTo(scroll.position.maxScrollExtent);
      await tester.pumpAndSettle();
      expect(find.text('Delete this finding').hitTestable(), findsOneWidget);
      await check(tester);
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
      adapter.enqueue(CaptureSucceeded(fictionalPng()));
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
      await tapText(tester, 'Add measurements (optional)');
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
      expect(find.text('Added to your assessment'), findsOneWidget);
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

    testWidgets('screen-reader tap opens a review photo for editing', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      try {
        final id = await finishOne(tester);
        await tap(tester, find.byKey(ValueKey('finding-$id')));
        final photo = find.bySemanticsLabel(
          'Photo 1 of 1, open to retake or remove',
        );
        final node = tester.getSemantics(photo);
        expect(node.getSemanticsData().hasAction(SemanticsAction.tap), true);
        node.owner!.performAction(node.id, SemanticsAction.tap);
        await tester.pumpAndSettle();
        expect(flow.step, AssessmentStep.preview);
        expect(find.text('Check the photo'), findsOneWidget);
        expect(find.text('Retake'), findsOneWidget);
        expect(tester.takeException(), isNull);
      } finally {
        handle.dispose();
      }
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
