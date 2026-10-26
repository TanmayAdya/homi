import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/app/theme.dart';
import 'package:safe_at_home/features/assistant/assistant_context.dart';
import 'package:safe_at_home/features/assistant/assistant_controller.dart';
import 'package:safe_at_home/features/assistant/assistant_model.dart';
import 'package:safe_at_home/features/assistant/assistant_message_text.dart';
import 'package:safe_at_home/features/assistant/plan_assistant_screen.dart';
import 'package:safe_at_home/l10n/app_localizations.dart';
import 'package:safe_at_home/l10n/catalogs/assistant.dart';
import 'package:safe_at_home/shared/models/case_draft.dart';

class FakeModel implements AssistantModel {
  AssistantAvailability status = AssistantAvailability.ready;
  Completer<String>? pending;
  final requests = <Map<String, String>>[];
  final cancelled = <String>[];
  Object? failure;
  @override
  Future<AssistantAvailability> availability(String locale) async => status;
  @override
  Future<void> cancel(String requestId) async => cancelled.add(requestId);
  @override
  Future<String> respond({
    required String requestId,
    required String locale,
    required String question,
    required String history,
    required String findings,
  }) async {
    requests.add({
      'id': requestId,
      'locale': locale,
      'question': question,
      'history': history,
      'findings': findings,
    });
    if (failure != null) throw failure!;
    return pending == null
        ? 'Open Rooms to review the saved model.'
        : pending!.future;
  }
}

CaseDraft draft() => CaseDraft.fromJson({
  'schemaVersion': '1',
  'caseId': 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
  'profile': {
    'city': 'Private city',
    'county': 'Private county',
    'healthPlan': 'Private plan',
    'tenure': 'owner',
    'ageYears': 75,
    'householdSize': 1,
    'annualIncomeUsd': 12345,
    'ownerConsentReported': true,
  },
  'unresolvedFields': <String>[],
  'findings': [
    for (var i = 0; i < 7; i++)
      {
        'id': 'finding-$i',
        'room': 'bathroom',
        'observation': i == 0
            ? 'Unreviewed private text'
            : 'Confirmed concern $i',
        'reviewState': i == 0
            ? 'needs_review'
            : i == 1
            ? 'dismissed'
            : 'confirmed',
        'evidenceIds': ['private-photo-$i'],
        'measurements': [
          {
            'type': 'door_clear_width',
            'value': 700,
            'unit': 'mm',
            'method': 'manual',
            'confirmed': true,
          },
        ],
      },
  ],
});

Widget app(
  Widget home, {
  Locale locale = const Locale('en'),
  bool dark = false,
}) => MaterialApp(
  locale: locale,
  supportedLocales: AppLocalizations.supportedLocales,
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  theme: dark ? SafeAtHomeTheme.dark() : SafeAtHomeTheme.light(),
  home: home,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'context excludes identifiers, profile, unreviewed data and measurements',
    () {
      final source = draft();
      final context = AssistantContext.fromDraft(source, 'local-scope');
      expect(context.findings, [
        'Confirmed concern 2',
        'Confirmed concern 3',
        'Confirmed concern 4',
        'Confirmed concern 5',
      ]);
      final serialized = context.modelFindings;
      for (final forbidden in [
        'Private',
        '12345',
        source.caseId,
        'finding-',
        'photo-',
        '700',
        'Unreviewed',
      ]) {
        expect(serialized, isNot(contains(forbidden)));
      }
      expect(assistantExcerpt('中' * 1000, 220).runes.length, 220);
    },
  );

  test(
    'chat is opt-in for findings and turning context off clears prior replies',
    () async {
      final model = FakeModel();
      final c = AssistantController(
        model: model,
        locale: 'en',
        contextProvider: () => AssistantContext.fromDraft(draft(), 'one'),
      );
      addTearDown(c.dispose);
      await c.check();
      await c.send('What should I do?');
      expect(model.requests.single['findings'], '[]');
      c.useFindings(true);
      expect(c.turns, isEmpty);
      await c.send('Explain my observations');
      expect(model.requests.last['findings'], contains('Confirmed concern 2'));
      c.useFindings(false);
      expect(c.turns, isEmpty);
      await c.send('Where is Help?');
      expect(model.requests.last['history'], '[]');
      expect(model.requests.last['findings'], '[]');
    },
  );

  test(
    'bounded history uses only two recent exchanges and keeps twelve turns',
    () async {
      final model = FakeModel();
      final c = AssistantController(
        model: model,
        locale: 'zh-Hant',
        contextProvider: () => const AssistantContext(key: 'one'),
      );
      addTearDown(c.dispose);
      await c.check();
      for (var i = 0; i < 15; i++) {
        await c.send('Question $i');
      }
      expect(c.turns.length, 12);
      expect(c.turns.first.question, 'Question 3');
      final history = jsonDecode(model.requests.last['history']!) as List;
      expect(history.map((t) => t['question']), ['Question 12', 'Question 13']);
      expect(model.requests.last['locale'], 'zh-Hant');
    },
  );

  for (final change in ['stop', 'clear', 'context', 'signout', 'dispose']) {
    test('$change cancels and rejects a late successful answer', () async {
      final model = FakeModel()..pending = Completer<String>();
      AssistantContext? context = const AssistantContext(
        key: 'account-A:case-A:revision-1',
      );
      final c = AssistantController(
        model: model,
        locale: 'en',
        contextProvider: () => context,
      );
      await c.check();
      final operation = c.send('A private question');
      await Future<void>.delayed(Duration.zero);
      expect(c.busy, isTrue);
      switch (change) {
        case 'stop':
          c.stop();
        case 'clear':
          c.clear();
        case 'context':
          context = const AssistantContext(key: 'account-A:case-A:revision-2');
          c.refreshContext();
        case 'signout':
          context = null;
          c.refreshContext();
        case 'dispose':
          c.dispose();
      }
      expect(model.cancelled, [model.requests.single['id']]);
      model.pending!.complete('Private late response');
      await operation;
      expect(c.turns, isEmpty);
      expect(c.busy, isFalse);
      if (change != 'dispose') c.dispose();
    });
  }

  test(
    'source change without notification rejects reply at completion',
    () async {
      final model = FakeModel()..pending = Completer<String>();
      AssistantContext? context = const AssistantContext(key: 'old');
      final c = AssistantController(
        model: model,
        locale: 'en',
        contextProvider: () => context,
      );
      addTearDown(c.dispose);
      await c.check();
      final operation = c.send('question');
      context = null;
      model.pending!.complete('late');
      await operation;
      expect(c.turns, isEmpty);
      expect(c.canSend, isFalse);
    },
  );

  test(
    'double send, long questions and unavailable models do not dispatch',
    () async {
      final model = FakeModel()..pending = Completer<String>();
      final c = AssistantController(
        model: model,
        locale: 'en',
        contextProvider: () => const AssistantContext(key: 'one'),
      );
      addTearDown(c.dispose);
      await c.check();
      await c.send('x' * 601);
      expect(c.errorCode, 'QUESTION_LIMIT');
      expect(model.requests, isEmpty);
      final first = c.send('first');
      await c.send('duplicate');
      expect(model.requests.length, 1);
      model.pending!.complete('answer');
      await first;
      model.status = AssistantAvailability.disabled;
      await c.check();
      await c.send('disabled');
      expect(model.requests.length, 1);
    },
  );

  test(
    'failure does not add fake answer; retry uses a fresh request ID',
    () async {
      final model = FakeModel()..failure = const AssistantFailure('REFUSED');
      final c = AssistantController(
        model: model,
        locale: 'en',
        contextProvider: () => const AssistantContext(key: 'one'),
      );
      addTearDown(c.dispose);
      await c.check();
      await c.send('question');
      expect(c.errorCode, 'REFUSED');
      expect(c.turns, isEmpty);
      model.failure = null;
      await c.send('question');
      expect(c.turns.length, 1);
      expect(model.requests.first['id'], isNot(model.requests.last['id']));
    },
  );

  test(
    'native channel preserves locale, cancels by ID and suppresses diagnostics',
    () async {
      const channel = MethodChannel('test/assistant');
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            if (call.method == 'availability') return 'ready';
            if (call.method == 'cancel') return null;
            throw PlatformException(
              code: 'REFUSED',
              message: 'private diagnostics',
            );
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      const model = OnDeviceAssistantModel(
        channel: channel,
        platform: TargetPlatform.iOS,
      );
      expect(await model.availability('es'), AssistantAvailability.ready);
      await expectLater(
        model.respond(
          requestId: 'one',
          locale: 'es',
          question: 'q',
          history: '[]',
          findings: '[]',
        ),
        throwsA(
          isA<AssistantFailure>().having((e) => e.code, 'code', 'REFUSED'),
        ),
      );
      await model.cancel('one');
      expect(calls.last.arguments, {'requestId': 'one'});
      expect(calls[1].arguments['locale'], 'es');
      const android = OnDeviceAssistantModel(
        channel: channel,
        platform: TargetPlatform.android,
      );
      expect(await android.availability('en'), AssistantAvailability.ready);
      expect(calls.length, 4);
      const desktop = OnDeviceAssistantModel(
        channel: channel,
        platform: TargetPlatform.linux,
      );
      expect(
        await desktop.availability('en'),
        AssistantAvailability.unsupportedPlatform,
      );
      expect(calls.length, 4);
    },
  );

  test('all assistant copy has complete translation keys', () {
    for (final row in assistantTranslations.values) {
      expect(row.keys.toSet(), {'es', 'zh-Hans', 'zh-Hant', 'vi', 'fil'});
      expect(row.values.every((value) => value.trim().isNotEmpty), isTrue);
    }
  });

  for (final locale in AppLocalizations.supportedLocales) {
    for (final dark in [false, true]) {
      testWidgets(
        '$locale dark=$dark chat fits narrow large text and keyboard',
        (tester) async {
          tester.view.physicalSize = const Size(320, 640);
          tester.view.devicePixelRatio = 1;
          tester.platformDispatcher.textScaleFactorTestValue = 3.2;
          addTearDown(() {
            tester.view.resetPhysicalSize();
            tester.view.resetDevicePixelRatio();
            tester.platformDispatcher.clearTextScaleFactorTestValue();
            tester.view.resetViewInsets();
          });
          final model = FakeModel();
          await tester.pumpWidget(
            app(
              PlanAssistantScreen(onSection: (_) {}, model: model),
              locale: locale,
              dark: dark,
            ),
          );
          await tester.pumpAndSettle();
          final input = find.byKey(const ValueKey('assistant-input'));
          await tester.scrollUntilVisible(
            input,
            180,
            scrollable: find.byType(Scrollable).first,
          );
          await tester.enterText(input, 'How do I review my room?');
          tester.view.viewInsets = const FakeViewPadding(bottom: 280);
          await tester.pumpAndSettle();
          expect(
            find.byKey(const ValueKey('assistant-hide-keyboard')),
            findsOneWidget,
          );
          await tester.testTextInput.receiveAction(TextInputAction.send);
          await tester.pumpAndSettle();
          expect(model.requests.length, 1);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets(
    'visible keyboard dismiss preserves question and permits the Send button',
    (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 3.2;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        tester.platformDispatcher.clearTextScaleFactorTestValue();
        tester.view.resetViewInsets();
      });
      final model = FakeModel();
      await tester.pumpWidget(
        app(PlanAssistantScreen(onSection: (_) {}, model: model)),
      );
      await tester.pumpAndSettle();
      final input = find.byKey(const ValueKey('assistant-input'));
      await tester.scrollUntilVisible(
        input,
        180,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.enterText(input, 'Where are my scans?');
      tester.view.viewInsets = const FakeViewPadding(bottom: 280);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('assistant-hide-keyboard')));
      tester.view.resetViewInsets();
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(input).controller!.text,
        'Where are my scans?',
      );
      final send = find.byKey(const ValueKey('assistant-send'));
      await tester.scrollUntilVisible(
        send,
        160,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.ensureVisible(send);
      await tester.pumpAndSettle();
      await tester.tap(send);
      await tester.pumpAndSettle();
      expect(model.requests.single['question'], 'Where are my scans?');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'background clears conversation, draft question and cancels inference',
    (tester) async {
      final model = FakeModel()..pending = Completer<String>();
      await tester.pumpWidget(
        app(PlanAssistantScreen(onSection: (_) {}, model: model)),
      );
      await tester.pumpAndSettle();
      final input = find.byKey(const ValueKey('assistant-input'));
      await tester.enterText(input, 'Private question');
      await tester.pump();
      final send = find.byKey(const ValueKey('assistant-send'));
      await tester.ensureVisible(send);
      await tester.tap(send);
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      expect(model.cancelled, isNotEmpty);
      expect(tester.widget<TextField>(input).controller!.text, isEmpty);
      model.pending!.complete('Late private answer');
      await tester.pump();
      expect(find.text('Late private answer'), findsNothing);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
    },
  );
  test(
    'generated emphasis remains readable with Chinese text and literal math',
    () {
      final text = assistantMessageText(
        'Open **Rooms** to review 李女士’s 房間.\n* Optional photo\n3 * 4 and unmatched ** stay literal.',
      );
      expect(
        text.toPlainText(),
        'Open Rooms to review 李女士’s 房間.\n• Optional photo\n3 * 4 and unmatched ** stay literal.',
      );
    },
  );

  testWidgets('model emphasis renders without raw delimiters', (tester) async {
    final model = FakeModel()..pending = Completer<String>();
    await tester.pumpWidget(
      app(PlanAssistantScreen(onSection: (_) {}, model: model)),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('assistant-input')),
      'Where are my scans?',
    );
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await tester.pump();
    model.pending!.complete('Open **Rooms** to review your scan.');
    await tester.pumpAndSettle();
    expect(find.text('Open Rooms to review your scan.'), findsOneWidget);
    expect(find.text('Open **Rooms** to review your scan.'), findsNothing);
  });

  testWidgets(
    'composer stays visible while reading a long chat and keyboard stays usable',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      final model = FakeModel()..pending = Completer<String>();
      await tester.pumpWidget(
        app(PlanAssistantScreen(onSection: (_) {}, model: model)),
      );
      await tester.pumpAndSettle();
      final input = find.byKey(const ValueKey('assistant-input'));
      final before = tester.getRect(input);
      await tester.enterText(input, 'How do I prepare a draft?');
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pump();
      expect(tester.widget<TextField>(input).controller!.text, isEmpty);
      expect(tester.widget<TextField>(input).focusNode!.hasFocus, isTrue);
      expect(find.byTooltip('Stop response'), findsOneWidget);
      model.pending!.complete(
        List.filled(25, 'Review your plan before preparing a draft.').join(' '),
      );
      await tester.pumpAndSettle();
      expect(tester.getRect(input).bottom, closeTo(before.bottom, 1));
      final messages = find.byKey(const ValueKey('assistant-messages'));
      await tester.drag(messages, const Offset(0, 500));
      await tester.pumpAndSettle();
      expect(tester.getRect(input).bottom, closeTo(before.bottom, 1));
      expect(
        find.byKey(const ValueKey('assistant-send')).hitTestable(),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('stop restores the question and ignores a late reply', (
    tester,
  ) async {
    final model = FakeModel()..pending = Completer<String>();
    await tester.pumpWidget(
      app(PlanAssistantScreen(onSection: (_) {}, model: model)),
    );
    await tester.pumpAndSettle();
    final input = find.byKey(const ValueKey('assistant-input'));
    await tester.enterText(input, 'Where is my draft?');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('assistant-send')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('assistant-stop')));
    await tester.pumpAndSettle();
    expect(model.cancelled, hasLength(1));
    expect(
      tester.widget<TextField>(input).controller!.text,
      'Where is my draft?',
    );
    model.pending!.complete('Late answer');
    await tester.pumpAndSettle();
    expect(find.text('Late answer'), findsNothing);
  });

  testWidgets('failed send restores the draft for direct retry', (
    tester,
  ) async {
    final model = FakeModel()..failure = const AssistantFailure('TIMEOUT');
    await tester.pumpWidget(
      app(PlanAssistantScreen(onSection: (_) {}, model: model)),
    );
    await tester.pumpAndSettle();
    final input = find.byKey(const ValueKey('assistant-input'));
    await tester.enterText(input, 'Where are my scans?');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('assistant-send')));
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(input).controller!.text,
      'Where are my scans?',
    );
    expect(
      find.text(
        'The response took too long. Your question is still here to retry.',
      ),
      findsOneWidget,
    );
    model.failure = null;
    await tester.tap(find.byKey(const ValueKey('assistant-send')));
    await tester.pumpAndSettle();
    expect(model.requests, hasLength(2));
    expect(find.text('Open Rooms to review the saved model.'), findsOneWidget);
    expect(tester.widget<TextField>(input).controller!.text, isEmpty);
  });

  testWidgets('chat controls have accessible labels and touch targets', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();

    await tester.pumpWidget(
      app(PlanAssistantScreen(onSection: (_) {}, model: FakeModel())),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('assistant-input')),
      'Next step?',
    );
    await tester.pumpAndSettle();
    expect(find.byTooltip('Send question'), findsOneWidget);
    expect(find.byTooltip('Chat options'), findsOneWidget);
    await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
    await expectLater(tester, meetsGuideline(iOSTapTargetGuideline));
    await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
    await expectLater(tester, meetsGuideline(textContrastGuideline));
    semantics.dispose();
  });

  for (final locale in AppLocalizations.supportedLocales) {
    testWidgets(
      '$locale options are accessible at large text and new chat closes sheet',
      (tester) async {
        tester.view.physicalSize = const Size(320, 640);
        tester.view.devicePixelRatio = 1;
        tester.platformDispatcher.textScaleFactorTestValue = 3.2;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
          tester.platformDispatcher.clearTextScaleFactorTestValue();
        });
        await tester.pumpWidget(
          app(
            PlanAssistantScreen(onSection: (_) {}, model: FakeModel()),
            locale: locale,
          ),
        );
        await tester.pumpAndSettle();
        final input = find.byKey(const ValueKey('assistant-input'));
        await tester.enterText(input, 'Private question');
        await tester.testTextInput.receiveAction(TextInputAction.send);
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('assistant-options')));
        await tester.pumpAndSettle();
        final l10n = AppLocalizations(locale);
        expect(find.text(l10n.text('Chat options')), findsOneWidget);
        final clear = find.text(l10n.text('New chat'));
        await tester.scrollUntilVisible(
          clear,
          160,
          scrollable: find
              .descendant(
                of: find.byKey(const ValueKey('assistant-options-list')),
                matching: find.byType(Scrollable),
              )
              .first,
        );
        await Scrollable.ensureVisible(tester.element(clear), alignment: .5);
        await tester.pumpAndSettle();
        await tester.tap(clear);
        await tester.pumpAndSettle();
        expect(find.text('Private question'), findsNothing);
        expect(find.text(l10n.text('Chat options')), findsNothing);
        expect(
          find.byKey(const ValueKey('assistant-options-list')),
          findsNothing,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }
}
