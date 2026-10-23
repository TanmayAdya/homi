import 'dart:math' as math;

const String annotationCoordinateConvention = 'image-px-top-left-v1';

final class AnnotatedImage {
  const AnnotatedImage({
    required this.evidenceId,
    required this.version,
    required this.width,
    required this.height,
    this.sha256,
  }) : assert(width > 0 && height > 0);

  final String evidenceId;

  final String version;

  final int width;
  final int height;

  final String? sha256;

  bool sameContentAs(AnnotatedImage other) =>
      other.evidenceId == evidenceId &&
      other.version == version &&
      other.width == width &&
      other.height == height &&
      other.sha256 == sha256;
}

final class ImageRect {
  const ImageRect(this.left, this.top, this.width, this.height);

  final double left;
  final double top;
  final double width;
  final double height;

  double get right => left + width;
  double get bottom => top + height;

  ImageRect clampTo(int imageWidth, int imageHeight, {double minSize = 1}) {
    final double w = width.clamp(
      math.min(minSize, imageWidth.toDouble()),
      imageWidth.toDouble(),
    );
    final double h = height.clamp(
      math.min(minSize, imageHeight.toDouble()),
      imageHeight.toDouble(),
    );
    final double l = left.clamp(0, imageWidth - w);
    final double t = top.clamp(0, imageHeight - h);
    return ImageRect(l, t, w, h);
  }

  @override
  bool operator ==(Object other) =>
      other is ImageRect &&
      other.left == left &&
      other.top == top &&
      other.width == width &&
      other.height == height;

  @override
  int get hashCode => Object.hash(left, top, width, height);

  @override
  String toString() => 'ImageRect($left, $top, $width x $height)';
}

final class BoxAnnotation {
  const BoxAnnotation({
    required this.id,
    required this.findingId,
    required this.image,
    required this.rect,
    required this.label,
    required this.revision,
    required this.stale,
    required this.hidden,
  });

  final String id;
  final String findingId;
  final AnnotatedImage image;
  final ImageRect rect;

  final String label;

  final int revision;

  final bool stale;

  final bool hidden;

  BoxAnnotation _copyWith({
    ImageRect? rect,
    String? label,
    bool? stale,
    bool? hidden,
  }) => BoxAnnotation(
    id: id,
    findingId: findingId,
    image: image,
    rect: rect ?? this.rect,
    label: label ?? this.label,
    revision: revision + 1,
    stale: stale ?? this.stale,
    hidden: hidden ?? this.hidden,
  );

  Map<String, Object?> toLocalJson() => {
    'id': id,
    'findingId': findingId,
    'evidenceId': image.evidenceId,
    'evidenceVersion': image.version,
    'imageSha256': image.sha256,
    'imageWidth': image.width,
    'imageHeight': image.height,
    'coordinates': annotationCoordinateConvention,
    'rect': [rect.left, rect.top, rect.width, rect.height],
    'label': label,
    'revision': revision,
    'stale': stale,
    'hidden': hidden,
  };
}

class AnnotationStore {
  AnnotationStore({required String Function() newId}) : _newId = newId;

  final String Function() _newId;
  final Map<String, BoxAnnotation> _boxes = {};

  static const double minSizeFraction = 0.02;

  BoxAnnotation? operator [](String id) => _boxes[id];

  List<BoxAnnotation> get all => List.unmodifiable(_boxes.values);

  List<BoxAnnotation> on(AnnotatedImage image) => List.unmodifiable(
    _boxes.values.where((b) => !b.stale && b.image.sameContentAs(image)),
  );

  List<BoxAnnotation> staleFor(String evidenceId) => List.unmodifiable(
    _boxes.values.where((b) => b.stale && b.image.evidenceId == evidenceId),
  );

  BoxAnnotation add({
    required String findingId,
    required AnnotatedImage image,
    ImageRect? rect,
    String label = '',
  }) {
    final ImageRect start =
        rect ??
        ImageRect(
          image.width / 3,
          image.height / 3,
          image.width / 3,
          image.height / 3,
        );
    final box = BoxAnnotation(
      id: _newId(),
      findingId: findingId,
      image: image,
      rect: _clamp(start, image),
      label: label.trim(),
      revision: 1,
      stale: false,
      hidden: false,
    );
    if (_boxes.containsKey(box.id)) {
      throw StateError('Annotation ID generator repeated an ID.');
    }
    _boxes[box.id] = box;
    return box;
  }

  BoxAnnotation? move(String id, double dx, double dy) => _edit(
    id,
    (b) => b._copyWith(
      rect: _clamp(
        ImageRect(
          b.rect.left + dx,
          b.rect.top + dy,
          b.rect.width,
          b.rect.height,
        ),
        b.image,
        keepSize: true,
      ),
    ),
  );

  BoxAnnotation? resize(String id, double dw, double dh) => _edit(id, (b) {
    final ImageRect r = b.rect;
    return b._copyWith(
      rect: _clamp(
        ImageRect(r.left - dw / 2, r.top - dh / 2, r.width + dw, r.height + dh),
        b.image,
      ),
    );
  });

  BoxAnnotation? setRect(String id, ImageRect rect) =>
      _edit(id, (b) => b._copyWith(rect: _clamp(rect, b.image)));

  BoxAnnotation? setLabel(String id, String label) =>
      _edit(id, (b) => b._copyWith(label: label.trim()));

  BoxAnnotation? setHidden(String id, bool hidden) {
    final BoxAnnotation? box = _boxes[id];
    if (box == null || box.hidden == hidden) return box;
    return _boxes[id] = box._copyWith(hidden: hidden);
  }

  bool remove(String id) => _boxes.remove(id) != null;

  int imageChanged(String evidenceId, AnnotatedImage? current) {
    var count = 0;
    for (final BoxAnnotation box in List.of(_boxes.values)) {
      if (box.stale || box.image.evidenceId != evidenceId) continue;
      if (current != null && box.image.sameContentAs(current)) continue;
      _boxes[box.id] = box._copyWith(stale: true);
      count++;
    }
    return count;
  }

  int removeForEvidence(String evidenceId) =>
      _removeWhere((b) => b.image.evidenceId == evidenceId);

  int removeForFinding(String findingId) =>
      _removeWhere((b) => b.findingId == findingId);

  void clear() => _boxes.clear();

  BoxAnnotation? _edit(String id, BoxAnnotation Function(BoxAnnotation) f) {
    final BoxAnnotation? box = _boxes[id];
    if (box == null || box.stale) return null;
    final BoxAnnotation next = f(box);
    if (next.rect == box.rect &&
        next.label == box.label &&
        next.hidden == box.hidden) {
      return box;
    }
    return _boxes[id] = next;
  }

  int _removeWhere(bool Function(BoxAnnotation) test) {
    final int before = _boxes.length;
    _boxes.removeWhere((_, b) => test(b));
    return before - _boxes.length;
  }

  static ImageRect _clamp(
    ImageRect rect,
    AnnotatedImage image, {
    bool keepSize = false,
  }) {
    final double minSize =
        math.min(image.width, image.height) * minSizeFraction;
    if (keepSize) {
      return ImageRect(
        rect.left.clamp(0, image.width - rect.width),
        rect.top.clamp(0, image.height - rect.height),
        rect.width,
        rect.height,
      );
    }
    return rect.clampTo(
      image.width,
      image.height,
      minSize: math.max(1, minSize),
    );
  }
}

final class ImageViewport {
  factory ImageViewport({
    required int imageWidth,
    required int imageHeight,
    required double viewWidth,
    required double viewHeight,
  }) {
    final double scale = math.min(
      viewWidth / imageWidth,
      viewHeight / imageHeight,
    );
    return ImageViewport._(
      scale,
      (viewWidth - imageWidth * scale) / 2,
      (viewHeight - imageHeight * scale) / 2,
    );
  }

  const ImageViewport._(this.scale, this.offsetX, this.offsetY);

  final double scale;

  final double offsetX;
  final double offsetY;

  (double, double) toView(double x, double y) =>
      (offsetX + x * scale, offsetY + y * scale);

  (double, double) toImage(double x, double y) =>
      ((x - offsetX) / scale, (y - offsetY) / scale);

  double toImageDistance(double viewDistance) => viewDistance / scale;

  ImageRect rectToView(ImageRect r) {
    final (double l, double t) = toView(r.left, r.top);
    return ImageRect(l, t, r.width * scale, r.height * scale);
  }
}
