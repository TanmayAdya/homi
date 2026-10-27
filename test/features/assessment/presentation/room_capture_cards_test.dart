import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/app/theme.dart';
import 'package:safe_at_home/features/assessment/application/bathroom_scan_adapter.dart';
import 'package:safe_at_home/features/assessment/application/bathroom_scan_availability.dart';
import 'package:safe_at_home/features/assessment/application/bathroom_scan_session.dart';
import 'package:safe_at_home/features/assessment/application/whole_home_session.dart';
import 'package:safe_at_home/features/assessment/domain/assessment_location.dart';
import 'package:safe_at_home/features/assessment/domain/home_safety/home_safety.dart';
import 'package:safe_at_home/features/assessment/domain/local_place_rooms.dart';
import 'package:safe_at_home/features/assessment/domain/scan/bathroom_scan_scene.dart';
import 'package:safe_at_home/features/assessment/presentation/room_capture_cards.dart';
import 'package:safe_at_home/l10n/app_localizations.dart';
import 'package:safe_at_home/l10n/catalogs/room_actions.dart';

import '../domain/scan/scan_test_fixtures.dart';
import '../application/whole_home_test_support.dart';
import '../home_safety/home_safety_support.dart' show SafetyStore;

const _case = '11111111-0000-4000-8000-000000000001';

class _Scanner implements BathroomScanAdapter {
  _Scanner(this.supported);
  final bool supported;
  int starts = 0;
  @override
  Future<BathroomScanCapabilities> capabilities() async =>
      BathroomScanCapabilities(
        supported: supported,
        source: 'roomplan',
        reason: supported ? 'available' : 'unsupported_device',
      );
  @override
  Future<void> cancel(String id) async {}
  @override
  Future<BathroomScanScene> start(String id) async {
    starts++;
    throw StateError('Cards must not start capture during capability checks');
  }
}

void main() {
  for (final localPlaces in [false, true]) {
    testWidgets(
      'connected-only room status is scoped, reviewed and invalidated (local places: $localPlaces)',
      (tester) async {
        final store = SafetyStore();
        final rooms = localPlaces
            ? LocalPlaceRooms.all.take(2).toList()
            : homeRooms.take(2).toList();
        final session = WholeHomeSession(
          store: store,
          caseId: _case,
          currentRooms: () => rooms,
          isCurrent: () => true,
          localPlaces: localPlaces,
          adapter: HomeTestCapture(),
        );
        addTearDown(session.dispose);
        final availability = BathroomScanAvailability(
          adapter: _Scanner(true),
          isCurrent: () => true,
        )..refresh();
        addTearDown(availability.dispose);
        await session.initialize();
        await session.capture(rooms.map((r) => r.id).toList(), {
          for (final r in rooms) r.id: r.name ?? r.type.title,
        });
        var connected = 0, version = 0;
        Widget screen({String id = _case, bool recovery = false}) =>
            MaterialApp(
              home: Scaffold(
                body: SingleChildScrollView(
                  child: RoomCaptureCards(
                    key: ValueKey(version++),
                    store: store,
                    caseId: id,
                    rooms: rooms,
                    availability: availability,
                    isCurrent: () => true,
                    enabled: true,
                    savedPlacesOnly: recovery,
                    onScan: (_) {},
                    onOpenRoom: (_) {},
                    onConnected: () => connected++,
                  ),
                ),
              ),
            );
        await tester.pumpWidget(screen());
        await tester.pumpAndSettle();
        expect(
          find.text('In connected model'),
          findsNothing,
          reason: 'Unreviewed proposals are not saved room models.',
        );
        await session.acceptCapture();
        final saved = store.bytes.map(
          (key, value) => MapEntry(key, List<int>.of(value)),
        );
        await tester.pumpWidget(screen());
        await tester.pumpAndSettle();
        expect(find.text('In connected model'), findsNWidgets(2));
        expect(find.text('No scan yet'), findsNothing);
        expect(
          find.text('Scan room'),
          findsNWidgets(2),
          reason: 'Individual capture stays available.',
        );
        await tester.tap(
          find.byKey(ValueKey('connected-room-${rooms.first.id}')),
        );
        expect(connected, 1);
        expect(
          store.bytes,
          saved,
          reason: 'Reading card status must not promote or mutate models.',
        );
        if (localPlaces) {
          await tester.pumpWidget(screen(recovery: true));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Saved place scans'));
          await tester.pumpAndSettle();
          expect(find.text('In connected model'), findsNWidgets(2));
        }
        await tester.pumpWidget(
          screen(id: '22222222-0000-4000-8000-000000000002'),
        );
        await tester.pumpAndSettle();
        expect(find.text('In connected model'), findsNothing);
        store.bytes[BathroomScanSession.storageKey(
          _case,
          room: rooms.first,
        )] = Uint8List.fromList(
          utf8.encode(
            jsonEncode(
              BathroomScanReview(
                scene: fictionalScanScene(),
              ).toJson(_case, room: rooms.first),
            ),
          ),
        );
        await tester.pumpWidget(screen());
        await tester.pumpAndSettle();
        expect(
          find.text('In connected model'),
          findsNothing,
          reason:
              'A changed reference scan invalidates the connected placement.',
        );
        expect(find.text('View model'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  for (final locale in AppLocalizations.supportedLocales) {
    for (final scale in [1.0, 3.2]) {
      testWidgets(
        'room actions preserve targets and fit $locale at $scale text',
        (tester) async {
          tester.view.physicalSize = Size(scale == 1 ? 390 : 320, 844);
          tester.view.devicePixelRatio = 1;
          addTearDown(() {
            tester.view.resetPhysicalSize();
            tester.view.resetDevicePixelRatio();
          });
          final store = SafetyStore(), scanner = _Scanner(true);
          final availability = BathroomScanAvailability(
            adapter: scanner,
            isCurrent: () => true,
          )..refresh();
          addTearDown(availability.dispose);
          final selected = <String?>[], opened = <String>[];
          final rooms = LocalPlaceRooms.all;
          final kitchen = rooms.firstWhere(
            (r) => r.type == AssessmentLocation.kitchen,
          );
          for (final room in <RoomInstance?>[null, kitchen]) {
            store.bytes[BathroomScanSession.storageKey(
              _case,
              room: room,
            )] = Uint8List.fromList(
              utf8.encode(
                jsonEncode(
                  BathroomScanReview(
                    scene: fictionalScanScene(),
                  ).toJson(_case, room: room),
                ),
              ),
            );
          }
          final before = store.bytes.map(
            (k, v) => MapEntry(k, List<int>.of(v)),
          );
          final words = AppLocalizations(locale);
          await tester.pumpWidget(
            MaterialApp(
              locale: locale,
              supportedLocales: AppLocalizations.supportedLocales,
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              theme: SafeAtHomeTheme.light(),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(scale)),
                child: child!,
              ),
              home: Scaffold(
                body: SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: RoomCaptureCards(
                    store: store,
                    caseId: _case,
                    rooms: rooms,
                    availability: availability,
                    isCurrent: () => true,
                    enabled: true,
                    mergeLegacyBathroom: true,
                    onScan: (room) => selected.add(room?.id),
                    onOpenRoom: (r) => opened.add(r.id),
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(
            find.byKey(const ValueKey('open-bathroom-scan')),
            findsNothing,
          );
          expect(find.text(words.text('View model')), findsNWidgets(2));
          if (scale == 1 && locale.languageCode == 'en') {
            final title = tester.getRect(find.text('Bathroom'));
            final scan = tester.getRect(
              find.byKey(const ValueKey('open-room-scan-device-area-bathroom')),
            );
            final open = tester.getRect(
              find.byKey(const ValueKey('area-bathroom')),
            );
            expect(scan.left, greaterThan(title.right));
            expect(open.top, greaterThanOrEqualTo(scan.bottom));
          }
          for (final room in rooms) {
            final scan = find.byKey(ValueKey('open-room-scan-${room.id}'));
            if (room.type == AssessmentLocation.outdoorPaths) {
              expect(scan, findsNothing);
            } else {
              await Scrollable.ensureVisible(
                tester.element(scan),
                alignment: .5,
              );
              await tester.pumpAndSettle();
              await tester.tap(scan);
            }
            final open = find.byKey(ValueKey('area-${room.type.name}'));
            await Scrollable.ensureVisible(tester.element(open), alignment: .5);
            await tester.pumpAndSettle();
            await tester.tap(open);
          }
          expect(selected, [
            null,
            ...rooms
                .where(
                  (r) =>
                      r.type != AssessmentLocation.bathroom &&
                      r.type != AssessmentLocation.outdoorPaths,
                )
                .map((r) => r.id),
          ]);
          expect(opened, rooms.map((r) => r.id));
          expect(scanner.starts, 0);
          expect(store.bytes, before);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
        },
      );
    }
  }

  testWidgets(
    'saved local models survive reopening and never appear in another case',
    (tester) async {
      final store = SafetyStore(), scanner = _Scanner(false);
      final availability = BathroomScanAvailability(
        adapter: scanner,
        isCurrent: () => true,
      )..refresh();
      addTearDown(availability.dispose);
      final room = LocalPlaceRooms.all.first;
      store.bytes[BathroomScanSession.storageKey(
        _case,
        room: room,
      )] = Uint8List.fromList(
        utf8.encode(
          jsonEncode(
            BathroomScanReview(
              scene: fictionalScanScene(),
            ).toJson(_case, room: room),
          ),
        ),
      );
      store.bytes[LocalPlaceRooms.homeKey(_case)] = Uint8List.fromList([1]);
      var connected = 0;
      Widget screen(String id, {bool recovery = false}) => MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: RoomCaptureCards(
              key: ValueKey('$id-$recovery'),
              store: store,
              caseId: id,
              rooms: LocalPlaceRooms.all,
              availability: availability,
              isCurrent: () => true,
              enabled: true,
              onScan: (_) {},
              onOpenRoom: (_) {},
              savedPlacesOnly: recovery,
              onConnected: () => connected++,
            ),
          ),
        ),
      );
      await tester.pumpWidget(screen(_case));
      await tester.pumpAndSettle();
      expect(find.text('View model'), findsOneWidget);
      expect(find.text('Scan options'), findsNWidgets(5));
      await tester.pumpWidget(screen('22222222-0000-4000-8000-000000000002'));
      await tester.pumpAndSettle();
      expect(find.text('View model'), findsNothing);
      await tester.pumpWidget(screen(_case, recovery: true));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Saved place scans'));
      await tester.pumpAndSettle();
      expect(find.text('View model'), findsOneWidget);
      expect(find.text('No scan yet'), findsNothing);
      await tester.tap(find.text('View connected model'));
      expect(connected, 1);
      expect(store.bytes, hasLength(2));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  test('room action copy covers every supported non-English locale', () {
    for (final entry in roomActionTranslations.entries) {
      expect(entry.value.keys.toSet(), {
        'es',
        'zh-Hans',
        'zh-Hant',
        'vi',
        'fil',
      }, reason: entry.key);
      expect(
        entry.value.values.every((v) => v.isNotEmpty && v != entry.key),
        true,
      );
    }
  });
}
