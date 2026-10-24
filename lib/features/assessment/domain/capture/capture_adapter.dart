import 'dart:typed_data';

enum AssessmentArea { bathroom, entrance }

enum CaptureView { overview, closeUp }

enum CaptureSource { camera, library }

final class CaptureRequest {
  const CaptureRequest({
    required this.area,
    required this.view,
    required this.promptId,
    this.source = CaptureSource.camera,
  });

  final AssessmentArea area;
  final CaptureView view;

  final String promptId;
  final CaptureSource source;
}

sealed class CaptureResult {
  const CaptureResult();
}

final class CaptureSucceeded extends CaptureResult {
  const CaptureSucceeded(
    this.bytes, {
    this.capturedAt,
    this.orientationNormalized = false,
  });
  final Uint8List bytes;

  final String? capturedAt;
  final bool orientationNormalized;
}

final class CaptureCancelled extends CaptureResult {
  const CaptureCancelled();
}

final class CapturePermissionDenied extends CaptureResult {
  const CapturePermissionDenied({required this.canAskAgain});
  final bool canAskAgain;
}

final class CaptureUnavailable extends CaptureResult {
  const CaptureUnavailable();
}

final class CaptureFailed extends CaptureResult {
  const CaptureFailed(this.code);
  final String code;
}

abstract interface class CaptureAdapter {
  Future<CaptureResult> capture(CaptureRequest request);
}
