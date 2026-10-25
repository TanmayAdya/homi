// ------------------------------------------------------------
// FORKED FROM Flutter's original InteractiveViewer.dart
// ------------------------------------------------------------
// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:math' as math;

import 'package:flutter/foundation.dart' show clampDouble;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/services.dart';
import 'package:vector_math/vector_math_64.dart' show Matrix4, Quad, Vector3;

import '../utils/double_extensions.dart';


typedef InteractiveViewerWidgetBuilder = Widget Function(BuildContext context, Quad viewport);

@immutable
class InteractiveViewer extends StatefulWidget {
  InteractiveViewer({
    required this.child,
    super.key,
    this.clipBehavior = Clip.hardEdge,
    this.panAxis = PanAxis.free,
    this.boundaryMargin = EdgeInsets.zero,
    this.constrained = true,
    this.maxScale = 8.0,
    this.minScale = 0.8,
    this.interactionEndFrictionCoefficient = _kDrag,
    this.onInteractionEnd,
    this.onInteractionStart,
    this.onInteractionUpdate,
    this.panEnabled = true,
    this.scaleEnabled = true,
    this.scaleFactor = kDefaultMouseScrollToScaleFactor,
    this.transformationController,
    this.alignment,
    this.trackpadScrollCausesScale = false,
    this.onWheelDelta,
    this.onPointerScale,
    this.scrollPhysics,
    this.scrollPhysicsScale,
    this.scrollPhysicsAutoAdjustBoundaries = true,
  }) : assert(minScale > 0),
       assert(interactionEndFrictionCoefficient > 0),
       assert(minScale.isFinite),
       assert(maxScale > 0),
       assert(!maxScale.isNaN),
       assert(maxScale >= minScale),
       assert(
         (boundaryMargin.horizontal.isInfinite && boundaryMargin.vertical.isInfinite) ||
             (boundaryMargin.top.isFinite &&
                 boundaryMargin.right.isFinite &&
                 boundaryMargin.bottom.isFinite &&
                 boundaryMargin.left.isFinite),
       ),
       builder = null;

  InteractiveViewer.builder({
    required InteractiveViewerWidgetBuilder this.builder,
    super.key,
    this.clipBehavior = Clip.hardEdge,
    this.panAxis = PanAxis.free,
    this.boundaryMargin = EdgeInsets.zero,
    this.maxScale = 8.0,
    this.minScale = 0.8,
    this.interactionEndFrictionCoefficient = _kDrag,
    this.onInteractionEnd,
    this.onInteractionStart,
    this.onInteractionUpdate,
    this.panEnabled = true,
    this.scaleEnabled = true,
    this.scaleFactor = 200.0,
    this.transformationController,
    this.alignment,
    this.trackpadScrollCausesScale = false,
    this.onWheelDelta,
    this.onPointerScale,
    this.scrollPhysics,
    this.scrollPhysicsScale,
    this.scrollPhysicsAutoAdjustBoundaries = true,
  }) : assert(minScale > 0),
       assert(interactionEndFrictionCoefficient > 0),
       assert(minScale.isFinite),
       assert(maxScale > 0),
       assert(!maxScale.isNaN),
       assert(maxScale >= minScale),
       assert(
         (boundaryMargin.horizontal.isInfinite && boundaryMargin.vertical.isInfinite) ||
             (boundaryMargin.top.isFinite &&
                 boundaryMargin.right.isFinite &&
                 boundaryMargin.bottom.isFinite &&
                 boundaryMargin.left.isFinite),
       ),
       constrained = false,
       child = null;

  final Alignment? alignment;

  final Clip clipBehavior;

  final PanAxis panAxis;

  final EdgeInsets boundaryMargin;

  final InteractiveViewerWidgetBuilder? builder;

  final Widget? child;

  final bool constrained;

  final bool panEnabled;

  final bool scaleEnabled;

  final bool trackpadScrollCausesScale;

  final double scaleFactor;

  final double maxScale;

  final double minScale;

  final double interactionEndFrictionCoefficient;

  final GestureScaleEndCallback? onInteractionEnd;

  final GestureScaleStartCallback? onInteractionStart;

  final GestureScaleUpdateCallback? onInteractionUpdate;

  final TransformationController? transformationController;

  final void Function(PointerScrollEvent event)? onWheelDelta;

  final void Function(PointerScaleEvent event)? onPointerScale;

  static const double _kDrag = 0.0000135;

  final ScrollPhysics? scrollPhysics;

  final ScrollPhysics? scrollPhysicsScale;

  final bool scrollPhysicsAutoAdjustBoundaries;

  @visibleForTesting
  static Vector3 getNearestPointOnLine(Vector3 point, Vector3 l1, Vector3 l2) {
    final lengthSquared = math.pow(l2.x - l1.x, 2.0).toDouble() + math.pow(l2.y - l1.y, 2.0).toDouble();

    if (lengthSquared == 0) {
      return l1;
    }

    final l1P = point - l1;
    final l1L2 = l2 - l1;
    final fraction = clampDouble(l1P.dot(l1L2) / lengthSquared, 0.0, 1.0);
    return l1 + l1L2 * fraction;
  }

  @visibleForTesting
  static Quad getAxisAlignedBoundingBox(Quad quad) {
    final double minX = math.min(quad.point0.x, math.min(quad.point1.x, math.min(quad.point2.x, quad.point3.x)));
    final double minY = math.min(quad.point0.y, math.min(quad.point1.y, math.min(quad.point2.y, quad.point3.y)));
    final double maxX = math.max(quad.point0.x, math.max(quad.point1.x, math.max(quad.point2.x, quad.point3.x)));
    final double maxY = math.max(quad.point0.y, math.max(quad.point1.y, math.max(quad.point2.y, quad.point3.y)));
    return Quad.points(Vector3(minX, minY, 0), Vector3(maxX, minY, 0), Vector3(maxX, maxY, 0), Vector3(minX, maxY, 0));
  }

  @visibleForTesting
  static bool pointIsInside(Vector3 point, Quad quad) {
    final aM = point - quad.point0;
    final aB = quad.point1 - quad.point0;
    final aD = quad.point3 - quad.point0;

    final aMAB = aM.dot(aB);
    final aBAB = aB.dot(aB);
    final aMAD = aM.dot(aD);
    final aDAD = aD.dot(aD);

    return 0 <= aMAB && aMAB <= aBAB && 0 <= aMAD && aMAD <= aDAD;
  }

  @visibleForTesting
  static Vector3 getNearestPointInside(Vector3 point, Quad quad) {
    if (pointIsInside(point, quad)) {
      return point;
    }

    final closestPoints = <Vector3>[
      InteractiveViewer.getNearestPointOnLine(point, quad.point0, quad.point1),
      InteractiveViewer.getNearestPointOnLine(point, quad.point1, quad.point2),
      InteractiveViewer.getNearestPointOnLine(point, quad.point2, quad.point3),
      InteractiveViewer.getNearestPointOnLine(point, quad.point3, quad.point0),
    ];
    var minDistance = double.infinity;
    late Vector3 closestOverall;
    for (final closePoint in closestPoints) {
      final distance = math.sqrt(math.pow(point.x - closePoint.x, 2) + math.pow(point.y - closePoint.y, 2));
      if (distance < minDistance) {
        minDistance = distance;
        closestOverall = closePoint;
      }
    }
    return closestOverall;
  }

  @override
  State<InteractiveViewer> createState() => InteractiveViewerState();
}

class InteractiveViewerState extends State<InteractiveViewer> with TickerProviderStateMixin {
  late final EdgeInsets _originalBoundaryMargin = widget.boundaryMargin;
  late TransformationController _transformer = widget.transformationController ?? TransformationController();

  final GlobalKey _childKey = GlobalKey();
  final GlobalKey _parentKey = GlobalKey();
  Animation<Offset>? _animation;
  Animation<double>? _scaleAnimation;
  late Offset _scaleAnimationFocalPoint;
  late AnimationController _controller;
  late AnimationController _scaleController;
  Axis? _currentAxis;
  Offset? _referenceFocalPoint;
  double? _scaleStart;
  double? _rotationStart = 0.0;
  double _currentRotation = 0.0;
  _GestureType? _gestureType;

  late AnimationController _snapController;
  late Matrix4 _snapStartMatrix;
  Matrix4? _snapTargetMatrix;
  late Offset _snapFocalPoint;
  double _lastScale = 1.0;
  Simulation? simulationX;
  Simulation? simulationY;
  Simulation? combinedSimulation;
  Simulation? simulationScale;

  final bool _rotateEnabled = false;

  Rect get _boundaryRect {
    assert(_childKey.currentContext != null);
    assert(!widget.boundaryMargin.left.isNaN);
    assert(!widget.boundaryMargin.right.isNaN);
    assert(!widget.boundaryMargin.top.isNaN);
    assert(!widget.boundaryMargin.bottom.isNaN);

    final childRenderBox = _childKey.currentContext!.findRenderObject()! as RenderBox;
    final childSize = childRenderBox.size;
    final boundaryRect = widget.boundaryMargin.inflateRect(Offset.zero & childSize);
    assert(!boundaryRect.isEmpty, "InteractiveViewer's child must have nonzero dimensions.");
    assert(
      boundaryRect.isFinite ||
          (boundaryRect.left.isInfinite &&
              boundaryRect.top.isInfinite &&
              boundaryRect.right.isInfinite &&
              boundaryRect.bottom.isInfinite),
      'boundaryRect must either be infinite in all directions or finite in all directions.',
    );
    return boundaryRect;
  }

  Rect get _viewport {
    assert(_parentKey.currentContext != null);
    final parentRenderBox = _parentKey.currentContext!.findRenderObject()! as RenderBox;
    return Offset.zero & parentRenderBox.size;
  }

  Matrix4 _matrixTranslate(Matrix4 matrix, Offset translation) {
    if (translation == Offset.zero) {
      return matrix.clone();
    }

    final Offset alignedTranslation;

    if (_currentAxis != null && _gestureType == _GestureType.pan) {
      alignedTranslation = switch (widget.panAxis) {
        PanAxis.horizontal => _alignAxis(translation, Axis.horizontal),
        PanAxis.vertical => _alignAxis(translation, Axis.vertical),
        PanAxis.aligned => _alignAxis(translation, _currentAxis!),
        PanAxis.free => translation,
      };
    } else {
      alignedTranslation = translation;
    }

    final nextMatrix = matrix.clone()..translateByDouble(alignedTranslation.dx, alignedTranslation.dy, 0, 1);

    final nextViewport = _transformViewport(nextMatrix, _viewport);

    if (_boundaryRect.isInfinite) {
      return nextMatrix;
    }

    if (widget.scrollPhysics != null) {
      final physics = (_gestureType == _GestureType.scale)
          ? (widget.scrollPhysicsScale ?? widget.scrollPhysics!)
          : widget.scrollPhysics!;
      final currentOffset = _getMatrixTranslation(_transformer.value) * -1;
      final metricsX = _calculateScrollMetrics(currentOffset.dx, AxisDirection.right);
      final metricsY = _calculateScrollMetrics(currentOffset.dy, AxisDirection.down);

      final proposedX = currentOffset.dx - alignedTranslation.dx;
      final proposedY = currentOffset.dy - alignedTranslation.dy;

      final overscrollX = proposedX == currentOffset.dx
          ? 0
          : physics.applyBoundaryConditions(metricsX, proposedX);
      final overscrollY = proposedY == currentOffset.dy
          ? 0
          : physics.applyBoundaryConditions(metricsY, proposedY);

      if (overscrollX == 0 && overscrollY == 0) {
        if (_gestureType == _GestureType.scale) {
          return nextMatrix;
        }
        var dx = 0.0;
        if (alignedTranslation.dx != 0 && physics.shouldAcceptUserOffset(_normalizeScrollMetrics(metricsX))) {
          dx = physics.applyPhysicsToUserOffset(metricsX, alignedTranslation.dx);
        }
        var dy = 0.0;
        if (alignedTranslation.dy != 0 && physics.shouldAcceptUserOffset(_normalizeScrollMetrics(metricsY))) {
          dy = physics.applyPhysicsToUserOffset(metricsY, alignedTranslation.dy);
        }
        return matrix.clone()..translateByDouble(dx, dy, 0, 1);
      } else {
        return matrix.clone()
          ..translateByDouble(alignedTranslation.dx + overscrollX, alignedTranslation.dy + overscrollY, 0, 1);
      }
    }

    final boundariesAabbQuad = _getAxisAlignedBoundingBoxWithRotation(_boundaryRect, _currentRotation);

    final offendingDistance = _exceedsBy(boundariesAabbQuad, nextViewport);
    if (offendingDistance == Offset.zero) {
      return nextMatrix;
    }

    final nextTotalTranslation = _getMatrixTranslation(nextMatrix);
    final currentScale = matrix.getMaxScaleOnAxis();
    final correctedTotalTranslation = Offset(
      nextTotalTranslation.dx - offendingDistance.dx * currentScale,
      nextTotalTranslation.dy - offendingDistance.dy * currentScale,
    );
    final correctedMatrix = matrix.clone()
      ..setTranslation(Vector3(correctedTotalTranslation.dx, correctedTotalTranslation.dy, 0.0));

    final correctedViewport = _transformViewport(correctedMatrix, _viewport);
    final offendingCorrectedDistance = _exceedsBy(boundariesAabbQuad, correctedViewport);
    if (offendingCorrectedDistance == Offset.zero) {
      return correctedMatrix;
    }

    if (offendingCorrectedDistance.dx != 0.0 && offendingCorrectedDistance.dy != 0.0) {
      return matrix.clone();
    }

    final unidirectionalCorrectedTotalTranslation = Offset(
      offendingCorrectedDistance.dx == 0.0 ? correctedTotalTranslation.dx : 0.0,
      offendingCorrectedDistance.dy == 0.0 ? correctedTotalTranslation.dy : 0.0,
    );
    return matrix.clone()..setTranslation(
      Vector3(unidirectionalCorrectedTotalTranslation.dx, unidirectionalCorrectedTotalTranslation.dy, 0.0),
    );
  }

  Matrix4 _matrixScale(Matrix4 matrix, double scale) {
    if (scale == 1.0) {
      return matrix.clone();
    }
    assert(scale != 0.0);

    final scrollPhysics = widget.scrollPhysicsScale ?? widget.scrollPhysics;

    if (scrollPhysics != null) {
      final currentScale = _transformer.value.getMaxScaleOnAxis();
      final scaleChange = scale;

      final desiredScale = currentScale * scale;

      final allowedScale = _getAllowedScale(desiredScale);
      if (allowedScale != desiredScale) {
        return matrix.clone()..scaleByDouble(allowedScale, allowedScale, allowedScale, 1);
      }

      final scaleRatio = scaleChange / _lastScale;
      _lastScale = scaleChange;
      final incrementalScale = currentScale * scaleRatio;

      if (_gestureType == _GestureType.scale &&
          !_snapController.isAnimating &&
          ((desiredScale < widget.minScale) || (desiredScale > widget.maxScale))) {
        final contentSize = _boundaryRect.isInfinite ? _childSize() : _boundaryRect.size;

        final contentWidth = contentSize.width * currentScale;
        final desiredContentWidth = contentSize.width * incrementalScale;
        final contentHeight = contentSize.height * currentScale;
        final desiredContentHeight = contentSize.height * incrementalScale;

        final ScrollMetrics metricsX = FixedScrollMetrics(
          pixels: contentWidth,
          minScrollExtent: contentSize.width * widget.minScale,
          maxScrollExtent: contentSize.width * widget.maxScale,
          viewportDimension: contentSize.width * widget.maxScale,
          axisDirection: AxisDirection.right,
          devicePixelRatio: 1.0,
        );
        final ScrollMetrics metricsY = FixedScrollMetrics(
          pixels: contentHeight,
          minScrollExtent: contentSize.height * widget.minScale,
          maxScrollExtent: contentSize.height * widget.maxScale,
          viewportDimension: contentSize.height * widget.maxScale,
          axisDirection: AxisDirection.down,
          devicePixelRatio: 1.0,
        );

        final deltaX = desiredContentWidth - contentWidth;
        final deltaY = desiredContentHeight - contentHeight;

        final adjustedX = scrollPhysics.applyPhysicsToUserOffset(metricsX, deltaX / 2) * 2;
        final adjustedY = scrollPhysics.applyPhysicsToUserOffset(metricsY, deltaY / 2) * 2;

        final newScaleX = (contentWidth + adjustedX) / contentWidth;
        final newScaleY = (contentHeight + adjustedY) / contentHeight;
        final factor = (newScaleX + newScaleY) / 2;

        return matrix.clone()..scaleByDouble(factor, factor, factor, 1);
      } else {
        final clampedTotalScale = clampDouble(desiredScale, widget.minScale, widget.maxScale);
        final clampedScale = clampedTotalScale / currentScale;

        return matrix.clone()..scaleByDouble(clampedScale, clampedScale, clampedScale, 1);
      }
    } else {
      final currentScale = _transformer.value.getMaxScaleOnAxis();
      final double totalScale = math.max(
        currentScale * scale,
        math.max(_viewport.width / _boundaryRect.width, _viewport.height / _boundaryRect.height),
      );
      final clampedTotalScale = clampDouble(totalScale, widget.minScale, widget.maxScale);
      final clampedScale = clampedTotalScale / currentScale;
      return matrix.clone()..scaleByDouble(clampedScale, clampedScale, clampedScale, 1);
    }
  }

  Matrix4 _matrixRotate(Matrix4 matrix, double rotation, Offset focalPoint) {
    if (rotation == 0) {
      return matrix.clone();
    }
    final focalPointScene = _transformer.toScene(focalPoint);
    return matrix.clone()
      ..translateByDouble(focalPointScene.dx, focalPointScene.dy, 0, 1)
      ..rotateZ(-rotation)
      ..translateByDouble(-focalPointScene.dx, -focalPointScene.dy, 0, 1);
  }

  bool _gestureIsSupported(_GestureType? gestureType) {
    return switch (gestureType) {
      _GestureType.rotate => _rotateEnabled,
      _GestureType.scale => widget.scaleEnabled,
      _GestureType.pan || null => widget.panEnabled,
    };
  }

  _GestureType _getGestureType(ScaleUpdateDetails details) {
    final scale = !widget.scaleEnabled ? 1.0 : details.scale;
    final rotation = !_rotateEnabled ? 0.0 : details.rotation;
    if ((scale - 1).abs() > rotation.abs()) {
      return _GestureType.scale;
    } else if (rotation != 0.0) {
      return _GestureType.rotate;
    } else {
      return _GestureType.pan;
    }
  }

  void _onScaleStart(ScaleStartDetails details) {
    widget.onInteractionStart?.call(details);

    if (_controller.isAnimating) {
      _controller.stop();
      _controller.reset();
      _animation?.removeListener(_handleInertiaAnimation);
      _animation = null;
    }

    if (_scaleController.isAnimating) {
      _scaleController.stop();
      _scaleController.reset();
      _scaleAnimation?.removeListener(_handleScaleAnimation);
      _scaleAnimation = null;
    }

    _gestureType = null;
    _currentAxis = null;
    _scaleStart = _transformer.value.getMaxScaleOnAxis();
    _lastScale = 1.0;
    _referenceFocalPoint = _transformer.toScene(details.localFocalPoint);
    _snapFocalPoint = details.localFocalPoint;
    _rotationStart = _currentRotation;
  }

  void _onScaleUpdate(ScaleUpdateDetails details) {
    final scale = _transformer.value.getMaxScaleOnAxis();
    _scaleAnimationFocalPoint = details.localFocalPoint;
    final focalPointScene = _transformer.toScene(details.localFocalPoint);

    if (_gestureType == _GestureType.pan) {
      _gestureType = _getGestureType(details);
    } else {
      _gestureType ??= _getGestureType(details);
    }
    if (!_gestureIsSupported(_gestureType)) {
      widget.onInteractionUpdate?.call(details);
      return;
    }

    switch (_gestureType!) {
      case _GestureType.scale:
        assert(_scaleStart != null);
        final desiredScale = _scaleStart! * details.scale;
        final scaleChange = desiredScale / scale;
        _snapFocalPoint = details.localFocalPoint;
        _transformer.value = _matrixScale(_transformer.value, scaleChange);

        final focalPointSceneScaled = _transformer.toScene(details.localFocalPoint);
        _transformer.value = _matrixTranslate(_transformer.value, focalPointSceneScaled - _referenceFocalPoint!);

        final focalPointSceneCheck = _transformer.toScene(details.localFocalPoint);
        if (_referenceFocalPoint!.round10BitFrac() != focalPointSceneCheck.round10BitFrac()) {
          _referenceFocalPoint = focalPointSceneCheck;
        }

      case _GestureType.rotate:
        if (details.rotation == 0.0) {
          widget.onInteractionUpdate?.call(details);
          return;
        }
        final desiredRotation = _rotationStart! + details.rotation;
        _transformer.value = _matrixRotate(
          _transformer.value,
          _currentRotation - desiredRotation,
          details.localFocalPoint,
        );
        _currentRotation = desiredRotation;

      case _GestureType.pan:
        assert(_referenceFocalPoint != null);
        if (details.scale != 1.0) {
          widget.onInteractionUpdate?.call(details);
          return;
        }
        _currentAxis ??= _getPanAxis(_referenceFocalPoint!, focalPointScene);
        final translationChange = focalPointScene - _referenceFocalPoint!;
        _transformer.value = _matrixTranslate(_transformer.value, translationChange);
        _referenceFocalPoint = _transformer.toScene(details.localFocalPoint);
    }
    widget.onInteractionUpdate?.call(details);
  }

  void _onScaleEnd(ScaleEndDetails details) {
    widget.onInteractionEnd?.call(details);
    _rotationStart = null;
    _referenceFocalPoint = null;

    _animation?.removeListener(_handleInertiaAnimation);
    _scaleAnimation?.removeListener(_handleScaleAnimation);
    _controller.reset();
    _scaleController.reset();

    if (!_gestureIsSupported(_gestureType)) {
      _currentAxis = null;
      return;
    }

    switch (_gestureType) {
      case _GestureType.pan:
        if (widget.scrollPhysics != null) {
          if (_snapController.isAnimating) return;

          final currentTranslation = _transformer.value.getTranslation();
          final currentOffset = Offset(currentTranslation.x, currentTranslation.y);
          final adjustedOffset = currentOffset * -1;

          final flingVelocityX =
              math.min(details.velocity.pixelsPerSecond.dx.abs(), widget.scrollPhysics!.maxFlingVelocity) *
              details.velocity.pixelsPerSecond.dx.sign;
          final flingVelocityY =
              math.min(details.velocity.pixelsPerSecond.dy.abs(), widget.scrollPhysics!.maxFlingVelocity) *
              details.velocity.pixelsPerSecond.dy.sign;

          final metricsX = _calculateScrollMetrics(adjustedOffset.dx, AxisDirection.right);
          final metricsY = _calculateScrollMetrics(adjustedOffset.dy, AxisDirection.down);

          if (details.velocity.pixelsPerSecond.distance <= widget.scrollPhysics!.minFlingVelocity &&
              !metricsX.outOfRange &&
              !metricsY.outOfRange) {
            return;
          }

          simulationX = widget.scrollPhysics!.createBallisticSimulation(metricsX, -flingVelocityX);
          simulationY = widget.scrollPhysics!.createBallisticSimulation(metricsY, -flingVelocityY);
          combinedSimulation = _getCombinedSimulation(simulationX, simulationY);

          if (combinedSimulation == null) {
            return;
          }

          _controller.addListener(_handleInertiaAnimation);
          _controller.animateWith(combinedSimulation!);
        } else {
          if (details.velocity.pixelsPerSecond.distance < kMinFlingVelocity) {
            _currentAxis = null;
            return;
          }
          final translationVector = _transformer.value.getTranslation();
          final translation = Offset(translationVector.x, translationVector.y);
          final frictionSimulationX = FrictionSimulation(
            widget.interactionEndFrictionCoefficient,
            translation.dx,
            details.velocity.pixelsPerSecond.dx,
          );
          final frictionSimulationY = FrictionSimulation(
            widget.interactionEndFrictionCoefficient,
            translation.dy,
            details.velocity.pixelsPerSecond.dy,
          );
          final tFinal = _getFinalTime(
            details.velocity.pixelsPerSecond.distance,
            widget.interactionEndFrictionCoefficient,
          );
          _animation = Tween<Offset>(
            begin: translation,
            end: Offset(frictionSimulationX.finalX, frictionSimulationY.finalX),
          ).animate(CurvedAnimation(parent: _controller, curve: Curves.decelerate));
          _controller.duration = Duration(milliseconds: (tFinal * 1000).round());
          _animation!.addListener(_handleInertiaAnimation);
          _controller.forward();
        }
        break;
      case _GestureType.scale:
        if (widget.scrollPhysics != null) {
          final endScale = _transformer.value.getMaxScaleOnAxis();
          final clampedScale = endScale.clamp(widget.minScale, widget.maxScale);

          if (clampedScale != endScale) {
            HapticFeedback.lightImpact();
          }
          _snapStartMatrix = _transformer.value.clone();
          final pivotScene = _transformer.toScene(_snapFocalPoint);
          final endMatrix = _snapStartMatrix.clone()
            ..translateByDouble(pivotScene.dx, pivotScene.dy, 0, 1)
            ..scaleByDouble(clampedScale / endScale, clampedScale / endScale, clampedScale / endScale, 1)
            ..translateByDouble(-pivotScene.dx, -pivotScene.dy, 0, 1);
          _snapTargetMatrix = _matrixClamp(endMatrix);

          _snapController
            ..removeListener(_animateSnap)
            ..addListener(_animateSnap)
            ..forward(from: 0.0).then((_) {
              _snapTargetMatrix = null;
            });
          break;
        } else {
          if (details.scaleVelocity.abs() < 0.1) {
            _currentAxis = null;
            return;
          }
          final scale = _transformer.value.getMaxScaleOnAxis();
          final frictionSimulation = FrictionSimulation(
            widget.interactionEndFrictionCoefficient * widget.scaleFactor,
            scale,
            details.scaleVelocity / 10,
          );
          final tFinal = _getFinalTime(
            details.scaleVelocity.abs(),
            widget.interactionEndFrictionCoefficient,
            effectivelyMotionless: 0.1,
          );
          _scaleAnimation = Tween<double>(
            begin: scale,
            end: frictionSimulation.x(tFinal),
          ).animate(CurvedAnimation(parent: _scaleController, curve: Curves.decelerate));
          _scaleController.duration = Duration(milliseconds: (tFinal * 1000).round());
          _scaleAnimation!.addListener(_handleScaleAnimation);
          _scaleController.forward();
        }
      case _GestureType.rotate:
      case null:
        break;
    }
  }


  void _receivedPointerSignal(PointerSignalEvent event) {
    final local = event.localPosition;
    final global = event.position;
    final double scaleChange;
    if (event is PointerScrollEvent) {
      if (event.kind == PointerDeviceKind.trackpad && !widget.trackpadScrollCausesScale) {
        widget.onInteractionStart?.call(ScaleStartDetails(focalPoint: global, localFocalPoint: local));

        final localDelta = PointerEvent.transformDeltaViaPositions(
          untransformedEndPosition: global + event.scrollDelta,
          untransformedDelta: event.scrollDelta,
          transform: event.transform,
        );

        if (!_gestureIsSupported(_GestureType.pan)) {
          widget.onInteractionUpdate?.call(
            ScaleUpdateDetails(
              focalPoint: global - event.scrollDelta,
              localFocalPoint: local - event.scrollDelta,
              focalPointDelta: -localDelta,
            ),
          );
          widget.onInteractionEnd?.call(ScaleEndDetails());
          return;
        }

        final focalPointScene = _transformer.toScene(local);
        final newFocalPointScene = _transformer.toScene(local - localDelta);

        _transformer.value = _matrixClamp(_matrixTranslate(_transformer.value, newFocalPointScene - focalPointScene));

        widget.onInteractionUpdate?.call(
          ScaleUpdateDetails(
            focalPoint: global - event.scrollDelta,
            localFocalPoint: local - localDelta,
            focalPointDelta: -localDelta,
          ),
        );
        widget.onInteractionEnd?.call(ScaleEndDetails());
        return;
      }

      if (widget.onWheelDelta != null) {
        widget.onWheelDelta!(event);
        return;
      }

      if (event.scrollDelta.dy == 0.0) {
        return;
      }
      scaleChange = math.exp(-event.scrollDelta.dy / widget.scaleFactor);
    } else if (event is PointerScaleEvent) {
      if (widget.onPointerScale != null) {
        widget.onPointerScale!(event);
        return;
      }
      scaleChange = event.scale;
    } else {
      return;
    }
    widget.onInteractionStart?.call(ScaleStartDetails(focalPoint: global, localFocalPoint: local));

    if (!_gestureIsSupported(_GestureType.scale)) {
      widget.onInteractionUpdate?.call(
        ScaleUpdateDetails(focalPoint: global, localFocalPoint: local, scale: scaleChange),
      );
      widget.onInteractionEnd?.call(ScaleEndDetails());
      return;
    }

    final focalPointScene = _transformer.toScene(local);
    _transformer.value = _matrixScale(_transformer.value, scaleChange);

    final focalPointSceneScaled = _transformer.toScene(local);
    _transformer.value = _matrixClamp(_matrixTranslate(_transformer.value, focalPointSceneScaled - focalPointScene));

    widget.onInteractionUpdate?.call(
      ScaleUpdateDetails(focalPoint: global, localFocalPoint: local, scale: scaleChange),
    );
    widget.onInteractionEnd?.call(ScaleEndDetails());
  }

  void _handleInertiaAnimation() {
    if (!_controller.isAnimating) {
      if (widget.scrollPhysics != null) {
        _controller.removeListener(_handleInertiaAnimation);
      } else {
        _animation?.removeListener(_handleInertiaAnimation);
        _animation = null;
      }
      _currentAxis = null;
      _controller.reset();
      return;
    }
    final translationVector = _transformer.value.getTranslation();
    final translation = Offset(translationVector.x, translationVector.y);
    final translationScene = _transformer.toScene(translation);

    if (widget.scrollPhysics != null) {
      final t = _controller.lastElapsedDuration!.inMilliseconds / 1000.0;
      final simulationOffsetX = simulationX != null ? -simulationX!.x(t) : translationVector.x;
      final simulationOffsetY = simulationY != null ? -simulationY!.x(t) : translationVector.y;
      final simulationOffset = Offset(simulationOffsetX, simulationOffsetY);
      final simulationScene = _transformer.toScene(simulationOffset);
      final translationChangeScene = simulationScene - translationScene;
      _transformer.value = _matrixTranslate(_transformer.value, translationChangeScene);
    } else {
      final animationScene = _transformer.toScene(_animation!.value);
      final translationChangeScene = animationScene - translationScene;
      _transformer.value = _matrixTranslate(_transformer.value, translationChangeScene);
    }
  }

  Size _childSize() {
    final childRenderBox = _childKey.currentContext!.findRenderObject()! as RenderBox;
    final childSize = childRenderBox.size;
    return childSize;
  }

  Rect _computePanBoundaries({
    required Size viewportSize,
    required double scale,
    EdgeInsets? boundaryMargin,
    bool overrideAutoAdjustBoundaries = false,
  }) {
    final baseMargin =
        (overrideAutoAdjustBoundaries && !widget.scrollPhysicsAutoAdjustBoundaries) || boundaryMargin == null
        ? _originalBoundaryMargin
        : boundaryMargin;

    if (_boundaryRect.isInfinite) {
      return const Rect.fromLTRB(-double.maxFinite, -double.maxFinite, double.maxFinite, double.maxFinite);
    }
    final baseBoundaryRect = baseMargin.inflateRect(Offset.zero & _childSize());
    final effectiveWidth = baseBoundaryRect.width * scale;
    final effectiveHeight = baseBoundaryRect.height * scale;

    final extraWidth = effectiveWidth - viewportSize.width;
    final extraHeight = effectiveHeight - viewportSize.height;

    const kOverflowTolerance = 0.1;
    final extraBoundaryHorizontal = extraWidth < -kOverflowTolerance ? (extraWidth.abs() / 2) : 0.0;
    final extraBoundaryVertical = extraHeight < -kOverflowTolerance ? (extraHeight.abs() / 2) : 0.0;

    final minX = -((baseMargin.left * scale + extraBoundaryHorizontal));
    final maxX = extraWidth < -kOverflowTolerance
        ? minX
        : -((baseMargin.left * scale + extraBoundaryHorizontal)) + extraWidth;
    final minY = -((baseMargin.top * scale + extraBoundaryVertical));
    final maxY = extraHeight < -kOverflowTolerance
        ? minY
        : -((baseMargin.bottom * scale + extraBoundaryVertical)) + extraHeight;
    return Rect.fromLTRB(minX, minY, maxX, maxY).round10BitFrac();
  }

  ScrollMetrics _normalizeScrollMetrics(ScrollMetrics scrollMetrics) {
    var range = scrollMetrics.maxScrollExtent - scrollMetrics.minScrollExtent;
    var pixels = scrollMetrics.pixels - scrollMetrics.minScrollExtent;

    const kTolerance = 0.01;
    range = range.abs() < kTolerance ? 0.0 : range;
    pixels = pixels.abs() < kTolerance ? 0.0 : pixels;

    return FixedScrollMetrics(
      pixels: pixels,
      minScrollExtent: 0.0,
      maxScrollExtent: range < 0.0 ? 0.0 : range,
      viewportDimension: scrollMetrics.viewportDimension,
      axisDirection: scrollMetrics.axisDirection,
      devicePixelRatio: scrollMetrics.devicePixelRatio,
    );
  }

  ScrollMetrics _calculateScrollMetrics(double pixels, AxisDirection axisDirection) {
    final panBoundaries = _computePanBoundaries(
      viewportSize: _viewport.size,
      scale: _transformer.value.getMaxScaleOnAxis(),
      boundaryMargin: widget.boundaryMargin,
    );

    final axis = switch (axisDirection) {
      AxisDirection.left => Axis.horizontal,
      AxisDirection.right => Axis.horizontal,
      AxisDirection.up => Axis.vertical,
      AxisDirection.down => Axis.vertical,
    };

    final minX = panBoundaries.left;
    final maxX = panBoundaries.right;
    final minY = panBoundaries.top;
    final maxY = panBoundaries.bottom;

    final scrollMetrics = FixedScrollMetrics(
      pixels: pixels,
      minScrollExtent: axis == Axis.horizontal ? minX : minY,
      maxScrollExtent: axis == Axis.horizontal ? maxX : maxY,
      viewportDimension: axis == Axis.horizontal ? _viewport.width : _viewport.height,
      axisDirection: axisDirection,
      devicePixelRatio: MediaQuery.of(context).devicePixelRatio,
    );
    return scrollMetrics;
  }

  Matrix4 _matrixClamp(Matrix4 matrix) {
    final totalTranslation = _getMatrixTranslation(matrix);
    final scale = matrix.getMaxScaleOnAxis();
    final viewSize = _viewport.size;
    final panBoundaries = _computePanBoundaries(
      viewportSize: viewSize,
      scale: scale,
      boundaryMargin: widget.boundaryMargin,
      overrideAutoAdjustBoundaries: false,
    );

    final minX = math.min(-panBoundaries.left, -panBoundaries.right);
    final maxX = math.max(-panBoundaries.left, -panBoundaries.right);
    final minY = math.min(-panBoundaries.top, -panBoundaries.bottom);
    final maxY = math.max(-panBoundaries.top, -panBoundaries.bottom);
    final clampedX = totalTranslation.dx.clamp(minX, maxX);
    final clampedY = totalTranslation.dy.clamp(minY, maxY);

    return matrix.clone()..setTranslation(Vector3(clampedX, clampedY, 0.0));
  }

  void _animateSnap() {
    if (_snapTargetMatrix == null) {
      return;
    }
    final t = Curves.ease.transform(_snapController.value);
    final lerped = Matrix4Tween(begin: _snapStartMatrix, end: _snapTargetMatrix!).transform(t);
    _transformer.value = lerped;
  }

  double _getAllowedScale(double proposedScale) {
    final scrollPhysics = widget.scrollPhysicsScale ?? widget.scrollPhysics;
    if (scrollPhysics == null) {
      return proposedScale.clamp(widget.minScale, widget.maxScale);
    }

    final contentSize = _boundaryRect.isInfinite ? _childSize() : _boundaryRect.size;

    final currentScale = _transformer.value.getMaxScaleOnAxis();
    final contentWidth = contentSize.width * currentScale;
    final desiredContentWidth = contentSize.width * proposedScale;
    final contentHeight = contentSize.height * currentScale;
    final desiredContentHeight = contentSize.height * proposedScale;

    final ScrollMetrics metricsX = FixedScrollMetrics(
      pixels: contentWidth,
      minScrollExtent: contentSize.width * widget.minScale,
      maxScrollExtent: contentSize.width * widget.maxScale,
      viewportDimension: _viewport.width,
      axisDirection: AxisDirection.right,
      devicePixelRatio: 1.0,
    );
    final ScrollMetrics metricsY = FixedScrollMetrics(
      pixels: contentHeight,
      minScrollExtent: contentSize.height * widget.minScale,
      maxScrollExtent: contentSize.height * widget.maxScale,
      viewportDimension: _viewport.height,
      axisDirection: AxisDirection.down,
      devicePixelRatio: 1.0,
    );

    final adjustmentX = scrollPhysics.applyBoundaryConditions(metricsX, desiredContentWidth);
    final adjustmentY = scrollPhysics.applyBoundaryConditions(metricsY, desiredContentHeight);

    if (adjustmentX == 0.0 && adjustmentY == 0.0) {
      return proposedScale;
    } else {
      final allowedContentWidth = desiredContentWidth - adjustmentX;
      final allowedContentHeight = desiredContentHeight - adjustmentY;

      if (proposedScale > widget.maxScale) {
        return math.max(allowedContentWidth / contentWidth, allowedContentHeight / contentHeight);
      } else {
        return math.max(allowedContentWidth / contentWidth, allowedContentHeight / contentHeight);
      }
    }
  }

  Simulation? _getCombinedSimulation(Simulation? simulationX, Simulation? simulationY) {
    if (simulationX == null && simulationY == null) {
      return null;
    }
    if (simulationX == null) {
      return simulationY;
    }
    if (simulationY == null) {
      return simulationX;
    }
    return CombinedSimulation(simulationX: simulationX, simulationY: simulationY);
  }

  void _onPointerDown(PointerDownEvent event) {
    if (widget.scrollPhysics != null && _controller.isAnimating) {
      stopAllAnimations();
    }
  }

  bool get hasActiveAnimations =>
      _controller.isAnimating || _scaleController.isAnimating || _snapController.isAnimating;

  void stopAllAnimations() {
    if (_controller.isAnimating) {
      _controller.stop();
      _controller.reset();
      _animation?.removeListener(_handleInertiaAnimation);
      _animation = null;
    }

    if (_scaleController.isAnimating) {
      _scaleController.stop();
      _scaleController.reset();
      _scaleAnimation?.removeListener(_handleScaleAnimation);
      _scaleAnimation = null;
    }

    if (_snapController.isAnimating) {
      _snapController.stop();
      _snapController.reset();
      _snapTargetMatrix = null;
    }

    simulationX = null;
    simulationY = null;
    combinedSimulation = null;
  }


  void _handleScaleAnimation() {
    if (!_scaleController.isAnimating) {
      _currentAxis = null;
      _scaleAnimation?.removeListener(_handleScaleAnimation);
      _scaleAnimation = null;
      _scaleController.reset();
      return;
    }
    final desiredScale = _scaleAnimation!.value;
    final scaleChange = desiredScale / _transformer.value.getMaxScaleOnAxis();
    final referenceFocalPoint = _transformer.toScene(_scaleAnimationFocalPoint);
    _transformer.value = _matrixScale(_transformer.value, scaleChange);

    final focalPointSceneScaled = _transformer.toScene(_scaleAnimationFocalPoint);
    _transformer.value = _matrixTranslate(_transformer.value, focalPointSceneScaled - referenceFocalPoint);
  }

  void _handleTransformation() {
    setState(() {});
  }

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this);
    _scaleController = AnimationController(vsync: this);
    _snapController = AnimationController(vsync: this, duration: const Duration(milliseconds: 250));

    _transformer.addListener(_handleTransformation);
  }

  @override
  void didUpdateWidget(InteractiveViewer oldWidget) {
    super.didUpdateWidget(oldWidget);

    final newController = widget.transformationController;
    if (newController == oldWidget.transformationController) {
      return;
    }
    _transformer.removeListener(_handleTransformation);
    if (oldWidget.transformationController == null) {
      _transformer.dispose();
    }
    _transformer = newController ?? TransformationController();
    _transformer.addListener(_handleTransformation);
  }

  @override
  void dispose() {
    _controller.dispose();
    _scaleController.dispose();
    _snapController.dispose();
    _transformer.removeListener(_handleTransformation);
    if (widget.transformationController == null) {
      _transformer.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    Widget child;
    if (widget.child != null) {
      child = _InteractiveViewerBuilt(
        childKey: _childKey,
        clipBehavior: widget.clipBehavior,
        constrained: widget.constrained,
        matrix: _transformer.value,
        alignment: widget.alignment,
        child: widget.child!,
      );
    } else {
      assert(widget.builder != null);
      assert(!widget.constrained);
      child = LayoutBuilder(
        builder: (context, constraints) {
          final matrix = _transformer.value;
          return _InteractiveViewerBuilt(
            childKey: _childKey,
            clipBehavior: widget.clipBehavior,
            constrained: widget.constrained,
            alignment: widget.alignment,
            matrix: matrix,
            child: widget.builder!(context, _transformViewport(matrix, Offset.zero & constraints.biggest)),
          );
        },
      );
    }

    return Listener(
      key: _parentKey,
      onPointerSignal: _receivedPointerSignal,
      onPointerDown: _onPointerDown,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onScaleEnd: _onScaleEnd,
        onScaleStart: _onScaleStart,
        onScaleUpdate: _onScaleUpdate,
        trackpadScrollCausesScale: widget.trackpadScrollCausesScale,
        trackpadScrollToScaleFactor: Offset(0, -1 / widget.scaleFactor),
        child: child,
      ),
    );
  }
}

class _InteractiveViewerBuilt extends StatelessWidget {
  const _InteractiveViewerBuilt({
    required this.child,
    required this.childKey,
    required this.clipBehavior,
    required this.constrained,
    required this.matrix,
    required this.alignment,
  });

  final Widget child;
  final GlobalKey childKey;
  final Clip clipBehavior;
  final bool constrained;
  final Matrix4 matrix;
  final Alignment? alignment;

  @override
  Widget build(BuildContext context) {
    Widget child = Transform(
      transform: matrix,
      alignment: alignment,
      child: KeyedSubtree(key: childKey, child: this.child),
    );

    if (!constrained) {
      child = OverflowBox(
        alignment: Alignment.topLeft,
        minWidth: 0.0,
        minHeight: 0.0,
        maxWidth: double.infinity,
        maxHeight: double.infinity,
        child: child,
      );
    }

    return ClipRect(clipBehavior: clipBehavior, child: child);
  }
}

enum _GestureType { pan, scale, rotate }

double _getFinalTime(double velocity, double drag, {double effectivelyMotionless = 0.5}) {
  final t = math.log(effectivelyMotionless / velocity) / math.log(drag / 100);
  if (!t.isFinite || t < 0) return 0;
  return t;
}

Offset _getMatrixTranslation(Matrix4 matrix) {
  final nextTranslation = matrix.getTranslation();
  return Offset(nextTranslation.x, nextTranslation.y);
}

Quad _transformViewport(Matrix4 matrix, Rect viewport) {
  final inverseMatrix = matrix.clone()..invert();
  return Quad.points(
    inverseMatrix.transform3(Vector3(viewport.topLeft.dx, viewport.topLeft.dy, 0.0)),
    inverseMatrix.transform3(Vector3(viewport.topRight.dx, viewport.topRight.dy, 0.0)),
    inverseMatrix.transform3(Vector3(viewport.bottomRight.dx, viewport.bottomRight.dy, 0.0)),
    inverseMatrix.transform3(Vector3(viewport.bottomLeft.dx, viewport.bottomLeft.dy, 0.0)),
  );
}

Quad _getAxisAlignedBoundingBoxWithRotation(Rect rect, double rotation) {
  final rotationMatrix = Matrix4.identity()
    ..translateByDouble(rect.size.width / 2, rect.size.height / 2, 0, 1)
    ..rotateZ(rotation)
    ..translateByDouble(-rect.size.width / 2, -rect.size.height / 2, 0, 1);
  final boundariesRotated = Quad.points(
    rotationMatrix.transform3(Vector3(rect.left, rect.top, 0.0)),
    rotationMatrix.transform3(Vector3(rect.right, rect.top, 0.0)),
    rotationMatrix.transform3(Vector3(rect.right, rect.bottom, 0.0)),
    rotationMatrix.transform3(Vector3(rect.left, rect.bottom, 0.0)),
  );
  return InteractiveViewer.getAxisAlignedBoundingBox(boundariesRotated);
}

Offset _exceedsBy(Quad boundary, Quad viewport) {
  final viewportPoints = <Vector3>[viewport.point0, viewport.point1, viewport.point2, viewport.point3];
  var largestExcess = Offset.zero;
  for (final point in viewportPoints) {
    final pointInside = InteractiveViewer.getNearestPointInside(point, boundary);
    final excess = Offset(pointInside.x - point.x, pointInside.y - point.y);
    if (excess.dx.abs() > largestExcess.dx.abs()) {
      largestExcess = Offset(excess.dx, largestExcess.dy);
    }
    if (excess.dy.abs() > largestExcess.dy.abs()) {
      largestExcess = Offset(largestExcess.dx, excess.dy);
    }
  }

  return largestExcess.round10BitFrac();
}

Offset _alignAxis(Offset offset, Axis axis) {
  return switch (axis) {
    Axis.horizontal => Offset(offset.dx, 0.0),
    Axis.vertical => Offset(0.0, offset.dy),
  };
}

Axis? _getPanAxis(Offset point1, Offset point2) {
  if (point1 == point2) {
    return null;
  }
  final x = point2.dx - point1.dx;
  final y = point2.dy - point1.dy;
  return x.abs() > y.abs() ? Axis.horizontal : Axis.vertical;
}

class CombinedSimulation extends Simulation {
  CombinedSimulation({required this.simulationX, required this.simulationY});
  final Simulation simulationX;
  final Simulation simulationY;

  @override
  double x(double time) => simulationX.x(time);

  @override
  double dx(double time) {
    final dxX = simulationX.dx(time);
    final dxY = simulationY.dx(time);
    return math.sqrt(dxX * dxX + dxY * dxY);
  }

  @override
  bool isDone(double time) {
    return simulationX.isDone(time) && simulationY.isDone(time);
  }
}

extension _OffsetRounder on Offset {
  Offset round10BitFrac() => Offset(dx.round10BitFrac(), dy.round10BitFrac());
}

extension _RectRounder on Rect {
  Rect round10BitFrac() =>
      Rect.fromLTRB(left.round10BitFrac(), top.round10BitFrac(), right.round10BitFrac(), bottom.round10BitFrac());
}
