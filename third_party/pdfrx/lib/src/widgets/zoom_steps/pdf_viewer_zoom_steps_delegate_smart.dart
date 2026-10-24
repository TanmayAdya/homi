import 'dart:math' as math;

import '../pdf_viewer_layout_metrics.dart';
import 'pdf_viewer_zoom_steps_delegate.dart';

class PdfViewerZoomStepsDelegateProviderSmart extends PdfViewerZoomStepsDelegateProvider {
  const PdfViewerZoomStepsDelegateProviderSmart({double? zoomStep, double? minZoomStep})
    : assert(zoomStep == null || zoomStep > 1.01, 'zoomStep must be greater than 1.01'),
      assert(minZoomStep == null || minZoomStep > 1.01, 'minZoomStep must be greater than 1.01'),
      zoomStep = zoomStep ?? 1.5,
      minZoomStep = minZoomStep ?? 1.2;

  final double zoomStep;

  final double minZoomStep;

  @override
  PdfViewerZoomStepsDelegate create() => PdfViewerZoomStepsDelegateSmart(zoomStep: zoomStep, minZoomStep: minZoomStep);

  @override
  bool operator ==(Object other) => other is PdfViewerZoomStepsDelegateProviderSmart;

  @override
  int get hashCode => runtimeType.hashCode;
}

class PdfViewerZoomStepsDelegateSmart implements PdfViewerZoomStepsDelegate {
  PdfViewerZoomStepsDelegateSmart({required double zoomStep, required double minZoomStep})
    : _zoomStep = zoomStep,
      _minZoomStep = minZoomStep;

  final double _zoomStep;
  final double _minZoomStep;
  @override
  void dispose() {}

  @override
  List<double> generateZoomStops(PdfViewerLayoutMetrics metrics) {
    const reasonableMin = 0.125;
    const reasonableMax = 8.0;

    final effectiveMin = math.max(metrics.minScale, reasonableMin);
    final effectiveMax = math.min(metrics.maxScale, reasonableMax);

    if (effectiveMin > effectiveMax) {
      return [metrics.minScale, metrics.maxScale];
    }

    final anchors = <double>{
      effectiveMin,
      effectiveMax,
      if (metrics.alternativeFitScale != null) metrics.alternativeFitScale!,
      metrics.coverScale,
      1.0,
    };

    final sortedAnchors = anchors.where((s) => s >= effectiveMin && s <= effectiveMax).toList()..sort();

    final safeZoomStep = _zoomStep <= 1.01 ? 1.5 : _zoomStep;
    final safeMinZoomStep = _minZoomStep <= 1.01 ? 1.1 : _minZoomStep;

    final result = <double>[sortedAnchors.first];

    for (var i = 0; i < sortedAnchors.length - 1; i++) {
      final start = sortedAnchors[i];
      final end = sortedAnchors[i + 1];

      if (start <= 0 || end <= 0) continue;

      final gap = end / start;

      if (gap < safeMinZoomStep) {
        result.add(end);
        continue;
      }

      final intervals = (math.log(gap) / math.log(safeZoomStep)).round();

      if (intervals <= 1) {
        result.add(end);
      } else {
        final specificRatio = math.pow(gap, 1 / intervals);

        var current = start;
        for (var k = 0; k < intervals - 1; k++) {
          current *= specificRatio;
          result.add(current);
        }
        result.add(end);
      }
    }

    final deduped = <double>[result.first];
    for (var i = 1; i < result.length; i++) {
      if ((result[i] - deduped.last).abs() > 0.001) {
        deduped.add(result[i]);
      }
    }

    return deduped;
  }
}
