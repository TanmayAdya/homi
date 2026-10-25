import '../image/image_validator.dart';
import 'capture_adapter.dart';
import 'staging_store.dart';

sealed class PhotoOutcome {
  const PhotoOutcome();
}

final class PhotoStaged extends PhotoOutcome {
  const PhotoStaged(this.image, {this.replaced});
  final StagedImage image;
  final StagingKey? replaced;
}

final class PhotoKept extends PhotoOutcome {
  const PhotoKept();
}

final class PhotoPermissionBlocked extends PhotoOutcome {
  const PhotoPermissionBlocked({required this.canAskAgain});
  final bool canAskAgain;
}

final class PhotoUnavailable extends PhotoOutcome {
  const PhotoUnavailable();
}

final class PhotoRejected extends PhotoOutcome {
  const PhotoRejected(this.reason);
  final ImageRejection reason;
}

final class PhotoFailed extends PhotoOutcome {
  const PhotoFailed(this.code);
  final String code;

  static const String busy = 'busy';
  static const String adapterError = 'adapter_error';
  static const String stagingError = 'staging_error';
}

class PhotoCaptureCoordinator {
  PhotoCaptureCoordinator({
    required CaptureAdapter adapter,
    required StagingStore staging,
    ImageValidator validator = const ImageValidator(),
  }) : _adapter = adapter,
       _staging = staging,
       _validator = validator;

  final CaptureAdapter _adapter;
  final StagingStore _staging;
  final ImageValidator _validator;

  bool _busy = false;
  final Set<CaptureSource> _blockedSources = {};

  bool get isBusy => _busy;

  bool get permissionBlocked => _blockedSources.contains(CaptureSource.camera);

  Future<PhotoOutcome> capture(
    CaptureRequest request, {
    StagingKey? replacing,
  }) async {
    if (_busy) return const PhotoFailed(PhotoFailed.busy);
    if (_blockedSources.contains(request.source)) {
      return const PhotoPermissionBlocked(canAskAgain: false);
    }

    _busy = true;
    try {
      final CaptureResult result;
      try {
        result = await _adapter.capture(request);
      } catch (_) {
        return const PhotoFailed(PhotoFailed.adapterError);
      }

      switch (result) {
        case CaptureCancelled():
          return const PhotoKept();
        case CapturePermissionDenied(:final canAskAgain):
          if (!canAskAgain) _blockedSources.add(request.source);
          return PhotoPermissionBlocked(canAskAgain: canAskAgain);
        case CaptureUnavailable():
          return const PhotoUnavailable();
        case CaptureFailed(:final code):
          return PhotoFailed(code);
        case CaptureSucceeded(
          :final bytes,
          :final capturedAt,
          :final orientationNormalized,
        ):
          final ImageCheck check = _validator.check(bytes);
          switch (check) {
            case ImageRejected(:final reason):
              return PhotoRejected(reason);
            case final ImageAccepted accepted:
              final StagedImage staged;
              try {
                staged = await _staging.put(
                  bytes,
                  accepted,
                  capturedAt: capturedAt,
                  orientationNormalized: orientationNormalized,
                );
              } catch (_) {
                return const PhotoFailed(PhotoFailed.stagingError);
              }
              if (replacing != null) {
                await _discardQuietly(replacing);
              }
              return PhotoStaged(staged, replaced: replacing);
          }
      }
    } finally {
      _busy = false;
    }
  }

  void permissionMayHaveChanged() {
    _blockedSources.clear();
  }

  Future<void> remove(StagingKey key) => _discardQuietly(key);

  Future<int> discardAll() => _staging.discardAll();

  Future<void> _discardQuietly(StagingKey key) async {
    try {
      await _staging.discard(key);
    } catch (_) {
      // ignore: empty_catches
    }
  }
}
