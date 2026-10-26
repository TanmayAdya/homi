import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/shared/services/draft_save_tracker.dart';

void main() {
  test('reserves immediately and waits for every accepted write', () async {
    final tracker = DraftSaveTracker(isCurrent: () => true);
    addTearDown(tracker.dispose);
    final first = Completer<void>(), second = Completer<void>();
    var reserved = 0, settled = false;
    final a = tracker.track(() {
      reserved++;
      return first.future;
    });
    final b = tracker.track(() {
      reserved++;
      return second.future;
    });
    expect(reserved, 2);
    expect(tracker.pending, isTrue);
    final waiting = tracker.settle().then((value) {
      settled = value;
    });
    second.complete();
    await b;
    await Future<void>.delayed(Duration.zero);
    expect(settled, isFalse);
    first.complete();
    await a;
    await waiting;
    expect(settled, isTrue);
    expect(tracker.needsSave, isFalse);
  });

  for (final latestFails in [false, true]) {
    test(
      'latest outcome remains authoritative when older write finishes last: $latestFails',
      () async {
        final tracker = DraftSaveTracker(isCurrent: () => true);
        addTearDown(tracker.dispose);
        final old = Completer<void>(), latest = Completer<void>();
        final a = tracker.track(() => old.future);
        final b = tracker.track(() => latest.future);
        final aCheck = latestFails
            ? expectLater(a, completes)
            : expectLater(a, throwsStateError);
        final bCheck = latestFails
            ? expectLater(b, throwsStateError)
            : expectLater(b, completes);
        if (latestFails) {
          latest.completeError(StateError('latest'));
        } else {
          latest.complete();
        }
        await bCheck;
        if (latestFails) {
          old.complete();
        } else {
          old.completeError(StateError('old'));
        }
        await aCheck;
        expect(await tracker.settle(), !latestFails);
        expect(tracker.failed, latestFails);
      },
    );
  }

  test(
    'retry retains the exact snapshot and cannot discard pending work',
    () async {
      final tracker = DraftSaveTracker(isCurrent: () => true);
      addTearDown(tracker.dispose);
      final gate = Completer<void>();
      final written = <String>[];
      var live = 'accepted snapshot', fail = true;
      final snapshot = live;
      await expectLater(
        tracker.track(() async {
          written.add(snapshot);
          if (fail) throw StateError('disk');
          await gate.future;
        }),
        throwsStateError,
      );
      await tracker.settle();
      live = 'later controller value';
      fail = false;
      final retry = tracker.retry();
      expect(written, ['accepted snapshot', 'accepted snapshot']);
      expect(live, 'later controller value');
      expect(tracker.discardLatest, throwsStateError);
      gate.complete();
      await retry;
      expect(await tracker.settle(), isTrue);
    },
  );

  test(
    'scope loss and disposal cannot retry or notify from a late result',
    () async {
      var current = true, notifications = 0;
      final tracker = DraftSaveTracker(isCurrent: () => current);
      tracker.addListener(() => notifications++);
      final gate = Completer<void>();
      final work = tracker.track(() => gate.future);
      final check = expectLater(work, throwsStateError);
      expect(notifications, 1);
      current = false;
      await expectLater(tracker.retry(), throwsStateError);
      tracker.dispose();
      gate.completeError(StateError('late device failure'));
      await check;
      expect(await tracker.settle(), isFalse);
      expect(notifications, 1);
      expect(tracker.failed, isFalse);
    },
  );
}
