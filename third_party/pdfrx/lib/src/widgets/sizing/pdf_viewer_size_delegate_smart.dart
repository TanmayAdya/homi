import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:pdfrx_engine/pdfrx_engine.dart';

import '../pdf_viewer.dart';
import '../pdf_viewer_layout_metrics.dart';
import '../pdf_viewer_params.dart';
import 'pdf_viewer_size_delegate.dart';

/// Creates adaptive page sizing configured by [PdfViewerParams]
class PdfViewerSizeDelegateProviderSmart extends PdfViewerSizeDelegateProvider {
  const PdfViewerSizeDelegateProviderSmart({
    double? minScale,
    double? maxScale,
    double? smartMaxScale,
    double? maxPagesVisible,
    double? onePassRenderingScaleThreshold,
  }) : maxScale = maxScale ?? 8.0,
       minScale = minScale ?? 0.1,
       smartMaxScale = smartMaxScale ?? 1.3,
       maxPagesVisible = maxPagesVisible ?? 3.0,
       onePassRenderingScaleThreshold = onePassRenderingScaleThreshold ?? 200 / 72;

  final double maxScale;

  final double minScale;

  final double maxPagesVisible;

  final double onePassRenderingScaleThreshold;

  final double smartMaxScale;

  @override
  PdfViewerSizeDelegate create() => PdfViewerSizeDelegateSmart(
    smartMaxScale: smartMaxScale,
    maxScale: maxScale,
    minScale: minScale,
    maxPagesVisible: maxPagesVisible,
    onePassRenderingScaleThreshold: onePassRenderingScaleThreshold,
  );

  @override
  bool operator ==(Object other) =>
      other is PdfViewerSizeDelegateProviderSmart &&
      other.smartMaxScale == smartMaxScale &&
      other.maxScale == maxScale &&
      other.minScale == minScale &&
      other.onePassRenderingScaleThreshold == onePassRenderingScaleThreshold &&
      other.maxPagesVisible == maxPagesVisible;

  @override
  int get hashCode => Object.hash(smartMaxScale, maxScale, minScale, onePassRenderingScaleThreshold, maxPagesVisible);
}

class PdfViewerSizeDelegateSmart implements PdfViewerSizeDelegate {
  PdfViewerSizeDelegateSmart({
    required double smartMaxScale,
    required double maxScale,
    required double minScale,
    required double maxPagesVisible,
    required this.onePassRenderingScaleThreshold,
  }) : _minScale = minScale,
       _maxScale = maxScale,
       _smartMaxScale = smartMaxScale,
       _maxPagesVisible = maxPagesVisible;

  final double _maxScale;
  final double _minScale;
  final double _maxPagesVisible;
  final double _smartMaxScale;

  PdfViewerController? _controller;

  @override
  final double onePassRenderingScaleThreshold;

  @override
  void init(PdfViewerController controller) {
    _controller = controller;
  }

  @override
  void dispose() {
    _controller = null;
  }

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

      if (pageNumber != null && pageNumber >= 1 && pageNumber <= layout.pageLayouts.length) {
        final rect = layout.pageLayouts[pageNumber - 1];
        final m2 = pageMargin * 2;
        alternativeFitScale = math.min(
          (viewSize.width) / (rect.width + bmh + m2),
          (viewSize.height) / (rect.height + bmv + m2),
        );
      }
    }

    final fitPageScale = alternativeFitScale ?? coverScale;

    final allowedMinScale = fitPageScale / _maxPagesVisible;

    final effectiveMinScale = math.max(_minScale, allowedMinScale);

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
    final controller = _controller;
    if (controller == null) return;


    final docWidth = state.layout?.documentSize.width ?? 1.0;
    final rawFitWidthScale = docWidth > 0 ? state.viewSize.width / docWidth : 1.0;

    final effectiveFitWidthScale = (rawFitWidthScale > _smartMaxScale) ? _smartMaxScale : rawFitWidthScale;

    var zoom = effectiveFitWidthScale;

    if (zoom < _minScale) {
      zoom = _minScale;
    }
    if (zoom > _maxScale) {
      zoom = _maxScale;
    }

    if (zoom < state.minScale) {
      zoom = state.minScale;
    }

    unawaited(controller.setZoom(Offset.zero, zoom, duration: Duration.zero));
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

    final zoomTo = currentZoom < newState.minScale || currentZoom == oldState.minScale
        ? newState.minScale
        : currentZoom;

    if (isLayoutChanged) {

      final oldLayout = oldState.layout;

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

    final oldLayout = oldState.layout;
    final newLayout = newState.layout;
    if (oldLayout == null || newLayout == null) return;

    final oldSize = oldState.viewSize;
    final newSize = newState.viewSize;

    final oldDocWidth = oldLayout.documentSize.width;
    final newDocWidth = newLayout.documentSize.width;

    final oldFitScale = oldSize.width / oldDocWidth;
    final newFitScale = newSize.width / newDocWidth;

    const epsilon = 0.01;

    final wasFittingExact = (currentZoom - oldFitScale).abs() < epsilon;

    final wasOverflowing = !wasFittingExact && currentZoom > oldFitScale;

    var targetZoom = currentZoom;

    if (wasOverflowing) {
      targetZoom = currentZoom;
    } else if (wasFittingExact) {
      targetZoom = newFitScale;

      if (newFitScale > oldFitScale) {
        if (targetZoom > _smartMaxScale) {
          targetZoom = _smartMaxScale;
          if (targetZoom < currentZoom) {
            targetZoom = currentZoom;
          }
        }
      }
    } else {
      targetZoom = currentZoom;

      if (targetZoom > newFitScale) {
        targetZoom = newFitScale;
      }
    }

    final minS = newState.minScale;
    if (targetZoom < minS) targetZoom = minS;


    final oldCenterInDoc = controller.value.calcPosition(oldSize);

    final newMatrix = controller.calcMatrixFor(oldCenterInDoc, zoom: targetZoom, viewSize: newSize);

    controller.stopInteractiveViewerAnimation();
    controller.value = newMatrix;
  }
}
