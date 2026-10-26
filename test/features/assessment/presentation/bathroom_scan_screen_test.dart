import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:safe_at_home/features/assessment/domain/home_safety/home_safety.dart';
import 'package:safe_at_home/features/assessment/domain/assessment_location.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/app/theme.dart';
import 'package:safe_at_home/features/assessment/application/bathroom_scan_adapter.dart';
import 'package:safe_at_home/features/assessment/application/bathroom_scan_session.dart';
import 'package:safe_at_home/features/assessment/domain/scan/bathroom_scan_scene.dart';
import 'package:safe_at_home/features/assessment/domain/scan/scan_suggestions.dart';
import 'package:safe_at_home/features/assessment/presentation/bathroom_model_view.dart';
import 'package:safe_at_home/features/assessment/presentation/bathroom_scan_screen.dart';
import 'package:safe_at_home/shared/services/local_private_store.dart';

import '../../../app/local_private_store_test.dart' show MemorySecrets;
import '../domain/scan/scan_test_fixtures.dart';

class _WidgetStore extends LocalPrivateStore {
  _WidgetStore({
    required super.directory,
    required super.accountId,
    required super.secrets,
  });
  bool failNextWrite = false;
  final failureObserved = Completer<void>();
  @override
  Future<void> writeBytes(String key, Uint8List bytes) {
    if (failNextWrite) {
      failNextWrite = false;
      if (!failureObserved.isCompleted) failureObserved.complete();
      return Future.error(const FileSystemException('Fictional full disk'));
    }
    return super.writeBytes(key, bytes);
  }
}

class _WidgetScanner implements BathroomScanAdapter {
  BathroomScanCapabilities capability = const BathroomScanCapabilities(
    supported: true,
    source: 'roomplan',
    reason: 'available',
    depthSupported: true,
  );
  final starts = <String>[], cancellations = <String>[];
  Future<BathroomScanScene> Function(String)? capture;
  @override
  Future<BathroomScanCapabilities> capabilities() async => capability;
  @override
  Future<BathroomScanScene> start(String id) async {
    starts.add(id);
    return capture == null
        ? BathroomScanScene.fromJson(
            scanSceneJson(
              source: capability.source,
              elements: capability.source == 'arcore'
                  ? [
                      scanElementJson(
                        kind: 'unknown',
                        nativeCategory: 'horizontal_upward',
                        dimensions: [2, 0, 3],
                        confidence: 'unknown',
                      ),
                    ]
                  : null,
            )..['scanId'] = id,
          )
        : await capture!(id);
  }

  @override
  Future<void> cancel(String id) async {
    cancellations.add(id);
  }
}

class _Harness {
  _Harness(this.directory, {RoomInstance? room}) {
    store = _WidgetStore(
      directory: directory,
      accountId: 'fictional-widget-owner',
      secrets: MemorySecrets(),
    );
    session = BathroomScanSession(
      store: store,
      caseId: caseId,
      room: room,
      isCurrent: () => current.value,
      adapter: scanner,
    );
  }
  static const caseId = 'f4b1b823-f3e5-4a77-825c-9b1696f21fe6';
  final Directory directory;
  final current = ValueNotifier(true);
  final scanner = _WidgetScanner();
  final imports = <ScanSuggestion>[];
  bool continued = false, otherConcern = false, usedPhotos = false;
  String? continuedFindingId;

  final removed = <String>{};
  late final _WidgetStore store;
  late final BathroomScanSession session;

  Future<void> seed(BathroomScanReview review) => store.writeBytes(
    session.key,
    Uint8List.fromList(
      utf8.encode(jsonEncode(review.toJson(caseId, room: session.room))),
    ),
  );

  Widget app({double textScale = 1}) => MaterialApp(
    theme: SafeAtHomeTheme.light(),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(textScaler: TextScaler.linear(textScale)),
      child: child!,
    ),
    home: Builder(
      builder: (context) => Scaffold(
        body: Center(
          child: FilledButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => BathroomScanScreen(
                  session: session,
                  scope: current,
                  onUsePhotos: () => usedPhotos = true,
                  onContinue: (id) {
                    continued = true;
                    continuedFindingId = id;
                  },
                  onAddOtherConcern: () {
                    otherConcern = true;
                  },
                  onImport: (suggestion) async {
                    imports.add(suggestion);
                    return 'fictional-finding';
                  },
                  importedFinding: (id) => imports.any((s) => s.id == id)
                      ? 'fictional-finding'
                      : null,
                  onSetImportActive: (id, active) async =>
                      active ? removed.remove(id) : removed.add(id),
                  activeImports: () => {
                    for (final s in imports)
                      if (!removed.contains(s.id)) s.id,
                  },
                ),
              ),
            ),
            child: const Text('Open scan review'),
          ),
        ),
      ),
    ),
  );
}

Future<void> _until(WidgetTester tester, bool Function() condition) async {
  for (var attempt = 0; attempt < 400 && !condition(); attempt++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
  }
  expect(
    condition(),
    isTrue,
    reason: 'Bounded private scan operation completed',
  );
}

Future<void> _idle(WidgetTester tester, _Harness harness) async {
  await _until(
    tester,
    () => harness.session.initialized && !harness.session.busy,
  );
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull);
}

Future<void> _open(
  WidgetTester tester,
  _Harness harness, {
  double textScale = 1,
  bool initialize = true,
}) async {
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    var closed = false;
    Object? failure;
    harness.store.close().then(
      (_) => closed = true,
      onError: (Object error) {
        failure = error;
        closed = true;
      },
    );
    await _until(tester, () => closed);
    expect(failure, isNull);
    harness.current.dispose();
    await tester.runAsync(() async {
      if (await harness.directory.exists()) {
        await harness.directory.delete(recursive: true);
      }
    });
  });
  await tester.pumpWidget(harness.app(textScale: textScale));
  await tester.tap(find.text('Open scan review'));
  await tester.pump();
  if (initialize) await _idle(tester, harness);
}

Future<void> _reveal(WidgetTester tester, Finder finder) async {
  final scrollable = find.byType(Scrollable).first;
  final state = tester.state<ScrollableState>(scrollable);
  for (
    var attempt = 0;
    attempt < 5 && state.position.pixels != state.position.minScrollExtent;
    attempt++
  ) {
    state.position.jumpTo(state.position.minScrollExtent);
    await tester.pump();
  }
  for (var attempt = 0; attempt < 120 && finder.evaluate().isEmpty; attempt++) {
    final bounds = tester.getRect(scrollable);
    await tester.dragFrom(
      Offset(bounds.left + 8, bounds.center.dy),
      const Offset(0, -300),
    );
    await tester.pump(const Duration(milliseconds: 50));
    final options = find.text('Scan options');
    if (finder.evaluate().isEmpty &&
        options.hitTestable().evaluate().isNotEmpty &&
        find.byKey(const ValueKey('bathroom-start-scan')).evaluate().isEmpty) {
      await tester.tap(options);
      await tester.pumpAndSettle();
    }
  }
  expect(finder, findsOneWidget);
  await Scrollable.ensureVisible(tester.element(finder), alignment: .5);
  await tester.pump();
}

final _suggestionCard = find.byWidgetPredicate(
  (w) =>
      w is Card &&
      w.key is ValueKey<String> &&
      (w.key! as ValueKey<String>).value.startsWith('scan-suggestion-'),
);

final _suggestionBox = find.descendant(
  of: _suggestionCard,
  matching: find.widgetWithText(OutlinedButton, 'Keep'),
);
final _notConcern = find.descendant(
  of: _suggestionCard,
  matching: find.widgetWithText(OutlinedButton, 'Not a concern'),
);

Future<void> _openModel(WidgetTester tester) async {
  await tester.pumpAndSettle();
  final item = find.byKey(const ValueKey('scan-item-door-1'));
  await _reveal(tester, item);
  await tester.tap(item);
  await tester.pumpAndSettle();
  expect(
    find.descendant(of: item, matching: find.text('Selected')),
    findsOneWidget,
  );
}

Future<void> _check(WidgetTester tester, _Harness harness, String label) async {
  final tile = find.widgetWithText(CheckboxListTile, label);
  await _reveal(tester, tile);
  final checkbox = find.descendant(of: tile, matching: find.byType(Checkbox));
  await Scrollable.ensureVisible(tester.element(checkbox), alignment: .5);
  await tester.pump();
  await tester.tap(checkbox);
  await _idle(tester, harness);
}

Future<void> _tapDialogAction(WidgetTester tester, String label) async {
  final target = find.descendant(
    of: find.byType(Dialog),
    matching: find.text(label),
  );
  expect(target, findsOneWidget);
  await Scrollable.ensureVisible(tester.element(target), alignment: .5);
  await tester.pump();
  await tester.tap(target);
}

void main() {
  late _Harness harness;
  setUp(
    () async => harness = _Harness(
      await Directory.systemTemp.createTemp('sah-scan-widget-'),
    ),
  );
  testWidgets(
    'a named bedroom opens its own model and offers room prompts instead of bathroom tasks',
    (tester) async {
      final directory = await tester.runAsync(
        () => Directory.systemTemp.createTemp('sah-bedroom-review-'),
      );
      final h = _Harness(
        directory!,
        room: RoomInstance(
          id: 'bedroom-a',
          type: AssessmentLocation.bedroom,
          name: 'Guest bedroom',
        ),
      );
      await tester.runAsync(
        () => h.seed(BathroomScanReview(scene: fictionalScanScene())),
      );
      await _open(tester, h, textScale: 2);
      expect(find.text('Guest bedroom in 3D'), findsOneWidget);
      final semantics = tester.ensureSemantics();
      await _openModel(tester);
      await _reveal(tester, find.byType(BathroomModelView));
      expect(
        find.bySemanticsLabel(RegExp('^Partial room model')),
        findsOneWidget,
      );
      expect(
        find.bySemanticsLabel(RegExp('^Partial bathroom model')),
        findsNothing,
      );
      semantics.dispose();
      await _reveal(tester, find.text('Getting through the doorway'));
      expect(find.text('Getting into or using the bath'), findsNothing);
      expect(
        find.text('Sitting down on or getting up from the toilet'),
        findsNothing,
      );
      expect(find.text('Getting through the doorway'), findsOneWidget);
      await tester.tap(find.text('Getting through the doorway'));
      await _idle(tester, h);
      expect(
        h.session.suggestedImprovements.single.title,
        'Make the doorway easier to use',
      );
      await tester.tap(find.byKey(const ValueKey('bathroom-continue')));
      await tester.pumpAndSettle();
      expect(h.continued, true);
      expect(h.usedPhotos, false);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'camera-only capture saves estimates and manual fallback keeps the model',
    (tester) async {
      harness.scanner.capability = const BathroomScanCapabilities(
        supported: true,
        source: 'arkit',
        reason: 'available',
        depthSupported: false,
      );
      harness.scanner.capture = (id) async => BathroomScanScene.fromJson(
        scanSceneJson(source: 'arkit')
          ..['scanId'] = id
          ..['measurements'] = [
            {
              'id': '2f3c7e0b-4f39-4a21-8ee1-5a8ca45fc861',
              'start': [0, 0, 0],
              'end': [1.25, 0, 0],
            },
          ],
      );
      await _open(tester, harness);
      expect(find.text('Camera-only scan'), findsOneWidget);
      final start = find.byKey(const ValueKey('bathroom-start-scan'));
      await _reveal(tester, start);
      expect(find.text('Start scan'), findsOneWidget);
      await tester.tap(start);
      await _idle(tester, harness);
      final fingerprint = harness.session.review.scene!.fingerprint;
      expect(harness.session.review.scene!.source, ScanSource.arkit);
      await tester.drag(find.byType(Scrollable).first, const Offset(0, 3000));
      await tester.pumpAndSettle();
      expect(find.text('Camera scans can’t recognise objects'), findsOneWidget);
      final first = harness.session.review.scene!.elements.first;
      final item = find.byKey(ValueKey('scan-item-${first.id}'));
      await _reveal(tester, item);
      expect(
        find.descendant(of: item, matching: find.text('Surface 1')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: item, matching: find.textContaining('estimate')),
        findsNothing,
      );
      expect(harness.imports, isEmpty);
      await _reveal(tester, find.text('Estimated distances'));
      await tester.tap(find.text('Estimated distances'));
      await tester.pumpAndSettle();
      await _reveal(tester, find.text('Distance 1: about 1.25 m'));
      expect(find.text('Distance 1: about 1.25 m'), findsOneWidget);
      await _reveal(tester, find.text('Scan options'));
      await tester.tap(find.text('Scan options'));
      await tester.pumpAndSettle();
      final manual = find.byKey(const ValueKey('bathroom-use-manual'));
      await _reveal(tester, manual);
      await tester.tap(manual);
      await tester.pumpAndSettle();
      expect(harness.usedPhotos, true);
      final saved = await tester.runAsync(
        () => BathroomScanSession.readSaved(harness.store, _Harness.caseId),
      );
      expect(saved!.scene!.fingerprint, fingerprint);
    },
  );

  for (final readiness in {
    'permission_denied': 'Camera access is needed for 3D scanning.',
    'services_missing': 'This phone supports ARCore.',
    'services_update_required': 'Google Play Services for AR needs an update.',
  }.entries) {
    testWidgets(
      'Android ${readiness.key} offers deliberate setup and a manual fallback',
      (tester) async {
        harness.scanner.capability = BathroomScanCapabilities(
          supported: true,
          source: 'arcore',
          reason: readiness.key,
        );
        await _open(tester, harness);
        await _reveal(tester, find.textContaining(readiness.value));
        expect(harness.scanner.starts, isEmpty);
        final start = find.byKey(const ValueKey('bathroom-start-scan'));
        await _reveal(tester, start);
        expect(tester.widget<ButtonStyleButton>(start).onPressed, isNotNull);
        expect(find.text('Set up 3D scanning'), findsOneWidget);
        final fallback = find.byKey(const ValueKey('bathroom-use-manual'));
        await _reveal(tester, fallback);
        expect(tester.widget<OutlinedButton>(fallback).onPressed, isNotNull);
        await _reveal(tester, start);
        await tester.tap(start);
        await _idle(tester, harness);
        expect(harness.scanner.starts, hasLength(1));
        expect(harness.session.review.scene!.source, ScanSource.arcore);
      },
    );
  }

  testWidgets(
    'supported LiDAR device explains readiness without starting capture',
    (tester) async {
      await _open(tester, harness);
      await _reveal(tester, find.text('LiDAR 3D scan'));
      expect(find.textContaining('RoomPlan'), findsNothing);
      expect(find.text('Less precise'), findsNothing);
      expect(harness.scanner.starts, isEmpty);
      final fallback = find.byKey(const ValueKey('bathroom-use-manual'));
      await _reveal(tester, fallback);
      await tester.tap(fallback);
      await tester.pumpAndSettle();
      expect(find.text('Open scan review'), findsOneWidget);
      expect(harness.scanner.starts, isEmpty);
    },
  );

  testWidgets(
    'iPhone blocked camera points to Settings without promising another prompt',
    (tester) async {
      harness.scanner.capability = const BathroomScanCapabilities(
        supported: true,
        source: 'roomplan',
        reason: 'permission_denied',
      );
      await _open(tester, harness);
      await _reveal(tester, find.textContaining('Camera access is blocked.'));
      expect(find.textContaining('iPhone Settings'), findsOneWidget);
      expect(find.text('Set up 3D scanning'), findsNothing);
      expect(harness.scanner.starts, isEmpty);
      final fallback = find.byKey(const ValueKey('bathroom-use-manual'));
      await _reveal(tester, fallback);
      await tester.tap(fallback);
      await tester.pumpAndSettle();
      expect(find.text('Open scan review'), findsOneWidget);
      expect(harness.scanner.starts, isEmpty);
    },
  );

  testWidgets(
    'unsupported phone can review its saved model and leave without erasing it',
    (tester) async {
      final original = BathroomScanReview(
        scene: fictionalScanScene(),
        reviewed: {'door-1'},
      );
      await tester.runAsync(() => harness.seed(original));
      harness.scanner.capability = const BathroomScanCapabilities(
        supported: false,
        source: 'arcore',
        reason: 'unsupported_device',
      );
      await _open(tester, harness);
      await _reveal(
        tester,
        find.textContaining('Your saved model is still available to review.'),
      );
      await _openModel(tester);
      await _reveal(tester, find.byType(BathroomModelView));
      final fallback = find.byKey(const ValueKey('bathroom-use-manual'));
      await _reveal(tester, fallback);
      await tester.tap(fallback);
      await tester.pumpAndSettle();
      expect(find.text('Open scan review'), findsOneWidget);
      final bytes = await tester.runAsync(
        () => harness.store.readBytes(harness.session.key),
      );
      expect(jsonDecode(utf8.decode(bytes!)), original.toJson(_Harness.caseId));
      expect(harness.scanner.starts, isEmpty);
    },
  );

  testWidgets(
    'manual fallback requires explicit discard after an unsaved review change',
    (tester) async {
      final original = BathroomScanReview(scene: fictionalScanScene());
      await tester.runAsync(() => harness.seed(original));
      await _open(tester, harness);
      await _openModel(tester);
      harness.store.failNextWrite = true;
      await _check(tester, harness, 'I checked this feature’s identity');
      expect(harness.session.dirty, isTrue);
      expect(harness.session.review.reviewed, {'door-1'});

      final fallback = find.byKey(const ValueKey('bathroom-use-manual'));
      await _reveal(tester, fallback);
      await tester.tap(fallback);
      await tester.pumpAndSettle();
      expect(find.text('Device changes are not saved'), findsOneWidget);
      await _tapDialogAction(tester, 'Cancel');
      await tester.pumpAndSettle();
      expect(harness.session.dirty, isTrue);
      expect(harness.session.review.reviewed, {'door-1'});
      expect(find.text('Open scan review'), findsNothing);

      await _reveal(tester, fallback);
      await tester.tap(fallback);
      await tester.pumpAndSettle();
      await _tapDialogAction(tester, 'Discard unsaved changes');
      await _until(
        tester,
        () => find.text('Open scan review').evaluate().isNotEmpty,
      );
      await tester.pumpAndSettle();
      final bytes = await tester.runAsync(
        () => harness.store.readBytes(harness.session.key),
      );
      expect(jsonDecode(utf8.decode(bytes!)), original.toJson(_Harness.caseId));
      expect(harness.scanner.starts, isEmpty);
    },
  );

  testWidgets(
    'a saved model can recheck pending ARCore availability without losing review',
    (tester) async {
      final scene = BathroomScanScene.fromJson(scanSceneJson());
      await tester.runAsync(
        () => harness.seed(
          BathroomScanReview(scene: scene, reviewed: {scene.elements.first.id}),
        ),
      );
      harness.scanner.capability = const BathroomScanCapabilities(
        supported: false,
        source: 'arcore',
        reason: 'checking',
      );
      await _open(tester, harness);
      final start = find.byKey(const ValueKey('bathroom-start-scan'));
      await _reveal(tester, start);
      expect(tester.widget<ButtonStyleButton>(start).onPressed, isNull);

      harness.scanner.capability = const BathroomScanCapabilities(
        supported: true,
        source: 'arcore',
        reason: 'available',
      );
      final recheck = find.text('Check device');
      await _reveal(tester, recheck);
      await tester.tap(recheck);
      await _idle(tester, harness);
      await _reveal(tester, start);
      expect(tester.widget<ButtonStyleButton>(start).onPressed, isNotNull);
      expect(harness.session.review.scene!.fingerprint, scene.fingerprint);
      expect(harness.session.review.reviewed, {scene.elements.first.id});
      expect(harness.scanner.starts, isEmpty);
      expect(harness.imports, isEmpty);
    },
  );
  testWidgets(
    'capture and one concern confirmation import without checking every feature',
    (tester) async {
      await _open(tester, harness);
      final start = find.byKey(const ValueKey('bathroom-start-scan'));
      await _reveal(tester, start);
      await tester.tap(start);
      await _idle(tester, harness);
      expect(harness.session.review.scene, isNotNull);
      expect(harness.imports, isEmpty);
      await _reveal(tester, find.byType(BathroomModelView));
      expect(find.byType(BathroomModelView), findsOneWidget);
      expect(find.textContaining('not a verified measurement'), findsNothing);
      expect(harness.session.review.reviewed, isEmpty);
      await _check(tester, harness, ScanDifficulty.enteringBathroom.label);
      expect(harness.imports, isEmpty);
      await _reveal(tester, _suggestionBox);
      await tester.tap(_suggestionBox);
      await _idle(tester, harness);
      expect(harness.imports, hasLength(1));
      expect(harness.session.review.reviewed, {'door-1'});
      expect(
        harness.imports.single.sceneFingerprint,
        harness.session.review.scene!.fingerprint,
      );
      expect(
        harness.imports.single.observation,
        contains('not a verified measurement'),
      );
      expect(find.text('Added to your plan'), findsOneWidget);
      final next = find.byKey(const ValueKey('bathroom-continue'));
      expect(next.hitTestable(), findsOneWidget);
      await tester.tap(next);
      await tester.pumpAndSettle();
      expect(harness.continued, isTrue);
      expect(harness.continuedFindingId, 'fictional-finding');
      expect(harness.scanner.starts, hasLength(1));
      expect(find.text('Open scan review'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'saved model is visible and another concern opens the note path',
    (tester) async {
      await tester.runAsync(
        () => harness.seed(BathroomScanReview(scene: fictionalScanScene())),
      );
      await _open(tester, harness);
      expect(find.byType(BathroomModelView), findsOneWidget);
      expect(
        find.byKey(const ValueKey('bathroom-continue')).hitTestable(),
        findsOneWidget,
      );
      final other = find.byKey(const ValueKey('bathroom-other-concern'));
      await _reveal(tester, other);
      await tester.tap(other);
      await tester.pumpAndSettle();
      expect(harness.otherConcern, isTrue);
      expect(harness.scanner.starts, isEmpty);
      expect(harness.imports, isEmpty);
      expect(find.text('Open scan review'), findsOneWidget);
    },
  );

  testWidgets(
    'unsupported simulator keeps manual assessment available and never starts native capture',
    (tester) async {
      harness.scanner.capability = const BathroomScanCapabilities(
        supported: false,
        source: 'roomplan',
        reason: 'simulator',
        depthSupported: false,
      );
      await _open(tester, harness);
      final start = find.byKey(const ValueKey('bathroom-start-scan'));
      await _reveal(tester, start);
      expect(tester.widget<ButtonStyleButton>(start).onPressed, isNull);
      await _reveal(
        tester,
        find.textContaining('The simulator cannot capture LiDAR.'),
      );
      expect(
        find.textContaining('The simulator cannot capture LiDAR.'),
        findsOneWidget,
      );
      expect(harness.scanner.starts, isEmpty);
      final fallback = find.byKey(const ValueKey('bathroom-use-manual'));
      await _reveal(tester, fallback);
      await tester.tap(fallback);
      await tester.pumpAndSettle();
      expect(find.text('Open scan review'), findsOneWidget);
      expect(harness.scanner.starts, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'scope change hides an existing model and cancels the exact pending replacement',
    (tester) async {
      await tester.runAsync(
        () => harness.seed(
          BathroomScanReview(scene: fictionalScanScene(), reviewed: {'door-1'}),
        ),
      );
      final entered = Completer<String>();
      final reply = Completer<BathroomScanScene>();
      harness.scanner.capture = (id) {
        entered.complete(id);
        return reply.future;
      };
      await _open(tester, harness);
      await _openModel(tester);
      await _reveal(tester, find.byType(BathroomModelView));
      expect(find.byType(BathroomModelView), findsOneWidget);
      final list = tester.state<ScrollableState>(find.byType(Scrollable).first);
      list.position.jumpTo(0);
      await tester.pump();
      await _reveal(tester, find.byKey(const ValueKey('bathroom-start-scan')));
      await tester.tap(find.byKey(const ValueKey('bathroom-start-scan')));
      await tester.pump(const Duration(milliseconds: 300));
      await _tapDialogAction(tester, 'Start new scan');
      await tester.pump();
      await _until(tester, () => entered.isCompleted);
      final id = harness.scanner.starts.single;
      harness.current.value = false;
      await tester.pump();
      expect(
        find.text(
          'This case or account has changed. Return to the assessment.',
        ),
        findsOneWidget,
      );
      expect(find.byType(BathroomModelView), findsNothing);
      expect(find.text('PARTIAL 3D MODEL'), findsNothing);
      expect(harness.scanner.cancellations, [id]);
      reply.complete(
        BathroomScanScene.fromJson(scanSceneJson()..['scanId'] = id),
      );
      await _until(tester, () => !harness.session.busy);
      await tester.pumpAndSettle();
      expect(harness.imports, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'scope expiry hides scan ideas and the model on its first frame',
    (tester) async {
      final scene = fictionalScanScene();
      await tester.runAsync(
        () => harness.seed(
          BathroomScanReview(
            scene: scene,
            reviewed: {'door-1'},
            difficulties: {ScanDifficulty.enteringBathroom},
          ),
        ),
      );
      await _open(tester, harness);
      await _reveal(tester, _suggestionBox);
      expect(harness.imports, isEmpty);
      harness.current.value = false;
      await tester.pump();
      expect(_suggestionBox, findsNothing);
      expect(find.byType(BathroomModelView), findsNothing);
      await tester.pumpAndSettle();
      expect(harness.imports, isEmpty);
      expect(
        find.text(
          'This case or account has changed. Return to the assessment.',
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'changing a feature label withdraws its review and prior suggestions',
    (tester) async {
      await tester.runAsync(
        () => harness.seed(
          BathroomScanReview(
            scene: fictionalScanScene(),
            reviewed: {'door-1'},
            difficulties: {ScanDifficulty.enteringBathroom},
          ),
        ),
      );
      await _open(tester, harness);
      await _openModel(tester);
      final dropdown = find.byKey(const ValueKey('door-1-door'));
      await _reveal(tester, dropdown);
      await tester.tap(dropdown);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Sink').last);
      await tester.tap(find.text('Sink').last);
      await _idle(tester, harness);
      expect(harness.session.review.labels['door-1'], ScanElementKind.sink);
      expect(harness.session.review.reviewed, isEmpty);
      expect(harness.imports, isEmpty);
      await _reveal(
        tester,
        find.textContaining('Nothing in the scan matched.'),
      );
      expect(_suggestionBox, findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  BathroomScanReview doorReview() => BathroomScanReview(
    scene: fictionalScanScene(),
    reviewed: {'door-1'},
    difficulties: {ScanDifficulty.enteringBathroom},
  );
  ScanSuggestion doorSuggestion() => suggestBathroomImprovements(
    scene: fictionalScanScene(),
    reviewedElementIds: {'door-1'},
    difficulties: {ScanDifficulty.enteringBathroom},
  ).single;
  final earlierNotice = find.textContaining(
    '1 earlier scan observation is still in the assessment',
  );

  testWidgets(
    'correcting a label flags an earlier imported observation without editing it',
    (tester) async {
      await tester.runAsync(() => harness.seed(doorReview()));
      harness.imports.add(doorSuggestion());
      await _open(tester, harness);
      await _reveal(tester, find.text('Added to your plan'));
      expect(earlierNotice, findsNothing);
      await _openModel(tester);
      final dropdown = find.byKey(const ValueKey('door-1-door'));
      await _reveal(tester, dropdown);
      await tester.tap(dropdown);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Sink').last);
      await tester.tap(find.text('Sink').last);
      await _idle(tester, harness);
      await _reveal(tester, earlierNotice);
      expect(harness.imports, hasLength(1));
      expect(harness.imports.single.id, doorSuggestion().id);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'Undo after Not a concern on a new suggestion restores it unanswered',
    (tester) async {
      await tester.runAsync(() => harness.seed(doorReview()));
      await _open(tester, harness);
      await _reveal(tester, _notConcern);
      await tester.tap(_notConcern);
      await _idle(tester, harness);
      expect(harness.session.review.dismissed, {doorSuggestion().id});
      await tester.tap(find.widgetWithText(SnackBarAction, 'Undo'));
      await _idle(tester, harness);
      expect(harness.session.review.dismissed, isEmpty);
      expect(harness.imports, isEmpty);
      await _reveal(tester, _notConcern);
      expect(_suggestionBox, findsOneWidget, reason: 'Neither is selected');
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'a removed import shows Not a concern and stays reversible without a new ID',
    (tester) async {
      await tester.runAsync(() => harness.seed(doorReview()));
      harness.imports.add(doorSuggestion());
      harness.removed.add(doorSuggestion().id);
      await _open(tester, harness);
      await _reveal(tester, find.text('Removed from your plan'));
      expect(_notConcern, findsNothing, reason: 'Not a concern is selected');
      await _reveal(tester, _suggestionBox);
      await tester.tap(_suggestionBox);
      await _idle(tester, harness);
      expect(harness.removed, isEmpty);
      expect(find.text('Added to your plan'), findsOneWidget);
      await _reveal(tester, _notConcern);
      await tester.tap(_notConcern);
      await _idle(tester, harness);
      expect(harness.removed, {doorSuggestion().id});
      expect(find.text('Removed from your plan'), findsOneWidget);
      expect(find.text('Marked not a concern'), findsOneWidget);
      await tester.tap(find.widgetWithText(SnackBarAction, 'Undo'));
      await _idle(tester, harness);
      expect(harness.removed, isEmpty, reason: 'Undo restores Keep');
      expect(find.text('Added to your plan'), findsOneWidget);
      await _reveal(tester, _notConcern);
      await tester.tap(_notConcern);
      await _idle(tester, harness);
      expect(harness.removed, {doorSuggestion().id});
      expect(earlierNotice, findsNothing);
      expect(harness.imports, hasLength(1), reason: 'No new finding IDs');
      ScaffoldMessenger.of(
        tester.element(find.byType(Scaffold).first),
      ).removeCurrentSnackBar();
      await tester.pumpAndSettle();
      expect(find.text('Continue'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('bathroom-continue')));
      await tester.pumpAndSettle();
      expect(harness.otherConcern, isFalse);
      expect(harness.continued, isTrue);
      expect(harness.continuedFindingId, isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'removing the device model keeps earlier observations visible as stale',
    (tester) async {
      await tester.runAsync(() => harness.seed(doorReview()));
      harness.imports.add(doorSuggestion());
      await _open(tester, harness);
      final remove = find.text('Remove device model');
      await _reveal(tester, remove);
      await tester.tap(remove);
      await tester.pump(const Duration(milliseconds: 300));
      await _tapDialogAction(tester, 'Remove model');
      await _idle(tester, harness);
      expect(harness.session.review.scene, isNull);
      await _reveal(tester, earlierNotice);
      final bytes = await tester.runAsync(
        () => harness.store.readBytes(harness.session.key),
      );
      expect((jsonDecode(utf8.decode(bytes!)) as Map)['scene'], isNull);
      expect(harness.imports, hasLength(1));
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'model announces its selected feature and controls meet a11y guidelines',
    (tester) async {
      final semantics = tester.ensureSemantics();
      await tester.runAsync(() => harness.seed(doorReview()));
      await _open(tester, harness);
      await _openModel(tester);
      await _reveal(tester, find.byType(BathroomModelView));
      final model = find.bySemanticsLabel(RegExp('^Partial room model'));
      expect(model, findsOneWidget);
      final scene = fictionalScanScene();
      expect(
        tester.getSemantics(model).value,
        'Selected: 1. ${scene.elements.first.kind.label}',
      );
      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      await expectLater(tester, meetsGuideline(iOSTapTargetGuideline));
      await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
      await expectLater(tester, meetsGuideline(textContrastGuideline));
      await _reveal(tester, _suggestionBox);
      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
      await expectLater(tester, meetsGuideline(textContrastGuideline));
      await tester.pumpWidget(const SizedBox.shrink());
      semantics.dispose();
    },
  );

  testWidgets(
    '320px viewport at 3.2x text keeps model controls and review content usable',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 812);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      await tester.runAsync(
        () => harness.seed(BathroomScanReview(scene: fictionalScanScene())),
      );
      await _open(tester, harness, textScale: 3.2);
      final fallback = find.byKey(const ValueKey('bathroom-use-manual'));
      await _reveal(tester, fallback);
      expect(tester.widget<OutlinedButton>(fallback).onPressed, isNotNull);
      expect(tester.takeException(), isNull);
      await _openModel(tester);
      await _reveal(tester, find.text('Top-down'));
      await tester.tap(find.text('Top-down'));
      await tester.pump();
      expect(tester.takeException(), isNull);
      await _reveal(tester, find.byTooltip('More view controls'));
      await tester.tap(find.byTooltip('More view controls'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Rotate model right'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(harness.session.review.reviewed, isEmpty);
      await _check(tester, harness, ScanDifficulty.enteringBathroom.label);
      await _reveal(tester, _suggestionBox);
      await tester.tap(_suggestionBox);
      await _idle(tester, harness);
      expect(harness.imports, hasLength(1));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'failed interrupted-capture cleanup does not trap Back or erase the durable model',
    (tester) async {
      final original = BathroomScanReview(
        scene: fictionalScanScene(),
        pendingScanId: '6c01f530-a6b1-4221-9034-c2a3731dde4d',
      );
      await tester.runAsync(() => harness.seed(original));
      harness.store.failNextWrite = true;
      await _open(tester, harness, initialize: false);
      await _until(tester, () => harness.store.failureObserved.isCompleted);
      await tester.pumpAndSettle();
      expect(
        find.textContaining('The private model could not be opened.'),
        findsOneWidget,
      );
      expect(harness.session.initialized, false);
      await tester.tap(find.text('Back to assessment'));
      await tester.pumpAndSettle();
      expect(find.text('Open scan review'), findsOneWidget);
      final bytes = await tester.runAsync(
        () => harness.store.readBytes(harness.session.key),
      );
      expect(jsonDecode(utf8.decode(bytes!)), original.toJson(_Harness.caseId));
      expect(harness.scanner.starts, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
