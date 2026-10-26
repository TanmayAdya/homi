import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/app/live_app.dart';
import 'package:safe_at_home/features/assessment/application/bathroom_scan_session.dart';
import 'package:safe_at_home/features/assessment/application/whole_home_capture_adapter.dart';
import 'package:safe_at_home/features/assessment/domain/scan/bathroom_scan_scene.dart';
import '../domain/scan/scan_test_fixtures.dart';
import 'package:safe_at_home/features/assessment/domain/home_safety/home_safety.dart';
import 'package:safe_at_home/features/assessment/domain/assessment_location.dart';
import 'package:safe_at_home/features/assessment/domain/local_place_rooms.dart';
import 'package:safe_at_home/features/assessment/domain/scan/whole_home_model.dart';
import 'package:safe_at_home/features/assessment/presentation/whole_home_screen.dart';
import 'package:safe_at_home/l10n/app_localizations.dart';
import 'package:safe_at_home/l10n/catalogs/whole_home.dart';
import '../../../app/case_coordinator_test.dart'
    show FakeSession, FakeTransport;
import '../application/whole_home_test_support.dart';
import '../home_safety/home_safety_support.dart' show SafetyStore;

class _Store extends SafetyStore {
  bool failHomeWrite = false;
  @override
  Future<void> writeBytes(String key, Uint8List value) async {
    if (failHomeWrite && key.endsWith(':whole-home')) {
      throw StateError('Fictional full disk');
    }
    await super.writeBytes(key, value);
  }
}

class _Harness {
  final store = _Store(),
      capture = HomeTestCapture(),
      current = ValueNotifier(true);
  List<RoomInstance> rooms = List.of(homeRooms);
  late AppServices services;
  String get caseId => services.coordinator.draft!.caseId;
  String get key => 'assessment:$caseId:whole-home';
  Future<void> init() async {
    services = AppServices(
      config: LiveAppConfig(
        apiOrigin: Uri.parse('https://example.org'),
        supabaseUrl: Uri.parse('https://example.supabase.co'),
        publishableKey: 'fictional',
      ),
      session: FakeSession(),
      store: store,
      transport: FakeTransport((_) async => throw StateError('Offline')),
    );
    await services.coordinator.createDraft();
    for (final room in rooms) {
      await store.writeBytes(
        BathroomScanSession.storageKey(caseId, room: room),
        Uint8List.fromList(
          utf8.encode(
            jsonEncode(
              BathroomScanReview(scene: homeScene()).toJson(caseId, room: room),
            ),
          ),
        ),
      );
    }
  }

  Widget app({Locale locale = const Locale('en'), double scale = 1}) =>
      MaterialApp(
        locale: locale,
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: WholeHomeScreen(
          services: services,
          rooms: () => rooms,
          isCurrent: () => current.value,
          scope: current,
          captureAdapter: capture,
        ),
      );
  WholeHomeModel? saved() => store.bytes[key] == null
      ? null
      : WholeHomeModel.fromJson(
          jsonDecode(utf8.decode(store.bytes[key]!)),
          caseId,
        );
  void dispose() {
    services.dispose();
    services.session.dispose();
    current.dispose();
  }
}

Future<void> tapVisible(WidgetTester tester, Finder finder) async {
  if (finder.evaluate().isEmpty) {
    tester
        .state<ScrollableState>(find.byType(Scrollable).first)
        .position
        .jumpTo(0);
    await tester.pumpAndSettle();
    for (var i = 0; i < 100 && finder.evaluate().isEmpty; i++) {
      final box = tester.getRect(find.byType(Scrollable).first);
      await tester.dragFrom(
        Offset(box.left + 8, box.center.dy),
        const Offset(0, -220),
      );
      await tester.pumpAndSettle();
    }
  }
  await Scrollable.ensureVisible(tester.element(finder), alignment: .5);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'eight named rooms of one type remain distinct through connected capture',
    (tester) async {
      final h = _Harness();
      h.rooms = [
        for (var i = 1; i <= 8; i++)
          RoomInstance(
            id: 'bedroom-$i',
            type: AssessmentLocation.bedroom,
            name: 'Bedroom $i',
          ),
      ];
      await h.init();
      addTearDown(h.dispose);
      final requestedNames = <String>[];
      h.capture.onStart = (id, rooms) async {
        requestedNames.addAll(rooms.map((room) => room.name));
        expect(rooms.map((r) => r.token).toSet(), hasLength(8));
        return h.capture.result(id, rooms);
      };
      await tester.pumpWidget(h.app());
      await tester.pumpAndSettle();
      await tapVisible(tester, find.byKey(const ValueKey('home-capture')));
      expect(find.textContaining('Choose 2–8 rooms'), findsOneWidget);
      for (final room in h.rooms.reversed) {
        await tapVisible(
          tester,
          find.widgetWithText(CheckboxListTile, room.name!),
        );
      }
      await tapVisible(tester, find.text('Start connected capture'));
      expect(requestedNames, h.rooms.reversed.map((room) => room.name));
      expect(h.saved(), isNull);
      await tapVisible(
        tester,
        find.widgetWithText(
          CheckboxListTile,
          'I checked the connected room positions.',
        ),
      );
      await tapVisible(tester, find.text('Save reviewed home model'));
      expect(
        h.saved()!.rooms.map((room) => room.roomId),
        h.rooms.reversed.map((room) => room.id),
      );
      expect(h.saved()!.captures, hasLength(8));
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(h.app());
      await tester.pumpAndSettle();
      expect(h.saved()!.rooms, hasLength(8));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('legacy chooser states the six available indoor places', (
    tester,
  ) async {
    final h = _Harness()..rooms = LocalPlaceRooms.all;
    await h.init();
    addTearDown(h.dispose);
    await tester.pumpWidget(h.app());
    await tester.pumpAndSettle();
    await tapVisible(tester, find.byKey(const ValueKey('home-capture')));
    expect(find.textContaining('Choose 2–6 rooms'), findsOneWidget);
    expect(find.byType(CheckboxListTile), findsNWidgets(6));
    expect(
      find.widgetWithText(CheckboxListTile, 'Outdoor paths'),
      findsNothing,
    );
    expect(find.textContaining('2–8 rooms'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'manual alignment previews, keeps input on failed save, retries and resumes',
    (tester) async {
      final h = _Harness();
      await h.init();
      addTearDown(h.dispose);
      h.capture.available = false;
      await tester.pumpWidget(h.app());
      await tester.pumpAndSettle();
      await tapVisible(
        tester,
        find.byKey(const ValueKey('home-reference-bath-one')),
      );
      await tapVisible(
        tester,
        find.byKey(const ValueKey('home-align-bath-two')),
      );
      expect(h.saved()!.rooms, hasLength(1));
      final check = find.widgetWithText(
        CheckboxListTile,
        'I checked the room position, orientation and height.',
      );
      expect(tester.widget<CheckboxListTile>(check).onChanged, isNull);
      await tester.enterText(find.byType(TextFormField).first, '4');
      await tapVisible(tester, find.text('Preview placement'));
      await tapVisible(tester, check);
      h.store.failHomeWrite = true;
      await tapVisible(tester, find.text('Save reviewed placement'));
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
      expect(h.saved()!.rooms, hasLength(1));
      h.store.failHomeWrite = false;
      await tapVisible(tester, find.text('Save reviewed placement'));
      expect(h.saved()!.globalPose('bath-two').x, 4);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      await tester.pumpWidget(h.app());
      await tester.pumpAndSettle();
      await tapVisible(
        tester,
        find.byKey(const ValueKey('home-align-bath-two')),
      );
      await tester.enterText(find.byType(TextFormField).first, '9');
      await tapVisible(tester, find.text('Cancel'));
      expect(h.saved()!.globalPose('bath-two').x, 4);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'connected-room chooser numbers walking order and explains the 8-room limit',
    (tester) async {
      final h = _Harness()
        ..rooms = [
          for (var i = 1; i <= 9; i++)
            RoomInstance(
              id: 'room-$i',
              type: AssessmentLocation.bedroom,
              name: 'Fictional room $i',
            ),
        ];
      await h.init();
      addTearDown(h.dispose);
      await tester.pumpWidget(h.app());
      await tester.pumpAndSettle();
      await tapVisible(tester, find.byKey(const ValueKey('home-capture')));
      expect(find.text('One level, in walking order'), findsOneWidget);
      expect(find.text('0 of 8 chosen'), findsOneWidget);
      for (var i = 1; i <= 8; i++) {
        await tapVisible(
          tester,
          find.widgetWithText(CheckboxListTile, 'Fictional room $i'),
        );
      }
      expect(find.text('8 of 8 chosen'), findsOneWidget);
      expect(find.text('Stop 1 of 8'), findsOneWidget);
      await tapVisible(
        tester,
        find.widgetWithText(CheckboxListTile, 'Fictional room 9'),
      );
      expect(
        tester
            .widget<CheckboxListTile>(
              find.widgetWithText(CheckboxListTile, 'Fictional room 9'),
            )
            .value,
        isFalse,
      );
      expect(
        find.textContaining('You can connect up to 8 rooms in one scan.'),
        findsOneWidget,
      );
      await tapVisible(
        tester,
        find.widgetWithText(CheckboxListTile, 'Fictional room 1'),
      );
      expect(find.text('7 of 8 chosen'), findsOneWidget);
      expect(find.textContaining('You can connect up to 8'), findsNothing);
      expect(
        find.descendant(
          of: find.widgetWithText(CheckboxListTile, 'Fictional room 2'),
          matching: find.text('Stop 1 of 7'),
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final (source, scale) in [
    ('roomplan', 1.0),
    ('roomplan', 3.2),
    ('arcore', 1.0),
    ('arcore', 3.2),
  ]) {
    testWidgets(
      '$source native capture at ${scale}x stays unreviewed until explicit save and resumes',
      (tester) async {
        tester.view.physicalSize = const Size(320, 760);
        tester.view.devicePixelRatio = 1;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });
        final h = _Harness();
        await h.init();
        addTearDown(h.dispose);
        if (source == 'arcore') {
          BathroomScanScene scene(String id) => BathroomScanScene.fromJson({
            ...scanSceneJson(
              source: 'arcore',
              elements: [
                scanElementJson(
                  kind: 'unknown',
                  nativeCategory: 'vertical',
                  dimensions: [2, 0, 3],
                  confidence: 'unknown',
                ),
              ],
            ),
            'scanId': id,
          });
          h.capture.onStart = (id, rooms) async => HomeCaptureResult({
            for (final r in rooms) r.token: scene(r.token),
          }, scene(id));
        }
        await tester.pumpWidget(h.app(scale: scale));
        await tester.pumpAndSettle();
        await tapVisible(tester, find.byKey(const ValueKey('home-capture')));
        await tapVisible(
          tester,
          find.widgetWithText(CheckboxListTile, 'First bathroom'),
        );
        await tapVisible(
          tester,
          find.widgetWithText(CheckboxListTile, 'Second bathroom'),
        );
        await tapVisible(tester, find.text('Start connected capture'));
        expect(h.saved(), isNull);
        final save = find.widgetWithText(
          FilledButton,
          'Save reviewed home model',
        );
        await tapVisible(tester, save);
        expect(tester.widget<FilledButton>(save).onPressed, isNull);
        await tapVisible(
          tester,
          find.widgetWithText(
            CheckboxListTile,
            'I checked the connected room positions.',
          ),
        );
        await tapVisible(tester, save);
        expect(h.saved()!.method, '${source}_shared_frame');
        expect(h.saved()!.rooms.every((r) => r.reviewed), isTrue);
        expect(h.store.bytes['${h.key}:draft'], isNull);
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
        await tester.pumpWidget(h.app(scale: scale));
        await tester.pumpAndSettle();
        expect(h.saved()!.captures, hasLength(2));
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
  testWidgets(
    'scope expiry removes private room geometry and dialog contents',
    (tester) async {
      final h = _Harness();
      await h.init();
      addTearDown(h.dispose);
      await tester.pumpWidget(h.app());
      await tester.pumpAndSettle();
      await tapVisible(
        tester,
        find.byKey(const ValueKey('home-reference-bath-one')),
      );
      await tapVisible(
        tester,
        find.byKey(const ValueKey('home-align-bath-two')),
      );
      await tapVisible(tester, find.text('Preview placement'));
      h.current.value = false;
      await tester.pumpAndSettle();
      expect(find.byType(TextFormField), findsNothing);
      expect(find.text('First bathroom'), findsNothing);
      expect(find.text('Align room: Second bathroom'), findsNothing);
      expect(
        find.text('Reopen the selected plan to view its model.'),
        findsWidgets,
      );
      expect(h.saved()!.rooms, hasLength(1));
      await tester.pumpWidget(const SizedBox());
    },
  );
  for (final locale in AppLocalizations.supportedLocales) {
    testWidgets(
      '$locale at 320px and 3.2x text keeps alignment controls reachable',
      (tester) async {
        tester.view.physicalSize = const Size(320, 760);
        tester.view.devicePixelRatio = 1;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });
        final h = _Harness();
        await h.init();
        addTearDown(h.dispose);
        h.capture.available = false;
        final words = AppLocalizations(locale);
        await tester.pumpWidget(h.app(locale: locale, scale: 3.2));
        await tester.pumpAndSettle();
        await tapVisible(
          tester,
          find.byKey(const ValueKey('home-reference-bath-one')),
        );
        await tapVisible(
          tester,
          find.byKey(const ValueKey('home-align-bath-two')),
        );
        await tapVisible(tester, find.text(words.text('Preview placement')));
        await tapVisible(
          tester,
          find.widgetWithText(
            CheckboxListTile,
            words.text('I checked the room position, orientation and height.'),
          ),
        );
        await tapVisible(
          tester,
          find.text(words.text('Save reviewed placement')),
        );
        expect(h.saved()!.rooms, hasLength(2));
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
  test(
    'all connected-home copy preserves placeholders in every bundled language',
    () {
      for (final entry in {
        ...wholeHomeTranslations,
        ...wholeHomeNativeTranslations,
      }.entries) {
        final expected = RegExp(
          r'\{[^}]+\}',
        ).allMatches(entry.key).map((m) => m[0]).toSet();
        expect(entry.value.keys.toSet(), {
          'es',
          'zh-Hans',
          'zh-Hant',
          'vi',
          'fil',
        });
        for (final text in entry.value.values) {
          expect(text.trim(), isNotEmpty);
          expect(
            RegExp(r'\{[^}]+\}').allMatches(text).map((m) => m[0]).toSet(),
            expected,
            reason: entry.key,
          );
        }
      }
    },
  );
}
