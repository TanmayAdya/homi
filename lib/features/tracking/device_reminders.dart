import 'dart:io';
import 'dart:convert';
import '../../shared/models/export_contract_values.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;
import '../../shared/services/local_private_store.dart';
import '../../shared/models/case_draft.dart';
import 'progress_models.dart';

abstract interface class NotificationDevice {
  Future<void> initialize(void Function() onTap);
  Future<bool> requestPermission();
  Future<bool> permitted();
  Future<String> timeZone();
  Future<void> cancelAll();
  Future<void> schedule(int id, DateTime instant, String zone, String body);
}

class LocalNotificationDevice implements NotificationDevice {
  final _plugin = FlutterLocalNotificationsPlugin();
  bool get _supported => Platform.isAndroid || Platform.isIOS;
  @override
  Future<void> initialize(void Function() onTap) async {
    tzdata.initializeTimeZones();
    if (!_supported) return;
    await _plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('ic_stat_next_step'),
        iOS: DarwinInitializationSettings(
          requestAlertPermission: false,
          requestBadgePermission: false,
          requestSoundPermission: false,
        ),
      ),
      onDidReceiveNotificationResponse: (_) => onTap(),
    );
    if ((await _plugin.getNotificationAppLaunchDetails())
            ?.didNotificationLaunchApp ==
        true) {
      onTap();
    }
  }

  @override
  Future<bool> requestPermission() async {
    if (Platform.isAndroid) {
      return await _plugin
              .resolvePlatformSpecificImplementation<
                AndroidFlutterLocalNotificationsPlugin
              >()
              ?.requestNotificationsPermission() ??
          false;
    }
    if (Platform.isIOS) {
      return await _plugin
              .resolvePlatformSpecificImplementation<
                IOSFlutterLocalNotificationsPlugin
              >()
              ?.requestPermissions(alert: true, sound: true, badge: false) ??
          false;
    }
    return false;
  }

  @override
  Future<bool> permitted() async {
    if (Platform.isAndroid) {
      return await _plugin
              .resolvePlatformSpecificImplementation<
                AndroidFlutterLocalNotificationsPlugin
              >()
              ?.areNotificationsEnabled() ??
          false;
    }
    if (Platform.isIOS) {
      return (await _plugin
                  .resolvePlatformSpecificImplementation<
                    IOSFlutterLocalNotificationsPlugin
                  >()
                  ?.checkPermissions())
              ?.isEnabled ??
          false;
    }
    return false;
  }

  @override
  Future<String> timeZone() async =>
      (await FlutterTimezone.getLocalTimezone()).identifier;
  @override
  Future<void> cancelAll() async {
    if (_supported) await _plugin.cancelAll();
  }

  @override
  Future<void> schedule(
    int id,
    DateTime instant,
    String zone,
    String body,
  ) async {
    if (!_supported) throw StateError('Device notifications are unavailable.');
    await _plugin.zonedSchedule(
      id: id,
      title: 'Safe at Home',
      body: body,
      scheduledDate: tz.TZDateTime.from(instant, tz.getLocation(zone)),
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails(
          'next_steps_v3',
          'Safe at Home',
          channelDescription: 'Safe at Home',
          visibility: NotificationVisibility.private,
        ),
        iOS: DarwinNotificationDetails(presentBadge: false),
      ),
      payload: 'next_steps',
    );
  }
}

DateTime reminderInstant(String date, String time, String zone) {
  progressDate(date);
  if (!RegExp(r'^([01][0-9]|2[0-3]):[0-5][0-9]$').hasMatch(time)) {
    throw const FormatException();
  }
  final day = DateTime.parse(date),
      parts = time.split(':').map(int.parse).toList();
  final location = tz.getLocation(zone);
  final wall = DateTime.utc(day.year, day.month, day.day, parts[0], parts[1]);
  final candidate = tz.TZDateTime(
    location,
    day.year,
    day.month,
    day.day,
    parts[0],
    parts[1],
  );
  final matches = <DateTime>[];
  final offsets = <int>{};
  for (final hours in [-48, -24, 0, 24, 48]) {
    offsets.add(
      location
          .timeZone(candidate.millisecondsSinceEpoch + hours * 3600000)
          .offset
          .inMilliseconds,
    );
  }
  for (final offset in offsets) {
    final instant = wall.subtract(Duration(milliseconds: offset));
    final local = tz.TZDateTime.from(instant, location);
    if (local.year == day.year &&
        local.month == day.month &&
        local.day == day.day &&
        local.hour == parts[0] &&
        local.minute == parts[1]) {
      matches.add(instant);
    }
  }
  if (matches.isEmpty) {
    throw const FormatException('Choose a time that exists in this time zone.');
  }
  matches.sort();
  return matches.first;
}

class ReminderPreference {
  ReminderPreference(Map<String, Object?> raw) : data = Map.unmodifiable(raw) {
    ExportContractValues.object(raw, {
      'caseId',
      'taskId',
      'date',
      'time',
      'zone',
      'instant',
      'notificationId',
      'enabled',
    });
    ExportContractValues.id(raw['caseId']);
    ExportContractValues.id(raw['taskId']);
    ExportContractValues.id(raw['zone']);
    ExportContractValues.integer(raw['notificationId'], max: 2147483647);
    ExportContractValues.instant(raw['instant']);
    if (raw['enabled'] is! bool ||
        reminderInstant(
              raw['date'] as String,
              raw['time'] as String,
              raw['zone'] as String,
            ) !=
            DateTime.parse(raw['instant'] as String)) {
      throw const FormatException();
    }
  }
  final Map<String, Object?> data;
  String get caseId => data['caseId'] as String;
  String get taskId => data['taskId'] as String;
  bool get enabled => data['enabled'] == true;
  DateTime get instant => DateTime.parse(data['instant'] as String);
  String get zone => data['zone'] as String;
  int get notificationId => data['notificationId'] as int;
}

class ReminderSettingsException implements Exception {
  const ReminderSettingsException(this.message);
  final String message;
}

class DeviceReminders {
  DeviceReminders({
    required this.store,
    required this.device,
    required this.isCurrent,
    required this.body,
    required this.onTap,
  });
  final LocalPrivateStore store;
  final NotificationDevice device;
  final bool Function() isCurrent;
  final String Function() body;
  final void Function() onTap;
  final Map<String, ReminderPreference> preferences = {};
  Future<void> _tail = Future.value();
  bool _active = true;
  bool _loaded = false;
  bool get requiresReset => !_loaded;
  static const _recoveryMessage =
      'Device reminder settings could not be read. Reset them to choose new reminders. Your tasks are still saved.';
  String? deviceId;
  String? feedback;
  int scheduledCount = 0;
  String _key(String caseId, String taskId) => jsonEncode([caseId, taskId]);
  Future<T> _serial<T>(Future<T> Function() work) {
    final next = _tail.then((_) => work());
    _tail = next.then<void>((_) {}, onError: (Object _) {});
    return next;
  }

  bool get current => _active && isCurrent();
  Future<void> initialize() => _serial(() async {
    try {
      await device.initialize(() {
        if (current) onTap();
      });
    } catch (_) {
      feedback = 'A reminder could not be scheduled. Your task is still saved.';
    }
    if (!current) return;
    try {
      final saved = await store.readJson('reminders.v3');
      if (!current) return;
      final restored = <String, ReminderPreference>{};
      String restoredId = newUuidV4();
      if (saved != null) {
        ExportContractValues.object(saved, {
          'schemaVersion',
          'deviceId',
          'preferences',
        });
        if (saved['schemaVersion'] != '3' ||
            saved['preferences'] is! List ||
            (saved['preferences'] as List).length > 128) {
          throw const FormatException();
        }
        ExportContractValues.id(saved['deviceId']);
        restoredId = saved['deviceId'] as String;
        final notificationIds = <int>{};
        for (final raw in saved['preferences'] as List) {
          final p = ReminderPreference(Map<String, Object?>.from(raw as Map));
          final key = _key(p.caseId, p.taskId);
          if (restored.containsKey(key) ||
              !notificationIds.add(p.notificationId)) {
            throw const FormatException();
          }
          restored[key] = p;
        }
      }
      if (saved == null) await _persist(restored, restoredId);
      if (!current) return;
      deviceId = restoredId;
      preferences
        ..clear()
        ..addAll(restored);
      _loaded = true;
    } catch (_) {
      feedback = _recoveryMessage;
      rethrow;
    }
  });
  Future<void> _persist(Map<String, ReminderPreference> next, String id) =>
      store.writeJson('reminders.v3', {
        'schemaVersion': '3',
        'deviceId': id,
        'preferences': next.values.map((p) => p.data).toList(),
      });
  void _requireLoaded() {
    if (!_loaded) throw const ReminderSettingsException(_recoveryMessage);
  }

  Future<void> _save(Map<String, ReminderPreference> next) async {
    _requireLoaded();
    await _persist(next, deviceId!);
    if (!current) return;
    preferences
      ..clear()
      ..addAll(next);
  }

  Future<void> reset() => _serial(() async {
    if (!current) return;
    await device.cancelAll();
    scheduledCount = 0;
    if (!current) return;
    final id = deviceId ?? newUuidV4();
    await _persist({}, id);
    if (!current) return;
    preferences.clear();
    deviceId = id;
    _loaded = true;
    feedback = null;
  });
  ReminderPreference? forTask(String caseId, String taskId) =>
      preferences[_key(caseId, taskId)];
  Future<void> configure(
    String caseId,
    String taskId,
    String date,
    String time,
    String zone, {
    DateTime? now,
  }) => _serial(() async {
    if (!current) return;
    _requireLoaded();
    final instant = reminderInstant(date, time, zone);
    final clock = now ?? DateTime.now();
    if (!instant.isAfter(clock)) throw const FormatException();
    final old = forTask(caseId, taskId);
    final next = Map<String, ReminderPreference>.of(preferences);
    if (old == null && next.length >= 128) {
      final reusable = next.entries.where(
        (e) => !e.value.enabled || !e.value.instant.isAfter(clock),
      );
      if (reusable.isEmpty) {
        throw const ReminderSettingsException(
          'This device has 128 active reminders. Disable one before adding another.',
        );
      }
      next.remove(reusable.first.key);
    }
    var nextId = 1;
    final used = next.values.map((p) => p.notificationId).toSet();
    while (used.contains(nextId)) {
      nextId++;
    }
    next[_key(caseId, taskId)] = ReminderPreference({
      'caseId': caseId,
      'taskId': taskId,
      'date': date,
      'time': time,
      'zone': zone,
      'instant': instant.toIso8601String(),
      'notificationId': old?.notificationId ?? nextId,
      'enabled': true,
    });
    await _save(next);
    if (!current) return;
    bool granted = false;
    try {
      granted = await device.requestPermission();
    } catch (_) {
      // ignore: empty_catches
    }
    if (!current) return;
    feedback = granted
        ? null
        : 'Notifications are off. Due tasks remain available in the app.';
  });
  Future<void> disable(String caseId, String taskId) => _serial(() async {
    if (!current) return;
    _requireLoaded();
    final next = Map<String, ReminderPreference>.of(preferences);
    final p = forTask(caseId, taskId);
    if (p != null) {
      next[_key(caseId, taskId)] = ReminderPreference({
        ...p.data,
        'enabled': false,
      });
    }
    await _save(next);
  });
  Future<void> forgetCase(String caseId) => _serial(() async {
    await device.cancelAll();
    scheduledCount = 0;
    if (!current || !_loaded) return;
    final next = Map<String, ReminderPreference>.of(preferences)
      ..removeWhere((_, p) => p.caseId == caseId);
    await _save(next);
  });
  Future<void> reconcile(
    Map<String, List<NextStepTask>> cases,
  ) => _serial(() async {
    if (!current) return;
    try {
      await device.cancelAll();
    } catch (_) {
      feedback = 'A reminder could not be scheduled. Your task is still saved.';
      return;
    }
    scheduledCount = 0;
    if (!current) return;
    if (!_loaded) {
      feedback = _recoveryMessage;
      return;
    }
    final next = Map<String, ReminderPreference>.of(preferences);
    for (final entry in next.entries.toList()) {
      final tasks = cases[entry.value.caseId];
      if (tasks != null &&
          !tasks.any((t) => t.id == entry.value.taskId && t.open)) {
        next[entry.key] = ReminderPreference({
          ...entry.value.data,
          'enabled': false,
        });
      }
    }
    await _save(next);
    final wanted =
        preferences.values
            .where(
              (p) =>
                  p.enabled &&
                  p.instant.isAfter(DateTime.now()) &&
                  cases[p.caseId]?.any((t) => t.id == p.taskId && t.open) ==
                      true,
            )
            .toList()
          ..sort((a, b) => a.instant.compareTo(b.instant));
    if (wanted.isEmpty || !current) return;
    bool permitted = false;
    try {
      permitted = await device.permitted();
    } catch (_) {
      // ignore: empty_catches
    }
    if (!permitted) {
      feedback =
          'Notifications are off. Due tasks remain available in the app.';
      return;
    }
    feedback = wanted.length > 48
        ? 'Only the next 48 reminders are scheduled. Open the app to refresh.'
        : null;
    for (final p in wanted.take(48)) {
      if (!current) return;
      try {
        await device.schedule(p.notificationId, p.instant, p.zone, body());
        scheduledCount++;
      } catch (_) {
        feedback =
            'A reminder could not be scheduled. Your task is still saved.';
      }
    }
  });
  Future<void> stop() {
    _active = false;
    return _serial(() => device.cancelAll());
  }
}
