import 'dart:math' as math;

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:vector_math/vector_math_64.dart' as vec;

import '../pdf_viewer.dart';
import '../pdf_viewer_layout_metrics.dart';
import 'pdf_viewer_scroll_interaction_delegate.dart';

class PdfViewerScrollInteractionDelegateProviderPhysics extends PdfViewerScrollInteractionDelegateProvider {
  const PdfViewerScrollInteractionDelegateProviderPhysics({this.panFriction = 12.0, this.zoomFriction = 12.0});

  final double panFriction;

  final double zoomFriction;

  @override
  PdfViewerScrollInteractionDelegate create() =>
      _PdfViewerScrollInteractionDelegatePhysics(panFriction: panFriction, zoomFriction: zoomFriction);

  @override
  bool operator ==(Object other) =>
      other is PdfViewerScrollInteractionDelegateProviderPhysics &&
      other.panFriction == panFriction &&
      other.zoomFriction == zoomFriction;

  @override
  int get hashCode => Object.hash(panFriction, zoomFriction);
}

class _PdfViewerScrollInteractionDelegatePhysics implements PdfViewerScrollInteractionDelegate {
  _PdfViewerScrollInteractionDelegatePhysics({required this.panFriction, required this.zoomFriction});

  final double panFriction;
  final double zoomFriction;

  PdfViewerController? _controller;
  TickerProvider? _vsync;

  Ticker? _panTicker;

  Offset? _panTarget;
  Duration? _lastPanFrameTime;

  Ticker? _zoomTicker;

  double? _zoomTarget;
  Duration? _lastZoomFrameTime;
  Offset? _lastFocalPoint;

  static const double _kEpsilon = 0.5;

  static const double _kScaleEpsilon = 0.0001;

  @override
  void init(PdfViewerController controller, TickerProvider vsync) {
    _controller = controller;
    _vsync = vsync;
  }

  @override
  void dispose() {
    stop();
    _controller = null;
    _vsync = null;
  }

  @override
  void stop() {
    _panTicker?.dispose();
    _panTicker = null;
    _panTarget = null;

    _zoomTicker?.dispose();
    _zoomTicker = null;
    _zoomTarget = null;
  }

  @override
  void pan(Offset delta, PdfViewerLayoutMetrics layoutMetrics) {
    final controller = _controller;
    final vsync = _vsync;
    if (controller == null || !controller.isReady || vsync == null) {
      return;
    }

    _zoomTicker?.dispose();
    _zoomTicker = null;
    _zoomTarget = null;

    if (_panTarget == null) {
      final currentTrans = controller.value.getTranslation();
      _panTarget = Offset(currentTrans.x, currentTrans.y);
    }

    _panTarget = _panTarget! + delta;

    if (_panTicker == null) {
      _lastPanFrameTime = null;
      _panTicker = vsync.createTicker(_onPanTick)..start();
    }
  }

  void _onPanTick(Duration elapsed) {
    final controller = _controller;
    if (controller == null || _panTarget == null) {
      _panTicker?.dispose();
      _panTicker = null;
      return;
    }

    final dt = _lastPanFrameTime == null
        ? (1.0 / 60.0)
        : (elapsed - _lastPanFrameTime!).inMicroseconds / 1000000.0;
    _lastPanFrameTime = elapsed;

    final currentTransVec = controller.value.getTranslation();
    final currentTrans = Offset(currentTransVec.x, currentTransVec.y);

    final diff = _panTarget! - currentTrans;

    if (diff.distance < _kEpsilon) {
      _applyTranslation(_panTarget!);
      _panTicker?.dispose();
      _panTicker = null;
      _panTarget = null;
      return;
    }

    final alpha = 1.0 - math.exp(-panFriction * dt);
    final newTrans = currentTrans + diff * alpha;

    _applyTranslation(newTrans);
  }

  void _applyTranslation(Offset translation) {
    final controller = _controller;
    if (controller == null) return;

    final currentMatrix = controller.value;

    final newMatrix = currentMatrix.clone();
    newMatrix.setTranslation(vec.Vector3(translation.dx, translation.dy, 0.0));

    controller.value = controller.makeMatrixInSafeRange(newMatrix, forceClamp: true);

    final actualTransVec = controller.value.getTranslation();
    final actualTrans = Offset(actualTransVec.x, actualTransVec.y);

    if (_panTarget != null) {
      if ((actualTrans.dx - translation.dx).abs() > 1.0) {
        _panTarget = Offset(actualTrans.dx, _panTarget!.dy);
      }
      if ((actualTrans.dy - translation.dy).abs() > 1.0) {
        _panTarget = Offset(_panTarget!.dx, actualTrans.dy);
      }
    }
  }

  @override
  void zoom(double scaleFactor, Offset focalPoint, PdfViewerLayoutMetrics layoutMetrics) {
    final controller = _controller;
    final vsync = _vsync;
    if (controller == null || !controller.isReady || vsync == null) return;

    _panTicker?.dispose();
    _panTicker = null;
    _panTarget = null;

    final currentZoom = controller.currentZoom;
    _zoomTarget ??= currentZoom;

    _zoomTarget = (_zoomTarget! * scaleFactor).clamp(layoutMetrics.minScale, layoutMetrics.maxScale);

    _lastFocalPoint = focalPoint;

    if (_zoomTicker == null) {
      _lastZoomFrameTime = null;
      _zoomTicker = vsync.createTicker(_onZoomTick)..start();
    }
  }

  void _onZoomTick(Duration elapsed) {
    final controller = _controller;
    if (controller == null || _zoomTarget == null || _lastFocalPoint == null) {
      _zoomTicker?.dispose();
      _zoomTicker = null;
      return;
    }

    final dt = _lastZoomFrameTime == null ? 1.0 / 60.0 : (elapsed - _lastZoomFrameTime!).inMicroseconds / 1000000.0;
    _lastZoomFrameTime = elapsed;

    final currentZoom = controller.currentZoom;
    final diff = _zoomTarget! - currentZoom;

    if (diff.abs() < _kScaleEpsilon) {
      controller.zoomOnLocalPosition(localPosition: _lastFocalPoint!, newZoom: _zoomTarget!, duration: Duration.zero);
      _zoomTicker?.dispose();
      _zoomTicker = null;
      _zoomTarget = null;
      return;
    }

    final alpha = 1.0 - math.exp(-zoomFriction * dt);
    final newZoom = currentZoom + diff * alpha;

    controller.zoomOnLocalPosition(localPosition: _lastFocalPoint!, newZoom: newZoom, duration: Duration.zero);
  }
}
