import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:safe_at_home/app/live_app.dart';
import 'package:safe_at_home/app/theme.dart';
import 'package:safe_at_home/features/assessment/application/bathroom_scan_session.dart';
import 'package:safe_at_home/features/assessment/application/whole_home_capture_adapter.dart';
import 'package:safe_at_home/features/assessment/domain/scan/whole_home_model.dart';
import 'package:safe_at_home/features/assessment/presentation/bathroom_model_view.dart';
import 'package:safe_at_home/features/assessment/presentation/whole_home_screen.dart';
import 'package:safe_at_home/l10n/app_localizations.dart';
import 'package:safe_at_home/shared/models/case_draft.dart';
import 'package:safe_at_home/shared/services/local_private_store.dart';
import '../test/app/case_coordinator_test.dart' show FakeSession, FakeTransport;
import '../test/features/assessment/application/whole_home_test_support.dart';

const _scan = MethodChannel('safe_at_home/bathroom_scan');
const _media = MethodChannel('safe_at_home/private_media');
const _native = NativeWholeHomeCaptureAdapter();

class _DeviceStore extends LocalPrivateStore {
  _DeviceStore({required super.directory, required super.accountId})
    : super(secrets: DeviceSecretStore());
  bool failHomeWrite = false;
  @override
  Future<void> writeBytes(String key, Uint8List value) {
    if (failHomeWrite && key.endsWith(':whole-home')) {
      return Future.error(const FileSystemException('Fictional disk failure'));
    }
    return super.writeBytes(key, value);
  }
}

class _ProposalFixture extends HomeTestCapture {
  @override
  Future<bool> supported() => _native.supported();
}

Future<void> _settle(WidgetTester tester) =>
    tester.pumpAndSettle(const Duration(milliseconds: 100));

Future<void> _reveal(WidgetTester tester, Finder finder) async {
  if (finder.evaluate().isEmpty) {
    final list = find.byType(Scrollable).first;
    tester.state<ScrollableState>(list).position.jumpTo(0);
    await _settle(tester);
    for (var i = 0; i < 100 && finder.evaluate().isEmpty; i++) {
      final rect = tester.getRect(list);
      await tester.dragFrom(
        Offset(rect.left + 8, rect.center.dy),
        const Offset(0, -220),
      );
      await _settle(tester);
    }
  }
  expect(finder, findsOneWidget);
  await Scrollable.ensureVisible(tester.element(finder), alignment: .5);
  await _settle(tester);
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await _reveal(tester, finder);
  await tester.tap(finder);
  await _settle(tester);
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'iPhone connected-home native contracts and encrypted alignment/review journey',
    (tester) async {
      if (!const bool.fromEnvironment('SAH_HOME_ISOLATED_APP')) {
        throw StateError('Use the isolated connected-home device runner.');
      }
      expect(Platform.isIOS, isTrue);
      final capability = await _scan
          .invokeMethod<Object?>('homeCapabilities')
          .timeout(const Duration(seconds: 10));
      expect(capability, isA<Map>());
      expect((capability as Map).keys.toSet(), {'supported'});
      expect(capability['supported'], isA<bool>());
      final singleCapabilities = await _scan.invokeMethod<Object?>(
        'capabilities',
      );
      const requestId = 'bb83bd01-1991-41b6-92da-8203bbe49cea';
      const token = '1638832b-a045-4f37-821f-fbcae2e9222e';
      const other = 'c40d245d-e8ef-4463-8dd2-c7284e4441f1';
      final validRooms = [
        {'token': token, 'name': 'Fictional first bathroom'},
        {'token': other, 'name': 'Fictional second bathroom'},
      ];
      for (final args in <Object?>[
        null,
        {},
        {'scanId': 'invalid'},
        {
          'scanId': requestId,
          'languageCode': 'en',
          'rooms': [validRooms.first],
        },
        {
          'scanId': requestId,
          'languageCode': 'en',
          'rooms': [validRooms.first, validRooms.first],
        },
        {
          'scanId': requestId,
          'languageCode': 'en',
          'rooms': validRooms,
          'caseId': 'forbidden',
        },
        {
          'scanId': requestId,
          'languageCode': 'en',
          'rooms': [
            validRooms.first,
            {'token': other, 'name': 'Bad\nname'},
          ],
        },
      ]) {
        await expectLater(
          _scan
              .invokeMethod<Object?>('startHome', args)
              .timeout(const Duration(seconds: 10)),
          throwsA(
            isA<PlatformException>().having(
              (e) => e.code,
              'code',
              'scan_failed',
            ),
          ),
        );
      }
      await _native.cancel(requestId);
      await _native.cancel(requestId);
      expect(await _native.supported(), capability['supported']);

      final root = await _media.invokeMethod<String>('privateRootDirectory');
      expect(root, isNotNull);
      final owner = newUuidV4();
      final directory = Directory('$root/connected-home-device-check-$owner');
      await directory.create(recursive: true);
      await _media.invokeMethod('preparePrivateDirectory', {
        'path': directory.path,
      });
      final current = ValueNotifier(true);
      final proposal = _ProposalFixture();
      final transport = FakeTransport(
        (_) async => throw StateError('No network permitted in this fixture'),
      );
      AppServices? app;
      Future<AppServices> open() async {
        final next = AppServices(
          config: LiveAppConfig(
            apiOrigin: Uri.parse('https://connected-home-check.invalid'),
            supabaseUrl: Uri.parse('https://connected-home-check.invalid'),
            publishableKey: 'fictional',
          ),
          session: FakeSession()..owner = owner,
          store: _DeviceStore(directory: directory, accountId: owner),
          transport: transport,
        );
        app = next;
        return next;
      }

      Future<void> close() async {
        final previous = app!;
        app = null;
        previous.dispose();
        previous.session.dispose();
        await previous.store.close();
      }

      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await _settle(tester);
        if (app != null) {
          await close();
        }
        final cleanup = _DeviceStore(directory: directory, accountId: owner);
        await cleanup.clear();
        current.dispose();
      });
      var services = await open();
      await services.coordinator.createDraft();
      final caseId = services.coordinator.draft!.caseId;
      final rooms = homeRooms.take(2).toList();
      for (final room in rooms) {
        await services.store.writeBytes(
          BathroomScanSession.storageKey(caseId, room: room),
          Uint8List.fromList(
            utf8.encode(
              jsonEncode(
                BathroomScanReview(
                  scene: homeScene(),
                ).toJson(caseId, room: room),
              ),
            ),
          ),
        );
      }
      final original = {
        for (final room in rooms)
          room.id: await services.store.readBytes(
            BathroomScanSession.storageKey(caseId, room: room),
          ),
      };
      final key = 'assessment:$caseId:whole-home';
      Future<WholeHomeModel> saved() async => WholeHomeModel.fromJson(
        jsonDecode(utf8.decode((await services.store.readBytes(key))!)),
        caseId,
      );
      Future<void> show() async {
        await tester.pumpWidget(
          MaterialApp(
            theme: SafeAtHomeTheme.light(),
            supportedLocales: AppLocalizations.supportedLocales,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            home: WholeHomeScreen(
              services: services,
              rooms: () => rooms,
              isCurrent: () => current.value,
              scope: current,
              captureAdapter: proposal,
            ),
          ),
        );
        await _settle(tester);
      }

      await show();
      await _tap(tester, find.byKey(const ValueKey('home-reference-bath-one')));
      await _tap(tester, find.byKey(const ValueKey('home-align-bath-two')));
      final confirmation = find.widgetWithText(
        CheckboxListTile,
        'I checked the room position, orientation and height.',
      );
      expect(tester.widget<CheckboxListTile>(confirmation).onChanged, isNull);
      await tester.enterText(find.byType(TextFormField).at(0), '4');
      await tester.enterText(find.byType(TextFormField).at(3), '90');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await _tap(tester, find.text('Preview placement'));
      await _tap(tester, confirmation);
      (services.store as _DeviceStore).failHomeWrite = true;
      await _tap(tester, find.text('Save reviewed placement'));
      expect(
        find.text(
          'The device save failed. Keep this screen open and try again.',
        ),
        findsOneWidget,
      );
      expect(
        tester
            .widget<TextFormField>(find.byType(TextFormField).first)
            .controller!
            .text,
        '4',
      );
      expect((await saved()).rooms, hasLength(1));
      (services.store as _DeviceStore).failHomeWrite = false;
      await _tap(tester, find.text('Save reviewed placement'));
      expect((await saved()).globalPose('bath-two').x, 4);
      expect((await saved()).globalPose('bath-two').yaw, 90);
      await _tap(tester, find.byKey(const ValueKey('home-align-bath-two')));
      await tester.enterText(find.byType(TextFormField).first, '9');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await _tap(tester, find.text('Cancel'));
      expect((await saved()).globalPose('bath-two').x, 4);

      await _reveal(tester, find.text('Top-down'));
      await tester.tap(find.text('Top-down').first);
      await _settle(tester);
      await tester.tap(find.byTooltip('More view controls').first);
      await _settle(tester);
      await tester.tap(find.text('Front').last);
      await _settle(tester);
      await tester.tap(find.text('Reset view').first);
      await _settle(tester);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await _settle(tester);
      await close();
      services = await open();
      await services.coordinator.restoreLocal(caseId);
      await show();
      expect((await saved()).globalPose('bath-two').x, 4);
      for (final room in rooms) {
        expect(
          await services.store.readBytes(
            BathroomScanSession.storageKey(caseId, room: room),
          ),
          original[room.id],
        );
      }
      var nativeProposalUi = false;
      if (capability['supported'] == true) {
        await _tap(tester, find.byKey(const ValueKey('home-capture')));
        await _tap(tester, find.text('Cancel'));
        expect(proposal.starts, isEmpty);
        await _tap(tester, find.byKey(const ValueKey('home-capture')));
        for (final room in rooms) {
          await _tap(tester, find.widgetWithText(CheckboxListTile, room.name!));
        }
        await _tap(tester, find.text('Start connected capture'));
        expect((await saved()).method, 'reviewed_alignment');
        final save = find.widgetWithText(
          FilledButton,
          'Save reviewed home model',
        );
        await _reveal(tester, save);
        expect(tester.widget<FilledButton>(save).onPressed, isNull);
        await tester.pumpWidget(const SizedBox());
        await _settle(tester);
        await close();
        services = await open();
        await services.coordinator.restoreLocal(caseId);
        await show();
        await _tap(
          tester,
          find.widgetWithText(
            CheckboxListTile,
            'I checked the connected room positions.',
          ),
        );
        await _tap(tester, find.text('Save reviewed home model'));
        expect((await saved()).method, 'roomplan_shared_frame');
        expect(await services.store.readBytes('$key:draft'), isNull);
        nativeProposalUi = true;
      }
      final changed = rooms.last;
      await services.store.writeBytes(
        BathroomScanSession.storageKey(caseId, room: changed),
        Uint8List.fromList(
          utf8.encode(
            jsonEncode(
              BathroomScanReview(
                scene: homeScene(),
              ).toJson(caseId, room: changed),
            ),
          ),
        ),
      );
      await _tap(tester, find.text('Refresh saved scans'));
      expect(
        find.text(
          'A room or source scan changed. Review its placement before including it again.',
        ),
        findsOneWidget,
      );
      if (nativeProposalUi) {
        expect(find.byType(BathroomModelView), findsNothing);
      }
      current.value = false;
      await _settle(tester);
      expect(
        find.text('Reopen the selected plan to view its model.'),
        findsOneWidget,
      );
      expect(find.text(rooms.first.name!), findsNothing);
      expect(transport.requests, isEmpty);
      await tester.pumpWidget(const SizedBox());
      await _settle(tester);
      await for (final file in directory.list()) {
        if (file is File) {
          final bytes = await file.readAsString();
          expect(bytes, isNot(contains('reviewed_alignment')));
          expect(bytes, isNot(contains('bath-one')));
        }
      }
      binding.reportData = {
        'platform': 'physical iPhone',
        'nativeHomeCapabilities': capability,
        'nativeSingleCapabilities': singleCapabilities,
        'savedScanAlignment': 'passed with fictional geometry',
        'encryptedServiceReopen': true,
        'failedWriteRetainsInput': true,
        'cancelRetainsPlacement': true,
        'staleSourceExclusion': true,
        'scopeExclusion': true,
        'syntheticProposalReviewReopen': nativeProposalUi,
        'cameraStarted': false,
        'realRoomCaptureTested': false,
        'processRelaunchTested': false,
        'backendRequests': transport.requests.length,
      };
      debugPrint(
        'CONNECTED_HOME_DEVICE_AUTOMATED_PASS ${jsonEncode(binding.reportData)}',
      );
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
