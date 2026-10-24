import '../pdf_viewer_layout_metrics.dart';
import '../pdf_viewer_params.dart';
import '../scroll_interaction/pdf_viewer_scroll_interaction_delegate.dart';
import '../sizing/pdf_viewer_size_delegate.dart';

/// Creates zoom steps for [PdfViewerParams], [PdfViewerSizeDelegate] and [PdfViewerScrollInteractionDelegate]
abstract class PdfViewerZoomStepsDelegateProvider {
  const PdfViewerZoomStepsDelegateProvider();

  PdfViewerZoomStepsDelegate create();

  @override
  bool operator ==(Object other);

  @override
  int get hashCode;
}

abstract class PdfViewerZoomStepsDelegate {
  void dispose();

  List<double> generateZoomStops(PdfViewerLayoutMetrics metrics);
}
