import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/features/assistant/assistant_context_v2.dart';
import 'package:safe_at_home/l10n/app_localizations.dart';
import 'package:safe_at_home/l10n/catalogs/assistant_context.dart';
import 'package:safe_at_home/shared/navigation/homi_destination.dart';

import '../../../../tool/assistant_eval/context_fixtures.dart';

void main() {
  final matrix =
      jsonDecode(File('tool/assistant_eval/matrix.json').readAsStringSync())
          as Map;
  final scenarios = buildEvaluationScenarios();
  AssistantEvalScenario scenario(String id) =>
      scenarios.singleWhere((s) => s.id == id);

  test(
    'context guidance and reviewed model controls are localized in six locales',
    () {
      for (final row in assistantContextTranslations.values) {
        expect(row.keys.toSet(), {'es', 'zh-Hans', 'zh-Hant', 'vi', 'fil'});
        expect(row.values.every((value) => value.trim().isNotEmpty), isTrue);
      }
      final guidance = scenarios
          .where((fixture) => fixture.initial.authorized)
          .map((fixture) => fixture.initial.deterministicReply().text)
          .toSet();
      for (final key in guidance) {
        expect(assistantContextTranslations, contains(key));
      }
      for (final locale in AppLocalizations.supportedLocales) {
        final localizations = AppLocalizations(locale);
        for (final key in assistantContextTranslations.keys) {
          final text = localizations.text(key, {'section': 'TEST_SECTION'});
          expect(text, isNotEmpty);
          expect(text, isNot(contains('{section}')));
          if (locale.languageCode != 'en') expect(text, isNot(key));
        }
        expect(
          localizations.text('Open {section}', {'section': 'TEST_SECTION'}),
          contains('TEST_SECTION'),
        );
      }
    },
  );

  test(
    'all 96 prompts bind to actual B1 contexts with bounded private-data exclusion',
    () {
      final rows = (matrix['scenarios'] as List).cast<Map>();
      expect(
        scenarios.map((s) => s.id).toSet(),
        rows.map((r) => r['id']).toSet(),
      );
      expect(
        rows.fold<int>(0, (sum, row) => sum + (row['prompts'] as Map).length),
        96,
      );
      for (final row in rows) {
        final current = scenario(row['id'] as String);
        expect((row['prompts'] as Map).keys.toSet(), {
          'en',
          'es',
          'zh-Hans',
          'zh-Hant',
          'vi',
          'fil',
        });
        for (final context in [current.initial, current.current]) {
          expect(
            utf8.encode(context.modelJson).length,
            lessThanOrEqualTo(AssistantContextV2.maxModelBytes),
          );
          for (final forbidden in [
            evaluationCaseId,
            otherEvaluationCaseId,
            'fictional-account-',
            'PRIVATE_',
            'IGNORE_ALL_RULES_SENTINEL',
            '1654321.15',
          ]) {
            expect(
              context.modelJson,
              isNot(contains(forbidden)),
              reason: row['id'] as String,
            );
          }
        }
      }
      final output = Platform.environment['HOMI_ASSISTANT_EVAL_CONTEXT_EXPORT'];
      if (output != null) {
        File(output).writeAsStringSync(
          '${const JsonEncoder.withIndent('  ').convert({'schemaVersion': 'homi-assistant-eval.v1', 'contexts': scenarios.map((s) => s.toExport()).toList()})}\n',
        );
      }
    },
  );

  for (final fixture in scenarios) {
    test(
      '${fixture.id}: source actions survive only current authorization and capability',
      () {
        for (final source in fixture.initial.sources) {
          final reply = fixture.initial.decodeReply(
            jsonEncode({
              'text': 'Fictional structural probe, not a model evaluation.',
              'sourceIds': [source.id],
              'openSourceId': source.id,
            }),
          );
          if (fixture.initial.key != fixture.current.key) {
            expect(fixture.current.isReplyCurrent(reply), isFalse);
            expect(fixture.current.resolveOpen(reply), isNull);
          } else {
            expect(fixture.current.isReplyCurrent(reply), isTrue);
            final target = fixture.current.resolveOpen(reply);
            if (!source.available) {
              expect(target, isNull);
            } else {
              expect(target, same(source.target));
              expect(target!.caseId, fixture.current.caseId);
            }
          }
        }
      },
    );
  }

  test(
    'two bathrooms remain distinct while saved scans do not imply live scanning',
    () {
      final rooms = scenario('multiple_rooms').initial.sources
          .where((s) => s.kind == AssistantSourceKind.room)
          .toList();
      expect(rooms, hasLength(4));
      expect(rooms.map((s) => s.id).toSet(), hasLength(4));
      expect(
        rooms
            .where((s) => s.facts['type'] == 'bathroom')
            .map((s) => s.target.roomId)
            .toSet(),
        {evaluationRoomId, 'fictional-bathroom-two'},
      );
      final saved = scenario('saved_scan').initial;
      expect(
        saved.sources
            .singleWhere((s) => s.kind == AssistantSourceKind.room)
            .facts['savedScan'],
        'available',
      );
      expect(
        (saved.toModelJson()['state'] as Map)['deviceCapabilities'],
        containsPair('roomScan', 'unsupportedDevice'),
      );
    },
  );

  test(
    'unknown review and stale draft facts never become approval in the source contract',
    () {
      final program = scenario('manual_review').initial.sources.singleWhere(
        (s) => s.kind == AssistantSourceKind.program,
      );
      expect(program.facts, containsPair('unknown', 10));
      expect(
        program.facts,
        containsPair('eligibilityOrApproval', 'not_established'),
      );
      final draft = scenario('stale_draft').initial.sources.singleWhere(
        (s) => s.kind == AssistantSourceKind.preparation,
      );
      expect(draft.facts, containsPair('draft', 'stale'));
      expect(
        draft.facts,
        containsPair('submissionOrApproval', 'not_established'),
      );
    },
  );

  test('helper fixture has only its granted room and task', () {
    final helper = scenario('limited_helper').initial;
    final records = helper.sources
        .where((s) => s.kind != AssistantSourceKind.guide)
        .toList();
    expect(records, hasLength(2));
    expect(records.map((s) => s.kind).toSet(), {
      AssistantSourceKind.room,
      AssistantSourceKind.task,
    });
    expect(
      records
          .singleWhere((s) => s.kind == AssistantSourceKind.room)
          .target
          .roomId,
      evaluationRoomId,
    );
    expect(
      records
          .singleWhere((s) => s.kind == AssistantSourceKind.task)
          .target
          .taskId,
      evaluationTaskId,
    );
  });

  test('identical public summaries cannot bypass changed-account fencing', () {
    final switched = scenario('changed_account');
    expect(switched.initial.modelJson, switched.current.modelJson);
    expect(switched.initial.key, isNot(switched.current.key));
    expect(
      switched.current.isReplyCurrent(switched.initial.deterministicReply()),
      isFalse,
    );
  });

  test(
    'injected notes never reach the model and foreign action syntax is rejected',
    () {
      expect(
        injectionSnapshot().findings.single.observation,
        contains('IGNORE_ALL_RULES_SENTINEL'),
      );
      final context = scenario('note_injection').initial;
      expect(context.modelJson, isNot(contains('IGNORE_ALL_RULES_SENTINEL')));
      for (final invalid in [
        {
          'text': 'Open',
          'sourceIds': ['admin:override'],
          'openSourceId': 'admin:override',
        },
        {
          'text': 'Open',
          'sourceIds': ['app.plan'],
          'caseId': otherEvaluationCaseId,
        },
        {
          'text': 'Submit',
          'sourceIds': ['app.help'],
          'command': 'submit_application',
        },
      ]) {
        expect(
          () => context.decodeReply(jsonEncode(invalid)),
          throwsFormatException,
        );
      }
    },
  );

  test(
    'unavailable Tasks and unsupported model keep honest deterministic routes',
    () {
      final disabled = scenario('disabled_service').initial;
      final reply = disabled.decodeReply(
        jsonEncode({
          'text': 'Tasks is unavailable.',
          'sourceIds': ['app.tasks'],
          'openSourceId': 'app.tasks',
        }),
      );
      expect(disabled.resolveOpen(reply), isNull);
      final unsupported = scenario('unsupported_device');
      expect(unsupported.requireDeterministic, isTrue);
      expect(
        unsupported.current
            .resolveOpen(unsupported.current.deterministicReply())!
            .destination,
        HomiDestination.settings,
      );
      final empty = scenario('no_plan').initial;
      expect(empty.caseId, isNull);
      expect(
        empty.sources.every((s) => s.kind == AssistantSourceKind.guide),
        isTrue,
      );
      expect(
        empty.resolveOpen(empty.deterministicReply())!.destination,
        HomiDestination.plan,
      );
    },
  );
}
