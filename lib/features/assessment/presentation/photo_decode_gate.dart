import 'dart:typed_data';
import 'package:flutter/material.dart';

class PhotoDecodeGate extends StatefulWidget {
  const PhotoDecodeGate({
    super.key,
    required this.bytes,
    required this.builder,
    this.onChanged,
  });
  final Uint8List? bytes;
  final Widget Function(BuildContext context, bool ready, bool failed) builder;
  final ValueChanged<bool>? onChanged;
  @override
  State<PhotoDecodeGate> createState() => _PhotoDecodeGateState();
}

class _PhotoDecodeGateState extends State<PhotoDecodeGate> {
  ImageStream? _stream;
  ImageStreamListener? _listener;
  bool ready = false, failed = false;
  int generation = 0;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _watch();
  }

  @override
  void didUpdateWidget(PhotoDecodeGate oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.bytes, widget.bytes)) _watch();
  }

  void _report(bool value, int at) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && generation == at) widget.onChanged?.call(value);
    });
  }

  void _watch() {
    _stop();
    final at = ++generation;
    ready = false;
    failed = false;
    _report(false, at);
    final bytes = widget.bytes;
    if (bytes == null) return;
    final stream = ResizeImage.resizeIfNeeded(
      1024,
      null,
      MemoryImage(bytes),
    ).resolve(createLocalImageConfiguration(context));
    _stream = stream;
    final listener = ImageStreamListener(
      (info, _) {
        info.dispose();
        if (!mounted || !identical(_stream, stream)) return;
        setState(() {
          ready = true;
          failed = false;
        });
        _report(true, at);
      },
      onError: (Object _, StackTrace? _) {
        if (!mounted || !identical(_stream, stream)) return;
        setState(() {
          ready = false;
          failed = true;
        });
        _report(false, at);
      },
    );
    _listener = listener;
    stream.addListener(listener);
  }

  void _stop() {
    final listener = _listener;
    if (listener != null) _stream?.removeListener(listener);
    _stream = null;
    _listener = null;
  }

  @override
  void dispose() {
    generation++;
    _stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, ready, failed);
}
