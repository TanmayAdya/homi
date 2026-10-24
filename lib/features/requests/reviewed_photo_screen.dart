import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../../shared/presentation/sah_components.dart';
import '../assessment/presentation/saved_photo_with_marks.dart';

class ReviewedPhotoScreen extends StatefulWidget {
  const ReviewedPhotoScreen({
    super.key,
    required this.bytes,
    required this.width,
    required this.height,
    required this.marks,
  });

  final Uint8List bytes;
  final int width, height;
  final List<Map<String, Object?>> marks;

  @override
  State<ReviewedPhotoScreen> createState() => _ReviewedPhotoScreenState();
}

class _ReviewedPhotoScreenState extends State<ReviewedPhotoScreen> {
  ImageStream? _imageStream;
  ImageStreamListener? _imageListener;
  bool _decoded = false, _failed = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _watchImage();
  }

  @override
  void didUpdateWidget(ReviewedPhotoScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.bytes, widget.bytes)) _watchImage();
  }

  void _watchImage() {
    _stopWatching();
    _decoded = false;
    _failed = false;
    final stream = ResizeImage.resizeIfNeeded(
      1024,
      null,
      MemoryImage(widget.bytes),
    ).resolve(createLocalImageConfiguration(context));
    _imageStream = stream;
    final listener = ImageStreamListener(
      (info, _) {
        info.dispose();
        if (mounted && identical(_imageStream, stream)) {
          setState(() => _decoded = true);
        }
      },
      onError: (Object error, StackTrace? stack) {
        if (mounted && identical(_imageStream, stream)) {
          setState(() {
            _decoded = false;
            _failed = true;
          });
        }
      },
    );
    _imageListener = listener;
    stream.addListener(listener);
  }

  void _stopWatching() {
    final listener = _imageListener;
    if (listener != null) _imageStream?.removeListener(listener);
    _imageStream = null;
    _imageListener = null;
  }

  @override
  void dispose() {
    _stopWatching();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Review private photo')),
    body: SafeArea(
      child: LayoutBuilder(
        builder: (context, constraints) => SahContent(
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              const SahPageHeader(
                title: 'Check this attachment',
                description:
                    'Review the saved photo and its notes. Pinch to zoom in on details.',
              ),
              SizedBox(
                height: (constraints.maxHeight * .55).clamp(240, 480),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: ColoredBox(
                    color: Theme.of(context).colorScheme.surfaceContainer,
                    child: InteractiveViewer(
                      minScale: 1,
                      maxScale: 5,
                      child: Center(
                        child: SavedPhotoWithMarks(
                          bytes: widget.bytes,
                          width: widget.width,
                          height: widget.height,
                          marks: widget.marks,
                          semanticLabel: 'Saved photo with observations',
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              if (_failed)
                const SahNotice(
                  message:
                      'This photo could not be opened for review. Leave it out, then reload the draft to try again.',
                  tone: SahNoticeTone.error,
                )
              else if (!_decoded)
                const LinearProgressIndicator(
                  semanticsLabel: 'Opening saved photo',
                ),
              if (widget.marks.any(
                (mark) => (mark['label'] as String).isNotEmpty,
              )) ...[
                const SahSectionHeading(title: 'Photo notes'),
                for (final mark in widget.marks)
                  if ((mark['label'] as String).isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Text(mark['label'] as String),
                    ),
              ],
              const SahNotice(
                message:
                    'Include only information you want in this draft. Marks are observations, not a professional assessment.',
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: _decoded && !_failed
                    ? () => Navigator.of(context).pop(true)
                    : null,
                icon: const Icon(Icons.check_rounded),
                label: const Text('Include this reviewed photo'),
              ),
              const SizedBox(height: 12),
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('Leave this photo out'),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
