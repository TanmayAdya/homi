import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/features/assessment/domain/image/private_media_platform.dart';
import 'package:safe_at_home/features/assessment/presentation/photo_privacy_screen.dart';
import '../fakes/image_bytes.dart';
import '../fakes/decodable_photo.dart';

class _Media extends PrivateMediaPlatform {
  final calls = <({List<double>? crop, List<List<double>> covers})>[];
  final Completer<Uint8List> result = Completer<Uint8List>();
  @override
  Future<Uint8List> edit(
    Uint8List bytes, {
    List<double>? crop,
    List<List<double>> redactions = const [],
  }) {
    calls.add((crop: crop, covers: redactions));
    return result.future;
  }
}

void main() {
  Future<void> tap(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  Future<void> open(
    WidgetTester tester,
    _Media media, {
    double scale = 1,
    Uint8List? bytes,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(textScaler: TextScaler.linear(scale)),
          child: PhotoPrivacyScreen(
            bytes: bytes ?? fictionalPng(),
            media: media,
          ),
        ),
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'independent width and height, undo and crop reset preserve exact normalized edits',
    (tester) async {
      final media = _Media();
      await open(tester, media);
      await tap(tester, find.byTooltip('Make wider'));
      await tap(tester, find.text('Add opaque cover'));
      await tap(tester, find.byTooltip('Make taller'));
      await tap(tester, find.text('Add opaque cover'));
      await tap(tester, find.text('Undo last cover'));
      await tap(tester, find.text('Crop to outlined area'));
      await tap(tester, find.text('Keep full photo'));
      await tap(tester, find.text('Apply and review photo'));
      expect(media.calls, hasLength(1));
      expect(media.calls.single.crop, isNull);
      final cover = media.calls.single.covers.single;
      expect(cover[0], .2);
      expect(cover[1], .2);
      expect(cover[2], closeTo(.425, .000001));
      expect(cover[3], closeTo(.4, .000001));
      expect(find.text('Applying…'), findsOneWidget);
      await tester.tap(find.text('Applying…'));
      await tester.pump();
      expect(media.calls, hasLength(1));
    },
  );
  testWidgets('failed processing retains selected edits and permits retry', (
    tester,
  ) async {
    final media = _Media();
    await open(tester, media);
    await tap(tester, find.text('Add opaque cover'));
    await tap(tester, find.text('Crop to outlined area'));
    await tap(tester, find.text('Apply and review photo'));
    media.result.completeError(StateError('synthetic decoder failure'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Your original photo and selected edits'),
      findsOneWidget,
    );
    expect(find.text('Undo last cover'), findsOneWidget);
    expect(find.text('Keep full photo'), findsOneWidget);
    await tap(tester, find.text('Apply and review photo'));
    expect(media.calls, hasLength(2));
    expect(media.calls[1].crop, media.calls[0].crop);
    expect(media.calls[1].covers, media.calls[0].covers);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'failed actual preview disables privacy edits and preserves them for recovery',
    (tester) async {
      final media = _Media();
      await open(tester, media);
      await tap(tester, find.byTooltip('Make wider'));
      await tap(tester, find.text('Add opaque cover'));
      await tap(tester, find.text('Crop to outlined area'));
      final priorApply = tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Apply and review photo'),
          )
          .onPressed!;
      await open(tester, media, bytes: pngHeader(width: 1200, height: 900));
      expect(find.textContaining('selected edits are kept'), findsOneWidget);
      expect(
        tester
            .widget<IconButton>(
              find.widgetWithIcon(IconButton, Icons.swap_horiz),
            )
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<OutlinedButton>(
              find.widgetWithText(OutlinedButton, 'Add opaque cover'),
            )
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Apply and review photo'),
            )
            .onPressed,
        isNull,
      );
      priorApply();
      await tester.pump();
      expect(media.calls, isEmpty);
      expect(find.text('Undo last cover'), findsOneWidget);
      expect(find.text('Keep full photo'), findsOneWidget);

      await open(tester, media);
      await tap(tester, find.text('Apply and review photo'));
      expect(media.calls, hasLength(1));
      expect(media.calls.single.crop![0], .2);
      expect(media.calls.single.crop![2], closeTo(.425, .000001));
      expect(media.calls.single.covers, hasLength(1));
      expect(media.calls.single.covers.single[2], closeTo(.425, .000001));
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'narrow large-text controls wrap, remain labeled and have 48px targets',
    (tester) async {
      tester.view.physicalSize = const Size(320, 740);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final media = _Media();
      await open(tester, media, scale: 2);
      await tester.ensureVisible(find.byTooltip('Make wider'));
      await tester.pumpAndSettle();
      final semantics = tester.ensureSemantics();
      expect(
        await meetsGuideline(androidTapTargetGuideline).matchAsync(tester),
        isNull,
      );
      expect(
        await meetsGuideline(labeledTapTargetGuideline).matchAsync(tester),
        isNull,
      );
      semantics.dispose();
      expect(
        tester
            .getSize(find.widgetWithIcon(IconButton, Icons.swap_horiz))
            .height,
        greaterThanOrEqualTo(48),
      );
      expect(tester.takeException(), isNull);
      await tap(tester, find.text('Add opaque cover'));
      await tap(tester, find.text('Apply and review photo'));
      expect(media.calls, hasLength(1));
    },
  );
  testWidgets('unreadable photo retains navigation back', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => PhotoPrivacyScreen(
                    bytes: pngHeader(width: 1200, height: 900),
                  ),
                ),
              ),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pumpAndSettle();
    expect(find.byTooltip('Back'), findsOneWidget);
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    expect(find.text('Open'), findsOneWidget);
  });
}
