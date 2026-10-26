import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'app_design_test.dart' show narrowLargeText;
import 'case_coordinator_test.dart' show FakeTransport;
import 'profile_recovery_test.dart'
    show ProfileTestStore, appFor, showProfile, press;

Finder field(String label) => find.widgetWithText(TextFormField, label);
Finder suggestion(String field, String value) =>
    find.byKey(ValueKey('profile-suggestion-$field-$value'));

Future<void> type(WidgetTester tester, String label, String text) async {
  if (label == 'Health plan' && field(label).evaluate().isEmpty) {
    final hasPlan = find.byKey(const ValueKey('profile-has-health-plan'));
    await tester.ensureVisible(hasPlan);
    await tester.pumpAndSettle();
    await tester.tap(hasPlan);
    await tester.pumpAndSettle();
  }
  await tester.ensureVisible(field(label));
  await tester.pumpAndSettle();
  await tester.enterText(field(label), text);
  await tester.pumpAndSettle();
}

Future<void> choose(WidgetTester tester, String key, String value) async {
  final option = suggestion(key, value);
  final panel = find.ancestor(
    of: option,
    matching: find.byWidgetPredicate(
      (widget) =>
          widget is Material &&
          widget.key is ValueKey<String> &&
          (widget.key! as ValueKey<String>).value.startsWith(
            'profile-suggestions-',
          ),
    ),
  );
  if (panel.evaluate().isNotEmpty) {
    await Scrollable.of(
      tester.element(option),
    ).position.ensureVisible(tester.renderObject(option));
    await tester.pumpAndSettle();
    final visible = tester.getRect(option).intersect(tester.getRect(panel));
    expect(visible.height, greaterThanOrEqualTo(48));
    await tester.tapAt(visible.center);
    await tester.pumpAndSettle();
    return;
  }

  await tester.ensureVisible(option);
  await tester.pumpAndSettle();
  await tester.tap(option);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'choosing a city autofills county and keeps both fields before sync',
    (tester) async {
      final store = ProfileTestStore();
      final app = await appFor(store);
      await showProfile(tester, app);
      await type(tester, 'City', 'san jo');
      expect(suggestion('city', 'San José'), findsOneWidget);
      await choose(tester, 'city', 'San José');
      expect(
        tester.widget<TextFormField>(field('City')).controller!.text,
        'San José',
      );
      expect(
        tester.widget<TextFormField>(field('County')).controller!.text,
        'Santa Clara',
      );
      expect(
        find.byKey(const ValueKey('profile-suggestions-city')),
        findsNothing,
      );
      expect(
        find.text('Filled from San José. You can change it.'),
        findsOneWidget,
      );
      await type(tester, 'Health plan', 'scfhp');
      await choose(tester, 'healthPlan', 'Santa Clara Family Health Plan');
      final id = app.coordinator.currentDraft().caseId;
      final journal = store.records['profile-edit.$id']!['values'] as Map;
      expect(journal['city'], 'San José');
      expect(journal['county'], 'Santa Clara');
      expect(journal['healthPlan'], 'Santa Clara Family Health Plan');
      expect(app.coordinator.currentDraft().profile.healthPlan, isNull);
      await press(tester, 'profile-keep-edits');
      final saved = app.coordinator.currentDraft().profile;
      expect(saved.city, 'San José');
      expect(saved.county, 'Santa Clara');
      expect(saved.healthPlan, 'Santa Clara Family Health Plan');
      expect(
        (app.transport as FakeTransport).requests.where(
          (r) => r.endpoint.path == '/v1/create-case',
        ),
        hasLength(1),
      );
      expect(app.coordinator.currentCase().profile.county, 'Santa Clara');
    },
  );

  testWidgets(
    'custom values and blank unknowns remain valid and recover after reopen',
    (tester) async {
      final store = ProfileTestStore();
      final app = await appFor(store);
      await showProfile(tester, app);
      await type(tester, 'City', 'Fictional unlisted town');
      expect(
        find.byKey(const ValueKey('profile-suggestions-city')),
        findsNothing,
      );
      await type(tester, 'Health plan', 'Fictional unlisted plan');
      await tester.pumpWidget(const SizedBox.shrink());
      await showProfile(tester, app);
      expect(
        tester.widget<TextFormField>(field('City')).controller!.text,
        'Fictional unlisted town',
      );
      expect(
        tester.widget<TextFormField>(field('Health plan')).controller!.text,
        'Fictional unlisted plan',
      );
      await press(tester, 'profile-keep-edits');
      expect(
        app.coordinator.currentDraft().profile.city,
        'Fictional unlisted town',
      );
      expect(app.coordinator.currentDraft().profile.county, isNull);
      expect(
        app.coordinator.currentDraft().profile.healthPlan,
        'Fictional unlisted plan',
      );
    },
  );

  testWidgets(
    'autofilled city and county recover together and county remains editable',
    (tester) async {
      final store = ProfileTestStore();
      final app = await appFor(store);
      await showProfile(tester, app);
      await type(tester, 'City', 'san jo');
      await choose(tester, 'city', 'San José');
      await tester.pumpWidget(const SizedBox.shrink());
      await showProfile(tester, app);
      expect(
        tester.widget<TextFormField>(field('City')).controller!.text,
        'San José',
      );
      expect(
        tester.widget<TextFormField>(field('County')).controller!.text,
        'Santa Clara',
      );
      await type(tester, 'County', 'Fictional custom county');
      FocusManager.instance.primaryFocus?.unfocus();
      await press(tester, 'profile-keep-edits');
      expect(
        app.coordinator.currentDraft().profile.county,
        'Fictional custom county',
      );
    },
  );

  for (final replace in [false, true]) {
    testWidgets(
      'a different existing county is ${replace ? 'replaced only after confirmation' : 'kept when replacement is declined'}',
      (tester) async {
        if (replace) narrowLargeText(tester, scale: 3.2);
        final store = ProfileTestStore();
        final app = await appFor(store);
        await showProfile(tester, app);
        await type(tester, 'County', 'San Mateo');
        await type(tester, 'City', 'san jo');
        await choose(tester, 'city', 'San José');
        expect(find.text('Update county?'), findsOneWidget);
        expect(
          tester.widget<TextFormField>(field('County')).controller!.text,
          'San Mateo',
        );
        final decision = find.byKey(
          ValueKey(
            replace
                ? 'profile-use-city-county'
                : 'profile-keep-existing-county',
          ),
        );
        await tester.ensureVisible(decision);
        await tester.pumpAndSettle();
        await tester.tap(decision);
        await tester.pumpAndSettle();
        expect(
          tester.widget<TextFormField>(field('City')).controller!.text,
          'San José',
        );
        expect(
          tester.widget<TextFormField>(field('County')).controller!.text,
          replace ? 'Santa Clara' : 'San Mateo',
        );
        final journal =
            store.records['profile-edit.${app.coordinator.currentDraft().caseId}']!['values']
                as Map;
        expect(journal['city'], 'San José');
        expect(journal['county'], replace ? 'Santa Clara' : 'San Mateo');
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'an equivalent manually entered county is retained without a prompt',
    (tester) async {
      final app = await appFor(ProfileTestStore());
      await showProfile(tester, app);
      await type(tester, 'County', '  Santa Clara County  ');
      await type(tester, 'City', 'san jo');
      await choose(tester, 'city', 'San José');
      expect(find.text('Update county?'), findsNothing);
      expect(
        tester.widget<TextFormField>(field('County')).controller!.text,
        '  Santa Clara County  ',
      );
    },
  );

  testWidgets('typing a city name alone never guesses a county', (
    tester,
  ) async {
    final app = await appFor(ProfileTestStore());
    await showProfile(tester, app);
    await type(tester, 'City', 'San José');
    expect(tester.widget<TextFormField>(field('County')).controller!.text, '');
    FocusManager.instance.primaryFocus?.unfocus();
    await press(tester, 'profile-keep-edits');
    expect(app.coordinator.currentDraft().profile.county, isNull);
  });

  testWidgets(
    'late county confirmation cannot change a new case or old journal',
    (tester) async {
      final store = ProfileTestStore();
      final app = await appFor(store);
      await showProfile(tester, app);
      final id = app.coordinator.currentDraft().caseId;
      await type(tester, 'County', 'San Mateo');
      await type(tester, 'City', 'san jo');
      await choose(tester, 'city', 'San José');
      await app.coordinator.createDraft();
      await tester.tap(find.byKey(const ValueKey('profile-use-city-county')));
      await tester.pumpAndSettle();
      expect(app.coordinator.currentDraft().profile.city, isNull);
      expect(app.coordinator.currentDraft().profile.county, isNull);
      final journal = store.records['profile-edit.$id']!['values'] as Map;
      expect(journal['county'], 'San Mateo');
      expect(
        tester.widget<TextFormField>(field('County')).controller!.text,
        'San Mateo',
      );
    },
  );

  testWidgets('clearing a selected answer restores unknown', (tester) async {
    final store = ProfileTestStore();
    final app = await appFor(store);
    await showProfile(tester, app);
    await type(tester, 'County', 'mateo');
    await choose(tester, 'county', 'San Mateo');
    await type(tester, 'County', '');
    expect(
      find.byKey(const ValueKey('profile-suggestions-county')),
      findsNothing,
    );
    FocusManager.instance.primaryFocus?.unfocus();
    await press(tester, 'profile-keep-edits');
    expect(app.coordinator.currentDraft().profile.county, isNull);
  });

  testWidgets('stale suggestion callback cannot modify a switched case', (
    tester,
  ) async {
    final store = ProfileTestStore();
    final app = await appFor(store);
    await showProfile(tester, app);
    final oldId = app.coordinator.currentDraft().caseId;
    await type(tester, 'City', 'san jo');
    final select = tester
        .widget<TextButton>(suggestion('city', 'San José'))
        .onPressed!;
    await app.coordinator.createDraft();
    select();
    await tester.pumpAndSettle();
    expect(app.coordinator.currentDraft().profile.city, isNull);
    expect(
      (store.records['profile-edit.$oldId']!['values'] as Map)['city'],
      'san jo',
    );
    expect(
      tester.widget<TextFormField>(field('City')).controller!.text,
      'san jo',
    );
    expect(
      find.byKey(const ValueKey('profile-suggestions-city')),
      findsNothing,
    );
  });

  testWidgets('keyboard can tab into a suggestion and select it', (
    tester,
  ) async {
    final app = await appFor(ProfileTestStore());
    await showProfile(tester, app);
    await type(tester, 'City', 'san jo');
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    expect(suggestion('city', 'San José'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextFormField>(field('City')).controller!.text,
      'San José',
    );
  });

  testWidgets('mouse press keeps suggestions alive until selection completes', (
    tester,
  ) async {
    final app = await appFor(ProfileTestStore());
    await showProfile(tester, app);
    await type(tester, 'City', 'san jo');
    final option = suggestion('city', 'San José');
    await tester.ensureVisible(option);
    await tester.pumpAndSettle();
    final pointer = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await pointer.down(tester.getCenter(option));
    await tester.pumpAndSettle();
    expect(option, findsOneWidget);
    await pointer.up();
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextFormField>(field('City')).controller!.text,
      'San José',
    );
  });

  testWidgets('large text suggestions wrap and retain labeled touch targets', (
    tester,
  ) async {
    narrowLargeText(tester, scale: 3.2);
    final semantics = tester.ensureSemantics();
    try {
      final app = await appFor(ProfileTestStore());
      await showProfile(tester, app);
      await type(tester, 'Health plan', 'hpsm');
      final option = suggestion('healthPlan', 'Health Plan of San Mateo');
      await tester.ensureVisible(option);
      await tester.pumpAndSettle();
      expect(tester.getSize(option).height, greaterThanOrEqualTo(48));
      expect(
        tester.getSemantics(option).label,
        contains('Health Plan of San Mateo'),
      );
      expect(tester.takeException(), isNull);
      await choose(tester, 'healthPlan', 'Health Plan of San Mateo');
      expect(
        tester.widget<TextFormField>(field('Health plan')).controller!.text,
        'Health Plan of San Mateo',
      );
    } finally {
      semantics.dispose();
    }
  });
}
