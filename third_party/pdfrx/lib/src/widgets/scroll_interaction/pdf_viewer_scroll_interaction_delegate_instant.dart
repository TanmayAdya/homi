import 'package:flutter/widgets.dart';

import '../pdf_viewer.dart';
import '../pdf_viewer_layout_metrics.dart';
import 'pdf_viewer_scroll_interaction_delegate.dart';

class PdfViewerScrollInteractionDelegateProviderInstant extends PdfViewerScrollInteractionDelegateProvider {
  const PdfViewerScrollInteractionDelegateProviderInstant();

  @override
  PdfViewerScrollInteractionDelegate create() => _PdfViewerScrollInteractionDelegateInstant();

  @override
  bool operator ==(Object other) => other is PdfViewerScrollInteractionDelegateProviderInstant;

  @override
  int get hashCode => runtimeType.hashCode;
}

class _PdfViewerScrollInteractionDelegateInstant implements PdfViewerScrollInteractionDelegate {
  PdfViewerController? _controller;

  @override
  void init(PdfViewerController controller, TickerProvider vsync) {
    _controller = controller;
  }

  @override
  void dispose() {
    _controller = null;
  }

  @override
  void stop() {
  }

  @override
  void pan(Offset delta, PdfViewerLayoutMetrics layoutMetrics) {
    final controller = _controller;
    if (controller == null || !controller.isReady) {
      return;
    }

    final m = controller.value.clone();

    m.translateByDouble(delta.dx, delta.dy, 0, 1);

    controller.value = controller.makeMatrixInSafeRange(m, forceClamp: true);
  }

  @override
  void zoom(double scale, Offset focalPoint, PdfViewerLayoutMetrics layoutMetrics) {
    final controller = _controller;
    if (controller == null || !controller.isReady) {
      return;
    }

    final currentZoom = controller.currentZoom;

    final newZoom = (currentZoom * scale).clamp(layoutMetrics.minScale, layoutMetrics.maxScale);

    if ((newZoom - currentZoom).abs() < 0.0001) {
      return;
    }

    controller.zoomOnLocalPosition(localPosition: focalPoint, newZoom: newZoom, duration: Duration.zero);
  }
}
