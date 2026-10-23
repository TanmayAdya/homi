import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../domain/capture/capture_adapter.dart';

class FictionalCameraAdapter implements CaptureAdapter {
  FictionalCameraAdapter({required this.navigatorKey});

  final GlobalKey<NavigatorState> navigatorKey;

  @override
  Future<CaptureResult> capture(CaptureRequest request) async {
    final BuildContext? context = navigatorKey.currentContext;
    if (context == null) return const CaptureUnavailable();
    final _Outcome? choice = await showDialog<_Outcome>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Fictional camera'),
        children: [
          for (final _Outcome o in _Outcome.values)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, o),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(o.label),
              ),
            ),
        ],
      ),
    );
    return switch (choice) {
      null || _Outcome.cancel => const CaptureCancelled(),
      _Outcome.photo => CaptureSucceeded(
        await drawFictionalScene(request.area, request.view),
      ),
      _Outcome.deniedRetry => const CapturePermissionDenied(canAskAgain: true),
      _Outcome.deniedBlocked => const CapturePermissionDenied(
        canAskAgain: false,
      ),
      _Outcome.unavailable => const CaptureUnavailable(),
      _Outcome.heic => CaptureSucceeded(_heicHeader),
    };
  }
}

enum _Outcome {
  photo('Take a fictional photo'),
  cancel('Cancel'),
  deniedRetry('Simulate: permission denied'),
  deniedBlocked('Simulate: permission turned off'),
  unavailable('Simulate: no camera'),
  heic('Simulate: HEIC photo');

  const _Outcome(this.label);
  final String label;
}

final Uint8List _heicHeader = Uint8List.fromList([
  0,
  0,
  0,
  24,
  ...'ftyp'.codeUnits,
  ...'heic'.codeUnits,
  0,
  0,
  0,
  0,
  ...'mif1'.codeUnits,
  ...'heic'.codeUnits,
]);

Future<Uint8List> drawFictionalScene(
  AssessmentArea area,
  CaptureView view, {
  int width = 1200,
  int height = 900,
}) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  final double w = width.toDouble();
  final double h = height.toDouble();
  final double zoom = view == CaptureView.closeUp ? 1.8 : 1;
  canvas.drawRect(
    Rect.fromLTWH(0, 0, w, h),
    Paint()..color = const Color(0xFFEDE7DC),
  );
  canvas.drawRect(
    Rect.fromLTWH(0, h * 0.7, w, h * 0.3),
    Paint()..color = const Color(0xFFB9A58C),
  );
  canvas.save();
  canvas.translate(w / 2, h * 0.7);
  canvas.scale(zoom);
  switch (area) {
    case AssessmentArea.entrance:
      canvas.drawRect(
        Rect.fromLTWH(-w * 0.18, -h * 0.55, w * 0.36, h * 0.55),
        Paint()..color = const Color(0xFF6B4F3A),
      );
      canvas.drawRect(
        Rect.fromLTWH(-w * 0.22, -h * 0.03, w * 0.44, h * 0.03),
        Paint()..color = const Color(0xFF8C8C8C),
      );
    case AssessmentArea.bathroom:
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(-w * 0.35, -h * 0.22, w * 0.7, h * 0.22),
          const Radius.circular(24),
        ),
        Paint()..color = const Color(0xFFFFFFFF),
      );
      canvas.drawRect(
        Rect.fromLTWH(-w * 0.35, -h * 0.22, w * 0.7, h * 0.02),
        Paint()..color = const Color(0xFFCCCCCC),
      );
  }
  canvas.restore();
  final TextPainter label = TextPainter(
    text: const TextSpan(
      text: 'FICTIONAL SCENE',
      style: TextStyle(color: Color(0xFF555555), fontSize: 40),
    ),
    textDirection: TextDirection.ltr,
  )..layout();
  label.paint(canvas, const Offset(24, 24));

  final ui.Image image = await recorder.endRecording().toImage(width, height);
  final ByteData? data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return data!.buffer.asUint8List();
}
