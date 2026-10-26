import '../domain/capture/staging_store.dart';
import '../domain/image/image_validator.dart';

class LocalEvidenceIndex {
  final Map<String, StagedImage> _byEvidenceId = {};

  StagedImage? operator [](String evidenceId) => _byEvidenceId[evidenceId];

  void put(String evidenceId, StagedImage image) =>
      _byEvidenceId[evidenceId] = image;

  StagedImage? remove(String evidenceId) => _byEvidenceId.remove(evidenceId);

  Iterable<String> get evidenceIds => List.unmodifiable(_byEvidenceId.keys);

  void clear() => _byEvidenceId.clear();

  Map<String, Object?> toLocalJson() => {
    for (final e in _byEvidenceId.entries)
      e.key: {
        'key': e.value.key.value,
        'format': e.value.format.name,
        'width': e.value.width,
        'height': e.value.height,
        'byteLength': e.value.byteLength,
        'capturedAt': e.value.capturedAt,
        'orientationNormalized': e.value.orientationNormalized,
      },
  };

  void restoreLocal(Map<String, Object?> value) {
    clear();
    for (final entry in value.entries) {
      final v = entry.value as Map;
      final width = v['width'] as int,
          height = v['height'] as int,
          count = v['byteLength'] as int;
      if (width <= 0 ||
          height <= 0 ||
          width > 8192 ||
          height > 8192 ||
          width * height > 16000000 ||
          count <= 0 ||
          count > 8 * 1024 * 1024) {
        throw const FormatException('Invalid staged image');
      }
      _byEvidenceId[entry.key] = StagedImage(
        key: StagingKey(v['key'] as String),
        format: SupportedImageFormat.values.byName(v['format'] as String),
        width: width,
        height: height,
        byteLength: count,
        capturedAt: v['capturedAt'] as String?,
        orientationNormalized: v['orientationNormalized'] == true,
      );
    }
  }
}

String localEvidenceVersion(StagingKey key) => 'local:${key.value}';
