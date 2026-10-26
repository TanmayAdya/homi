import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:safe_at_home/l10n/app_localizations.dart';

import '../domain/annotation/box_annotation.dart';
import 'photo_decode_gate.dart';

class AnnotationEditorScreen extends StatefulWidget {
  const AnnotationEditorScreen({
    super.key,
    required this.store,
    required this.findingId,
    required this.image,
    required this.bytes,
    required this.observation,
    this.onChanged,
  });

  final AnnotationStore store;
  final String findingId;
  final AnnotatedImage image;
  final Uint8List bytes;

  final String observation;

  final VoidCallback? onChanged;

  @override
  State<AnnotationEditorScreen> createState() => _AnnotationEditorScreenState();
}

class _AnnotationEditorScreenState extends State<AnnotationEditorScreen> {
  bool _canEdit = false;
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
    if (!_canEdit) return;
    final BoxAnnotation? box = _box;
    if (box == null) return;
    setState(() => edit(box.id));
    widget.onChanged?.call();
  }

  @override
  Widget build(BuildContext context) => PhotoDecodeGate(
    bytes: widget.bytes,
    builder: (context, ready, failed) {
      _canEdit = ready;
      return _editor(context, ready, failed);
    },
  );
  Widget _editor(BuildContext context, bool ready, bool failed) {
    final BoxAnnotation? box = _box;
    final List<BoxAnnotation> stale = widget.store
        .staleFor(widget.image.evidenceId)
        .where((b) => b.findingId == widget.findingId)
        .toList();
    final double dx = widget.image.width * _step;
    final double dy = widget.image.height * _step;

    return Scaffold(
      appBar: AppBar(title: Text(context.tr('Mark the area'))),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                context.tr(
                  'Draw a box around the part your observation is about. The box only points to it; it does not measure anything. Save marks online, then review them with the photo before including it in a draft PDF.',
                ),
              ),
              SizedBox(height: 8),
              Text(
                context.tr('Your observation: {observation}', {
                  'observation': widget.observation.trim(),
                }),
              ),
              if (failed)
                Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: Text(
                    context.tr(
                      'This photo could not be opened. Existing marks are retained. Go back and reload the saved photo before editing marks.',
                    ),
                  ),
                )
              else if (!ready)
                LinearProgressIndicator(
                  semanticsLabel: context.tr('Opening photo before marking'),
                ),
              if (stale.isNotEmpty) ...[
                SizedBox(height: 8),
                Semantics(
                  liveRegion: true,
                  child: Text(
                    context.tr(
                      stale.length == 1
                          ? 'This photo changed, so {count} earlier mark no longer applies. Remove it and add a new mark if you need one.'
                          : 'This photo changed, so {count} earlier marks no longer apply. Remove them and add a new mark if you need one.',
                      {'count': stale.length},
                    ),
                  ),
                ),
                TextButton(
                  onPressed: !ready
                      ? null
                      : () {
                          setState(() {
                            for (final BoxAnnotation b in stale) {
                              widget.store.remove(b.id);
                            }
                          });
                          widget.onChanged?.call();
                        },
                  child: Text(context.tr('Remove old marks')),
                ),
              ],
              SizedBox(height: 12),
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
              SizedBox(height: 12),
              if (box == null)
                FilledButton(
                  onPressed: !ready
                      ? null
                      : () {
                          setState(() {
                            widget.store.add(
                              findingId: widget.findingId,
                              image: widget.image,
                            );
                          });
                          widget.onChanged?.call();
                        },
                  child: Text(context.tr('Add a box')),
                )
              else ...[
                TextField(
                  key: const ValueKey('annotation-label'),
                  enabled: ready,
                  controller: _label,
                  maxLength: 80,
                  decoration: InputDecoration(
                    labelText: context.tr('What does the box show? (optional)'),
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (text) =>
                      _apply((id) => widget.store.setLabel(id, text)),
                ),
                SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  alignment: WrapAlignment.center,
                  children: [
                    _control(
                      Icons.arrow_back,
                      context.tr('Move left'),
                      () => _apply((id) => widget.store.move(id, -dx, 0)),
                    ),
                    _control(
                      Icons.arrow_forward,
                      context.tr('Move right'),
                      () => _apply((id) => widget.store.move(id, dx, 0)),
                    ),
                    _control(
                      Icons.arrow_upward,
                      context.tr('Move up'),
                      () => _apply((id) => widget.store.move(id, 0, -dy)),
                    ),
                    _control(
                      Icons.arrow_downward,
                      context.tr('Move down'),
                      () => _apply((id) => widget.store.move(id, 0, dy)),
                    ),
                    _control(
                      Icons.zoom_out_map,
                      context.tr('Make bigger'),
                      () => _apply((id) => widget.store.resize(id, dx, dy)),
                    ),
                    _control(
                      Icons.zoom_in_map,
                      context.tr('Make smaller'),
                      () => _apply((id) => widget.store.resize(id, -dx, -dy)),
                    ),
                  ],
                ),
                SizedBox(height: 8),
                OutlinedButton(
                  onPressed: !ready
                      ? null
                      : () => _apply(
                          (id) => widget.store.setHidden(id, !box.hidden),
                        ),
                  child: Text(
                    box.hidden
                        ? context.tr('Show the box')
                        : context.tr('Hide the box'),
                  ),
                ),
                SizedBox(height: 8),
                OutlinedButton(
                  onPressed: !ready
                      ? null
                      : () {
                          setState(() {
                            widget.store.remove(box.id);
                            _label.clear();
                          });
                          widget.onChanged?.call();
                        },
                  child: Text(context.tr('Remove the box')),
                ),
              ],
              SizedBox(height: 8),
              FilledButton.tonal(
                onPressed: () => Navigator.of(context).maybePop(),
                child: Text(context.tr('Done')),
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
          cacheWidth: 1024,
          fit: BoxFit.contain,
          semanticLabel: context.tr('Photo to mark'),
          errorBuilder: (_, _, _) =>
              Center(child: Text(context.tr('Preview unavailable'))),
        ),
        if (view != null) ...[
          Positioned(
            left: view.left,
            top: view.top,
            width: view.width,
            height: view.height,
            child: Semantics(
              label: box!.label.isEmpty
                  ? context.tr('Marked area')
                  : context.tr('Marked area: {label}', {'label': box.label}),
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
              child: Center(
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
        onPressed: _canEdit ? onPressed : null,
        icon: Icon(icon),
        tooltip: label,
      );
}
