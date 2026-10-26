final class ImageLimits {
  const ImageLimits({
    required this.maxBytes,
    required this.maxPixels,
    required this.maxEdge,
  });

  static const ImageLimits server = ImageLimits(
    maxBytes: 8 * 1024 * 1024,
    maxPixels: 16000000,
    maxEdge: 8192,
  );

  final int maxBytes;

  final int maxPixels;

  final int maxEdge;
}
