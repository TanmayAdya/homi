import 'dart:typed_data';

import '../image/image_validator.dart';

final class StagingKey {
  const StagingKey(this.value);
  final String value;

  @override
  bool operator ==(Object other) => other is StagingKey && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => 'StagingKey($value)';
}

final class StagedImage {
  const StagedImage({
    required this.key,
    required this.format,
    required this.width,
    required this.height,
    required this.byteLength,
    this.capturedAt,
    this.orientationNormalized = false,
  });

  final StagingKey key;
  final SupportedImageFormat format;
  final int width;
  final int height;
  final int byteLength;
  final String? capturedAt;
  final bool orientationNormalized;
}

abstract interface class StagingStore {
  Future<StagedImage> put(
    Uint8List bytes,
    ImageAccepted info, {
    String? capturedAt,
    bool orientationNormalized = false,
  });

  Future<Uint8List?> read(StagingKey key);

  Future<bool> discard(StagingKey key);

  Future<int> discardAll();

  Future<List<StagingKey>> keys();
}

class InMemoryStagingStore implements StagingStore {
  final Map<StagingKey, Uint8List> _bytes = {};
  int _counter = 0;

  @override
  Future<StagedImage> put(
    Uint8List bytes,
    ImageAccepted info, {
    String? capturedAt,
    bool orientationNormalized = false,
  }) async {
    _counter++;
    final key = StagingKey('staged-$_counter');
    _bytes[key] = Uint8List.fromList(bytes);
    return StagedImage(
      key: key,
      format: info.format,
      width: info.width,
      height: info.height,
      byteLength: bytes.length,
      capturedAt: capturedAt,
      orientationNormalized: orientationNormalized,
    );
  }

  @override
  Future<Uint8List?> read(StagingKey key) async {
    final Uint8List? stored = _bytes[key];
    return stored == null ? null : Uint8List.fromList(stored);
  }

  @override
  Future<bool> discard(StagingKey key) async => _bytes.remove(key) != null;

  @override
  Future<int> discardAll() async {
    final int count = _bytes.length;
    _bytes.clear();
    return count;
  }

  @override
  Future<List<StagingKey>> keys() async => List.unmodifiable(_bytes.keys);
}
