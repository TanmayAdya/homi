import 'dart:io';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:safe_at_home/l10n/app_localizations.dart';

import '../domain/capture/capture_adapter.dart';
import '../domain/image/private_media_platform.dart';

class NativeCaptureAdapter implements CaptureAdapter {
  NativeCaptureAdapter({
    required this.context,
    PrivateMediaPlatform media = const PrivateMediaPlatform(),
    ImagePicker? picker,
    Future<List<CameraDescription>> Function()? loadCameras,
    CameraController Function(CameraDescription)? cameraControllerFactory,
    this.isCurrent,
  }) : _media = media,
       _picker = picker ?? ImagePicker(),
       _loadCameras = loadCameras ?? availableCameras,
       _cameraControllerFactory = cameraControllerFactory;
  final BuildContext Function() context;
  final PrivateMediaPlatform _media;
  final ImagePicker _picker;
  final Future<List<CameraDescription>> Function() _loadCameras;
  final CameraController Function(CameraDescription)? _cameraControllerFactory;
  final bool Function()? isCurrent;
  bool get _current => isCurrent?.call() ?? true;

  static Future<bool> discardInterruptedImport() async {
    if (!Platform.isAndroid) return false;
    final response = await ImagePicker().retrieveLostData();
    for (final file in response.files ?? <XFile>[]) {
      try {
        await File(file.path).delete();
      } catch (_) {}
    }
    return !response.isEmpty;
  }

  @override
  Future<CaptureResult> capture(CaptureRequest request) async {
    XFile? file;
    String? capturedAt;
    try {
      if (!_current) return const CaptureCancelled();
      await discardInterruptedImport();
      if (!_current) return const CaptureCancelled();
      await _media.prepareCaptureStorage();
      if (!_current) return const CaptureCancelled();
      if (request.source == CaptureSource.library) {
        if (Platform.isIOS) {
          final path = await _media.pickPhoto();
          file = path == null ? null : XFile(path);
        } else {
          file = await _picker.pickImage(
            source: ImageSource.gallery,
            requestFullMetadata: false,
          );
        }
      } else {
        final outcome = await Navigator.of(context()).push<_CameraOutcome>(
          MaterialPageRoute(
            builder: (_) => _CameraScreen(
              loadCameras: _loadCameras,
              cameraControllerFactory: _cameraControllerFactory,
              isCurrent: () => _current,
            ),
          ),
        );
        file = outcome?.file;
        if (!_current) return const CaptureCancelled();
        if (outcome?.error != null) {
          return _failure(outcome!.error!);
        }
        capturedAt = outcome?.capturedAt;
      }
      if (!_current || file == null) return const CaptureCancelled();
      final bytes = await _media.normalizePath(file.path);
      if (!_current) return const CaptureCancelled();
      return CaptureSucceeded(
        bytes,
        orientationNormalized: true,
        capturedAt: capturedAt,
      );
    } on CameraException catch (error) {
      return _failure(error.code);
    } on PlatformException catch (error) {
      return _failure(error.code);
    } catch (_) {
      return const CaptureFailed('photo_processing_failed');
    } finally {
      if (file != null) {
        try {
          await File(file.path).delete();
        } catch (_) {
          // ignore: empty_catches
        }
      }
    }
  }

  CaptureResult _failure(String code) => switch (code) {
    'PHOTO_IMPORT_TIMEOUT' => const CaptureFailed('photo_import_timeout'),
    'PHOTO_IMPORT_FAILED' ||
    'PHOTO_UNSUPPORTED' ||
    'PICKER_UNAVAILABLE' => const CaptureFailed('photo_import_failed'),
    'CameraAccessDenied' ||
    'CameraAccessDeniedWithoutPrompt' ||
    'CameraAccessRestricted' ||
    'photo_access_denied' => const CapturePermissionDenied(canAskAgain: false),
    'no_camera' => const CaptureUnavailable(),
    _ => const CaptureFailed('camera_unavailable'),
  };
}

class _CameraOutcome {
  const _CameraOutcome({this.file, this.error, this.capturedAt});
  final XFile? file;
  final String? error;
  final String? capturedAt;
}

class _CameraScreen extends StatefulWidget {
  const _CameraScreen({
    required this.loadCameras,
    this.cameraControllerFactory,
    required this.isCurrent,
  });
  final Future<List<CameraDescription>> Function() loadCameras;
  final CameraController Function(CameraDescription)? cameraControllerFactory;
  final bool Function() isCurrent;
  @override
  State<_CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<_CameraScreen>
    with WidgetsBindingObserver {
  CameraController? _controller;
  bool _taking = false;
  bool _interrupted = false;
  bool _foreground = true;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _open();
  }

  Future<void> _open() async {
    if (!widget.isCurrent()) return;
    final generation = ++_generation;
    CameraController? controller;
    try {
      final cameras = await widget.loadCameras();
      if (!mounted ||
          generation != _generation ||
          !_foreground ||
          !widget.isCurrent()) {
        return;
      }
      if (cameras.isEmpty) {
        Navigator.of(context).pop(const _CameraOutcome(error: 'no_camera'));
        return;
      }
      final camera =
          cameras
              .where((c) => c.lensDirection == CameraLensDirection.back)
              .firstOrNull ??
          cameras.first;
      controller =
          widget.cameraControllerFactory?.call(camera) ??
          CameraController(
            camera,
            ResolutionPreset.high,
            enableAudio: false,
            imageFormatGroup: ImageFormatGroup.jpeg,
          );
      await controller.initialize();
      if (!mounted ||
          generation != _generation ||
          !_foreground ||
          !widget.isCurrent()) {
        await controller.dispose();
        return;
      }
      setState(() => _controller = controller);
    } on CameraException catch (error) {
      await controller?.dispose();
      if (mounted && generation == _generation) {
        Navigator.of(context).pop(_CameraOutcome(error: error.code));
      }
    } catch (_) {
      await controller?.dispose();
      if (mounted && generation == _generation) {
        Navigator.of(context).pop(const _CameraOutcome(error: 'unavailable'));
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      _foreground = false;
      _generation++;
      _taking = false;
      final previous = _controller;
      _controller = null;
      previous?.dispose();
      if (mounted) setState(() {});
    } else if (state == AppLifecycleState.resumed && !_foreground) {
      _foreground = true;
      _open();
    }
  }

  Future<void> _take() async {
    final controller = _controller;
    final generation = _generation;
    if (_taking ||
        !widget.isCurrent() ||
        controller == null ||
        !controller.value.isInitialized) {
      return;
    }
    setState(() {
      _taking = true;
      _interrupted = false;
    });
    try {
      final file = await controller.takePicture();
      if (mounted &&
          _foreground &&
          widget.isCurrent() &&
          generation == _generation &&
          identical(controller, _controller)) {
        Navigator.of(context).pop(
          _CameraOutcome(
            file: file,
            capturedAt: DateTime.now().toUtc().toIso8601String(),
          ),
        );
      } else {
        try {
          await File(file.path).delete();
        } catch (_) {}
      }
    } catch (_) {
      if (mounted &&
          _foreground &&
          widget.isCurrent() &&
          generation == _generation &&
          identical(controller, _controller)) {
        setState(() {
          _taking = false;
          _interrupted = true;
        });
      }
    }
  }

  @override
  void dispose() {
    _generation++;
    WidgetsBinding.instance.removeObserver(this);
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(context.tr('Take a home photo'))),
    body: SafeArea(
      child: LayoutBuilder(
        builder: (context, constraints) => SingleChildScrollView(
          child: Column(
            children: [
              if (_interrupted)
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Semantics(
                    liveRegion: true,
                    child: Text(
                      context.tr(
                        'The photo was interrupted. Please try again.',
                      ),
                    ),
                  ),
                ),
              Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  context.tr(
                    'Keep people, mail, medicines and account details out of the picture.',
                  ),
                ),
              ),
              SizedBox(
                height: (constraints.maxHeight * .7).clamp(80.0, 600.0),
                child: _controller == null
                    ? Center(
                        child: CircularProgressIndicator(
                          semanticsLabel: context.tr('Preparing camera'),
                        ),
                      )
                    : Center(child: CameraPreview(_controller!)),
              ),
            ],
          ),
        ),
      ),
    ),
    bottomNavigationBar: SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: FilledButton.icon(
          onPressed: _taking || _controller == null ? null : _take,
          icon: const Icon(Icons.camera_alt),
          label: Text(context.tr(_taking ? 'Taking photo…' : 'Take photo')),
        ),
      ),
    ),
  );
}
