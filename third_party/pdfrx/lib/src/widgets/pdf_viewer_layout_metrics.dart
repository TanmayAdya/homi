import 'sizing/pdf_viewer_size_delegate.dart';

/// Stores page layout values from [PdfViewerSizeDelegate]
class PdfViewerLayoutMetrics {
  const PdfViewerLayoutMetrics({
    required this.minScale,
    required this.maxScale,
    required this.coverScale,
    this.alternativeFitScale,
  });

  final double minScale;

  final double maxScale;

  final double coverScale;

  final double? alternativeFitScale;
}
