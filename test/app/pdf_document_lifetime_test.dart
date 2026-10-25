import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:safe_at_home/features/requests/private_pdf_document_lease.dart';

class _TrackedDocument implements PdfDocument {
  int disposals = 0;
  @override
  Future<void> dispose() async => disposals++;
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError(
    'This controlled document only supports disposal.',
  );
}

void main() {
  test(
    'loaded pdfrx document is disposed after its final listener leaves',
    () async {
      final document = _TrackedDocument();
      final reference = PdfDocumentRefByLoader(
        (_) async => document,
        key: PdfDocumentRefKey('fictional-loaded-lifetime'),
      );
      final listenable = reference.resolveListenable();
      void viewer() {}
      listenable.addListener(viewer);
      try {
        await listenable.load();
        expect(document.disposals, 0);
        listenable.removeListener(viewer);
        expect(document.disposals, 1);
        expect(listenable.document, isNull);
      } finally {
        listenable.removeListener(viewer);
      }
    },
  );

  test(
    'closed preview lease disposes its document after delayed load completes',
    () async {
      final entered = Completer<void>(), reply = Completer<PdfDocument>();
      final document = _TrackedDocument();
      final reference = PdfDocumentRefByLoader((_) {
        entered.complete();
        return reply.future;
      }, key: PdfDocumentRefKey('fictional-early-close-lifetime'));
      final lease = PrivatePdfDocumentLease(reference);
      final listenable = reference.resolveListenable();
      void viewer() {}
      listenable.addListener(viewer);
      await entered.future;
      listenable.removeListener(viewer);
      final closing = lease.close();
      expect(document.disposals, 0);
      reply.complete(document);
      try {
        await closing;
        expect(
          document.disposals,
          1,
          reason:
              'A preview closed during loading no longer owns the completed document.',
        );
        expect(listenable.document, isNull);
      } finally {
        listenable.removeListener(viewer);
        await lease.close();
      }
    },
  );

  test(
    'closing a loaded lease preserves an active viewer and is idempotent',
    () async {
      final document = _TrackedDocument();
      final reference = PdfDocumentRefByLoader(
        (_) async => document,
        key: PdfDocumentRefKey('fictional-active-viewer-lifetime'),
      );
      final lease = PrivatePdfDocumentLease(reference);
      final listenable = reference.resolveListenable();
      void viewer() {}
      listenable.addListener(viewer);
      try {
        await lease.loaded;
        await lease.close();
        await lease.close();
        expect(document.disposals, 0);
        expect(listenable.document, same(document));
        listenable.removeListener(viewer);
        expect(document.disposals, 1);
        await lease.close();
        expect(document.disposals, 1);
      } finally {
        listenable.removeListener(viewer);
        await lease.close();
      }
    },
  );

  test(
    'failed load settles a closed lease and releases its cached reference',
    () async {
      final entered = Completer<void>(), reply = Completer<PdfDocument>();
      final reference = PdfDocumentRefByLoader((_) {
        entered.complete();
        return reply.future;
      }, key: PdfDocumentRefKey('fictional-failed-load-lifetime'));
      final lease = PrivatePdfDocumentLease(reference);
      final original = reference.resolveListenable();
      await entered.future;
      final closing = lease.close();
      reply.completeError(StateError('Fictional loader failure'));
      await closing;
      final fresh = reference.resolveListenable();
      expect(fresh, isNot(same(original)));
      expect(original.document, isNull);
      void cleanup() {}
      fresh.addListener(cleanup);
      fresh.removeListener(cleanup);
    },
  );

  test(
    'replacement closes late old document without closing the new viewer',
    () async {
      final entered = Completer<void>(), reply = Completer<PdfDocument>();
      final oldDocument = _TrackedDocument(), newDocument = _TrackedDocument();
      final old = PrivatePdfDocumentLease(
        PdfDocumentRefByLoader((_) {
          entered.complete();
          return reply.future;
        }, key: PdfDocumentRefKey('fictional-old-replacement')),
      );
      await entered.future;
      final closingOld = old.close();
      final replacement = PrivatePdfDocumentLease(
        PdfDocumentRefByLoader(
          (_) async => newDocument,
          key: PdfDocumentRefKey('fictional-new-replacement'),
        ),
      );
      await replacement.loaded;
      reply.complete(oldDocument);
      await closingOld;
      expect(oldDocument.disposals, 1);
      expect(newDocument.disposals, 0);
      expect(
        replacement.reference.resolveListenable().document,
        same(newDocument),
      );
      await replacement.close();
      expect(newDocument.disposals, 1);
    },
  );
}
