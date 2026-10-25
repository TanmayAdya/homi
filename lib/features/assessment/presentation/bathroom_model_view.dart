import 'dart:math' as math;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import '../../../app/theme.dart';
import 'package:safe_at_home/l10n/app_localizations.dart';

import '../domain/scan/bathroom_scan_scene.dart';
import '../domain/scan/scan_projection.dart';
import '../domain/scan/whole_home_model.dart';

class BathroomModelView extends StatefulWidget {
  const BathroomModelView({
    super.key,
    required this.scene,
    this.selectedId,
    this.selectedLabel,
    required this.onSelect,
    this.placedRooms,
    this.homeModel = false,
    this.markers,
  });
  final BathroomScanScene scene;
  final String? selectedId;

  final String? selectedLabel;
  final ValueChanged<String> onSelect;
  final List<PlacedRoomScene>? placedRooms;
  final bool homeModel;

  final Map<String, String>? markers;
  @override
  State<BathroomModelView> createState() => _BathroomModelViewState();
}

enum _ViewAction { left, right, front, zoomOut, zoomIn }

class _BathroomModelViewState extends State<BathroomModelView> {
  static const _yaw = -.65, _pitch = .55;
  double yaw = _yaw, pitch = _pitch, zoom = 1, startZoom = 1;
  bool top = false;
  Offset? tapStart;
  double travelled = 0;

  void _bind(
    _ModelGestureRecognizer recognizer,
    Size size,
    ScanProjection projection,
  ) {
    recognizer.onStart = (details) {
      startZoom = zoom;
      tapStart = details.localFocalPoint;
      travelled = 0;
    };
    recognizer.onUpdate = (details) {
      setState(() {
        travelled += details.focalPointDelta.distance;
        zoom = (startZoom * details.scale).clamp(.7, 2.5);
        if (details.pointerCount == 1 && travelled > kTouchSlop) {
          top = false;
          yaw += details.focalPointDelta.dx * .008;
          pitch = (pitch + details.focalPointDelta.dy * .008).clamp(
            -math.pi / 2,
            math.pi / 2,
          );
        }
      });
    };
    recognizer.onEnd = (_) {
      final start = tapStart;
      tapStart = null;
      if (start == null || travelled > kTouchSlop) return;
      final middle = size.center(Offset.zero);
      final at = (start - middle) / zoom + middle;
      for (final face in projection.faces.reversed) {
        if (_facePath(face).contains(at)) {
          widget.onSelect(face.elementId);
          return;
        }
      }
    };
  }

  void _act(_ViewAction action) => setState(() {
    switch (action) {
      case _ViewAction.left:
        top = false;
        yaw -= .3;
      case _ViewAction.right:
        top = false;
        yaw += .3;
      case _ViewAction.front:
        top = false;
        yaw = 0;
        pitch = 0;
      case _ViewAction.zoomOut:
        zoom = (zoom - .2).clamp(.7, 2.5);
      case _ViewAction.zoomIn:
        zoom = (zoom + .2).clamp(.7, 2.5);
    }
  });

  void _setTop(bool value) => setState(() {
    top = value;
    yaw = value ? 0 : _yaw;
    pitch = value ? math.pi / 2 : _pitch;
  });

  void _reset() => setState(() {
    top = false;
    yaw = _yaw;
    pitch = _pitch;
    zoom = 1;
  });

  static const _actionLabels = {
    _ViewAction.left: 'Rotate model left',
    _ViewAction.right: 'Rotate model right',
    _ViewAction.front: 'Front',
    _ViewAction.zoomOut: 'Zoom out',
    _ViewAction.zoomIn: 'Zoom in',
  };

  @override
  Widget build(BuildContext context) {
    final height = (MediaQuery.sizeOf(context).height * .5).clamp(280.0, 560.0);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(SahRadius.large),
          child: ColoredBox(
            color: const Color(0xFF123F3C),
            child: SizedBox(
              height: height,
              child: LayoutBuilder(
                builder: (context, bounds) {
                  final size = Size(bounds.maxWidth, height);
                  final projection = ScanProjection.project(
                    widget.scene,
                    width: size.width,
                    height: size.height,
                    yaw: yaw,
                    pitch: pitch,
                    placedRooms: widget.placedRooms,
                  );
                  return Semantics(
                    value: widget.selectedLabel == null
                        ? null
                        : context.tr('Selected: {label}', {
                            'label': widget.selectedLabel,
                          }),
                    label: context.tr(
                      widget.homeModel
                          ? 'Partial connected home model. Review room positions in the room list below. Unscanned space remains unknown.'
                          : 'Partial room model. {features} detected features and {samples} point samples. This model is optional. Use the feature list below to identify an item if needed.',
                      {
                        'features': widget.scene.elements.length,
                        'samples': widget.scene.points.length,
                      },
                    ),
                    customSemanticsActions: {
                      for (final e in _actionLabels.entries)
                        CustomSemanticsAction(label: context.tr(e.value)): () =>
                            _act(e.key),
                      CustomSemanticsAction(label: context.tr('Reset view')):
                          _reset,
                    },
                    child: RawGestureDetector(
                      gestures: {
                        _ModelGestureRecognizer:
                            GestureRecognizerFactoryWithHandlers<
                              _ModelGestureRecognizer
                            >(
                              _ModelGestureRecognizer.new,
                              (recognizer) =>
                                  _bind(recognizer, size, projection),
                            ),
                      },
                      child: CustomPaint(
                        painter: _ModelPainter(
                          projection,
                          widget.selectedId,
                          zoom,
                          widget.markers ?? const {},
                        ),
                        child: Align(
                          alignment: Alignment.topLeft,
                          child: Padding(
                            padding: EdgeInsets.all(16),
                            child: ExcludeSemantics(
                              child: Text(
                                context.tr(
                                  widget.homeModel
                                      ? 'CONNECTED HOME MODEL'
                                      : 'PARTIAL 3D MODEL',
                                ),
                                style: TextStyle(
                                  color: Color(0xFFD4E8DF),
                                  fontSize: 12,
                                  letterSpacing: 1.5,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            ChoiceButtons<bool>(
              key: const ValueKey('model-view-mode'),
              options: {false: context.tr('3D'), true: context.tr('Top-down')},
              selected: top,
              onSelected: _setTop,
            ),
            TextButton(
              key: const ValueKey('model-reset'),
              onPressed: _reset,
              child: Text(context.tr('Reset view')),
            ),
            PopupMenuButton<_ViewAction>(
              key: const ValueKey('model-more-controls'),
              tooltip: context.tr('More view controls'),
              onSelected: _act,
              itemBuilder: (ctx) => [
                for (final e in _actionLabels.entries)
                  PopupMenuItem(value: e.key, child: Text(ctx.tr(e.value))),
              ],
            ),
          ],
        ),
        Text(
          context.tr(
            'Drag to rotate · Pinch to zoom · Tap a feature\nEmpty space can mean unscanned space.',
          ),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }
}

class ChoiceButtons<T> extends StatelessWidget {
  const ChoiceButtons({
    super.key,
    required this.options,
    required this.selected,
    required this.onSelected,
  });
  final Map<T, String> options;
  final T? selected;
  final ValueChanged<T>? onSelected;

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 8,
    runSpacing: 8,
    children: [
      for (final MapEntry(:key, :value) in options.entries)
        Semantics(
          selected: key == selected,
          inMutuallyExclusiveGroup: true,
          child: key == selected
              ? FilledButton.tonalIcon(
                  onPressed: onSelected == null ? null : () {},
                  icon: MediaQuery.textScalerOf(context).scale(14) <= 21
                      ? const Icon(Icons.check)
                      : null,
                  label: Text(value),
                )
              : OutlinedButton(
                  onPressed: onSelected == null ? null : () => onSelected!(key),
                  child: Text(value),
                ),
        ),
    ],
  );
}

Path _facePath(ProjectedScanFace face) =>
    Path()
      ..addPolygon(face.vertices.map((p) => Offset(p.x, p.y)).toList(), true);

class _ModelPainter extends CustomPainter {
  _ModelPainter(this.projection, this.selectedId, this.zoom, this.markers);
  final ScanProjection projection;
  final String? selectedId;
  final double zoom;
  final Map<String, String> markers;
  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    canvas.translate(size.width / 2, size.height / 2);
    canvas.scale(zoom);
    canvas.translate(-size.width / 2, -size.height / 2);
    final grid = Paint()
      ..color = const Color(0xFF37615B)
      ..strokeWidth = .5;
    for (var x = 0.0; x < size.width; x += 32) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), grid);
    }
    for (var y = 0.0; y < size.height; y += 32) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }
    final points = Paint()..color = const Color(0xFF91C6B7);
    for (final p in projection.points) {
      canvas.drawCircle(Offset(p.x, p.y), .9 / zoom, points);
    }
    for (final face in projection.faces) {
      final selected = face.elementId == selectedId;
      final base = selected
          ? const Color(0xFFF2B48E)
          : switch (face.kind) {
              ScanElementKind.wall ||
              ScanElementKind.floor => const Color(0xFFAFCEBE),
              ScanElementKind.door ||
              ScanElementKind.opening => const Color(0xFFB7DDEE),
              _ => const Color(0xFFE2EBCB),
            };
      final path = _facePath(face);
      canvas.drawPath(
        path,
        Paint()..color = base.withValues(alpha: selected ? .65 : .16),
      );
      canvas.drawPath(
        path,
        Paint()
          ..color = base.withValues(alpha: selected ? 1 : .65)
          ..style = PaintingStyle.stroke
          ..strokeWidth = (selected ? 2 : 1) / zoom,
      );
    }
    for (var i = 0; i < projection.distances.length; i++) {
      final (start, end) = projection.distances[i];
      final a = Offset(start.x, start.y), b = Offset(end.x, end.y);
      final line = Paint()
        ..color = const Color(0xFFFFD66B)
        ..strokeWidth = 3 / zoom;
      canvas.drawLine(a, b, line);
      canvas.drawCircle(a, 4 / zoom, line);
      canvas.drawCircle(b, 4 / zoom, line);
      final label = TextPainter(
        text: TextSpan(
          text: '${i + 1}',
          style: TextStyle(
            color: const Color(0xFFFFD66B),
            backgroundColor: const Color(0xFF123F3C),
            fontSize: 16 / zoom,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      label.paint(canvas, (a + b) / 2);
      label.dispose();
    }
    final marked = <String>{};
    for (final face in projection.faces.reversed) {
      final text = markers[face.elementId];
      if (text == null || !marked.add(face.elementId)) continue;
      var centre = Offset.zero;
      for (final p in face.vertices) {
        centre += Offset(p.x, p.y);
      }
      centre /= face.vertices.length.toDouble();
      final selected = face.elementId == selectedId;
      canvas.drawCircle(
        centre,
        11 / zoom,
        Paint()
          ..color = selected
              ? const Color(0xFFF2B48E)
              : const Color(0xFFD4E8DF),
      );
      final label = TextPainter(
        text: TextSpan(
          text: text,
          style: TextStyle(
            color: const Color(0xFF123F3C),
            fontSize: 12 / zoom,
            fontWeight: FontWeight.w700,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      label.paint(canvas, centre - Offset(label.width / 2, label.height / 2));
      label.dispose();
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_ModelPainter oldDelegate) => true;
}

class _ModelGestureRecognizer extends ScaleGestureRecognizer {
  @override
  void addAllowedPointer(PointerDownEvent event) {
    super.addAllowedPointer(event);
    resolve(GestureDisposition.accepted);
  }
}
