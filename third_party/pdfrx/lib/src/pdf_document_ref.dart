import 'dart:async';

import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:pdfrx_engine/pdfrx_engine.dart';
import 'package:synchronized/extension.dart';

import 'pdfrx_flutter.dart';

typedef PdfDocumentLoaderProgressCallback = void Function(int downloadedBytes, [int? totalBytes]);

class PdfDocumentRefKey {
  PdfDocumentRefKey(this.sourceName, [Iterable<Object?> parts = const []]) : parts = List<Object?>.unmodifiable(parts);

  final String sourceName;

  final List<Object?> parts;

  @override
  bool operator ==(Object other) =>
      other is PdfDocumentRefKey && sourceName == other.sourceName && listEquals(parts, other.parts);

  @override
  int get hashCode => Object.hash(sourceName, const ListEquality().hash(parts));

  @override
  String toString() => 'PdfDocumentRefKey($sourceName)';
}

abstract class PdfDocumentRef {
  const PdfDocumentRef({required this.key, this.autoDispose = true});

  final bool autoDispose;

  final PdfDocumentRefKey key;

  @Deprecated('For compatibility. Use key for source identification')
  String get sourceName => key.sourceName;

  static final _listenables = CanonicalizedMap<PdfDocumentRefKey, PdfDocumentRef, PdfDocumentListenable>(
    (ref) => ref.key,
  );

  PdfDocumentListenable resolveListenable() => _listenables.putIfAbsent(this, () => PdfDocumentListenable._(this));

  Future<PdfDocument> loadDocument(PdfDocumentLoaderProgressCallback progressCallback);

  PdfPasswordProvider? get passwordProvider;

  bool get firstAttemptByEmptyPassword;
}

class PdfDocumentRefAsset extends PdfDocumentRef {
  PdfDocumentRefAsset(
    this.name, {
    this.passwordProvider,
    this.firstAttemptByEmptyPassword = true,
    super.autoDispose = true,
    this.useProgressiveLoading = true,
    PdfDocumentRefKey? key,
  }) : super(key: key ?? PdfDocumentRefKey(name));

  final String name;
  @override
  final PdfPasswordProvider? passwordProvider;
  @override
  final bool firstAttemptByEmptyPassword;

  final bool useProgressiveLoading;

  @override
  Future<PdfDocument> loadDocument(PdfDocumentLoaderProgressCallback progressCallback) async {
    await pdfrxFlutterInitialize();
    return await PdfDocument.openAsset(
      name,
      passwordProvider: passwordProvider,
      firstAttemptByEmptyPassword: firstAttemptByEmptyPassword,
      useProgressiveLoading: useProgressiveLoading,
    );
  }
}

class PdfDocumentRefUri extends PdfDocumentRef {
  PdfDocumentRefUri(
    this.uri, {
    this.passwordProvider,
    this.firstAttemptByEmptyPassword = true,
    super.autoDispose = true,
    this.preferRangeAccess = false,
    this.headers,
    this.withCredentials = false,
    this.timeout,
    this.useProgressiveLoading = true,
    PdfDocumentRefKey? key,
  }) : super(key: key ?? PdfDocumentRefKey(uri.toString()));

  final Uri uri;
  @override
  final PdfPasswordProvider? passwordProvider;
  @override
  final bool firstAttemptByEmptyPassword;

  final bool preferRangeAccess;

  final Map<String, String>? headers;

  final bool withCredentials;

  final Duration? timeout;

  final bool useProgressiveLoading;

  @override
  Future<PdfDocument> loadDocument(PdfDocumentLoaderProgressCallback progressCallback) async {
    await pdfrxFlutterInitialize();
    return await PdfDocument.openUri(
      uri,
      passwordProvider: passwordProvider,
      firstAttemptByEmptyPassword: firstAttemptByEmptyPassword,
      useProgressiveLoading: useProgressiveLoading,
      progressCallback: progressCallback,
      preferRangeAccess: preferRangeAccess,
      headers: headers,
      withCredentials: withCredentials,
      timeout: timeout,
    );
  }
}

class PdfDocumentRefFile extends PdfDocumentRef {
  PdfDocumentRefFile(
    this.file, {
    this.passwordProvider,
    this.firstAttemptByEmptyPassword = true,
    super.autoDispose = true,
    this.useProgressiveLoading = true,
    PdfDocumentRefKey? key,
  }) : super(key: key ?? PdfDocumentRefKey(file));

  final String file;
  @override
  final PdfPasswordProvider? passwordProvider;
  @override
  final bool firstAttemptByEmptyPassword;

  final bool useProgressiveLoading;

  @override
  Future<PdfDocument> loadDocument(PdfDocumentLoaderProgressCallback progressCallback) async {
    await pdfrxFlutterInitialize();
    return await PdfDocument.openFile(
      file,
      passwordProvider: passwordProvider,
      firstAttemptByEmptyPassword: firstAttemptByEmptyPassword,
      useProgressiveLoading: useProgressiveLoading,
    );
  }
}

class PdfDocumentRefData extends PdfDocumentRef {
  PdfDocumentRefData(
    this.data, {
    required String sourceName,
    this.passwordProvider,
    this.firstAttemptByEmptyPassword = true,
    super.autoDispose = true,
    this.allowDataOwnershipTransfer = false,
    this.onDispose,
    this.useProgressiveLoading = true,
    PdfDocumentRefKey? key,
  }) : super(key: key ?? PdfDocumentRefKey(sourceName));

  final Uint8List data;
  @override
  final PdfPasswordProvider? passwordProvider;
  @override
  final bool firstAttemptByEmptyPassword;
  final bool allowDataOwnershipTransfer;
  final void Function()? onDispose;

  final bool useProgressiveLoading;

  @override
  Future<PdfDocument> loadDocument(PdfDocumentLoaderProgressCallback progressCallback) async {
    await pdfrxFlutterInitialize();
    return await PdfDocument.openData(
      data,
      passwordProvider: passwordProvider,
      firstAttemptByEmptyPassword: firstAttemptByEmptyPassword,
      useProgressiveLoading: useProgressiveLoading,
      sourceName: key.sourceName,
      allowDataOwnershipTransfer: allowDataOwnershipTransfer,
      onDispose: onDispose,
    );
  }
}

class PdfDocumentRefCustom extends PdfDocumentRef {
  PdfDocumentRefCustom({
    required this.fileSize,
    required this.read,
    required String sourceName,
    this.passwordProvider,
    this.firstAttemptByEmptyPassword = true,
    super.autoDispose = true,
    this.maxSizeToCacheOnMemory,
    this.onDispose,
    this.useProgressiveLoading = true,
    PdfDocumentRefKey? key,
  }) : super(key: key ?? PdfDocumentRefKey(sourceName));

  final int fileSize;
  final FutureOr<int> Function(Uint8List buffer, int position, int size) read;
  @override
  final PdfPasswordProvider? passwordProvider;
  @override
  final bool firstAttemptByEmptyPassword;
  final int? maxSizeToCacheOnMemory;
  final void Function()? onDispose;

  final bool useProgressiveLoading;

  @override
  Future<PdfDocument> loadDocument(PdfDocumentLoaderProgressCallback progressCallback) async {
    await pdfrxFlutterInitialize();
    return await PdfDocument.openCustom(
      read: read,
      fileSize: fileSize,
      sourceName: key.sourceName,
      passwordProvider: passwordProvider,
      firstAttemptByEmptyPassword: firstAttemptByEmptyPassword,
      useProgressiveLoading: useProgressiveLoading,
      maxSizeToCacheOnMemory: maxSizeToCacheOnMemory,
      onDispose: onDispose,
    );
  }
}

class PdfDocumentRefDirect extends PdfDocumentRef {
  PdfDocumentRefDirect(this.document, {super.autoDispose = true, PdfDocumentRefKey? key})
    : super(key: key ?? PdfDocumentRefKey(document.sourceName));

  final PdfDocument document;

  @override
  Future<PdfDocument> loadDocument(PdfDocumentLoaderProgressCallback progressCallback) => Future.value(document);

  @override
  bool get firstAttemptByEmptyPassword => throw UnimplementedError('Not applicable for PdfDocumentRefDirect');

  @override
  PdfPasswordProvider? get passwordProvider => throw UnimplementedError('Not applicable for PdfDocumentRefDirect');
}

class PdfDocumentRefByLoader extends PdfDocumentRef {
  PdfDocumentRefByLoader(this.loader, {required super.key, super.autoDispose = true});

  final Future<PdfDocument> Function(PdfDocumentLoaderProgressCallback progressCallback) loader;

  @override
  Future<PdfDocument> loadDocument(PdfDocumentLoaderProgressCallback progressCallback) => loader(progressCallback);

  @override
  bool get firstAttemptByEmptyPassword => throw UnimplementedError('Not applicable for PdfDocumentRefByLoader');

  @override
  PdfPasswordProvider? get passwordProvider => throw UnimplementedError('Not applicable for PdfDocumentRefByLoader');
}

class PdfDocumentListenable extends Listenable {
  PdfDocumentListenable._(this.ref);

  final PdfDocumentRef ref;

  final _listeners = <VoidCallback>{};

  PdfDocument? _document;
  Object? _error;
  StackTrace? _stackTrace;
  int _revision = 0;
  int _bytesDownloaded = 0;
  int? _totalBytes;
  int _additionalRefs = 0;

  PdfDocument? get document => _document;

  Object? get error => _error;

  StackTrace? get stackTrace => _stackTrace;

  int get revision => _revision;

  int get bytesDownloaded => _bytesDownloaded;

  int? get totalBytes => _totalBytes;

  bool get loadAttempted => _document != null || _error != null;

  Future<PdfDownloadReport?> load({bool forceReload = false}) async {
    if (!forceReload && loadAttempted) {
      return null;
    }
    final stopwatch = Stopwatch()..start();
    return await synchronized(() async {
      if (!forceReload && loadAttempted) return null;
      final PdfDocument document;
      PdfDownloadReport? report;
      try {
        document = await ref.loadDocument((cur, [total]) {
          _progress(cur, total);
          if (total != null) {
            report = PdfDownloadReport(downloaded: cur, total: total, elapsedTime: stopwatch.elapsed);
          }
        });
        debugPrint('PdfDocument initial load: ${ref.key} (${stopwatch.elapsedMilliseconds} ms)');
      } catch (err, stackTrace) {
        setError(err, stackTrace);
        return report?.copyWith(elapsedTime: stopwatch.elapsed);
      }
      setDocument(document);
      return report?.copyWith(elapsedTime: stopwatch.elapsed);
    });
  }

  @override
  VoidCallback addListener(VoidCallback listener) {
    _listeners.add(listener);
    return () => removeListener(listener);
  }

  @override
  void removeListener(VoidCallback listener) {
    _listeners.remove(listener);
    _releaseIfNoRefs();
  }

  void _releaseIfNoRefs() {
    if (_listeners.isEmpty && _additionalRefs == 0) {
      PdfDocumentRef._listenables.remove(ref);
      _release();
    }
  }

  void _release() {
    if (ref.autoDispose) {
      _document?.dispose();
    }
    _document = null;
    _error = null;
    _stackTrace = null;
    _revision = 0;
    _bytesDownloaded = 0;
    _totalBytes = null;
  }

  void notifyListeners() {
    for (final listener in _listeners) {
      listener();
    }
  }

  FutureOr<T?> useDocument<T>(
    FutureOr<T> Function(PdfDocument document) task, {
    bool ensureLoaded = true,
    Completer? cancelLoading,
  }) async {
    try {
      _additionalRefs++;
      if (ensureLoaded) {
        await Future.any([load(), if (cancelLoading != null) cancelLoading.future]);
      }
      return _document != null ? await task(_document!) : null;
    } finally {
      _additionalRefs--;
      _releaseIfNoRefs();
    }
  }

  void _progress(int progress, [int? total]) {
    _bytesDownloaded = progress;
    _totalBytes = total;
    notifyListeners();
  }

  void setError(Object error, [StackTrace? stackTrace]) {
    _error = error;
    _stackTrace = stackTrace;
    if (ref.autoDispose) {
      _document?.dispose();
    }
    _document = null;
    _revision++;
    notifyListeners();
  }

  bool setDocument(PdfDocument newDocument) {
    final oldDocument = _document;
    if (newDocument == oldDocument) {
      return false;
    }
    _document = newDocument;
    if (ref.autoDispose) {
      oldDocument?.dispose();
    }
    _error = null;
    _stackTrace = null;
    _revision++;
    notifyListeners();
    return true;
  }
}

class PdfDownloadReport {
  const PdfDownloadReport({required this.downloaded, required this.total, required this.elapsedTime});
  final int downloaded;
  final int total;
  final Duration elapsedTime;

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;

    return other is PdfDownloadReport &&
        other.downloaded == downloaded &&
        other.total == total &&
        other.elapsedTime == elapsedTime;
  }

  PdfDownloadReport copyWith({int? downloaded, int? total, Duration? elapsedTime}) {
    return PdfDownloadReport(
      downloaded: downloaded ?? this.downloaded,
      total: total ?? this.total,
      elapsedTime: elapsedTime ?? this.elapsedTime,
    );
  }

  @override
  int get hashCode => downloaded.hashCode ^ total.hashCode ^ elapsedTime.hashCode;
}
