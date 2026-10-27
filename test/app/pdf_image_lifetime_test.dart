import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart';

class _ControlledEntry implements PdfrxEntryFunctions {
  @override
  Future<void> init() async {}
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('$invocation');
}

class _ControlledDocument implements PdfDocument {
  _ControlledDocument(this.sourceName) {
    page = _ControlledPage(this);
  }
  @override
  final String sourceName;
  late final _ControlledPage page;
  int disposals = 0;
  @override
  bool get isEncrypted => false;
  @override
  PdfPermissions? get permissions => null;
  @override
  Stream<PdfDocumentEvent> get events => const Stream.empty();
  @override
  List<PdfPage> get pages => [page];
  @override
  Future<void> loadPagesProgressively<T>({
    PdfPageLoadingCallback<T>? onPageLoadProgress,
    T? data,
    Duration loadUnitDuration = const Duration(milliseconds: 250),
  }) async {}
  @override
  Future<void> dispose() async {
    disposals++;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('$invocation');
}

class _ControlledPage implements PdfPage {
  _ControlledPage(this.document);
  @override
  final _ControlledDocument document;
  final renderReply = Completer<PdfImage?>();
  final tokens = <PdfPageRenderCancellationToken?>[];
  @override
  int get pageNumber => 1;
  @override
  double get width => 612;
  @override
  double get height => 792;
  @override
  PdfPageRotation get rotation => PdfPageRotation.none;
  @override
  bool get isLoaded => true;
  @override
  PdfPageRenderCancellationToken createCancellationToken() =>
      _ControlledToken();
  @override
  Future<PdfImage?> render({
    int x = 0,
    int y = 0,
    int? width,
    int? height,
    double? fullWidth,
    double? fullHeight,
    int? backgroundColor,
    PdfPageRotation? rotationOverride,
    PdfAnnotationRenderingMode annotationRenderingMode =
        PdfAnnotationRenderingMode.annotationAndForms,
    int flags = PdfPageRenderFlags.none,
    PdfPageRenderCancellationToken? cancellationToken,
  }) {
    tokens.add(cancellationToken);
    return renderReply.future.then(
      (image) => image is _TrackedRawImage ? image.copy() : image,
    );
  }

  @override
  Future<PdfPageRawText?> loadText() async => null;
  @override
  Future<List<PdfLink>> loadLinks({
    bool compact = false,
    bool enableAutoLinkDetection = true,
  }) async => [];
}

class _ControlledToken implements PdfPageRenderCancellationToken {
  bool _canceled = false;
  @override
  bool get isCanceled => _canceled;
  @override
  Future<void> cancel() async {
    _canceled = true;
  }
}

class _TrackedRawImage implements PdfImage {
  _TrackedRawImage({this.width = 37, this.height = 53});
  int _reads = 0, _disposals = 0;
  final copies = <_TrackedRawImage>[];
  int get reads => copies.fold(_reads, (sum, image) => sum + image._reads);
  int get disposals =>
      copies.fold(_disposals, (sum, image) => sum + image._disposals);
  _TrackedRawImage copy() {
    final image = _TrackedRawImage(width: width, height: height);
    copies.add(image);
    return image;
  }

  @override
  final int width;
  @override
  final int height;
  @override
  Uint8List get pixels {
    _reads++;
    return Uint8List(width * height * 4)..fillRange(0, width * height * 4, 255);
  }

  @override
  void dispose() {
    _disposals++;
  }
}

enum _Departure {
  afterDecode,
  duringDecode,
  keyedReplacement,
  sameStateReplacement,
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final departure in _Departure.values) {
    testWidgets('PDF decoded image ownership: ${departure.name}', (
      tester,
    ) async {
      final previousEntry = PdfrxEntryFunctions.instance;
      final previousCache = Pdfrx.cacheDirectoryPath;
      final previousLoadAsset = Pdfrx.loadAsset;
      final previousCreate = ui.Image.onCreate;
      final previousDispose = ui.Image.onDispose;
      final created = <ui.Image>[];
      final disposed = <ui.Image>[];
      PdfrxEntryFunctions.instance = _ControlledEntry();
      Pdfrx.cacheDirectoryPath = '.';
      ui.Image.onCreate = (image) {
        previousCreate?.call(image);
        if ((image.width == 37 && image.height == 53) ||
            (image.width == 41 && image.height == 59)) {
          created.add(image);
        }
      };
      ui.Image.onDispose = (image) {
        previousDispose?.call(image);
        if (created.contains(image)) disposed.add(image);
      };
      final old = _ControlledDocument('fictional-old-${departure.name}');
      final replacement = _ControlledDocument(
        'fictional-new-${departure.name}',
      );
      final oldRaw = _TrackedRawImage();
      final newRaw = _TrackedRawImage(width: 41, height: 59);
      final controller = PdfViewerController();
      final replacementController = departure == _Departure.keyedReplacement
          ? PdfViewerController()
          : controller;
      bool removed = false;
      Widget viewer(
        _ControlledDocument document,
        PdfViewerController control,
      ) => MaterialApp(
        home: Scaffold(
          body: PdfViewer(
            PdfDocumentRefDirect(document),
            key: ValueKey(
              departure == _Departure.keyedReplacement
                  ? document.sourceName
                  : 'same-viewer',
            ),
            controller: control,
            params: const PdfViewerParams(
              behaviorControlParams: PdfViewerBehaviorControlParams(
                trailingPageLoadingDelay: Duration.zero,
              ),
            ),
          ),
        ),
      );
      Future<void> decodeUntil(bool Function() complete) async {
        for (var i = 0; i < 50 && !complete(); i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump();
        }
        expect(
          complete(),
          isTrue,
          reason: 'The real image decode must settle.',
        );
      }

      try {
        await tester.pumpWidget(viewer(old, controller));
        for (var i = 0; i < 20 && old.page.tokens.isEmpty; i++) {
          await tester.pump(const Duration(milliseconds: 10));
        }
        expect(controller.isReady, isTrue);
        expect(old.page.tokens, hasLength(1));
        old.page.renderReply.complete(oldRaw);
        await tester.pump();
        expect(
          oldRaw.reads,
          1,
          reason: 'createImage has started reading pixels.',
        );
        if (departure != _Departure.afterDecode) {
          expect(
            created,
            isEmpty,
            reason: 'Departure precedes image creation.',
          );
          if (departure == _Departure.duringDecode) {
            await tester.pumpWidget(const SizedBox.shrink());
            removed = true;
          } else {
            await tester.pumpWidget(viewer(replacement, replacementController));
            for (
              var i = 0;
              i < 20 &&
                  (!replacementController.isReady ||
                      !identical(replacementController.document, replacement));
              i++
            ) {
              await tester.pump(const Duration(milliseconds: 10));
            }
            expect(replacementController.document, same(replacement));
          }
          expect(old.disposals, 1);
        }
        await decodeUntil(() => created.isNotEmpty && oldRaw.disposals >= 1);
        final oldImages = created.where((image) => image.width == 37).toList();
        expect(oldImages, isNotEmpty);
        if (departure == _Departure.afterDecode) {
          expect(oldImages.any((image) => !image.debugDisposed), isTrue);
          await tester.pumpWidget(const SizedBox.shrink());
          removed = true;
        }
        await tester.pump(const Duration(seconds: 1));
        expect(tester.takeException(), isNull);
        for (final image in oldImages) {
          expect(
            image.debugDisposed,
            isTrue,
            reason:
                'A late image must be disposed after its viewer/document leaves.',
          );
          expect(image.debugGetOpenHandleStackTraces(), isEmpty);
          expect(
            disposed.where((disposedImage) => identical(disposedImage, image)),
            hasLength(1),
          );
        }
        if (departure == _Departure.keyedReplacement ||
            departure == _Departure.sameStateReplacement) {
          expect(replacement.disposals, 0);
          replacement.page.renderReply.complete(newRaw);
          await decodeUntil(
            () =>
                created.any((image) => image.width == 41) &&
                newRaw.disposals >= 1,
          );
          final newImages = created
              .where((image) => image.width == 41)
              .toList();
          expect(
            newImages.any((image) => !image.debugDisposed),
            isTrue,
            reason: 'The current replacement image stays owned by its viewer.',
          );
          await tester.pumpWidget(const SizedBox.shrink());
          removed = true;
          expect(newImages.every((image) => image.debugDisposed), isTrue);
          expect(replacement.disposals, 1);
        }
        expect(oldRaw.copies.every((image) => image._disposals == 1), isTrue);
        expect(newRaw.copies.every((image) => image._disposals == 1), isTrue);
      } finally {
        try {
          if (!removed) await tester.pumpWidget(const SizedBox.shrink());
          if (!old.page.renderReply.isCompleted) {
            old.page.renderReply.complete(null);
          }
          if (!replacement.page.renderReply.isCompleted) {
            replacement.page.renderReply.complete(null);
          }
          await tester.pump(const Duration(seconds: 1));
          for (final image in created) {
            if (!image.debugDisposed) image.dispose();
          }
        } finally {
          ui.Image.onCreate = previousCreate;
          ui.Image.onDispose = previousDispose;
          PdfrxEntryFunctions.instance = previousEntry;
          Pdfrx.cacheDirectoryPath = previousCache;
          Pdfrx.loadAsset = previousLoadAsset;
        }
      }
    });
  }
}
