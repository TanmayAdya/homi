import 'package:flutter/widgets.dart';

class FixedOverscrollPhysics extends ClampingScrollPhysics {
  const FixedOverscrollPhysics({super.parent, this.maxOverscroll = 200.0});

  final double maxOverscroll;

  @override
  FixedOverscrollPhysics applyTo(ScrollPhysics? ancestor) {
    return FixedOverscrollPhysics(parent: buildParent(ancestor), maxOverscroll: maxOverscroll);
  }

  @override
  double applyBoundaryConditions(ScrollMetrics position, double value) {

    if (value < position.minScrollExtent && value >= position.minScrollExtent - maxOverscroll) {
      return 0.0;
    }
    if (value > position.maxScrollExtent && value <= position.maxScrollExtent + maxOverscroll) {
      return 0.0;
    }

    if (value <= position.minScrollExtent - maxOverscroll) {
      return value - (position.minScrollExtent - maxOverscroll);
    } else if (value >= position.maxScrollExtent + maxOverscroll) {
      return value - (position.maxScrollExtent + maxOverscroll);
    }
    return 0.0;
  }

  @override
  Simulation? createBallisticSimulation(ScrollMetrics position, double velocity) {
    final tolerance = toleranceFor(position);

    if (velocity.abs() >= tolerance.velocity || position.outOfRange) {
      return _HybridScrollSimulation(
        position: position,
        velocity: velocity,
        tolerance: tolerance,
        maxOverscroll: maxOverscroll,
      );
    }
    return null;
  }
}

class _HybridScrollSimulation extends Simulation {
  _HybridScrollSimulation({
    required ScrollMetrics position,
    required double velocity,
    required Tolerance tolerance,
    required this.maxOverscroll,
  }) : _minExtent = position.minScrollExtent,
       _maxExtent = position.maxScrollExtent,
       _tolerance = tolerance {
    final currentPosition = position.pixels;
    final isOutOfBounds = currentPosition < _minExtent || currentPosition > _maxExtent;
    final isInOverscrollZone =
        (currentPosition >= _minExtent - maxOverscroll && currentPosition < _minExtent) ||
        (currentPosition > _maxExtent && currentPosition <= _maxExtent + maxOverscroll);

    if (isOutOfBounds || isInOverscrollZone) {
      _createBouncingSimulation(currentPosition, velocity);
    } else {
      _currentSimulation = ClampingScrollSimulation(position: currentPosition, velocity: velocity);
    }
  }

  final double _minExtent;
  final double _maxExtent;
  final double maxOverscroll;
  @override
  Tolerance get tolerance => _tolerance;
  final Tolerance _tolerance;

  late Simulation _currentSimulation;
  bool _hasSwitchedToBouncing = false;

  @override
  double x(double time) {
    final position = _currentSimulation.x(time);

    if (!_hasSwitchedToBouncing) {
      final wouldExceedBounds = position < _minExtent || position > _maxExtent;

      if (wouldExceedBounds) {
        _switchToBouncingSimulation(position, dx(time));
      }
    }

    return _currentSimulation.x(time);
  }

  @override
  double dx(double time) => _currentSimulation.dx(time);

  @override
  bool isDone(double time) => _currentSimulation.isDone(time);

  void _switchToBouncingSimulation(double position, double velocity) {
    _hasSwitchedToBouncing = true;
    _createBouncingSimulation(position, velocity);
  }

  void _createBouncingSimulation(double position, double velocity) {

    final spring = SpringDescription.withDampingRatio(mass: 0.3, stiffness: 1500.0, ratio: 3);

    _currentSimulation = BouncingScrollSimulation(
      spring: spring,
      position: position,
      velocity: velocity,
      leadingExtent: _minExtent,
      trailingExtent: _maxExtent,
      tolerance: tolerance,
    );
  }
}
