import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/features/assistant/assistant_context_v2.dart';
import 'package:safe_at_home/features/assistant/assistant_model.dart';
import 'package:safe_at_home/features/assistant/plan_assistant_screen.dart';
import 'package:safe_at_home/l10n/app_localizations.dart';
import 'package:safe_at_home/l10n/catalogs/assistant_context.dart';
import 'package:safe_at_home/shared/navigation/homi_destination.dart';

import 'assistant_test.dart' show app, FakeModel;

class GuidanceModel extends FakeModel implements ContextualAssistantModel {
  int checks = 0;
  String raw = jsonEncode({
    'text': 'Review the current plan in Help.',
    'sourceIds': ['app.help'],
    'openSourceId': 'app.help',
  });

  @override
  Future<AssistantAvailability> availability(String locale) async {
    checks++;
    return status;
  }

  @override
  Future<String> respondWithContext({
    required String requestId,
    required String locale,
    required String question,
    required String history,
    required String findings,
    required String appContext,
    required String guide,
  }) async {
    requests.add({
      'question': question,
      'history': history,
      'findings': findings,
    });
    if (failure != null) throw failure!;
    return raw;
  }
}

AssistantContextV2 contextFor({
  bool authorized = true,
  bool selected = true,
  FeatureAvailability help = FeatureAvailability.supported,
  int revision = 1,
}) => AssistantContextV2.fromAuthorizedRecords(
  scopeKey: 'fictional-account',
  authorized: authorized,
  access: const AssistantRecordAccess.owner(),
  destination: HomiDestination.plan,
  caseId: selected ? 'fictional-plan' : null,
  caseRevision: selected ? revision : null,
  capabilities: {
    for (final destination in HomiDestination.values)
      destination: FeatureAvailability.supported,
    HomiDestination.help: help,
  },
);

Future<void> tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Finder guidance() => find.byKey(const ValueKey('assistant-app-guidance'));

void main() {
  test('draft guidance respects no-plan, unavailable and revoked context', () {
    final noPlan = contextFor(selected: false);
    expect(
      noPlan.resolveOpen(noPlan.draftPreparationReply())!.destination,
      HomiDestination.plan,
    );
    final unavailable = contextFor(
      help: FeatureAvailability.temporarilyUnavailable,
    );
    expect(
      unavailable.resolveOpen(unavailable.draftPreparationReply())!.destination,
      HomiDestination.plan,
    );
    final ready = contextFor();
    final reply = ready.draftPreparationReply();
    expect(ready.resolveOpen(reply)!.destination, HomiDestination.help);
    expect(contextFor(revision: 2).resolveOpen(reply), isNull);
    expect(contextFor(authorized: false).resolveOpen(reply), isNull);
  });

  for (final availability in [
    AssistantAvailability.ready,
    AssistantAvailability.unsupportedDevice,
  ]) {
    testWidgets(
      'built-in prompts are labeled app guidance without model calls: $availability',
      (tester) async {
        final model = GuidanceModel()..status = availability;
        var current = contextFor();
        final opened = <HomiTarget>[];
        await tester.pumpWidget(
          app(
            PlanAssistantScreen(
              model: model,
              onSection: (_) {},
              onTarget: opened.add,
              appContextProvider: () => current,
            ),
          ),
        );
        await tester.pumpAndSettle();
        if (availability == AssistantAvailability.ready) {
          expect(guidance(), findsNothing);
          expect(find.byKey(const ValueKey('assistant-context')), findsOne);
          await tap(tester, find.byKey(const ValueKey('assistant-options')));
          await tap(
            tester,
            find.byKey(const ValueKey('assistant-options-guide')),
          );
        } else {
          expect(find.byKey(const ValueKey('assistant-status')), findsOne);
        }
        await tap(
          tester,
          find.byKey(const ValueKey('assistant-app-help-prepareDraft')),
        );
        expect(find.text('App guide — not AI'), findsOneWidget);
        expect(
          find.text('These app steps do not use a language model.'),
          findsOneWidget,
        );
        expect(
          find.textContaining('Saving or sharing a draft does not submit'),
          findsOneWidget,
        );
        expect(model.requests, isEmpty);
        expect(find.text('Thinking on your phone…'), findsNothing);
        final open = find.descendant(
          of: guidance(),
          matching: find.widgetWithText(OutlinedButton, 'Open Help'),
        );
        current = contextFor(authorized: false);
        await tap(tester, open);
        expect(opened, isEmpty);
        current = contextFor();
        await tap(
          tester,
          find.byKey(const ValueKey('assistant-app-help-nextStep')),
        );
        expect(model.requests, isEmpty);
        expect(
          find.text('These app steps do not use a language model.'),
          findsOneWidget,
        );
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets(
    'invalid arbitrary model answer exposes retry and availability actions without fake reply',
    (tester) async {
      final model = GuidanceModel()..raw = 'Unstructured unverified reply';
      final current = contextFor();
      await tester.pumpWidget(
        app(
          PlanAssistantScreen(
            model: model,
            onSection: (_) {},
            appContextProvider: () => current,
          ),
        ),
      );
      await tester.pumpAndSettle();
      final input = find.byKey(const ValueKey('assistant-input'));
      await tester.enterText(input, 'Explain the next review step.');
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pumpAndSettle();
      expect(
        find.text(
          'The model returned a reply the app could not verify. Try again or use App guidance.',
        ),
        findsOneWidget,
      );
      expect(find.text('Unstructured unverified reply'), findsNothing);
      expect(
        tester.widget<TextField>(input).controller!.text,
        'Explain the next review step.',
      );
      await tap(
        tester,
        find.byKey(const ValueKey('assistant-check-availability')),
      );
      expect(model.checks, 2);
      model.raw = jsonEncode({
        'text': 'Review the current plan in Help.',
        'sourceIds': ['app.help'],
        'openSourceId': 'app.help',
      });
      await tap(tester, find.byKey(const ValueKey('assistant-retry-question')));
      expect(model.requests, hasLength(2));
      expect(model.requests.last['history'], '[]');
      expect(find.text('Review the current plan in Help.'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('assistant-retry-question')),
        findsNothing,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'ready model becoming unavailable can be rechecked while app guidance remains usable',
    (tester) async {
      final model = GuidanceModel()
        ..failure = const AssistantFailure('UNAVAILABLE');
      final current = contextFor();
      await tester.pumpWidget(
        app(
          PlanAssistantScreen(
            model: model,
            onSection: (_) {},
            appContextProvider: () => current,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('assistant-input')),
        'Explain the next step.',
      );
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pumpAndSettle();
      expect(
        find.text(
          'The on-device model is unavailable. Check availability, or use App guidance.',
        ),
        findsOneWidget,
      );
      model.status = AssistantAvailability.modelNotReady;
      await tap(
        tester,
        find.byKey(const ValueKey('assistant-check-availability')),
      );
      expect(
        find.textContaining('Apple’s on-device model is not ready'),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('assistant-status')), findsOne);
      await tap(
        tester,
        find.byKey(const ValueKey('assistant-app-help-prepareDraft')),
      );
      expect(model.requests, hasLength(1));
      expect(
        find.textContaining('Saving or sharing a draft does not submit'),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  test('all app guidance and recovery messages have six-locale coverage', () {
    for (final entry in assistantContextTranslations.entries) {
      for (final locale in AppLocalizations.supportedLocales) {
        final translated = AppLocalizations(locale).text(entry.key);
        expect(translated, isNotEmpty);
        if (locale.languageCode != 'en') {
          expect(translated, isNot(entry.key), reason: '$locale ${entry.key}');
        }
      }
    }
  });
}
