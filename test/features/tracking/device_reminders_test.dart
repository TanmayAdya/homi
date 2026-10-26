import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:safe_at_home/features/tracking/device_reminders.dart';
import 'package:safe_at_home/features/tracking/progress_models.dart';
import '../../app/live_workflows_test.dart' show MemoryPrivateStore;

class FakeNotificationDevice implements NotificationDevice {
  bool permission = true, failSchedule = false, failInitialize = false;
  int requests = 0, cancellations = 0;
  Completer<bool>? permissionGate;
  final scheduled = <int, DateTime>{};
  final bodies = <String>[];
  void Function()? tap;
  @override
  Future<void> initialize(void Function() onTap) async {
    tzdata.initializeTimeZones();
    tap = onTap;
    if (failInitialize) throw StateError('unavailable');
  }

  @override
  Future<String> timeZone() async => 'America/Los_Angeles';
  @override
  Future<bool> permitted() async => permission;
  @override
  Future<bool> requestPermission() async {
    requests++;
    return permissionGate?.future ?? permission;
  }

  @override
  Future<void> cancelAll() async {
    cancellations++;
    scheduled.clear();
  }

  @override
  Future<void> schedule(
    int id,
    DateTime instant,
    String zone,
    String body,
  ) async {
    if (failSchedule) throw StateError('fictional device failure');
    scheduled[id] = instant;
    bodies.add(body);
  }
}

NextStepTask task(String id, {String state = 'pending'}) =>
    NextStepTask.fromJson({
      'id': id,
      'programId': null,
      'findingId': null,
      'formId': null,
      'title': 'Fictional private health paperwork',
      'kind': 'documents',
      'state': state,
      'responsiblePerson': null,
      'dueOn': '2030-01-05',
      'basedOnCaseRevision': 1,
      'basedOnRuleVersion': null,
      'revision': 1,
      'sourceEventId': null,
      'needsReview': false,
    });

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(tzdata.initializeTimeZones);
  DeviceReminders reminders(
    MemoryPrivateStore store,
    FakeNotificationDevice device, {
    bool Function()? current,
    void Function()? onTap,
  }) => DeviceReminders(
    store: store,
    device: device,
    isCurrent: current ?? () => true,
    body: () => 'You have a Safe at Home next step.',
    onTap: onTap ?? () {},
  );
  test(
    'DST gaps are rejected, repeated time uses earlier occurrence, original zone survives travel',
    () {
      expect(
        () => reminderInstant('2027-03-14', '02:30', 'America/Los_Angeles'),
        throwsFormatException,
      );
      expect(
        reminderInstant('2026-11-01', '01:30', 'America/Los_Angeles'),
        DateTime.utc(2026, 11, 1, 8, 30),
      );
      expect(
        reminderInstant('2027-01-05', '09:00', 'America/Los_Angeles'),
        DateTime.utc(2027, 1, 5, 17),
      );
      expect(
        reminderInstant('2027-07-05', '09:00', 'America/Los_Angeles'),
        DateTime.utc(2027, 7, 5, 16),
      );
    },
  );
  test(
    'opt-in only, denial retains due tasks and preferences; restart preserves device identity and snooze',
    () async {
      final store = MemoryPrivateStore(),
          device = FakeNotificationDevice()..permission = false;
      final first = reminders(store, device);
      await first.initialize();
      expect(device.requests, 0);
      await first.configure(
        'case',
        'one',
        '2030-01-05',
        '09:00',
        'America/Los_Angeles',
      );
      await first.reconcile({
        'case': [task('one'), task('two')],
      });
      expect(device.scheduled, isEmpty);
      expect(first.feedback, contains('Notifications are off'));
      final second = reminders(store, device);
      await second.initialize();
      expect(second.deviceId, first.deviceId);
      expect(
        second.forTask('case', 'one')!.instant,
        DateTime.utc(2030, 1, 5, 17),
      );
      device.permission = true;
      await second.configure(
        'case',
        'one',
        '2030-01-06',
        '10:00',
        'America/Los_Angeles',
      );
      await second.reconcile({
        'case': [task('one'), task('two')],
      });
      expect(device.scheduled.values.single, DateTime.utc(2030, 1, 6, 18));
      expect(device.bodies.last, 'You have a Safe at Home next step.');
    },
  );
  test(
    'completion cancels only that task; disable, deletion, and stop remove schedules',
    () async {
      final device = FakeNotificationDevice(),
          value = reminders(MemoryPrivateStore(), device);
      await value.initialize();
      for (final id in ['one', 'two']) {
        await value.configure('case', id, '2030-01-05', '09:00', 'UTC');
      }
      await value.reconcile({
        'case': [task('one'), task('two')],
      });
      expect(device.scheduled.length, 2);
      await value.reconcile({
        'case': [task('one', state: 'completed'), task('two')],
      });
      expect(device.scheduled.length, 1);
      expect(value.forTask('case', 'one')!.enabled, false);
      await value.disable('case', 'two');
      await value.reconcile({
        'case': [task('two')],
      });
      expect(device.scheduled, isEmpty);
      await value.forgetCase('case');
      expect(value.preferences, isEmpty);
      await value.stop();
      expect(device.scheduled, isEmpty);
    },
  );
  test(
    'sign-out during permission prompt fences late scheduling and stale notification taps',
    () async {
      final device = FakeNotificationDevice()
        ..permissionGate = Completer<bool>();
      var current = true, taps = 0;
      final value = reminders(
        MemoryPrivateStore(),
        device,
        current: () => current,
        onTap: () => taps++,
      );
      await value.initialize();
      final configure = value.configure(
        'case',
        'one',
        '2030-01-05',
        '09:00',
        'UTC',
      );
      await Future<void>.delayed(Duration.zero);
      current = false;
      final stop = value.stop();
      device.permissionGate!.complete(true);
      await configure;
      await stop;
      await value.reconcile({
        'case': [task('one')],
      });
      device.tap!();
      expect(device.scheduled, isEmpty);
      expect(taps, 0);
    },
  );
  test(
    '48-item scheduling cap and OS failures are visible, with saved tasks retained',
    () async {
      final device = FakeNotificationDevice(),
          value = reminders(MemoryPrivateStore(), device);
      await value.initialize();
      for (var i = 0; i < 50; i++) {
        await value.configure('case', '$i', '2030-01-05', '09:00', 'UTC');
      }
      final tasks = List.generate(50, (i) => task('$i'));
      await value.reconcile({'case': tasks});
      expect(device.scheduled.length, 48);
      expect(value.feedback, contains('48'));
      device.failSchedule = true;
      await value.reconcile({'case': tasks});
      expect(device.scheduled, isEmpty);
      expect(value.feedback, contains('could not be scheduled'));
      expect(value.preferences.length, 50);
    },
  );
}
