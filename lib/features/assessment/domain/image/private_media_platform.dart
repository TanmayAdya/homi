import 'package:flutter/services.dart';

class PrivateMediaPlatform {
  const PrivateMediaPlatform();
  static const channel = MethodChannel('safe_at_home/private_media');

  Future<void> prepareCaptureStorage() async {
    await channel.invokeMethod<void>('prepareCaptureStorage');
  }

  Future<String?> pickPhoto() => channel.invokeMethod<String>('pickPhoto');

  Future<Uint8List> normalizePath(String path) async {
    final result = await channel.invokeMapMethod<String, Object?>(
      'normalizeImage',
      {'path': path, 'maxEdge': 2048, 'quality': 85},
    );
    final bytes = result?['bytes'];
    if (bytes is! Uint8List ||
        bytes.isEmpty ||
        bytes.length > 8 * 1024 * 1024) {
      throw const FormatException('Image normalization failed');
    }
    return bytes;
  }

  Future<Uint8List> edit(
    Uint8List bytes, {
    List<double>? crop,
    List<List<double>> redactions = const [],
  }) async {
    final result = await channel.invokeMapMethod<String, Object?>('editImage', {
      'bytes': bytes,
      'crop': crop,
      'redactions': redactions,
      'maxEdge': 2048,
      'quality': 85,
    });
    final output = result?['bytes'];
    if (output is! Uint8List ||
        output.isEmpty ||
        output.length > 8 * 1024 * 1024) {
      throw const FormatException('Image editing failed');
    }
    return output;
  }
}
