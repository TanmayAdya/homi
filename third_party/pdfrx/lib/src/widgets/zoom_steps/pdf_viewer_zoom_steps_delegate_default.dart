import '../pdf_viewer_layout_metrics.dart';
import 'pdf_viewer_zoom_steps_delegate.dart';

class PdfViewerZoomStepsDelegateProviderDefault extends PdfViewerZoomStepsDelegateProvider {
  const PdfViewerZoomStepsDelegateProviderDefault();

  @override
  PdfViewerZoomStepsDelegate create() => PdfViewerZoomStepsDelegateDefault();

  @override
  bool operator ==(Object other) => other is PdfViewerZoomStepsDelegateProviderDefault;

  @override
  int get hashCode => runtimeType.hashCode;
}

class PdfViewerZoomStepsDelegateDefault implements PdfViewerZoomStepsDelegate {
  @override
  void dispose() {}

  @override
  List<double> generateZoomStops(PdfViewerLayoutMetrics metrics) {
    final zoomStops = <double>[];

    final alternativeFitScale = metrics.alternativeFitScale;
    final coverScale = metrics.coverScale;
    final minScale = metrics.minScale;
    final maxScale = metrics.maxScale;

    double z;
    if (alternativeFitScale != null && !_areZoomsAlmostIdentical(alternativeFitScale, coverScale)) {
      if (alternativeFitScale < coverScale) {
        zoomStops.add(alternativeFitScale);
        z = coverScale;
      } else {
        zoomStops.add(coverScale);
        z = alternativeFitScale;
      }
    } else {
      z = coverScale;
    }

    if (z < 1 / 128) {
      zoomStops.add(1.0);
      return zoomStops;
    }

    while (z < metrics.maxScale) {
      zoomStops.add(z);
      z *= 2;
    }

    if (!_areZoomsAlmostIdentical(z, maxScale)) {
      zoomStops.add(maxScale);
    }

    z = zoomStops.first;

    while (z > minScale) {
      z /= 2;
      zoomStops.insert(0, z);
    }

    if (!_areZoomsAlmostIdentical(z, minScale)) {
      zoomStops.insert(0, minScale);
    }

    return zoomStops;
  }

  static bool _areZoomsAlmostIdentical(double z1, double z2) => (z1 - z2).abs() < 0.01;
}
