import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../domain/annotation/box_annotation.dart';

class AnnotationEditorScreen extends StatefulWidget {
  const AnnotationEditorScreen({
    super.key,
    required this.store,
    required this.findingId,
    required this.image,
    required this.bytes,
    required this.observation,
  });

  final AnnotationStore store;
  final String findingId;
  final AnnotatedImage image;
  final Uint8List bytes;

  final String observation;

  @override
  State<AnnotationEditorScreen> createState() => _AnnotationEditorScreenState();
}

class _AnnotationEditorScreenState extends State<AnnotationEditorScreen> {
  late final TextEditingController _label = TextEditingController(
    text: _box?.label ?? '',
  );

  static const double _step = 0.05;

  BoxAnnotation? get _box {
    for (final BoxAnnotation b in widget.store.on(widget.image)) {
      if (b.findingId == widget.findingId) return b;
    }
    return null;
  }

  @override
  void dispose() {
    _label.dispose();
    super.dispose();
  }

  void _apply(void Function(String id) edit) {
    final BoxAnnotation? box = _box;
    if (box == null) return;
    setState(() => edit(box.id));
  }

  @override
  Widget build(BuildContext context) {
    final BoxAnnotation? box = _box;
    final List<BoxAnnotation> stale = widget.store
        .staleFor(widget.image.evidenceId)
        .where((b) => b.findingId == widget.findingId)
        .toList();
    final double dx = widget.image.width * _step;
    final double dy = widget.image.height * _step;

    return Scaffold(
      appBar: AppBar(title: const Text('Mark the area')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Draw a box around the part your observation is about. The '
                'box only points to it; it does not measure anything. Marks '
                'stay on this phone and are not added to the draft PDF.',
              ),
              const SizedBox(height: 8),
              Text('Your observation: ${widget.observation.trim()}'),
              if (stale.isNotEmpty) ...[
                const SizedBox(height: 8),
                Semantics(
                  liveRegion: true,
                  child: Text(
                    'This photo changed, so ${stale.length} earlier '
                    '${stale.length == 1 ? 'mark no longer applies' : 'marks no longer apply'}. '
                    'Remove ${stale.length == 1 ? 'it' : 'them'} and add a new '
                    'mark if you need one.',
                  ),
                ),
                TextButton(
                  onPressed: () => setState(() {
                    for (final BoxAnnotation b in stale) {
                      widget.store.remove(b.id);
                    }
                  }),
                  child: const Text('Remove old marks'),
                ),
              ],
              const SizedBox(height: 12),
              AspectRatio(
                aspectRatio: widget.image.width / widget.image.height,
                child: LayoutBuilder(
                  builder: (context, constraints) => _canvas(
                    box,
                    ImageViewport(
                      imageWidth: widget.image.width,
                      imageHeight: widget.image.height,
                      viewWidth: constraints.maxWidth,
                      viewHeight: constraints.maxHeight,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              if (box == null)
                FilledButton(
                  onPressed: () => setState(() {
                    widget.store.add(
                      findingId: widget.findingId,
                      image: widget.image,
                    );
                  }),
                  child: const Text('Add a box'),
                )
              else ...[
                TextField(
                  key: const ValueKey('annotation-label'),
                  controller: _label,
                  decoration: const InputDecoration(
                    labelText: 'What does the box show? (optional)',
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (text) =>
                      _apply((id) => widget.store.setLabel(id, text)),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  alignment: WrapAlignment.center,
                  children: [
                    _control(
                      Icons.arrow_back,
                      'Move left',
                      () => _apply((id) => widget.store.move(id, -dx, 0)),
                    ),
                    _control(
                      Icons.arrow_forward,
                      'Move right',
                      () => _apply((id) => widget.store.move(id, dx, 0)),
                    ),
                    _control(
                      Icons.arrow_upward,
                      'Move up',
                      () => _apply((id) => widget.store.move(id, 0, -dy)),
                    ),
                    _control(
                      Icons.arrow_downward,
                      'Move down',
                      () => _apply((id) => widget.store.move(id, 0, dy)),
                    ),
                    _control(
                      Icons.zoom_out_map,
                      'Make bigger',
                      () => _apply((id) => widget.store.resize(id, dx, dy)),
                    ),
                    _control(
                      Icons.zoom_in_map,
                      'Make smaller',
                      () => _apply((id) => widget.store.resize(id, -dx, -dy)),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                OutlinedButton(
                  onPressed: () => setState(
                    () => widget.store.setHidden(box.id, !box.hidden),
                  ),
                  child: Text(box.hidden ? 'Show the box' : 'Hide the box'),
                ),
                const SizedBox(height: 8),
                OutlinedButton(
                  onPressed: () => setState(() {
                    widget.store.remove(box.id);
                    _label.clear();
                  }),
                  child: const Text('Remove the box'),
                ),
              ],
              const SizedBox(height: 8),
              FilledButton.tonal(
                onPressed: () => Navigator.of(context).maybePop(),
                child: const Text('Done'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _canvas(BoxAnnotation? box, ImageViewport viewport) {
    final ImageRect? view = box == null || box.hidden
        ? null
        : viewport.rectToView(box.rect);
    return Stack(
      fit: StackFit.expand,
      children: [
        Image.memory(
          widget.bytes,
          fit: BoxFit.contain,
          semanticLabel: 'Photo to mark',
          errorBuilder: (_, _, _) =>
              const Center(child: Text('Preview unavailable')),
        ),
        if (view != null) ...[
          Positioned(
            left: view.left,
            top: view.top,
            width: view.width,
            height: view.height,
            child: Semantics(
              label: box!.label.isEmpty
                  ? 'Marked area'
                  : 'Marked area: ${box.label}',
              child: GestureDetector(
                key: const ValueKey('annotation-box'),
                dragStartBehavior: DragStartBehavior.down,
                onPanUpdate: (d) => _apply(
                  (id) => widget.store.move(
                    id,
                    viewport.toImageDistance(d.delta.dx),
                    viewport.toImageDistance(d.delta.dy),
                  ),
                ),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    border: Border.all(color: Colors.amber, width: 3),
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            left: view.right - 24,
            top: view.bottom - 24,
            width: 48,
            height: 48,
            child: GestureDetector(
              key: const ValueKey('annotation-resize'),
              dragStartBehavior: DragStartBehavior.down,
              onPanUpdate: (d) => _apply((id) {
                final ImageRect r = widget.store[id]!.rect;
                widget.store.setRect(
                  id,
                  ImageRect(
                    r.left,
                    r.top,
                    r.width + viewport.toImageDistance(d.delta.dx),
                    r.height + viewport.toImageDistance(d.delta.dy),
                  ),
                );
              }),
              child: const Center(
                child: Icon(Icons.open_in_full, color: Colors.amber),
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _control(IconData icon, String label, VoidCallback onPressed) =>
      IconButton.outlined(
        onPressed: onPressed,
        icon: Icon(icon),
        tooltip: label,
      );
}
