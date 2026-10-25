import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../../app/theme.dart';
import 'package:safe_at_home/l10n/app_localizations.dart';
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
    appBar: AppBar(title: Text(context.tr('Review private photo'))),
    body: SafeArea(
      child: LayoutBuilder(
        builder: (context, constraints) => SahContent(
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              SahPageHeader(title: context.tr('Check this attachment')),
              SizedBox(
                height: (constraints.maxHeight * .55).clamp(240, 480),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(SahRadius.large),
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
                          semanticLabel: context.tr(
                            'Saved photo with observations',
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              if (_failed)
                SahNotice(
                  message: context.tr(
                    'This photo could not be opened for review. Leave it out, then reload the draft to try again.',
                  ),
                  tone: SahNoticeTone.error,
                )
              else if (!_decoded)
                LinearProgressIndicator(
                  semanticsLabel: context.tr('Opening saved photo'),
                ),
              if (widget.marks.any(
                (mark) => (mark['label'] as String).isNotEmpty,
              )) ...[
                SahSectionHeading(title: context.tr('Photo notes')),
                for (final mark in widget.marks)
                  if ((mark['label'] as String).isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Text(mark['label'] as String),
                    ),
              ],
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: _decoded && !_failed
                    ? () => Navigator.of(context).pop(true)
                    : null,
                icon: const Icon(Icons.check_rounded),
                label: Text(context.tr('Include this reviewed photo')),
              ),
              const SizedBox(height: 12),
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: Text(context.tr('Leave this photo out')),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
