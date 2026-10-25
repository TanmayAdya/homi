import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:pdfrx_engine/pdfrx_engine.dart';
import 'package:vector_math/vector_math_64.dart' as vec;

import '../pdf_viewer.dart';
import '../pdf_viewer_layout_metrics.dart';
import '../pdf_viewer_params.dart';
import 'pdf_viewer_size_delegate.dart';
import 'pdf_viewer_size_delegate_smart.dart';

/// Keeps legacy page sizing; [PdfViewerSizeDelegateProviderSmart] provides adaptive sizing
class PdfViewerSizeDelegateProviderLegacy extends PdfViewerSizeDelegateProvider {
  const PdfViewerSizeDelegateProviderLegacy({
    double? maxScale,
    double? minScale,
    bool? useAlternativeFitScaleAsMinScale,
    double? onePassRenderingScaleThreshold,
    this.calculateInitialZoom,
  }) : maxScale = maxScale ?? 8.0,
       minScale = minScale ?? 0.1,
       useAlternativeFitScaleAsMinScale = useAlternativeFitScaleAsMinScale ?? true,
       onePassRenderingScaleThreshold = onePassRenderingScaleThreshold ?? 200 / 72;

  final double maxScale;

  final double minScale;

  final bool useAlternativeFitScaleAsMinScale;

  final double onePassRenderingScaleThreshold;

  final PdfViewerCalculateZoomFunction? calculateInitialZoom;

  @override
  PdfViewerSizeDelegate create() => PdfViewerSizeDelegateLegacy(
    maxScale: maxScale,
    minScale: minScale,
    useAlternativeFitScaleAsMinScale: useAlternativeFitScaleAsMinScale,
    onePassRenderingScaleThreshold: onePassRenderingScaleThreshold,
    calculateInitialZoom: calculateInitialZoom,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PdfViewerSizeDelegateProviderLegacy &&
          maxScale == other.maxScale &&
          minScale == other.minScale &&
          useAlternativeFitScaleAsMinScale == other.useAlternativeFitScaleAsMinScale &&
          onePassRenderingScaleThreshold == other.onePassRenderingScaleThreshold &&
          calculateInitialZoom == other.calculateInitialZoom;

  @override
  int get hashCode => Object.hash(
    maxScale,
    minScale,
    useAlternativeFitScaleAsMinScale,
    onePassRenderingScaleThreshold,
    calculateInitialZoom,
  );
}

class PdfViewerSizeDelegateLegacy implements PdfViewerSizeDelegate {
  PdfViewerSizeDelegateLegacy({
    required double maxScale,
    required double minScale,
    required bool useAlternativeFitScaleAsMinScale,
    required this.onePassRenderingScaleThreshold,
    required PdfViewerCalculateZoomFunction? calculateInitialZoom,
  }) : _minScale = minScale,
       _maxScale = maxScale,
       _useAlternativeFitScaleAsMinScale = useAlternativeFitScaleAsMinScale,
       _calculateInitialZoom = calculateInitialZoom;

  PdfViewerController? _controller;

  @override
  void init(PdfViewerController controller) {
    _controller = controller;
  }

  @override
  void dispose() {
    _controller = null;
  }

  final double _maxScale;
  final double _minScale;
  final bool _useAlternativeFitScaleAsMinScale;
  final PdfViewerCalculateZoomFunction? _calculateInitialZoom;

  @override
  final double onePassRenderingScaleThreshold;

  @override
  PdfViewerLayoutMetrics calculateMetrics({
    required Size viewSize,
    required PdfPageLayout? layout,
    required int? pageNumber,
    required double pageMargin,
    required EdgeInsets? boundaryMargin,
  }) {
    final bmh = boundaryMargin?.horizontal == double.infinity ? 0 : boundaryMargin?.horizontal ?? 0;
    final bmv = boundaryMargin?.vertical == double.infinity ? 0 : boundaryMargin?.vertical ?? 0;

    var coverScale = 1.0;
    double? alternativeFitScale;

    if (layout != null) {
      final s1 = viewSize.width / (layout.documentSize.width + bmh);
      final s2 = viewSize.height / (layout.documentSize.height + bmv);
      coverScale = math.max(s1, s2);
    }
    if (pageNumber != null && pageNumber >= 1 && pageNumber <= layout!.pageLayouts.length) {
      final rect = layout.pageLayouts[pageNumber - 1];
      final m2 = pageMargin * 2;
      alternativeFitScale = math.min(
        (viewSize.width) / (rect.width + bmh + m2),
        (viewSize.height) / (rect.height + bmv + m2),
      );
      if (alternativeFitScale <= 0) {
        alternativeFitScale = null;
      }
    } else {
      alternativeFitScale = null;
    }

    final effectiveMinScale = !_useAlternativeFitScaleAsMinScale
        ? _minScale
        : alternativeFitScale == null
        ? coverScale
        : math.min(coverScale, alternativeFitScale);

    return PdfViewerLayoutMetrics(
      minScale: effectiveMinScale,
      maxScale: _maxScale,
      coverScale: coverScale,
      alternativeFitScale: alternativeFitScale,
    );
  }

  @override
  void onLayoutInitialized({
    required PdfViewerLayoutSnapshot state,
    required int initialPageNumber,
    required double coverScale,
    required double? alternativeFitScale,
    required PdfPageLayout layout,
    required PdfDocument document,
  }) {
    double? zoom;

    final calculateInitialZoom = _calculateInitialZoom;
    if (calculateInitialZoom != null) {
      zoom = calculateInitialZoom(document, _controller!, alternativeFitScale ?? coverScale, coverScale);
    }

    zoom ??= coverScale;

    unawaited(_controller!.setZoom(Offset.zero, zoom, duration: Duration.zero));
  }

  @override
  void onLayoutUpdate({
    required PdfViewerLayoutSnapshot oldState,
    required PdfViewerLayoutSnapshot newState,
    required double currentZoom,
    required Rect oldVisibleRect,
    required int? anchorPageNumber,
    required bool isLayoutChanged,
    required bool isViewSizeChanged,
  }) {
    final controller = _controller;
    if (controller == null) return;

    final oldLayout = oldState.layout;

    final zoomTo = currentZoom < newState.minScale || currentZoom == oldState.minScale
        ? newState.minScale
        : currentZoom;
    if (isLayoutChanged) {

      if (oldLayout != null && anchorPageNumber != null) {
        final hit = controller.getClosestPageHit(anchorPageNumber, oldLayout, oldVisibleRect);
        final pageNumber = hit?.page.pageNumber ?? anchorPageNumber;

        final oldPageRect = oldLayout.pageLayouts[pageNumber - 1];
        final newPageRect = newState.layout!.pageLayouts[pageNumber - 1];
        final oldOffset = oldVisibleRect.topLeft - oldPageRect.topLeft;
        final fracX = oldOffset.dx / oldPageRect.width;
        final fracY = oldOffset.dy / oldPageRect.height;

        final newOffset = Offset(
          newPageRect.left + fracX * newPageRect.width,
          newPageRect.top + fracY * newPageRect.height,
        );

        unawaited(controller.goToPosition(documentOffset: newOffset, zoom: zoomTo));
      }
      return;
    }

    assert(isViewSizeChanged);

    if (zoomTo != currentZoom) {
      final zoomChange = zoomTo / currentZoom;

      final pivot = vec.Vector3(controller.value.x, controller.value.y, 0);

      final pivotScale = Matrix4.identity()
        ..translateByVector3(pivot)
        ..scaleByDouble(zoomChange, zoomChange, zoomChange, 1)
        ..translateByVector3(-pivot / zoomChange);

      final Matrix4 zoomPivoted = pivotScale * controller.value;

      final clamped = controller.calcMatrixForClampedToNearestBoundary(zoomPivoted, viewSize: newState.viewSize);

      controller.stopInteractiveViewerAnimation();
      controller.value = clamped;
    } else {
      final clamped = controller.calcMatrixForClampedToNearestBoundary(controller.value, viewSize: newState.viewSize);
      controller.stopInteractiveViewerAnimation();
      controller.value = clamped;
    }
  }
}
