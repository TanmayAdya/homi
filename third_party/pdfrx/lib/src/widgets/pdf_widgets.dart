import 'dart:async';
import 'dart:developer' as developer;
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:pdfrx_engine/pdfrx_engine.dart';

import '../pdf_document_ref.dart';
import '../pdfrx_flutter.dart';

class PdfDocumentViewBuilder extends StatefulWidget {
  const PdfDocumentViewBuilder({
    required this.documentRef,
    required this.builder,
    this.loadingBuilder,
    this.errorBuilder,
    super.key,
  });

  PdfDocumentViewBuilder.asset(
    String assetName, {
    required this.builder,
    this.loadingBuilder,
    this.errorBuilder,
    super.key,
    PdfPasswordProvider? passwordProvider,
    bool firstAttemptByEmptyPassword = true,
    bool useProgressiveLoading = false,
    bool autoDispose = true,
  }) : documentRef = PdfDocumentRefAsset(
         assetName,
         passwordProvider: passwordProvider,
         firstAttemptByEmptyPassword: firstAttemptByEmptyPassword,
         useProgressiveLoading: useProgressiveLoading,
         autoDispose: autoDispose,
       );

  PdfDocumentViewBuilder.file(
    String filePath, {
    required this.builder,
    this.loadingBuilder,
    this.errorBuilder,
    super.key,
    PdfPasswordProvider? passwordProvider,
    bool firstAttemptByEmptyPassword = true,
    bool useProgressiveLoading = false,
    bool autoDispose = true,
  }) : documentRef = PdfDocumentRefFile(
         filePath,
         passwordProvider: passwordProvider,
         firstAttemptByEmptyPassword: firstAttemptByEmptyPassword,
         useProgressiveLoading: useProgressiveLoading,
         autoDispose: autoDispose,
       );

  PdfDocumentViewBuilder.uri(
    Uri uri, {
    required this.builder,
    this.loadingBuilder,
    this.errorBuilder,
    super.key,
    PdfPasswordProvider? passwordProvider,
    bool firstAttemptByEmptyPassword = true,
    bool useProgressiveLoading = false,
    bool autoDispose = true,
    bool preferRangeAccess = false,
    Map<String, String>? headers,
    bool withCredentials = false,
  }) : documentRef = PdfDocumentRefUri(
         uri,
         passwordProvider: passwordProvider,
         firstAttemptByEmptyPassword: firstAttemptByEmptyPassword,
         useProgressiveLoading: useProgressiveLoading,
         autoDispose: autoDispose,
         preferRangeAccess: preferRangeAccess,
         headers: headers,
         withCredentials: withCredentials,
       );

  final PdfDocumentRef documentRef;

  final PdfDocumentViewBuilderFunction builder;

  final WidgetBuilder? loadingBuilder;

  final PdfDocumentViewBuilderErrorBuilder? errorBuilder;

  @override
  State<PdfDocumentViewBuilder> createState() => _PdfDocumentViewBuilderState();
}

typedef PdfDocumentViewBuilderErrorBuilder =
    Widget Function(BuildContext context, Object error, StackTrace? stackTrace);

class _PdfDocumentViewBuilderState extends State<PdfDocumentViewBuilder> {
  StreamSubscription<PdfDocumentEvent>? _updateSubscription;

  @override
  void initState() {
    super.initState();
    pdfrxFlutterInitialize();
    widget.documentRef.resolveListenable()
      ..addListener(_onDocumentChanged)
      ..load();
    _onDocumentChanged();
  }

  @override
  void didUpdateWidget(covariant PdfDocumentViewBuilder oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.documentRef != oldWidget.documentRef) {
      oldWidget.documentRef.resolveListenable().removeListener(_onDocumentChanged);
      widget.documentRef.resolveListenable()
        ..addListener(_onDocumentChanged)
        ..load();
      _onDocumentChanged();
    }
  }

  @override
  void dispose() {
    _updateSubscription?.cancel();
    widget.documentRef.resolveListenable().removeListener(_onDocumentChanged);
    super.dispose();
  }

  void _onDocumentChanged() {
    if (mounted) {
      _updateSubscription?.cancel();
      final document = widget.documentRef.resolveListenable().document;
      _updateSubscription = document?.events.listen((event) {
        if (mounted && event.type == PdfDocumentEventType.pageStatusChanged) {
          setState(() {});
        }
      });
      document?.loadPagesProgressively();
      if (mounted) setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final listenable = widget.documentRef.resolveListenable();

    if (listenable.error != null && widget.errorBuilder != null) {
      return widget.errorBuilder!(context, listenable.error!, listenable.stackTrace);
    }

    if (listenable.document == null && widget.loadingBuilder != null) {
      return widget.loadingBuilder!(context);
    }

    return widget.builder(context, listenable.document);
  }
}

typedef PdfDocumentViewBuilderFunction = Widget Function(BuildContext context, PdfDocument? document);

typedef PdfPageViewSizeCallback = Size Function(Size biggestSize, PdfPage page, PdfPageRotation? rotationOverride);

typedef PdfPageViewDecorationBuilder =
    Widget Function(BuildContext context, Size pageSize, PdfPage page, RawImage? pageImage);

class PdfPageView extends StatefulWidget {
  const PdfPageView({
    required this.document,
    required this.pageNumber,
    this.rotationOverride,
    this.maximumDpi = 300,
    this.alignment = Alignment.center,
    this.decoration,
    this.backgroundColor,
    this.pageSizeCallback,
    this.decorationBuilder,
    super.key,
  });

  final PdfDocument? document;

  final int pageNumber;

  final PdfPageRotation? rotationOverride;

  final double maximumDpi;

  final AlignmentGeometry alignment;

  final Decoration? decoration;

  final Color? backgroundColor;

  final PdfPageViewSizeCallback? pageSizeCallback;

  final PdfPageViewDecorationBuilder? decorationBuilder;

  @override
  State<PdfPageView> createState() => _PdfPageViewState();
}

class _PdfPageViewState extends State<PdfPageView> {
  ui.Image? _image;
  Size? _pageSize;
  PdfPageRenderCancellationToken? _cancellationToken;
  StreamSubscription<PdfDocumentEvent>? _eventSubscription;

  @override
  void initState() {
    super.initState();
    _subscribeToDocumentEvents();
  }

  @override
  void dispose() {
    _eventSubscription?.cancel();
    _clearCache(refresh: false);
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant PdfPageView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.document != oldWidget.document ||
        widget.pageNumber != oldWidget.pageNumber ||
        widget.rotationOverride != oldWidget.rotationOverride) {
      _clearCache();
      _subscribeToDocumentEvents();
    }
  }

  void _clearCache({bool refresh = true}) {
    _image?.dispose();
    _image = null;
    _pageSize = null;
    _cancellationToken?.cancel();
    _cancellationToken = null;
    if (refresh && mounted) {
      setState(() {});
    }
  }

  void _subscribeToDocumentEvents() {
    _eventSubscription?.cancel();
    _eventSubscription = widget.document?.events.listen((event) {
      if (event is PdfDocumentPageStatusChangedEvent) {
        if (event.changes.keys.contains(widget.pageNumber)) {
          _clearCache();
        }
      }
    });
  }

  Widget _defaultDecorationBuilder(BuildContext context, Size pageSize, PdfPage page, RawImage? pageImage) {
    return Align(
      alignment: widget.alignment,
      child: AspectRatio(
        aspectRatio: pageSize.width / pageSize.height,
        child: Stack(
          children: [
            Container(
              decoration:
                  widget.decoration ??
                  BoxDecoration(
                    color: pageImage == null ? widget.backgroundColor ?? Colors.white : Colors.transparent,
                    boxShadow: const [BoxShadow(color: Colors.black54, blurRadius: 4, offset: Offset(2, 2))],
                  ),
            ),
            ?pageImage,
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final query = MediaQuery.of(context);
        _updateImage(constraints.biggest * query.devicePixelRatio);

        if (_pageSize != null) {
          final decorationBuilder = widget.decorationBuilder ?? _defaultDecorationBuilder;
          final scale = min(constraints.maxWidth / _pageSize!.width, constraints.maxHeight / _pageSize!.height);
          return decorationBuilder(
            context,
            _pageSize!,
            widget.document!.pages[widget.pageNumber - 1],
            _image != null
                ? RawImage(
                    image: _image,
                    width: _pageSize!.width * scale,
                    height: _pageSize!.height * scale,
                    fit: BoxFit.fill,
                  )
                : null,
          );
        }
        return const SizedBox();
      },
    );
  }

  Future<void> _updateImage(Size size) async {
    final document = widget.document;
    if (document == null || widget.pageNumber < 1 || widget.pageNumber > document.pages.length || size.isEmpty) {
      return;
    }
    final page = document.pages[widget.pageNumber - 1];

    final Size pageSize;
    if (widget.pageSizeCallback != null) {
      pageSize = widget.pageSizeCallback!(size, page, widget.rotationOverride);
    } else {
      final swapWH = ((widget.rotationOverride ?? page.rotation).index - page.rotation.index) & 1 == 1;
      final w = swapWH ? page.height : page.width;
      final h = swapWH ? page.width : page.height;

      final scale = min(widget.maximumDpi / 72, min(size.width / w, size.height / h));
      pageSize = Size(w * scale, h * scale);
    }

    if (pageSize == _pageSize) return;
    _pageSize = pageSize;

    _cancellationToken?.cancel();
    _cancellationToken = page.createCancellationToken();
    final pageImage = await page.render(
      fullWidth: pageSize.width,
      fullHeight: pageSize.height,
      rotationOverride: widget.rotationOverride,
      cancellationToken: _cancellationToken,
    );
    if (pageImage == null) return;
    try {
      final newImage = await pageImage.createImage();
      pageImage.dispose();
      _image = newImage;
      if (mounted) {
        setState(() {});
      }
    } catch (e) {
      developer.log('Error creating image: $e');
      pageImage.dispose();
    }
  }
}
