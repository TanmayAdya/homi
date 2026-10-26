import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/app/live_app.dart';
import 'package:safe_at_home/app/theme.dart';
import 'package:safe_at_home/features/cases/profile_editor_screen.dart';
import 'package:safe_at_home/shared/models/case_draft.dart';
import 'package:safe_at_home/shared/models/contracts.dart';
import 'app_design_test.dart' show narrowLargeText, reveal;
import 'case_coordinator_test.dart' show FakeTransport;
import 'live_workflows_test.dart' show MemoryPrivateStore, services;
import '../services/case_evidence_api_client_test.dart' as http;

Map<String, Object?> unfinished() => {
  'values': {'city': 'Unfinished fictional city', 'annualIncomeUsd': '0'},
  'tenure': null,
  'consent': false,
};

class ProfileTestStore extends MemoryPrivateStore {
  bool failWrite = false, failDelete = false, failCase = false;
  bool blockRead = false, blockWrite = false;
  final entered = Completer<void>(), release = Completer<void>();
  @override
  Future<Map<String, Object?>?> readJson(String key) async {
    if (key.startsWith('profile-edit.') && blockRead && !entered.isCompleted) {
      entered.complete();
      await release.future;
    }
    return super.readJson(key);
  }

  @override
  Future<void> writeJson(String key, Map<String, Object?> value) async {
    if (key.startsWith('case.') && failCase ||
        key.startsWith('profile-edit.') && failWrite) {
      throw StateError('Fictional full private storage');
    }
    if (key.startsWith('profile-edit.') && blockWrite && !entered.isCompleted) {
      entered.complete();
      await release.future;
    }
    await super.writeJson(key, value);
  }

  @override
  Future<void> delete(String key) async {
    if (key.startsWith('profile-edit.') && failDelete) {
      throw StateError('Fictional private deletion failure');
    }
    await super.delete(key);
  }
}

Future<AppServices> appFor(ProfileTestStore store, {bool saved = false}) async {
  final transport = FakeTransport((request) async {
    if (request.endpoint.path != '/v1/create-case') {
      throw StateError('Unexpected network');
    }
    return http.jsonResponse({...http.requestJson(request), 'revision': 1});
  });
  final app = services(store, transport);
  addTearDown(app.dispose);
  await app.coordinator.createDraft();
  if (saved) await app.coordinator.save();
  return app;
}

Future<void> showProfile(WidgetTester tester, AppServices app) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: SafeAtHomeTheme.light(),
      home: ProfileEditorScreen(services: app),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> press(WidgetTester tester, String key) async {
  final button = find.byKey(ValueKey(key));
  await reveal(tester, button);
  await tester.ensureVisible(button);
  await tester.pumpAndSettle();
  await tester.tap(button);
  await tester.pumpAndSettle();
}

Finder cityField() => find.widgetWithText(TextFormField, 'City');

void main() {
  testWidgets(
    'legacy comparison wraps at largest text and requires a deliberate choice',
    (tester) async {
      narrowLargeText(tester, scale: 3.2);
      final store = ProfileTestStore();
      final app = await appFor(store);
      final id = app.coordinator.currentDraft().caseId;
      store.records['profile-edit.$id'] = unfinished();
      await showProfile(tester, app);
      await reveal(
        tester,
        find.byKey(const ValueKey('profile-recovery-comparison')),
      );
      expect(find.text('Compare unfinished edits'), findsOneWidget);
      expect(find.text('Unfinished: 0'), findsOneWidget);
      expect(find.text('Unfinished: No'), findsOneWidget);
      expect(find.text('Current: Unknown'), findsWidgets);
      await reveal(tester, cityField());
      expect(tester.widget<TextFormField>(cityField()).enabled, false);
      await reveal(tester, find.byKey(const ValueKey('profile-keep-edits')));
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('profile-keep-edits')),
            )
            .onPressed,
        isNull,
      );
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('profile-review-recovered')),
        -250,
        scrollable: find.byType(Scrollable).first,
        maxScrolls: 100,
      );
      await press(tester, 'profile-review-recovered');
      expect(store.records['profile-edit.$id']!['version'], 2);
      expect(store.records['profile-edit.$id']!['baseCaseRevision'], isNull);
      expect(
        store.records['profile-edit.$id']!['baseProfileFingerprint'],
        matches(RegExp('^[a-f0-9]{64}\$')),
      );
      expect(app.coordinator.currentDraft().profile.city, isNull);
      await press(tester, 'profile-keep-edits');
      expect(
        app.coordinator.currentDraft().profile.city,
        'Unfinished fictional city',
      );
      expect(app.coordinator.currentDraft().profile.annualIncomeUsd, 0);
      expect(
        app.coordinator.currentDraft().profile.ownerConsentReported,
        false,
      );
      expect(app.coordinator.currentDraft().profile.ageYears, isNull);
      expect(store.records.containsKey('profile-edit.$id'), false);
      expect((app.transport as FakeTransport).requests, hasLength(1));
      expect(
        app.coordinator.currentCase().profile.city,
        'Unfinished fictional city',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'keeping current details removes only the reviewed unfinished journal',
    (tester) async {
      final store = ProfileTestStore();
      final app = await appFor(store);
      final id = app.coordinator.currentDraft().caseId;
      store.records['profile-edit.$id'] = unfinished();
      store.records['profile-edit.another-fictional-case'] = unfinished();
      final original = app.coordinator.currentDraft().toJson();
      await showProfile(tester, app);
      await press(tester, 'profile-keep-current');
      expect(store.records.containsKey('profile-edit.$id'), false);
      expect(
        store.records.containsKey('profile-edit.another-fictional-case'),
        true,
      );
      expect(app.coordinator.currentDraft().toJson(), original);
      await tester.scrollUntilVisible(
        cityField(),
        -200,
        scrollable: find.byType(Scrollable).first,
        maxScrolls: 100,
      );
      expect(tester.widget<TextFormField>(cityField()).enabled, true);
      expect(tester.widget<TextFormField>(cityField()).controller!.text, '');
      expect(tester.takeException(), isNull);
    },
  );

  for (final change in ['none', 'revision', 'profile']) {
    testWidgets(
      'versioned profile journal checks its base after $change change',
      (tester) async {
        final store = ProfileTestStore();
        final app = await appFor(store, saved: true);
        await showProfile(tester, app);
        await reveal(tester, cityField());
        await tester.enterText(cityField(), 'Unfinished fictional city');
        await tester.pumpAndSettle();
        await tester.pumpWidget(
          const MaterialApp(home: Text('Between editors')),
        );
        if (change == 'revision') {
          await app.coordinator.adoptRemoteSnapshot(
            CaseSnapshot.fromJson({
              ...app.coordinator.currentCase().toJson(),
              'revision': 2,
            }),
          );
        } else if (change == 'profile') {
          await app.coordinator.updateDraft(
            CaseDraft.fromJson({
              ...app.coordinator.currentDraft().toJson(),
              'profile': {
                ...app.coordinator.currentDraft().profile.toJson(),
                'city': 'Current fictional city',
              },
            }),
          );
        }
        await showProfile(tester, app);
        if (change == 'none') {
          expect(
            find.text('Recovered unfinished edits from this device.'),
            findsOneWidget,
          );
          expect(
            find.byKey(const ValueKey('profile-recovery-comparison')),
            findsNothing,
          );
          await reveal(tester, cityField());
          expect(
            tester.widget<TextFormField>(cityField()).controller!.text,
            'Unfinished fictional city',
          );
          expect(tester.widget<TextFormField>(cityField()).enabled, true);
        } else {
          await reveal(
            tester,
            find.byKey(const ValueKey('profile-recovery-comparison')),
          );
          expect(find.text('Compare unfinished edits'), findsOneWidget);
          expect(
            find.text('Unfinished: Unfinished fictional city'),
            findsOneWidget,
          );
          await reveal(tester, cityField());
          expect(tester.widget<TextFormField>(cityField()).enabled, false);
        }
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final action in ['write', 'delete']) {
    testWidgets(
      'failed recovery $action retains both choices for explicit retry',
      (tester) async {
        final store = ProfileTestStore();
        final app = await appFor(store);
        final key = 'profile-edit.${app.coordinator.currentDraft().caseId}';
        store.records[key] = unfinished();
        await showProfile(tester, app);
        store.failWrite = action == 'write';
        store.failDelete = action == 'delete';
        final button = action == 'write'
            ? 'profile-review-recovered'
            : 'profile-keep-current';
        await press(tester, button);
        expect(store.records[key], unfinished());
        expect(
          find.byKey(const ValueKey('profile-recovery-comparison')),
          findsOneWidget,
        );
        expect(app.coordinator.currentDraft().profile.city, isNull);
        store.failWrite = store.failDelete = false;
        await press(tester, button);
        expect(
          find.byKey(const ValueKey('profile-recovery-comparison')),
          findsNothing,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final departure in ['another case', 'same case reopened', 'disposed']) {
    testWidgets('late profile restore is rejected after $departure', (
      tester,
    ) async {
      final store = ProfileTestStore();
      final app = await appFor(store);
      final original = app.coordinator.currentDraft().caseId;
      store.records['profile-edit.$original'] = unfinished();
      await app.coordinator.createDraft();
      final other = app.coordinator.currentDraft().caseId;
      await app.coordinator.restoreLocal(original);
      store.blockRead = true;
      await tester.pumpWidget(
        MaterialApp(
          theme: SafeAtHomeTheme.light(),
          home: ProfileEditorScreen(services: app),
        ),
      );
      await tester.pump();
      expect(store.entered.isCompleted, true);
      if (departure == 'disposed') {
        await tester.pumpWidget(const MaterialApp(home: Text('Other screen')));
      } else {
        await app.coordinator.restoreLocal(other);
        if (departure == 'same case reopened') {
          await app.coordinator.restoreLocal(original);
        }
      }
      store.release.complete();
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('profile-recovery-comparison')),
        findsNothing,
      );
      expect(store.records['profile-edit.$original'], unfinished());
      expect(store.records.containsKey('profile-edit.$other'), false);
      expect(app.coordinator.currentDraft().profile.city, isNull);
      expect(tester.takeException(), isNull);
    });
  }

  for (final departure in ['same case reopened', 'disposed']) {
    testWidgets('late recovery choice cannot activate edits after $departure', (
      tester,
    ) async {
      final store = ProfileTestStore();
      final app = await appFor(store);
      final original = app.coordinator.currentDraft().caseId;
      store.records['profile-edit.$original'] = unfinished();
      await showProfile(tester, app);
      final button = find.byKey(const ValueKey('profile-review-recovered'));
      await reveal(tester, button);
      await tester.ensureVisible(button);
      store.blockWrite = true;
      await tester.tap(button);
      await tester.pump();
      expect(store.entered.isCompleted, true);
      if (departure == 'disposed') {
        await tester.pumpWidget(const MaterialApp(home: Text('Other screen')));
      } else {
        await app.coordinator.restoreLocal(original);
      }
      store.release.complete();
      await tester.pumpAndSettle();
      expect(app.coordinator.currentDraft().profile.city, isNull);
      expect(
        find.textContaining('Recovered edits are ready to review.'),
        findsNothing,
      );
      expect(store.records['profile-edit.$original']!['version'], 2);
      expect((app.transport as FakeTransport).requests, isEmpty);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'keeping current details cannot erase recovery while its device save fails',
    (tester) async {
      final store = ProfileTestStore();
      final app = await appFor(store);
      final key = 'profile-edit.${app.coordinator.currentDraft().caseId}';
      store.records[key] = unfinished();
      store.failCase = true;
      await expectLater(
        app.coordinator.updateDraft(
          CaseDraft.fromJson({
            ...app.coordinator.currentDraft().toJson(),
            'profile': {
              ...app.coordinator.currentDraft().profile.toJson(),
              'city': 'Current unsaved fictional city',
            },
          }),
        ),
        throwsStateError,
      );
      await showProfile(tester, app);
      await press(tester, 'profile-keep-current');
      expect(store.records[key], unfinished());
      expect(app.coordinator.localSaveFailed, true);
      store.failCase = false;
      await press(tester, 'profile-keep-current');
      expect(store.records.containsKey(key), false);
      expect(app.coordinator.localSaveFailed, false);
      final storedCase =
          store.records['case.${app.coordinator.currentDraft().caseId}']!['draft']
              as Map;
      expect(
        (storedCase['profile'] as Map)['city'],
        'Current unsaved fictional city',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('failed case persistence leaves profile keep action retryable', (
    tester,
  ) async {
    final store = ProfileTestStore();
    final app = await appFor(store);
    final key = 'profile-edit.${app.coordinator.currentDraft().caseId}';
    await showProfile(tester, app);
    await reveal(tester, cityField());
    await tester.enterText(cityField(), 'Fictional retry city');
    await tester.pumpAndSettle();
    store.failCase = true;
    await press(tester, 'profile-keep-edits');
    expect(app.coordinator.localSaveFailed, true);
    expect(store.records.containsKey(key), true);
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const ValueKey('profile-keep-edits')),
          )
          .onPressed,
      isNotNull,
    );
    store.failCase = false;
    await press(tester, 'profile-keep-edits');
    expect(app.coordinator.localSaveFailed, false);
    expect(app.coordinator.currentDraft().profile.city, 'Fictional retry city');
    expect(store.records.containsKey(key), false);
    expect(tester.takeException(), isNull);
  });
}
