import 'dart:async';
import 'package:flutter/foundation.dart';

class DraftSaveTracker extends ChangeNotifier {
  DraftSaveTracker({required bool Function() isCurrent}) : _current = isCurrent;
  final bool Function() _current;
  final _accepted = <Future<void>>{};
  Future<void> Function()? _latestWrite;
  int _revision = 0;
  bool _failed = false, _disposed = false;

  bool get isCurrent => !_disposed && _current();
  bool get pending => _accepted.isNotEmpty;
  bool get failed => _failed;
  bool get needsSave => pending || failed;

  Future<void> track(Future<void> Function() exactSnapshotWrite) {
    if (!isCurrent) {
      return Future.error(StateError('The editor is no longer current.'));
    }
    final revision = ++_revision;
    _latestWrite = exactSnapshotWrite;
    _failed = false;
    final work = Future<void>.sync(exactSnapshotWrite).then<void>(
      (_) {
        if (revision == _revision && isCurrent) _failed = false;
      },
      onError: (Object error, StackTrace stack) {
        if (revision == _revision && isCurrent) _failed = true;
        Error.throwWithStackTrace(error, stack);
      },
    );
    late final Future<void> settled;
    settled = work
        .then<void>((_) {}, onError: (Object _, StackTrace stack) {})
        .whenComplete(() {
          _accepted.remove(settled);
          if (!_disposed) notifyListeners();
        });
    _accepted.add(settled);
    notifyListeners();
    return work;
  }

  Future<bool> settle() async {
    while (!_disposed && _accepted.isNotEmpty) {
      await Future.wait(_accepted.toList());
    }
    return isCurrent && !_failed;
  }

  Future<void> retry() {
    if (pending || !isCurrent || _latestWrite == null) {
      return Future.error(StateError('This device save cannot be retried.'));
    }
    return track(_latestWrite!);
  }

  void discardLatest() {
    if (pending || !isCurrent) {
      throw StateError('Wait for accepted device writes before discarding.');
    }
    _revision++;
    _failed = false;
    _latestWrite = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _latestWrite = null;
    super.dispose();
  }
}
