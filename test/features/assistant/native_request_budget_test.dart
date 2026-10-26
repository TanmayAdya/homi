import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/features/assistant/assistant_context_v2.dart';
import 'package:safe_at_home/features/assessment/domain/assessment_location.dart';
import 'package:safe_at_home/shared/navigation/homi_destination.dart';

void main() {
  test(
    'representative native requests preserve bounded sources in six locales',
    () {
      final requests = <Map<String, Object?>>[];
      final programs = ['scfhp-eaa', 'hpsm-eaa', 'rtp-home-repair'];
      final records = <AssistantRecord>[
        for (var i = 0; i < 4; i++) ...[
          AssistantRecord.room(
            id: 'room-$i',
            type: AssessmentLocation.bathroom,
            answeredQuestions: 8,
            concerns: 1,
            hasSavedScan: i == 0,
          ),
          AssistantRecord.concern(
            id: 'concern-$i',
            roomId: 'room-$i',
            reviewState: 'needs_review',
          ),
        ],
        for (final program in programs) ...[
          AssistantRecord.program(
            id: program,
            status: 'needs_confirmation',
            availability: 'unverified',
            passed: 2,
            unknown: 4,
            residentReview: 1,
            professionalReview: 3,
          ),
          AssistantRecord.preparation(
            programId: program,
            intake: 'incomplete',
            draft: 'stale',
          ),
        ],
        for (var i = 0; i < 3; i++)
          AssistantRecord.task(
            id: 'task-$i',
            kind: 'draft_review',
            state: 'pending',
            dueOn: '2026-11-01',
          ),
      ];
      final examples = {
        'en': 'What should I review before preparing my draft?',
        'es': '¿Qué debo revisar antes de preparar mi borrador?',
        'zh-Hans': '准备草稿之前我应该检查什么？',
        'zh-Hant': '準備草稿之前我應該檢查什麼？',
        'vi': 'Tôi nên xem lại những gì trước khi chuẩn bị bản nháp?',
        'fil': 'Ano ang dapat kong suriin bago ihanda ang draft ko?',
      };
      for (final entry in {
        'no-plan': <AssistantRecord>[],
        'normal-plan': records,
        'large-plan': [
          ...records,
          for (var i = 0; i < 100; i++)
            AssistantRecord.task(
              id: 'extra-task-$i',
              kind: 'room_review',
              state: 'pending',
            ),
        ],
      }.entries) {
        final selected = entry.key != 'no-plan';
        final context = AssistantContextV2.fromAuthorizedRecords(
          scopeKey: 'fictional-account',
          authorized: true,
          access: const AssistantRecordAccess.owner(),
          destination: HomiDestination.help,
          capabilities: {
            for (final d in HomiDestination.values)
              d: FeatureAvailability.supported,
          },
          caseId: selected ? 'fictional-plan' : null,
          caseRevision: selected ? 1 : null,
          filteredRecords: selected
              ? AssistantFilteredRecords(
                  caseId: 'fictional-plan',
                  caseRevision: 1,
                  revisionKey: '1',
                  records: entry.value,
                )
              : null,
        );
        expect(
          utf8.encode(context.modelJson).length,
          lessThanOrEqualTo(AssistantContextV2.maxModelBytes),
        );
        if (selected) {
          expect(
            context.sources.map((s) => s.kind).toSet(),
            containsAll(AssistantSourceKind.values),
          );
        }
        for (final example in examples.entries) {
          requests.add({
            'requestId': 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
            'locale': example.key,
            'question': example.value,
            'history': '[]',
            'findings': '[]',
            'appContext': context.modelJson,
            'guide': AssistantContextV2.trustedGuide,
          });
        }
      }
      final export = Platform.environment['HOMI_NATIVE_REQUEST_FIXTURES'];
      if (export != null) File(export).writeAsStringSync(jsonEncode(requests));
      expect(requests, hasLength(18));
    },
  );
}
