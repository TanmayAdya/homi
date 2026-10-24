import 'package:pdfrx/pdfrx.dart';

class PrivatePdfDocumentLease {
  PrivatePdfDocumentLease(this.reference)
    : _listenable = reference.resolveListenable() {
    if (!reference.autoDispose) {
      throw ArgumentError(
        'Private preview documents must dispose automatically.',
      );
    }
    _listenable.addListener(_keepAlive);
    loaded = _listenable.load().then<void>(
      (_) {},
      onError: (Object error, StackTrace stack) {},
    );
  }

  final PdfDocumentRef reference;
  final PdfDocumentListenable _listenable;
  late final Future<void> loaded;
  Future<void>? _closing;

  void _keepAlive() {}

  Future<void> close() => _closing ??= _releaseAfterLoad();

  Future<void> _releaseAfterLoad() async {
    await loaded;
    _listenable.removeListener(_keepAlive);
  }
}
