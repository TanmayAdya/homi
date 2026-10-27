import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:safe_at_home/app/live_app.dart';
import 'package:safe_at_home/features/cases/case_workspace_screen.dart';
import 'package:safe_at_home/features/local_help/local_help_repository.dart';
import 'package:safe_at_home/features/local_help/local_help_screen.dart';
import 'package:safe_at_home/features/tracking/device_reminders.dart';
import 'package:safe_at_home/features/tracking/program_progress_screen.dart';
import 'package:safe_at_home/shared/models/case_draft.dart';
import 'package:safe_at_home/shared/services/local_private_store.dart';

import '../test/app/case_coordinator_test.dart' show FakeSession, FakeTransport;
import '../test/app/core_localization_test.dart' show localized;
import '../test/features/local_help/referral_test_support.dart'
    show ReferralServer;

const _provider = 'provider-habitat-east-bay-silicon-valley';
const _note = 'Fictional private iPhone contact note';
const _title = 'Fictional ask about repair coverage';

class _ObservedNotifications implements NotificationDevice {
  final native = LocalNotificationDevice();
  int permissionRequests = 0, schedules = 0;
  @override
  Future<void> initialize(void Function() onTap) => native.initialize(onTap);
  @override
  Future<bool> requestPermission() {
    permissionRequests++;
    return native.requestPermission();
  }

  @override
  Future<bool> permitted() => native.permitted();
  @override
  Future<String> timeZone() => native.timeZone();
  @override
  Future<void> cancelAll() => native.cancelAll();
  @override
  Future<void> schedule(int id, DateTime instant, String zone, String body) {
    schedules++;
    return native.schedule(id, instant, zone, body);
  }
}

Future<void> _settle(WidgetTester tester) async {
  await tester.pumpAndSettle(const Duration(milliseconds: 100));
}

Future<void> _reveal(WidgetTester tester, Finder finder) async {
  await _settle(tester);
  final scrollable = find.byType(Scrollable).first;
  tester.state<ScrollableState>(scrollable).position.jumpTo(0);
  await tester.pump();
  await tester.scrollUntilVisible(finder, 200, scrollable: scrollable);
  await tester.ensureVisible(finder);
  await _settle(tester);
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await _reveal(tester, finder);
  await tester.tap(finder);
  await _settle(tester);
}

Future<void> _tab(WidgetTester tester, String name) async {
  await tester.tap(find.byKey(ValueKey('plan-tab-$name')));
  await _settle(tester);
}

Future<void> _help(WidgetTester tester) async {
  await _tab(tester, 'help');
  await _tap(tester, find.byKey(const ValueKey('case-local-help')));
  expect(find.byType(LocalHelpScreen), findsOneWidget);
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'native Help contacts and Tasks use encrypted device persistence',
    (tester) async {
      if (!const bool.fromEnvironment('SAH_HELP_ISOLATED_APP')) {
        throw StateError('Use the isolated device-check runner.');
      }
      expect(Platform.isIOS || Platform.isAndroid, isTrue);
      const channel = MethodChannel('safe_at_home/private_media');
      final root = await channel.invokeMethod<String>('privateRootDirectory');
      expect(root, isNotNull);
      final owner = newUuidV4();
      final directory = Directory('$root/help-device-check-$owner');
      await directory.create(recursive: true);
      await channel.invokeMethod('preparePrivateDirectory', {
        'path': directory.path,
      });
      final backend = ReferralServer();
      final device = _ObservedNotifications();
      AppServices? app;
      Future<AppServices> open() async {
        final session = FakeSession()..owner = owner;
        final next = AppServices(
          config: LiveAppConfig(
            apiOrigin: Uri.parse('https://help-device-check.invalid'),
            supabaseUrl: Uri.parse('https://help-device-check.invalid'),
            publishableKey: 'fictional',
            localHelpEnabled: true,
            trackingEnabled: true,
          ),
          session: session,
          store: LocalPrivateStore(
            directory: directory,
            accountId: owner,
            secrets: DeviceSecretStore(),
          ),
          transport: FakeTransport(backend.handle),
          notificationDevice: device,
        );
        app = next;
        await next.progressReady;
        return next;
      }

      Future<void> close() async {
        final previous = app!;
        await previous.progress!.stop();
        previous.dispose();
        previous.session.dispose();
        await previous.store.close();
      }

      addTearDown(() async {
        if (app != null) {
          await app!.progress!.stop();
          app!.dispose();
          app!.session.dispose();
          await app!.store.clear();
        }
      });
      var current = await open();
      await current.coordinator.createDraft();
      await current.coordinator.save();
      final caseId = current.coordinator.snapshot!.caseId;
      await tester.pumpWidget(
        localized(const Locale('en'), CaseWorkspaceScreen(services: current)),
      );
      await _settle(tester);
      await _help(tester);
      await _tap(tester, find.byKey(const ValueKey('local-provider-search')));
      final query = find.byKey(const ValueKey('provider-search-query'));
      await _reveal(tester, query);
      await tester.enterText(query, 'East Bay');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await _settle(tester);
      await _tap(
        tester,
        find.byKey(const ValueKey('provider-result-$_provider')),
      );
      Finder action(String title) => find.descendant(
        of: find.byKey(const ValueKey(_provider)),
        matching: find.text(title),
      );
      await _tap(tester, action('Save · on this phone'));
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Contact note (optional)'),
        _note,
      );
      await tester.tap(find.text('Save on this device'));
      await _settle(tester);
      expect(
        (await LocalHelpRepository(
          current.coordinator,
        ).load()).contacts.single.note,
        _note,
      );
      await _tap(tester, action('Add follow-up'));
      expect(find.byType(ProgramProgressScreen), findsOneWidget);
      expect(backend.tasks, isEmpty);
      final quickAdd = find.byKey(const ValueKey('task-quick-add'));
      await _reveal(tester, quickAdd);
      await tester.enterText(quickAdd, _title);
      await _tap(tester, find.byKey(const ValueKey('task-quick-add-button')));
      final taskId = backend.tasks.keys.single;
      expect(
        (backend.tasks[taskId]!['referral'] as Map)['providerId'],
        _provider,
      );
      expect(jsonEncode(backend.tasks), isNot(contains(_note)));
      await tester.pageBack();
      await _settle(tester);
      await _tab(tester, 'tasks');
      await _tap(tester, find.text(_title));
      await tester.enterText(
        find.widgetWithText(TextFormField, 'For (optional note)'),
        'Fictional resident',
      );
      await _tap(tester, find.text('Save task'));
      expect(backend.tasks.keys.single, taskId);
      await _tap(tester, find.byKey(ValueKey('task-done-$taskId')));
      expect(backend.tasks[taskId]!['state'], 'completed');
      expect(device.permissionRequests, 0);
      expect(device.schedules, 0);
      final zone = await device.timeZone();
      expect(zone, isNotEmpty);

      await tester.pumpWidget(const SizedBox());
      await _settle(tester);
      await close();
      backend.offline = true;
      current = await open();
      await current.coordinator.restoreLocal(caseId);
      await tester.pumpWidget(
        localized(const Locale('en'), CaseWorkspaceScreen(services: current)),
      );
      await _settle(tester);
      await _help(tester);
      await _reveal(tester, find.text(_note));
      await _tap(tester, find.text('Edit contact note'));
      const offlineNote = 'Fictional contact edited offline on device';
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Contact note (optional)'),
        offlineNote,
      );
      await tester.tap(find.text('Save on this device'));
      await _settle(tester);
      await _reveal(tester, find.text(offlineNote));
      await _tab(tester, 'tasks');
      await _tap(tester, find.byKey(const ValueKey('tasks-done')));
      await _reveal(tester, find.text(_title));
      expect(
        tester.widget<ListTile>(find.byKey(ValueKey('task-$taskId'))).onTap,
        isNull,
      );
      for (final file in directory.listSync().whereType<File>()) {
        final bytes = await file.readAsString();
        expect(bytes, isNot(contains(_note)));
        expect(bytes, isNot(contains(offlineNote)));
        expect(bytes, isNot(contains(_title)));
      }
      expect(device.permissionRequests, 0);
      expect(device.schedules, 0);
      expect(tester.takeException(), isNull);
      binding.reportData = {
        'platform': Platform.operatingSystem,
        'nativeEncryptedStoreReopened': true,
        'helpSavedContactAndTasks': true,
        'offlineContactEditAndReadonlyTask': true,
        'permissionRequestsWithoutOptIn': device.permissionRequests,
        'schedulesWithoutOptIn': device.schedules,
        'deviceTimeZone': zone,
        'backend': 'fictional in-process response fixture',
        'processRestartTested': false,
        'notificationDeliveryTested': false,
      };
      debugPrint('HELP_DEVICE_AUTOMATED_PASS');
      backend.offline = false;
      await _help(tester);
    },
    timeout: const Timeout(Duration(minutes: 20)),
  );
}
