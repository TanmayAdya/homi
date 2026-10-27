import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/features/tracking/device_reminders.dart';
import '../../app/live_workflows_test.dart' show MemoryPrivateStore;
import 'device_reminders_test.dart' show FakeNotificationDevice, task;

class _FailingSettingsStore extends MemoryPrivateStore {
  bool failWrites = false;
  @override
  Future<void> writeJson(String key, Map<String, Object?> value) async {
    if (failWrites && key == 'reminders.v3') {
      throw StateError('Fictional disk failure');
    }
    await super.writeJson(key, value);
  }
}

DeviceReminders _controller(
  MemoryPrivateStore store,
  FakeNotificationDevice device,
) => DeviceReminders(
  store: store,
  device: device,
  isCurrent: () => true,
  body: () => 'You have a Safe at Home next step.',
  onTap: () {},
);
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'a failed preference write keeps the last saved intent and never prompts permission',
    () async {
      final store = _FailingSettingsStore(),
          device = FakeNotificationDevice(),
          value = _controller(store, device);
      await value.initialize();
      await value.configure('case', 'one', '2030-01-05', '09:00', 'UTC');
      final saved = jsonEncode(store.records['reminders.v3']),
          previous = value.forTask('case', 'one')!.instant,
          requests = device.requests;
      store.failWrites = true;
      await expectLater(
        value.configure('case', 'one', '2030-01-06', '10:00', 'UTC'),
        throwsStateError,
      );
      expect(value.forTask('case', 'one')!.instant, previous);
      expect(jsonEncode(store.records['reminders.v3']), saved);
      expect(device.requests, requests);
      await expectLater(value.disable('case', 'one'), throwsStateError);
      expect(value.forTask('case', 'one')!.enabled, true);
    },
  );
  test(
    'disabled reminders free capacity without removing other active preferences',
    () async {
      final device = FakeNotificationDevice(),
          value = _controller(MemoryPrivateStore(), device);
      await value.initialize();
      for (var i = 0; i < 128; i++) {
        await value.configure('case', '$i', '2030-01-05', '09:00', 'UTC');
      }
      await value.disable('case', '7');
      await value.configure('case', 'next', '2030-01-05', '09:00', 'UTC');
      expect(value.preferences.length, 128);
      expect(value.forTask('case', 'next')!.enabled, true);
      expect(value.forTask('case', '8')!.enabled, true);
    },
  );
  test(
    'an unreadable settings record is retained during reconciliation until explicit reset',
    () async {
      final store = MemoryPrivateStore(),
          device = FakeNotificationDevice(),
          value = _controller(store, device);
      final record = <String, Object?>{
        'schemaVersion': '3',
        'deviceId': 'fictional-device',
        'preferences': [
          {'invalid': true},
        ],
      };
      await store.writeJson('reminders.v3', record);
      await expectLater(value.initialize(), throwsFormatException);
      await value.reconcile({
        'case': [task('one')],
      });
      expect(store.records['reminders.v3'], record);
      expect(value.feedback, contains('could not'));
      expect(device.scheduled, isEmpty);
    },
  );
  test(
    'full active capacity reports a recoverable limit and preserves intent',
    () async {
      final store = MemoryPrivateStore(),
          device = FakeNotificationDevice(),
          value = _controller(store, device);
      await value.initialize();
      for (var i = 0; i < 128; i++) {
        await value.configure('case', '$i', '2030-01-05', '09:00', 'UTC');
      }
      final before = jsonEncode(store.records['reminders.v3']);
      await expectLater(
        value.configure('case', 'next', '2030-01-05', '09:00', 'UTC'),
        throwsA(
          isA<ReminderSettingsException>().having(
            (e) => e.message,
            'message',
            contains('Disable one'),
          ),
        ),
      );
      expect(jsonEncode(store.records['reminders.v3']), before);
      expect(device.requests, 128);
      await value.configure('case', '8', '2030-01-06', '09:00', 'UTC');
      expect(value.preferences.length, 128);
    },
  );
  test(
    'duplicate notification identities reject the entire restore without scheduling',
    () async {
      final store = MemoryPrivateStore(),
          device = FakeNotificationDevice(),
          first = _controller(store, device);
      await first.initialize();
      await first.configure('case', 'one', '2030-01-05', '09:00', 'UTC');
      final original = first.forTask('case', 'one')!.data;
      final record = <String, Object?>{
        'schemaVersion': '3',
        'deviceId': first.deviceId,
        'preferences': [
          original,
          {...original, 'taskId': 'two'},
        ],
      };
      await store.writeJson('reminders.v3', record);
      final restored = _controller(store, device);
      await expectLater(restored.initialize(), throwsFormatException);
      expect(restored.preferences, isEmpty);
      expect(restored.requiresReset, true);
      await restored.reconcile({
        'case': [task('one'), task('two')],
      });
      expect(store.records['reminders.v3'], record);
      expect(device.scheduled, isEmpty);
      await expectLater(
        restored.configure('case', 'three', '2030-01-05', '09:00', 'UTC'),
        throwsA(isA<ReminderSettingsException>()),
      );
      await restored.forgetCase('case');
      expect(store.records['reminders.v3'], record);
    },
  );
  test(
    'explicit reset is durable, never prompts, and recovers after disk failure',
    () async {
      final store = _FailingSettingsStore(),
          device = FakeNotificationDevice(),
          value = _controller(store, device);
      await store.writeJson('reminders.v3', {'bad': true});
      await expectLater(value.initialize(), throwsFormatException);
      store.failWrites = true;
      await expectLater(value.reset(), throwsStateError);
      expect(value.requiresReset, true);
      expect(store.records['reminders.v3'], {'bad': true});
      store.failWrites = false;
      await value.reset();
      expect(value.requiresReset, false);
      expect(value.preferences, isEmpty);
      expect(device.requests, 0);
      final restart = _controller(store, device);
      await restart.initialize();
      expect(restart.deviceId, value.deviceId);
      expect(restart.preferences, isEmpty);
      await restart.configure('case', 'one', '2030-01-05', '09:00', 'UTC');
      await restart.reconcile({
        'case': [task('one')],
      });
      expect(device.scheduled.length, 1);
    },
  );
  test(
    'failed completion reconciliation cancels schedules while preserving the saved preference',
    () async {
      final store = _FailingSettingsStore(),
          device = FakeNotificationDevice(),
          value = _controller(store, device);
      await value.initialize();
      await value.configure('case', 'one', '2030-01-05', '09:00', 'UTC');
      await value.reconcile({
        'case': [task('one')],
      });
      store.failWrites = true;
      await expectLater(
        value.reconcile({
          'case': [task('one', state: 'completed')],
        }),
        throwsStateError,
      );
      expect(value.forTask('case', 'one')!.enabled, true);
      expect(device.scheduled, isEmpty);
      store.failWrites = false;
      await value.reconcile({
        'case': [task('one', state: 'completed')],
      });
      expect(value.forTask('case', 'one')!.enabled, false);
      expect(device.scheduled, isEmpty);
    },
  );
  test(
    'valid saved preferences can restore while settings writes are unavailable',
    () async {
      final store = _FailingSettingsStore(),
          device = FakeNotificationDevice(),
          first = _controller(store, device);
      await first.initialize();
      await first.configure('case', 'one', '2030-01-05', '09:00', 'UTC');
      store.failWrites = true;
      final restored = _controller(store, device);
      await restored.initialize();
      expect(restored.requiresReset, false);
      expect(
        restored.forTask('case', 'one')!.instant,
        first.forTask('case', 'one')!.instant,
      );
      expect(device.requests, 1);
    },
  );
}
