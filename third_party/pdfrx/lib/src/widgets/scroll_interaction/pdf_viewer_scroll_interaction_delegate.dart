import 'package:flutter/gestures.dart' show PointerScrollEvent;
import 'package:flutter/scheduler.dart' show Ticker;
import 'package:flutter/widgets.dart';

import '../pdf_viewer.dart';
import '../pdf_viewer_layout_metrics.dart';
import '../pdf_viewer_params.dart';

/// Creates [PdfViewerParams] scrolling handlers for [PointerScrollEvent] and [Ticker] updates
abstract class PdfViewerScrollInteractionDelegateProvider {
  const PdfViewerScrollInteractionDelegateProvider();

  PdfViewerScrollInteractionDelegate create();

  @override
  bool operator ==(Object other);

  @override
  int get hashCode;
}

abstract class PdfViewerScrollInteractionDelegate {
  void init(PdfViewerController controller, TickerProvider vsync);

  void dispose();

  void stop();

  void pan(Offset delta, PdfViewerLayoutMetrics layoutMetrics);

  void zoom(double scale, Offset focalPoint, PdfViewerLayoutMetrics layoutMetrics);
}
