import 'dart:typed_data';
import 'package:flutter/material.dart';

class SavedPhotoWithMarks extends StatelessWidget {
  const SavedPhotoWithMarks({
    super.key,
    required this.bytes,
    required this.width,
    required this.height,
    required this.marks,
    this.semanticLabel = 'Saved photo with observations',
  });
  final Uint8List bytes;
  final int width, height;
  final List<Map<String, Object?>> marks;
  final String semanticLabel;
  @override
  Widget build(BuildContext context) => Semantics(
    label:
        '$semanticLabel. ${marks.map((m) => m['label']).where((l) => l != '').join('. ')}',
    child: AspectRatio(
      aspectRatio: width / height,
      child: LayoutBuilder(
        builder: (context, constraints) => ClipRect(
          child: Stack(
            fit: StackFit.expand,
            children: [
              Image.memory(
                bytes,
                cacheWidth: 1024,
                fit: BoxFit.contain,
                errorBuilder: (_, _, _) =>
                    const Center(child: Text('Photo preview unavailable')),
              ),
              for (final mark in marks) _mark(mark, constraints),
            ],
          ),
        ),
      ),
    ),
  );
  Widget _mark(Map<String, Object?> mark, BoxConstraints constraints) {
    final rect = (mark['rect'] as List).cast<num>();
    final x = rect[0] / 1000000 * constraints.maxWidth;
    final y = rect[1] / 1000000 * constraints.maxHeight;
    final w = rect[2] / 1000000 * constraints.maxWidth;
    final h = rect[3] / 1000000 * constraints.maxHeight;
    final label = mark['label'] as String;
    return Positioned(
      left: x,
      top: y,
      width: w,
      height: h,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border.all(color: Colors.amber, width: 3),
        ),
        child: label.isEmpty
            ? null
            : Align(
                alignment: Alignment.topLeft,
                child: Container(
                  color: Colors.black87,
                  padding: const EdgeInsets.all(3),
                  child: Text(
                    label,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white, fontSize: 13),
                  ),
                ),
              ),
      ),
    );
  }
}
