import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/app/live_app.dart';
import 'package:safe_at_home/features/cases/profile_response_state.dart';
import 'package:safe_at_home/shared/models/case_draft.dart';

import 'app_design_test.dart' show reveal, narrowLargeText;
import 'case_coordinator_test.dart' show FakeTransport;
import 'profile_recovery_test.dart'
    show ProfileTestStore, appFor, showProfile, press, cityField;

class ResponseFailureStore extends ProfileTestStore {
  bool failResponses = false, failResponseRead = false;
  @override
  Future<void> writeJson(String key, Map<String, Object?> value) async {
    if (failResponses && key.startsWith('profile-response.')) {
      throw StateError('Fictional response save failure');
    }
    await super.writeJson(key, value);
  }

  @override
  Future<Map<String, Object?>?> readJson(String key) {
    if (failResponseRead && key.startsWith('profile-response.')) {
      throw StateError('Fictional response read failure');
    }
    return super.readJson(key);
  }
}

String? selected(WidgetTester tester, String prefix) => tester
    .widget<RadioGroup<String>>(find.byKey(ValueKey('profile-$prefix-group')))
    .groupValue;

Future<void> choose(WidgetTester tester, String prefix, String label) async {
  final value = {
    'Not sure': 'notSure',
    'Own': 'owner',
    'Rent': 'renter',
    'Yes': 'yes',
    'No': 'no',
  }[label]!;
  await press(tester, 'profile-$prefix-$value');
}

Future<void> autosave(WidgetTester tester) async {
  FocusManager.instance.primaryFocus?.unfocus();
  await tester.pump(const Duration(seconds: 1));
  await tester.pumpAndSettle();
}

Future<void> reopen(WidgetTester tester, AppServices app) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
  await showProfile(tester, app);
}

ProfileResponseState responses(AppServices app) {
  final draft = app.coordinator.currentDraft();
  return app.profileResponses.currentFor(draft.caseId, draft.profile);
}

Object? coverageSelection(WidgetTester tester) => tester
    .widget<RadioGroup>(find.byKey(const ValueKey('profile-coverage-group')))
    .groupValue;

void main() {
  testWidgets(
    'new answers are blank and health coverage is first at large type',
    (tester) async {
      narrowLargeText(tester, scale: 3.2);
      final app = await appFor(ProfileTestStore());
      await showProfile(tester, app);
      expect(coverageSelection(tester), isNull);
      expect(selected(tester, 'tenure'), isNull);
      expect(selected(tester, 'consent'), isNull);
      expect(find.text('About the resident'), findsNothing);
      final orderedCards = ['coverage', 'tenure', 'consent'];
      for (var index = 0; index < orderedCards.length - 1; index++) {
        expect(
          tester
              .getTopLeft(
                find.byKey(ValueKey('profile-${orderedCards[index]}-card')),
              )
              .dy,
          lessThan(
            tester
                .getTopLeft(
                  find.byKey(
                    ValueKey('profile-${orderedCards[index + 1]}-card'),
                  ),
                )
                .dy,
          ),
        );
      }
      expect(
        tester
            .getTopLeft(find.byKey(const ValueKey('profile-consent-card')))
            .dy,
        lessThan(tester.getTopLeft(find.text('Location')).dy),
      );
      expect(
        tester.getTopLeft(find.text('Health coverage')).dy,
        lessThan(tester.getTopLeft(find.text('Location')).dy),
      );
      expect(
        responses(app).answeredCount(app.coordinator.currentDraft().profile),
        0,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'explicit Not sure survives reopen and unrelated profile edits without policy facts',
    (tester) async {
      final disk = ProfileTestStore();
      final app = await appFor(disk);
      await showProfile(tester, app);
      await press(tester, 'profile-unknown-health-coverage');
      await choose(tester, 'tenure', 'Not sure');
      await choose(tester, 'consent', 'Not sure');
      await autosave(tester);
      final draft = app.coordinator.currentDraft();
      expect(draft.profile.toJson().values, everyElement(isNull));
      expect(responses(app).answeredCount(draft.profile), 3);
      expect((app.transport as FakeTransport).requests, isEmpty);
      expect(disk.records.containsKey('profile-edit.${draft.caseId}'), false);
      await reopen(tester, app);
      expect(coverageSelection(tester), isNotNull);
      expect(selected(tester, 'tenure'), 'notSure');
      expect(selected(tester, 'consent'), 'notSure');
      await reveal(tester, cityField());
      await tester.enterText(cityField(), 'Fictional city');
      await autosave(tester);
      expect(
        responses(app).answeredCount(app.coordinator.currentDraft().profile),
        4,
      );
      await reopen(tester, app);
      expect(selected(tester, 'tenure'), 'notSure');
      expect(selected(tester, 'consent'), 'notSure');
      expect(responses(app).coverage, ProfileCoverageChoice.notSure);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('existing known coverage, rent and explicit no are preserved', (
    tester,
  ) async {
    final app = await appFor(ProfileTestStore());
    final draft = app.coordinator.currentDraft();
    await app.coordinator.updateDraft(
      CaseDraft.fromJson({
        ...draft.toJson(),
        'profile': {
          ...draft.profile.toJson(),
          'healthPlan': 'Fictional coverage',
          'tenure': 'renter',
          'ownerConsentReported': false,
        },
      }),
    );
    await showProfile(tester, app);
    expect(selected(tester, 'tenure'), 'renter');
    expect(selected(tester, 'consent'), 'no');
    expect(find.widgetWithText(TextFormField, 'Health plan'), findsOneWidget);
    expect(
      responses(app).answeredCount(app.coordinator.currentDraft().profile),
      3,
    );
    await choose(tester, 'tenure', 'Not sure');
    await choose(tester, 'consent', 'Not sure');
    await autosave(tester);
    expect(
      app.coordinator.currentDraft().profile.healthPlan,
      'Fictional coverage',
    );
    expect(app.coordinator.currentDraft().profile.tenure, isNull);
    expect(app.coordinator.currentDraft().profile.ownerConsentReported, isNull);
    expect(
      responses(app).answeredCount(app.coordinator.currentDraft().profile),
      3,
    );
  });

  testWidgets(
    'plan choice with unfinished name survives journal recovery and reopen',
    (tester) async {
      final disk = ProfileTestStore();
      final app = await appFor(disk);
      await showProfile(tester, app);
      final planChoice = find.byKey(const ValueKey('profile-has-health-plan'));
      await reveal(tester, planChoice);
      await tester.tap(planChoice);
      await tester.pump();
      final id = app.coordinator.currentDraft().caseId;
      expect(
        (disk.records['profile-edit.$id']!['responses'] as Map)['coverage'],
        'plan',
      );
      await reopen(tester, app);
      expect(find.widgetWithText(TextFormField, 'Health plan'), findsOneWidget);
      await autosave(tester);
      expect(app.coordinator.currentDraft().profile.healthPlan, isNull);
      expect(responses(app).coverage, ProfileCoverageChoice.plan);
      await reopen(tester, app);
      expect(find.widgetWithText(TextFormField, 'Health plan'), findsOneWidget);
      expect(
        responses(app).answeredCount(app.coordinator.currentDraft().profile),
        1,
      );
    },
  );

  testWidgets(
    'response save failure keeps journal and reports failure until retry succeeds',
    (tester) async {
      final disk = ResponseFailureStore()..failResponses = true;
      final app = await appFor(disk);
      await showProfile(tester, app);
      await press(tester, 'profile-unknown-health-coverage');
      await autosave(tester);
      final id = app.coordinator.currentDraft().caseId;
      expect(disk.records.containsKey('profile-edit.$id'), true);
      expect(disk.records.containsKey('profile-response.$id'), false);
      expect(
        find.text('Device save needs attention. Your entries are still here.'),
        findsOneWidget,
      );
      expect(
        responses(app).answeredCount(app.coordinator.currentDraft().profile),
        0,
      );
      disk.failResponses = false;
      await press(tester, 'profile-keep-edits');
      expect(disk.records.containsKey('profile-edit.$id'), false);
      expect(responses(app).coverage, ProfileCoverageChoice.notSure);
      await reopen(tester, app);
      expect(responses(app).coverage, ProfileCoverageChoice.notSure);
    },
  );

  testWidgets(
    'response read failure disables editing until saved choices can be restored',
    (tester) async {
      final disk = ResponseFailureStore();
      final app = await appFor(disk);
      final draft = app.coordinator.currentDraft();
      await app.profileResponses.write(
        draft.caseId,
        draft.profile,
        const ProfileResponseState(tenureNotSure: true),
      );
      disk.failResponseRead = true;
      await showProfile(tester, app);
      expect(tester.widget<TextFormField>(cityField()).enabled, false);
      expect(
        find.byKey(const ValueKey('profile-retry-responses')),
        findsOneWidget,
      );
      disk.failResponseRead = false;
      await press(tester, 'profile-retry-responses');
      expect(tester.widget<TextFormField>(cityField()).enabled, true);
      expect(selected(tester, 'tenure'), 'notSure');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'sections count answers, keep unanswered visible and explain sensitive asks',
    (tester) async {
      final app = await appFor(ProfileTestStore());
      await showProfile(tester, app);
      Finder text(String key) => find.byKey(ValueKey(key));
      String shown(String key) => tester.widget<Text>(text(key)).data!;
      expect(
        shown('profile-answered-total'),
        '0 of 8 answered · 8 not answered',
      );
      expect(shown('profile-answer-state-tenure'), 'Not answered');
      expect(
        find.descendant(
          of: text('profile-section-Home'),
          matching: find.text('0 of 2 answered'),
        ),
        findsOneWidget,
      );
      await choose(tester, 'tenure', 'Not sure');
      expect(shown('profile-answer-state-tenure'), 'Answered');
      expect(selected(tester, 'tenure'), 'notSure');
      expect(
        find.descendant(
          of: text('profile-section-Home'),
          matching: find.text('1 of 2 answered'),
        ),
        findsOneWidget,
      );
      expect(
        shown('profile-answered-total'),
        '1 of 8 answered · 7 not answered',
      );
      await press(tester, 'profile-has-health-plan');
      expect(text('profile-suggestion-coverage-healthPlan'), findsOneWidget);
      for (final key in ['profile-why-consent', 'profile-why-income']) {
        await reveal(tester, text(key));
        expect(text(key), findsOneWidget);
      }
      expect(text('profile-consent-card'), findsOneWidget);
      expect(text('profile-field-annualIncomeUsd'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'ZIP fills the state, stays correctable and saves only on this phone',
    (tester) async {
      final disk = ProfileTestStore();
      final app = await appFor(disk);
      await showProfile(tester, app);
      final zip = find.widgetWithText(TextFormField, 'ZIP code');
      String? state() => tester
          .widget<DropdownButtonFormField<String?>>(
            find.byKey(const ValueKey('profile-state')),
          )
          .initialValue;
      await reveal(tester, zip);
      expect(
        tester.getTopLeft(zip).dy,
        lessThan(tester.getTopLeft(cityField()).dy),
      );
      expect(state(), isNull);
      await tester.enterText(zip, '96910');
      await tester.pumpAndSettle();
      expect(state(), isNull);
      expect(
        find.text('Choose the state. This ZIP code doesn’t tell us which one.'),
        findsOneWidget,
      );
      await tester.enterText(zip, '951');
      await press(tester, 'profile-keep-edits');
      await reveal(tester, find.text('Enter a 5-digit ZIP code.'));

      await tester.enterText(zip, '95112');
      await tester.pumpAndSettle();
      expect(state(), 'CA');
      expect(
        find.text('Filled from ZIP code 95112. You can change it.'),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('profile-state')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Arizona').last);
      await tester.pumpAndSettle();
      expect(state(), 'AZ');
      expect(find.textContaining('Filled from ZIP code'), findsNothing);
      await autosave(tester);
      final draft = app.coordinator.currentDraft();
      expect((responses(app).stateCode, responses(app).zip), ('AZ', '95112'));
      expect(draft.profile.toJson().values, everyElement(isNull));
      expect(draft.profile.toJson().keys, isNot(contains('zip')));
      expect((app.transport as FakeTransport).requests, isEmpty);
      expect(
        find.byKey(const ValueKey('profile-location-device-note')),
        findsOneWidget,
      );

      await reopen(tester, app);
      await reveal(tester, zip);
      expect(find.text('95112'), findsOneWidget);
      expect(state(), 'AZ');
      expect(tester.takeException(), isNull);
    },
  );
}
