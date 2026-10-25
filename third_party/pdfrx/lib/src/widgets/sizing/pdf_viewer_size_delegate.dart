import 'package:flutter/rendering.dart';
import 'package:pdfrx_engine/pdfrx_engine.dart';

import '../interactive_viewer.dart';
import '../pdf_viewer.dart';
import '../pdf_viewer_layout_metrics.dart';
import '../pdf_viewer_params.dart';

/// Creates [InteractiveViewer] sizing handlers configured by [PdfViewerParams]
abstract class PdfViewerSizeDelegateProvider {
  const PdfViewerSizeDelegateProvider();

  PdfViewerSizeDelegate create();

  @override
  bool operator ==(Object other);

  @override
  int get hashCode;
}

abstract class PdfViewerSizeDelegate {
  void init(PdfViewerController controller);

  void dispose();

  PdfViewerLayoutMetrics calculateMetrics({
    required Size viewSize,
    required PdfPageLayout? layout,
    required int? pageNumber,
    required double pageMargin,
    required EdgeInsets? boundaryMargin,
  });

  double get onePassRenderingScaleThreshold;

  void onLayoutInitialized({
    required PdfViewerLayoutSnapshot state,
    required int initialPageNumber,
    required double coverScale,
    required double? alternativeFitScale,
    required PdfPageLayout layout,
    required PdfDocument document,
  });

  void onLayoutUpdate({
    required PdfViewerLayoutSnapshot oldState,
    required PdfViewerLayoutSnapshot newState,
    required double currentZoom,
    required Rect oldVisibleRect,
    required int? anchorPageNumber,
    required bool isLayoutChanged,
    required bool isViewSizeChanged,
  });
}

class PdfViewerLayoutSnapshot {
  const PdfViewerLayoutSnapshot({
    required this.viewSize,
    required this.layout,
    required this.minScale,
    required this.coverScale,
    required this.alternativeFitScale,
  });

  final Size viewSize;

  final PdfPageLayout? layout;

  final double minScale;

  final double coverScale;

  final double? alternativeFitScale;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PdfViewerLayoutSnapshot &&
          viewSize == other.viewSize &&
          layout == other.layout &&
          minScale == other.minScale &&
          coverScale == other.coverScale &&
          alternativeFitScale == other.alternativeFitScale;

  @override
  int get hashCode => Object.hash(viewSize, layout, minScale, coverScale, alternativeFitScale);
}
