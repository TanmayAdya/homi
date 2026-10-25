import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/features/assessment/presentation/recovery_photo_review_card.dart';

import '../fakes/decodable_photo.dart';

void main() {
  testWidgets(
    'missing or invalid saved pixels cannot replace the device photo',
    (tester) async {
      var keptSaved = 0, keptDevice = 0, reloads = 0;
      Future<void> show(Uint8List? bytes) async {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: RecoveryPhotoReviewCard(
                  bytes: bytes,
                  busy: false,
                  onShowSaved: () => reloads++,
                  onKeepSaved: () => keptSaved++,
                  onKeepDevice: () => keptDevice++,
                ),
              ),
            ),
          ),
        );
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)),
        );
        await tester.pumpAndSettle();
      }

      FilledButton keep() => tester.widget(
        find.widgetWithText(FilledButton, 'Keep the saved photo'),
      );

      await show(null);
      expect(keep().onPressed, isNull);
      await show(Uint8List.fromList([1, 2, 3, 4]));
      expect(
        find.textContaining('could not be opened for review'),
        findsOneWidget,
      );
      expect(keep().onPressed, isNull);
      await tester.tap(find.text('Show saved photo'));
      await tester.tap(find.text('Keep device photo to upload after review'));
      expect(reloads, 1);
      expect(keptDevice, 1);
      expect(keptSaved, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'only current decoded pixels allow saved choice and busy blocks all choices',
    (tester) async {
      final pixels = fictionalPng();
      var saved = 0;
      Future<void> show(
        Uint8List? bytes, {
        bool busy = false,
        bool settleCodec = true,
      }) async {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: RecoveryPhotoReviewCard(
                  bytes: bytes,
                  busy: busy,
                  onShowSaved: () {},
                  onKeepSaved: () => saved++,
                  onKeepDevice: () {},
                ),
              ),
            ),
          ),
        );
        if (settleCodec) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 100)),
          );
          await tester.pumpAndSettle();
        }
      }

      FilledButton keep() => tester.widget(
        find.widgetWithText(FilledButton, 'Keep the saved photo'),
      );

      await show(pixels);
      expect(keep().onPressed, isNotNull);
      await tester.tap(find.text('Keep the saved photo'));
      expect(saved, 1);
      await show(pixels, busy: true);
      expect(keep().onPressed, isNull);
      expect(
        tester.widget<OutlinedButton>(find.byType(OutlinedButton)).onPressed,
        isNull,
      );
      expect(
        tester.widget<TextButton>(find.byType(TextButton)).onPressed,
        isNull,
      );
      await show(Uint8List.fromList([9, 9]), settleCodec: false);
      expect(keep().onPressed, isNull);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pumpAndSettle();
      expect(keep().onPressed, isNull);
      await show(null);
      expect(keep().onPressed, isNull);
      expect(saved, 1);
      expect(tester.takeException(), isNull);
    },
  );
}
