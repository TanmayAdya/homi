import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/app/theme.dart';
import 'package:safe_at_home/l10n/app_localizations.dart';
import 'program_localization_support.dart';
import 'package:safe_at_home/features/assessment/presentation/saved_photo_with_marks.dart';
import 'package:safe_at_home/features/requests/reviewed_photo_screen.dart';

Future<Uint8List> fictionalImage() async {
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawRect(
    const Rect.fromLTWH(0, 0, 320, 200),
    Paint()..color = const Color(0xFFCBDDD4),
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage(320, 200);
  try {
    return (await image.toByteData(
      format: ui.ImageByteFormat.png,
    ))!.buffer.asUint8List();
  } finally {
    image.dispose();
    picture.dispose();
  }
}

void main() {
  testWidgets('a photo that cannot decode cannot be marked reviewed', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: SafeAtHomeTheme.light(),
        home: ReviewedPhotoScreen(
          bytes: Uint8List.fromList([1, 2, 3, 4]),
          width: 320,
          height: 200,
          marks: const [],
        ),
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pumpAndSettle();
    expect(
      find.textContaining('This photo could not be opened for review'),
      findsOneWidget,
    );
    await tester.scrollUntilVisible(
      find.text('Include this reviewed photo'),
      160,
    );
    final button = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Include this reviewed photo'),
    );
    expect(button.onPressed, isNull);
    expect(tester.takeException(), isNull);
  });

  for (final config in [
    for (final scale in [1.0, 2.0, 3.2]) (const Locale('en'), scale),
    for (final locale in programLocales) (locale, 3.2),
  ]) {
    final (locale, scale) = config;
    String tr(String text) => programText(locale, text);
    testWidgets(
      'photo confirmation and complete notes remain reachable at ${scale}x in $locale',
      (tester) async {
        tester.view.physicalSize = const Size(320, 640);
        tester.view.devicePixelRatio = 1;
        tester.platformDispatcher.textScaleFactorTestValue = scale;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
          tester.platformDispatcher.clearTextScaleFactorTestValue();
        });
        final bytes = (await tester.runAsync(fictionalImage))!;
        final note =
            'Fictional threshold — Casa de María 李家 {number}. Revise toda la observación antes de incluirla. 請完整檢查原始備註。';
        bool? result;
        await tester.pumpWidget(
          MaterialApp(
            locale: locale,
            supportedLocales: AppLocalizations.supportedLocales,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            theme: SafeAtHomeTheme.light(),
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () async {
                    result = await Navigator.of(context).push<bool>(
                      MaterialPageRoute(
                        builder: (_) => ReviewedPhotoScreen(
                          bytes: bytes,
                          width: 320,
                          height: 200,
                          marks: [
                            {
                              'id': 'test-box',
                              'rect': [100000, 100000, 500000, 500000],
                              'label': note,
                            },
                          ],
                        ),
                      ),
                    );
                  },
                  child: const Text('Review'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Review'));
        await tester.pump();
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)),
        );
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(find.byType(SavedPhotoWithMarks), 160);
        final imageSize = tester.getSize(find.byType(SavedPhotoWithMarks));
        expect(imageSize.width / imageSize.height, closeTo(320 / 200, .001));
        await tester.scrollUntilVisible(find.text(tr('Photo notes')), 160);
        await tester.scrollUntilVisible(
          find.byWidgetPredicate(
            (w) => w is Text && w.data == note && w.maxLines == null,
          ),
          160,
          maxScrolls: 30,
        );
        expect(
          find.byWidgetPredicate(
            (w) => w is Text && w.data == note && w.maxLines == null,
          ),
          findsOneWidget,
        );
        await tester.scrollUntilVisible(
          find.text(tr('Include this reviewed photo')),
          160,
        );
        await tester.ensureVisible(
          find.widgetWithText(FilledButton, tr('Include this reviewed photo')),
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find.widgetWithText(FilledButton, tr('Include this reviewed photo')),
        );
        await tester.pumpAndSettle();
        expect(result, isTrue);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
