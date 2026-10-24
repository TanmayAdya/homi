import 'dart:async';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show WidgetsFlutterBinding;
import 'package:flutter/services.dart';
import 'package:pdfrx_engine/pdfrx_engine.dart';

import 'utils/platform.dart';

bool _isInitialized = false;

Future<void> pdfrxFlutterInitialize({
  @Deprecated('WASM modules are now only included in web builds. This flag now does nothing.')
  bool dismissPdfiumWasmWarnings = false,
}) async {
  if (_isInitialized) return;

  WidgetsFlutterBinding.ensureInitialized();

  if (pdfrxEntryFunctionsOverride != null) {
    PdfrxEntryFunctions.instance = pdfrxEntryFunctionsOverride!;
  }

  Pdfrx.loadAsset ??= (name) async {
    final asset = await rootBundle.load(name);
    return asset.buffer.asUint8List();
  };

  if (!kIsWeb) {
    Pdfrx.cacheDirectoryPath ??= await getCacheDirectory();
  }

  await platformInitialize();

  _isInitialized = true;
}

extension PdfPageExt on PdfPage {
  Size get size => Size(width, height);
}

extension PdfImageExt on PdfImage {
  Future<Image> createImage({int? pixelSizeThreshold}) {
    int? targetWidth;
    int? targetHeight;
    if (pixelSizeThreshold != null && (width > pixelSizeThreshold || height > pixelSizeThreshold)) {
      final aspectRatio = width / height;
      if (width >= height) {
        targetWidth = pixelSizeThreshold;
        targetHeight = (pixelSizeThreshold / aspectRatio).round();
      } else {
        targetHeight = pixelSizeThreshold;
        targetWidth = (pixelSizeThreshold * aspectRatio).round();
      }
    }

    final comp = Completer<Image>();
    decodeImageFromPixels(
      pixels,
      width,
      height,
      PixelFormat.bgra8888,
      (image) => comp.complete(image),
      targetWidth: targetWidth,
      targetHeight: targetHeight,
    );
    return comp.future;
  }
}

extension ImageExt on Image {
  Future<PdfImage> toPdfImage() async {
    final rgba = (await toByteData(format: ImageByteFormat.rawRgba))!.buffer.asUint8List();
    for (var i = 0; i < rgba.length; i += 4) {
      final r = rgba[i];
      rgba[i] = rgba[i + 2];
      rgba[i + 2] = r;
    }
    return PdfImage.createFromBgraData(rgba, width: width, height: height);
  }
}

extension PdfRectExt on PdfRect {
  Rect toRect({required PdfPage page, Size? scaledPageSize, int? rotation}) {
    final rotated = rotate(rotation ?? page.rotation.index, page);
    final scale = scaledPageSize == null ? 1.0 : scaledPageSize.height / page.height;
    return Rect.fromLTRB(
      rotated.left * scale,
      (page.height - rotated.top) * scale,
      rotated.right * scale,
      (page.height - rotated.bottom) * scale,
    );
  }

  Rect toRectInDocument({required PdfPage page, required Rect pageRect}) =>
      toRect(page: page, scaledPageSize: pageRect.size).translate(pageRect.left, pageRect.top);
}

extension RectPdfRectExt on Rect {
  PdfRect toPdfRect({required PdfPage page, Size? scaledPageSize, int? rotation}) {
    final scale = scaledPageSize == null ? 1.0 : scaledPageSize.height / page.height;
    return PdfRect(
      left / scale,
      page.height - top / scale,
      right / scale,
      page.height - bottom / scale,
    ).rotateReverse(rotation ?? page.rotation.index, page);
  }
}

extension PdfPointExt on PdfPoint {
  Offset toOffset({required PdfPage page, Size? scaledPageSize, int? rotation}) {
    final rotated = rotate(rotation ?? page.rotation.index, page);
    final scale = scaledPageSize == null ? 1.0 : scaledPageSize.height / page.height;
    return Offset(rotated.x * scale, (page.height - rotated.y) * scale);
  }

  Offset toOffsetInDocument({required PdfPage page, required Rect pageRect}) {
    final rotated = rotate(page.rotation.index, page);
    final scale = pageRect.height / page.height;
    return Offset(rotated.x * scale, (page.height - rotated.y) * scale).translate(pageRect.left, pageRect.top);
  }
}

extension OffsetPdfPointExt on Offset {
  PdfPoint toPdfPoint({required PdfPage page, Size? scaledPageSize, int? rotation}) {
    final scale = scaledPageSize == null ? 1.0 : page.height / scaledPageSize.height;
    return PdfPoint(dx * scale, page.height - dy * scale).rotateReverse(rotation ?? page.rotation.index, page);
  }
}
