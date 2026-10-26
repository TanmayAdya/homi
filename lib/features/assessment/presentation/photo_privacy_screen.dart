import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:safe_at_home/l10n/app_localizations.dart';
import '../../../shared/presentation/sah_components.dart';
import '../domain/image/image_validator.dart';
import '../domain/image/private_media_platform.dart';
import 'photo_decode_gate.dart';

class PhotoPrivacyScreen extends StatefulWidget {
  const PhotoPrivacyScreen({
    super.key,
    required this.bytes,
    this.media = const PrivateMediaPlatform(),
  });
  final Uint8List bytes;
  final PrivateMediaPlatform media;
  @override
  State<PhotoPrivacyScreen> createState() => _PhotoPrivacyScreenState();
}

class _PhotoPrivacyScreenState extends State<PhotoPrivacyScreen> {
  Rect selection = const Rect.fromLTWH(.2, .2, .4, .4);
  Rect? crop;
  final List<Rect> covers = [];
  bool busy = false;
  bool _canEdit = false;
  String? error;
  List<double> wire(Rect r) => [r.left, r.top, r.width, r.height];

  void updateEdits(VoidCallback action) {
    if (busy || !_canEdit) return;
    setState(action);
  }

  void adjust({double x = 0, double y = 0, double w = 0, double h = 0}) {
    if (busy || !_canEdit) return;
    setState(() {
      final width = (selection.width + w).clamp(.02, 1.0);
      final height = (selection.height + h).clamp(.02, 1.0);
      selection = Rect.fromLTWH(
        (selection.left + x).clamp(0, 1 - width),
        (selection.top + y).clamp(0, 1 - height),
        width,
        height,
      );
    });
  }

  Future<void> apply() async {
    if (busy || !_canEdit || (covers.isEmpty && crop == null)) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final bytes = await widget.media.edit(
        widget.bytes,
        crop: crop == null ? null : wire(crop!),
        redactions: covers.map(wire).toList(),
      );
      if (mounted) Navigator.of(context).pop(bytes);
    } catch (_) {
      if (mounted) {
        setState(() {
          busy = false;
          error =
              'The edit could not be applied. Your original photo and selected edits are still available. Try again.';
        });
      }
    }
  }

  Widget control(IconData icon, String label, VoidCallback action) =>
      IconButton.outlined(
        tooltip: label,
        constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
        onPressed: busy || !_canEdit ? null : action,
        icon: Icon(icon),
      );

  @override
  Widget build(BuildContext context) => PhotoDecodeGate(
    bytes: widget.bytes,
    builder: (context, ready, failed) {
      _canEdit = ready;
      return _editor(context, ready, failed);
    },
  );

  Widget _editor(BuildContext context, bool ready, bool failed) {
    final info = const ImageValidator().check(widget.bytes);
    if (info is! ImageAccepted) {
      return Scaffold(
        appBar: AppBar(title: Text(context.tr('Remove private details'))),
        body: SafeArea(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: SahNotice(
              message: context.tr(
                'This photo could not be opened. Go back to choose another photo.',
              ),
              tone: SahNoticeTone.error,
            ),
          ),
        ),
      );
    }
    final description = context.tr(
      'Selected area: left {left}%, top {top}%, width {width}%, height {height}%.',
      {
        'left': (selection.left * 100).round(),
        'top': (selection.top * 100).round(),
        'width': (selection.width * 100).round(),
        'height': (selection.height * 100).round(),
      },
    );
    return PopScope(
      canPop: !busy,
      child: Scaffold(
        appBar: AppBar(title: Text(context.tr('Remove private details'))),
        body: SafeArea(
          child: SahContent(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SahPageHeader(title: context.tr('Cover private details')),
                  if (failed)
                    SahNotice(
                      message: context.tr(
                        'The photo preview could not be opened. Your selected edits are kept. Go back and reopen the photo before changing or applying them.',
                      ),
                      tone: SahNoticeTone.error,
                    )
                  else if (!ready)
                    LinearProgressIndicator(
                      semanticsLabel: context.tr(
                        'Opening photo before privacy edits',
                      ),
                    ),
                  AspectRatio(
                    aspectRatio: info.width / info.height,
                    child: LayoutBuilder(
                      builder: (context, constraints) => Stack(
                        fit: StackFit.expand,
                        children: [
                          Image.memory(
                            widget.bytes,
                            fit: BoxFit.fill,
                            cacheWidth: 1024,
                            semanticLabel: context.tr(
                              'Photo before privacy edits',
                            ),
                            errorBuilder: (_, _, _) => Center(
                              child: Text(context.tr('Preview unavailable')),
                            ),
                          ),
                          if (ready)
                            for (final r in covers)
                              Positioned(
                                left: r.left * constraints.maxWidth,
                                top: r.top * constraints.maxHeight,
                                width: r.width * constraints.maxWidth,
                                height: r.height * constraints.maxHeight,
                                child: const ColoredBox(color: Colors.black),
                              ),
                          if (ready)
                            if (crop case final r?)
                              Positioned(
                                left: r.left * constraints.maxWidth,
                                top: r.top * constraints.maxHeight,
                                width: r.width * constraints.maxWidth,
                                height: r.height * constraints.maxHeight,
                                child: IgnorePointer(
                                  child: DecoratedBox(
                                    decoration: BoxDecoration(
                                      border: Border.all(
                                        color: Colors.white,
                                        width: 2,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                          if (ready)
                            Positioned(
                              left: selection.left * constraints.maxWidth,
                              top: selection.top * constraints.maxHeight,
                              width: selection.width * constraints.maxWidth,
                              height: selection.height * constraints.maxHeight,
                              child: Semantics(
                                label: description,
                                child: GestureDetector(
                                  key: const ValueKey('privacy-selection'),
                                  onPanUpdate: busy
                                      ? null
                                      : (d) => adjust(
                                          x: d.delta.dx / constraints.maxWidth,
                                          y: d.delta.dy / constraints.maxHeight,
                                        ),
                                  child: DecoratedBox(
                                    decoration: BoxDecoration(
                                      border: Border.all(
                                        color: Colors.white,
                                        width: 5,
                                      ),
                                    ),
                                    child: Padding(
                                      padding: const EdgeInsets.all(2),
                                      child: DecoratedBox(
                                        decoration: BoxDecoration(
                                          border: Border.all(
                                            color: Theme.of(
                                              context,
                                            ).colorScheme.primary,
                                            width: 2,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  SizedBox(height: 12),
                  Text(description),
                  SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      control(
                        Icons.arrow_back,
                        context.tr('Move left'),
                        () => adjust(x: -.025),
                      ),
                      control(
                        Icons.arrow_forward,
                        context.tr('Move right'),
                        () => adjust(x: .025),
                      ),
                      control(
                        Icons.arrow_upward,
                        context.tr('Move up'),
                        () => adjust(y: -.025),
                      ),
                      control(
                        Icons.arrow_downward,
                        context.tr('Move down'),
                        () => adjust(y: .025),
                      ),
                      control(
                        Icons.unfold_more,
                        context.tr('Make taller'),
                        () => adjust(h: .025),
                      ),
                      control(
                        Icons.unfold_less,
                        context.tr('Make shorter'),
                        () => adjust(h: -.025),
                      ),
                      control(
                        Icons.swap_horiz,
                        context.tr('Make wider'),
                        () => adjust(w: .025),
                      ),
                      control(
                        Icons.compress,
                        context.tr('Make narrower'),
                        () => adjust(w: -.025),
                      ),
                    ],
                  ),
                  SizedBox(height: 16),
                  Semantics(
                    liveRegion: true,
                    child: Text(
                      context.tr(
                        '{count} of 20 solid covers added. {cropStatus}',
                        {
                          'count': covers.length,
                          'cropStatus': context.tr(
                            crop == null
                                ? 'The full photo will be kept.'
                                : 'Only the selected crop will be kept.',
                          ),
                        },
                      ),
                    ),
                  ),
                  SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: busy || !ready || covers.length >= 20
                        ? null
                        : () => updateEdits(() => covers.add(selection)),
                    icon: const Icon(Icons.privacy_tip_outlined),
                    label: Text(context.tr('Add opaque cover')),
                  ),
                  if (covers.isNotEmpty)
                    TextButton.icon(
                      onPressed: busy || !ready
                          ? null
                          : () => updateEdits(() => covers.removeLast()),
                      icon: const Icon(Icons.undo),
                      label: Text(context.tr('Undo last cover')),
                    ),
                  OutlinedButton.icon(
                    onPressed: busy || !ready
                        ? null
                        : () => updateEdits(() => crop = selection),
                    icon: const Icon(Icons.crop),
                    label: Text(context.tr('Crop to outlined area')),
                  ),
                  if (crop != null)
                    TextButton(
                      onPressed: busy || !ready
                          ? null
                          : () => updateEdits(() => crop = null),
                      child: Text(context.tr('Keep full photo')),
                    ),
                  TextButton(
                    onPressed:
                        busy || !ready || (covers.isEmpty && crop == null)
                        ? null
                        : () => updateEdits(() {
                            covers.clear();
                            crop = null;
                          }),
                    child: Text(context.tr('Clear edits')),
                  ),
                  if (error != null) ...[
                    Semantics(
                      liveRegion: true,
                      child: SahNotice(
                        message: context.tr(error!),
                        tone: SahNoticeTone.error,
                      ),
                    ),
                    SizedBox(height: 12),
                  ],
                  FilledButton(
                    onPressed:
                        busy || !ready || (covers.isEmpty && crop == null)
                        ? null
                        : apply,
                    child: Text(
                      busy
                          ? context.tr('Applying…')
                          : context.tr('Apply and review photo'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
