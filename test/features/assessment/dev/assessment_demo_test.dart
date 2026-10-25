import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/features/assessment/dev/assessment_demo.dart';
import 'package:safe_at_home/features/assessment/dev/fictional_camera.dart';
import 'package:safe_at_home/features/assessment/domain/capture/capture_adapter.dart';
import 'package:safe_at_home/features/assessment/domain/image/image_validator.dart';

import '../fakes/fakes.dart';

void main() {
  test('generated scenes are PNGs the validator accepts', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    for (final AssessmentArea area in AssessmentArea.values) {
      for (final CaptureView view in CaptureView.values) {
        final Uint8List bytes = await drawFictionalScene(area, view);
        final ImageCheck check = const ImageValidator().check(bytes);
        expect(check, isA<ImageAccepted>(), reason: '$area $view');
        final accepted = check as ImageAccepted;
        expect(accepted.format, SupportedImageFormat.png);
        expect((accepted.width, accepted.height), (1200, 900));
      }
    }
  });

  testWidgets('demo: scenarios, save, and the photo chooser', (tester) async {
    await tester.pumpWidget(
      AssessmentDemoApp(camera: ScriptedCaptureAdapter()),
    );
    expect(find.textContaining('Fictional data only'), findsOneWidget);
    expect(find.textContaining('Saved to your case'), findsOneWidget);

    await tester.tap(find.text('Add the fictional scenarios'));
    await tester.pumpAndSettle();
    expect(
      find.text('I notice a raised threshold at the front door.'),
      findsOneWidget,
    );
    expect(find.textContaining('Not saved yet'), findsOneWidget);

    await tester.tap(find.text('Save to my case'));
    await tester.pumpAndSettle();
    expect(find.text('Saved to your case.'), findsOneWidget);

    await tester.ensureVisible(find.text('Choose photos for the draft'));
    await tester.tap(find.text('Choose photos for the draft'));
    await tester.pumpAndSettle();
    expect(find.text('Photos for the draft'), findsOneWidget);
    expect(find.text('No saved photos yet.'), findsOneWidget);
  });

  testWidgets('demo: the guided flow opens from home', (tester) async {
    await tester.pumpWidget(
      AssessmentDemoApp(camera: ScriptedCaptureAdapter()),
    );
    await tester.tap(find.text('Add or continue a finding'));
    await tester.pumpAndSettle();
    expect(find.text('Choose an area'), findsOneWidget);
    expect(find.byType(BackButton), findsOneWidget);
  });
}
