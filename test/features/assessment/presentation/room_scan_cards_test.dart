import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/features/assessment/application/bathroom_scan_session.dart';
import 'package:safe_at_home/features/assessment/domain/assessment_location.dart';
import 'package:safe_at_home/features/assessment/domain/home_safety/home_safety.dart';
import 'package:safe_at_home/features/assessment/presentation/room_scan_cards.dart';
import 'package:safe_at_home/l10n/app_localizations.dart';
import 'package:safe_at_home/l10n/catalogs/room_scans.dart';
import '../../../app/live_workflows_test.dart' show MemoryPrivateStore;
import '../domain/scan/scan_test_fixtures.dart';

class _Store extends MemoryPrivateStore {
  final bytes = <String, Uint8List>{};
  @override
  Future<Uint8List?> readBytes(String key) async => bytes[key];
}

void main() {
  const caseId = 'd33df8a2-d16f-4817-a596-e1786ac7ae0c';
  final rooms = [
    RoomInstance(
      id: 'one',
      type: AssessmentLocation.bathroom,
      name: 'Upstairs',
    ),
    RoomInstance(
      id: 'two',
      type: AssessmentLocation.bathroom,
      name: 'Downstairs',
    ),
  ];
  for (final locale in AppLocalizations.supportedLocales) {
    testWidgets(
      '$locale room index keeps separate targets and legacy work at large text',
      (tester) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });
        final store = _Store(), selected = <String?>[];
        for (final room in <RoomInstance?>[null, rooms.first]) {
          store.bytes[BathroomScanSession.storageKey(
            caseId,
            room: room,
          )] = Uint8List.fromList(
            utf8.encode(
              jsonEncode(
                BathroomScanReview(
                  scene: fictionalScanScene(),
                ).toJson(caseId, room: room),
              ),
            ),
          );
        }
        var current = true;
        final words = AppLocalizations(locale);
        await tester.pumpWidget(
          MaterialApp(
            locale: locale,
            supportedLocales: AppLocalizations.supportedLocales,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: const TextScaler.linear(2.5)),
              child: child!,
            ),
            home: Scaffold(
              body: SingleChildScrollView(
                child: RoomScanCards(
                  store: store,
                  caseId: caseId,
                  rooms: rooms,
                  isCurrent: () => current,
                  enabled: true,
                  onOpen: (room) => selected.add(room?.id),
                  onChecklist: (_) {},
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          find.text(words.text('3D scan saved on this phone')),
          findsOneWidget,
        );
        expect(
          find.text(words.text('Not scanned on this phone')),
          findsOneWidget,
        );
        for (final id in ['one', 'two']) {
          final button = find.byKey(ValueKey('open-room-scan-$id'));
          await tester.scrollUntilVisible(button, 200);
          await tester.tap(button);
          await tester.pump();
        }
        await tester.scrollUntilVisible(
          find.byKey(const ValueKey('legacy-bathroom-scan')),
          200,
        );
        await tester.tap(find.byKey(const ValueKey('legacy-bathroom-scan')));
        expect(selected, ['one', 'two', null]);
        expect(tester.takeException(), isNull);
        current = false;
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
  test('room scan copy has all five non-English translations', () {
    for (final entry in roomScanTranslations.entries) {
      expect(entry.value.keys.toSet(), {
        'es',
        'zh-Hans',
        'zh-Hant',
        'vi',
        'fil',
      }, reason: entry.key);
      expect(
        entry.value.values.every((s) => s.trim().isNotEmpty && s != entry.key),
        true,
      );
    }
  });
}
