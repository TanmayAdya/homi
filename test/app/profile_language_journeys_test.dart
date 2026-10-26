import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/features/cases/profile_editor_screen.dart';
import 'package:safe_at_home/l10n/app_localizations.dart';

import 'app_design_test.dart' show narrowLargeText;
import 'assessment_language_journeys_test.dart' show locales;
import 'core_localization_test.dart' show localized;
import 'profile_recovery_test.dart' show ProfileTestStore, appFor, unfinished;

Future<void> tap(WidgetTester tester, Finder finder) async {
  final panel = find.ancestor(
    of: finder,
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
      tester.element(finder),
    ).position.ensureVisible(tester.renderObject(finder));
    await tester.pumpAndSettle();
    final visible = tester.getRect(finder).intersect(tester.getRect(panel));
    expect(visible.height, greaterThanOrEqualTo(48));
    await tester.tapAt(visible.center);
    await tester.pumpAndSettle();
    return;
  }

  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

void main() {
  for (final locale in locales) {
    final words = AppLocalizations(locale);
    String tr(String text, [Map<String, Object?> values = const {}]) =>
        words.text(text, values);
    Finder field(String label) => find.widgetWithText(TextFormField, tr(label));

    for (final large in [false, true]) {
      testWidgets(
        '$locale long profile questions are fully visible at ${large ? '3.2x' : 'normal'} text',
        (tester) async {
          narrowLargeText(tester, scale: large ? 3.2 : 1);
          final app = await appFor(ProfileTestStore());
          await tester.pumpWidget(
            localized(locale, ProfileEditorScreen(services: app)),
          );
          await tester.pumpAndSettle();
          for (final text in [
            'Has a health plan',
            'No health coverage',
            'Not sure',
          ]) {
            expect(tr(text), isNot(text));
            expect(
              find.descendant(
                of: find.byKey(const ValueKey('profile-coverage-card')),
                matching: find.text(tr(text)),
              ),
              findsOneWidget,
            );
          }
          for (final key in [
            'annualIncomeUsd',
            'tenure',
            'consent',
            if (large) ...['city', 'county', 'ageYears', 'householdSize'],
          ]) {
            final label = find.byKey(ValueKey('profile-full-label-$key'));
            await tester.ensureVisible(label);
            await tester.pumpAndSettle();
            final text = tester.widget<Text>(label);
            final paragraph = tester.renderObject<RenderParagraph>(label);
            expect(text.data, isNotEmpty);
            expect(paragraph.didExceedMaxLines, false, reason: '$locale $key');
            expect(paragraph.maxLines, isNull);
            expect(tester.getRect(label).width, lessThanOrEqualTo(320));
            if (large && key == 'consent') {
              expect(paragraph.size.height, greaterThan(55));
            }
          }
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
        },
      );
    }

    testWidgets(
      '$locale profile recovery, county replacement and validation at 320px/3.2x',
      (tester) async {
        narrowLargeText(tester, scale: 3.2);
        final store = ProfileTestStore();
        final app = await appFor(store);
        final id = app.coordinator.currentDraft().caseId;
        store.records['profile-edit.$id'] = unfinished();
        await tester.pumpWidget(
          localized(locale, ProfileEditorScreen(services: app)),
        );
        await tester.pumpAndSettle();
        expect(find.text(tr('Compare unfinished edits')), findsOneWidget);
        expect(
          find.text(tr('Unfinished: {value}', {'value': tr('No')})),
          findsOneWidget,
        );
        expect(tester.widget<TextFormField>(field('City')).enabled, false);
        await tap(
          tester,
          find.byKey(const ValueKey('profile-review-recovered')),
        );
        expect(
          tester.widget<TextFormField>(field('City')).controller!.text,
          'Unfinished fictional city',
        );
        Future<void> type(String label, String value) async {
          await tester.ensureVisible(field(label));
          await tester.pumpAndSettle();
          await tester.enterText(field(label), value);
          await tester.pumpAndSettle();
        }

        await type('County', 'Original county {county}');
        await type('City', 'San Jo');
        await tap(
          tester,
          find.byKey(const ValueKey('profile-suggestion-city-San José')),
        );
        expect(find.text(tr('Update county?')), findsOneWidget);
        final prompt = tr(
          '{city} is in {county} County. Replace your current county, “{currentCounty}”, with “{county}”?',
          {
            'city': 'San José',
            'county': 'Santa Clara',
            'currentCounty': 'Original county {county}',
          },
        );
        expect(find.text(prompt), findsOneWidget);
        await tap(
          tester,
          find.byKey(const ValueKey('profile-keep-existing-county')),
        );
        expect(
          tester.widget<TextFormField>(field('County')).controller!.text,
          'Original county {county}',
        );
        await type('City', 'San Jo');
        await tap(
          tester,
          find.byKey(const ValueKey('profile-suggestion-city-San José')),
        );
        await tap(
          tester,
          find.byKey(const ValueKey('profile-use-city-county')),
        );
        expect(
          tester.widget<TextFormField>(field('County')).controller!.text,
          'Santa Clara',
        );
        await tap(
          tester,
          find.byKey(const ValueKey('profile-has-health-plan')),
        );
        await type('Health plan', 'scfhp');
        await tap(
          tester,
          find.byKey(
            const ValueKey(
              'profile-suggestion-healthPlan-Santa Clara Family Health Plan',
            ),
          ),
        );
        expect(
          tester.widget<TextFormField>(field('Health plan')).controller!.text,
          'Santa Clara Family Health Plan',
        );
        await type('Age in years', 'invalid');
        await tap(tester, find.byKey(const ValueKey('profile-keep-edits')));
        final validation = tr('Enter a whole number in the supported range.');
        expect(find.text(validation), findsOneWidget);
        final paragraph = tester.renderObject<RenderParagraph>(
          find.text(validation),
        );
        expect(paragraph.didExceedMaxLines, false);
        await type('Age in years', '75');
        await type('Annual household income (USD)', '0');
        FocusManager.instance.primaryFocus?.unfocus();
        await tester.pumpAndSettle();
        await tap(tester, find.byKey(const ValueKey('profile-keep-edits')));
        expect(app.coordinator.currentDraft().profile.city, 'San José');
        expect(app.coordinator.currentDraft().profile.county, 'Santa Clara');
        expect(app.coordinator.currentDraft().profile.ageYears, 75);
        expect(app.coordinator.currentDraft().profile.annualIncomeUsd, 0);
        expect(
          app.coordinator.currentDraft().profile.ownerConsentReported,
          false,
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}
