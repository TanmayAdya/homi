import 'dart:typed_data';

import 'image_limits.dart';

enum SupportedImageFormat {
  jpeg('image/jpeg'),
  png('image/png');

  const SupportedImageFormat(this.mediaType);
  final String mediaType;
}

enum ImageRejection {
  empty,

  tooManyBytes,

  heif,

  unsupportedFormat,

  unreadableDimensions,

  zeroDimension,

  edgeTooLong,

  tooManyPixels,
}

sealed class ImageCheck {
  const ImageCheck();
}

final class ImageAccepted extends ImageCheck {
  const ImageAccepted({
    required this.format,
    required this.width,
    required this.height,
    required this.byteLength,
  });

  final SupportedImageFormat format;

  final int width;
  final int height;
  final int byteLength;
}

final class ImageRejected extends ImageCheck {
  const ImageRejected(this.reason, {this.width, this.height});

  final ImageRejection reason;

  final int? width;
  final int? height;
}

class ImageValidator {
  const ImageValidator({this.limits = ImageLimits.server});

  final ImageLimits limits;

  ImageCheck check(Uint8List bytes) {
    if (bytes.isEmpty) return const ImageRejected(ImageRejection.empty);
    if (bytes.length > limits.maxBytes) {
      return const ImageRejected(ImageRejection.tooManyBytes);
    }

    final _Dimensions? dims;
    final SupportedImageFormat format;
    if (_isHeif(bytes)) {
      return const ImageRejected(ImageRejection.heif);
    } else if (_hasPrefix(bytes, _pngSignature)) {
      format = SupportedImageFormat.png;
      dims = _pngDimensions(bytes);
    } else if (_hasPrefix(bytes, _jpegSignature)) {
      format = SupportedImageFormat.jpeg;
      dims = _jpegDimensions(bytes);
    } else {
      return const ImageRejected(ImageRejection.unsupportedFormat);
    }

    if (dims == null) {
      return const ImageRejected(ImageRejection.unreadableDimensions);
    }
    final (:int width, :int height) = dims;
    if (width == 0 || height == 0) {
      return ImageRejected(
        ImageRejection.zeroDimension,
        width: width,
        height: height,
      );
    }
    if (width > limits.maxEdge || height > limits.maxEdge) {
      return ImageRejected(
        ImageRejection.edgeTooLong,
        width: width,
        height: height,
      );
    }
    if (width * height > limits.maxPixels) {
      return ImageRejected(
        ImageRejection.tooManyPixels,
        width: width,
        height: height,
      );
    }
    return ImageAccepted(
      format: format,
      width: width,
      height: height,
      byteLength: bytes.length,
    );
  }
}

typedef _Dimensions = ({int width, int height});

const List<int> _pngSignature = [
  0x89,
  0x50,
  0x4E,
  0x47,
  0x0D,
  0x0A,
  0x1A,
  0x0A,
];
const List<int> _jpegSignature = [0xFF, 0xD8, 0xFF];
const List<int> _ihdr = [0x49, 0x48, 0x44, 0x52];
const List<int> _ftyp = [0x66, 0x74, 0x79, 0x70];

const Set<String> _heifBrands = {
  'heic',
  'heix',
  'heim',
  'heis',
  'hevc',
  'hevx',
  'hevm',
  'hevs',
  'mif1',
  'msf1',
  'avif',
  'avis',
};

bool _hasPrefix(Uint8List bytes, List<int> prefix) {
  if (bytes.length < prefix.length) return false;
  for (var i = 0; i < prefix.length; i++) {
    if (bytes[i] != prefix[i]) return false;
  }
  return true;
}

bool _matchesAt(Uint8List bytes, int offset, List<int> expected) {
  if (offset < 0 || offset + expected.length > bytes.length) return false;
  for (var i = 0; i < expected.length; i++) {
    if (bytes[offset + i] != expected[i]) return false;
  }
  return true;
}

int _u16(Uint8List b, int i) => b[i] * 0x100 + b[i + 1];
int _u32(Uint8List b, int i) =>
    b[i] * 0x1000000 + b[i + 1] * 0x10000 + b[i + 2] * 0x100 + b[i + 3];

String _ascii4(Uint8List b, int i) => String.fromCharCodes(b.sublist(i, i + 4));

bool _isHeif(Uint8List bytes) {
  if (bytes.length < 12 || !_matchesAt(bytes, 4, _ftyp)) return false;
  if (_heifBrands.contains(_ascii4(bytes, 8))) return true;
  final int boxSize = _u32(bytes, 0);
  final int end = boxSize < bytes.length ? boxSize : bytes.length;
  for (var i = 16; i + 4 <= end; i += 4) {
    if (_heifBrands.contains(_ascii4(bytes, i))) return true;
  }
  return false;
}

_Dimensions? _pngDimensions(Uint8List bytes) {
  if (bytes.length < 24) return null;
  if (_u32(bytes, 8) != 13 || !_matchesAt(bytes, 12, _ihdr)) return null;
  return (width: _u32(bytes, 16), height: _u32(bytes, 20));
}

_Dimensions? _jpegDimensions(Uint8List bytes) {
  final int len = bytes.length;
  var i = 2;
  while (i < len) {
    if (bytes[i] != 0xFF) return null;
    while (i < len && bytes[i] == 0xFF) {
      i++;
    }
    if (i >= len) return null;
    final int marker = bytes[i];
    i++;

    if (marker == 0xD8 ||
        marker == 0x01 ||
        (marker >= 0xD0 && marker <= 0xD7)) {
      continue;
    }
    if (marker == 0xD9 || marker == 0xDA) return null;

    if (i + 2 > len) return null;
    final int segmentLength = _u16(bytes, i);
    if (segmentLength < 2 || i + segmentLength > len) return null;

    if (_isStartOfFrame(marker)) {
      if (segmentLength < 7) return null;
      return (width: _u16(bytes, i + 5), height: _u16(bytes, i + 3));
    }
    i += segmentLength;
  }
  return null;
}

bool _isStartOfFrame(int marker) =>
    marker >= 0xC0 &&
    marker <= 0xCF &&
    marker != 0xC4 &&
    marker != 0xC8 &&
    marker != 0xCC;
