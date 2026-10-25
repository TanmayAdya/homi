import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../../app/theme.dart';
import 'package:safe_at_home/l10n/app_localizations.dart';
import 'package:pdfrx/pdfrx.dart';
import '../../shared/models/case_draft.dart';
import '../../shared/presentation/sah_components.dart';
import 'private_pdf_document_lease.dart';

class PrivateDraftPreview extends StatefulWidget {
  const PrivateDraftPreview({super.key, required this.bytes});
  final Uint8List bytes;

  @override
  State<PrivateDraftPreview> createState() => _PrivateDraftPreviewState();
}

class _PrivateDraftPreviewState extends State<PrivateDraftPreview> {
  late String _sourceName;
  late PdfViewerController _controller;
  PrivatePdfDocumentLease? _documentLease;
  int _generation = 0, _textRequest = 0, _page = 1, _pageCount = 0;
  bool _ready = false, _moving = false, _readText = false, _textLoading = false;
  bool _loadFailed = false;
  String? _text, _textError, _navigationError;
  static const _maximumTextCharacters = 40000;

  @override
  void initState() {
    super.initState();
    _replaceDocument();
  }

  @override
  void didUpdateWidget(covariant PrivateDraftPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.bytes, widget.bytes)) _replaceDocument();
  }

  void _replaceDocument() {
    final previousLease = _documentLease;
    if (previousLease != null) unawaited(previousLease.close());
    _generation++;
    _textRequest++;
    _sourceName = 'sah-private-preview-${newUuidV4()}';
    _documentLease = PrivatePdfDocumentLease(
      PdfDocumentRefData(widget.bytes, sourceName: _sourceName),
    );
    _controller = PdfViewerController();
    _page = 1;
    _pageCount = 0;
    _ready = false;
    _moving = false;
    _readText = false;
    _textLoading = false;
    _loadFailed = false;
    _text = null;
    _textError = null;
    _navigationError = null;
  }

  @override
  void dispose() {
    _generation++;
    _textRequest++;
    final lease = _documentLease;
    _documentLease = null;
    if (lease != null) unawaited(lease.close());
    super.dispose();
  }

  bool _current(int generation) => mounted && generation == _generation;

  void _acceptPage(int generation, int? page) {
    if (!_current(generation) ||
        !_ready ||
        page == null ||
        page < 1 ||
        page > _pageCount ||
        page == _page) {
      return;
    }
    setState(() => _page = page);
    if (_readText) unawaited(_loadPageText());
  }

  Future<void> _movePage(int delta) async {
    if (!_ready || _moving || !_controller.isReady) return;
    final target = _page + delta;
    if (target < 1 || target > _pageCount) return;
    final generation = _generation;
    final controller = _controller;
    setState(() {
      _moving = true;
      _navigationError = null;
    });
    try {
      await controller.goToPage(pageNumber: target);
      if (!_current(generation) || !identical(controller, _controller)) return;
      _acceptPage(generation, controller.pageNumber ?? target);
    } catch (_) {
      if (_current(generation)) {
        setState(
          () => _navigationError =
              'This page could not be opened. Try again or reload the draft.',
        );
      }
    } finally {
      if (_current(generation)) setState(() => _moving = false);
    }
  }

  Future<void> _loadPageText() async {
    if (!_ready || !_readText || !_controller.isReady) return;
    final generation = _generation, request = ++_textRequest, page = _page;
    final controller = _controller;
    bool current() =>
        _current(generation) &&
        request == _textRequest &&
        _readText &&
        _page == page &&
        identical(controller, _controller);
    setState(() {
      _textLoading = true;
      _text = null;
      _textError = null;
    });
    try {
      final text = await Future<String?>.sync(
        () => controller.useDocument<String>((document) async {
          if (page < 1 || page > document.pages.length) {
            throw StateError('Page unavailable');
          }
          final extracted = await document.pages[page - 1].loadText();
          if (extracted == null) throw StateError('Page unavailable');
          return extracted.fullText;
        }),
      ).timeout(const Duration(seconds: 15));
      if (!current()) return;
      if (text == null) throw StateError('Page unavailable');
      if (text.length > _maximumTextCharacters) {
        setState(
          () => _textError =
              'This page has more text than this view can show. Review the page image instead.',
        );
      } else {
        setState(() => _text = text.trim());
      }
    } catch (_) {
      if (current()) {
        setState(
          () => _textError =
              'The text on this page could not be read. Retry or review the page image.',
        );
      }
    } finally {
      if (current()) setState(() => _textLoading = false);
    }
  }

  void _toggleText(bool enabled) {
    if (!_ready) return;
    setState(() {
      _readText = enabled;
      _textRequest++;
      _textLoading = false;
      _text = null;
      _textError = null;
    });
    if (enabled) unawaited(_loadPageText());
  }

  @override
  Widget build(BuildContext context) {
    final generation = _generation;
    final controller = _controller;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PrivatePdfPageNavigation(
          page: _page,
          pageCount: _pageCount,
          ready: _ready,
          busy: _moving,
          failed: _loadFailed,
          onPrevious: () => _movePage(-1),
          onNext: () => _movePage(1),
        ),
        if (_navigationError != null)
          SahNotice(
            message: context.tr(_navigationError!),
            tone: SahNoticeTone.error,
          ),
        SwitchListTile.adaptive(
          key: const ValueKey('private-pdf-read-text'),
          contentPadding: EdgeInsets.zero,
          title: Text(context.tr('Read page text')),
          value: _readText,
          onChanged: _ready ? _toggleText : null,
        ),
        const SizedBox(height: 8),
        ClipRRect(
          borderRadius: BorderRadius.circular(SahRadius.large),
          child: SizedBox(
            height: (MediaQuery.sizeOf(context).height * .68).clamp(360, 640),
            child: Stack(
              fit: StackFit.expand,
              children: [
                Offstage(
                  offstage: _readText,
                  child: ExcludeFocus(
                    excluding: _readText,
                    child: PdfViewer(
                      _documentLease!.reference,
                      key: ValueKey(_sourceName),
                      controller: controller,
                      params: PdfViewerParams(
                        textSelectionParams: PdfTextSelectionParams(
                          enabled: false,
                        ),
                        onViewerReady: (document, readyController) {
                          if (!_current(generation) ||
                              !identical(controller, readyController)) {
                            return;
                          }
                          setState(() {
                            _pageCount = document.pages.length;
                            _page = readyController.pageNumber ?? 1;
                            _ready = _pageCount > 0;
                          });
                        },
                        onPageChanged: (page) => _acceptPage(generation, page),
                        onDocumentLoadFinished: (_, succeeded) {
                          if (!succeeded && _current(generation)) {
                            setState(() {
                              _loadFailed = true;
                              _ready = false;
                            });
                          }
                        },
                        loadingBannerBuilder: (context, _, _) => Center(
                          child: CircularProgressIndicator(
                            semanticsLabel: context.tr('Opening PDF preview'),
                          ),
                        ),
                        errorBannerBuilder: (context, _, _, _) =>
                            SingleChildScrollView(
                              padding: EdgeInsets.all(20),
                              child: Text(
                                context.tr(
                                  'The PDF preview could not be opened. Reload and prepare the draft again.',
                                ),
                              ),
                            ),
                      ),
                    ),
                  ),
                ),
                if (_readText)
                  PrivatePdfPageText(
                    key: ValueKey('$_sourceName:$_page'),
                    loading: _textLoading,
                    text: _text,
                    error: _textError,
                    onRetry: _loadPageText,
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class PrivatePdfPageNavigation extends StatelessWidget {
  const PrivatePdfPageNavigation({
    super.key,
    required this.page,
    required this.pageCount,
    required this.ready,
    required this.busy,
    this.failed = false,
    required this.onPrevious,
    required this.onNext,
  });
  final int page, pageCount;
  final bool ready, busy, failed;
  final VoidCallback onPrevious, onNext;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Semantics(
        liveRegion: true,
        child: Text(
          ready
              ? context.tr('Page {page} of {count}', {
                  'page': page,
                  'count': pageCount,
                })
              : failed
              ? context.tr('PDF pages unavailable')
              : context.tr('Opening PDF pages…'),
          key: const ValueKey('private-pdf-page-status'),
          style: Theme.of(context).textTheme.titleMedium,
        ),
      ),
      const SizedBox(height: 8),
      Wrap(
        spacing: 12,
        runSpacing: 12,
        children: [
          OutlinedButton(
            key: const ValueKey('private-pdf-previous'),
            onPressed: ready && !busy && page > 1 ? onPrevious : null,
            child: Text(
              context.tr('Previous page'),
              textAlign: TextAlign.center,
            ),
          ),
          OutlinedButton(
            key: const ValueKey('private-pdf-next'),
            onPressed: ready && !busy && page < pageCount ? onNext : null,
            child: Text(context.tr('Next page'), textAlign: TextAlign.center),
          ),
        ],
      ),
    ],
  );
}

class PrivatePdfPageText extends StatelessWidget {
  const PrivatePdfPageText({
    super.key,
    required this.loading,
    required this.text,
    required this.error,
    required this.onRetry,
  });
  final bool loading;
  final String? text, error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: Theme.of(context).colorScheme.surface,
    child: SingleChildScrollView(
      key: const ValueKey('private-pdf-page-text'),
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            context.tr(
              'Text view does not show photo markings. Review the page image too.',
            ),
          ),
          const SizedBox(height: 16),
          if (loading)
            LinearProgressIndicator(
              semanticsLabel: context.tr('Reading page text'),
            )
          else if (error != null) ...[
            SahNotice(message: context.tr(error!), tone: SahNoticeTone.error),
            TextButton(
              onPressed: onRetry,
              child: Text(context.tr('Retry page text')),
            ),
          ] else if (text?.isNotEmpty == true)
            Text(text!)
          else
            Text(
              context.tr(
                'No readable text was found on this page. It may contain an image or scanned form. Review the page image instead.',
              ),
            ),
        ],
      ),
    ),
  );
}
