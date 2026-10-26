import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/features/cases/plan_next_step.dart';
import 'package:safe_at_home/features/tracking/progress_models.dart';
import 'package:safe_at_home/l10n/app_localizations.dart';

TrackedProgram program(String id, {bool retired = false, String? status}) =>
    TrackedProgram.fromJson({
      'programId': id,
      'name': 'Fictional $id',
      'trackedAt': '2026-10-24T12:00:00.000Z',
      'trackedBy': 'fictional-owner',
      'latest': status == null
          ? null
          : {
              'updateId': '11111111-0000-4000-8000-000000000099',
              'status': status,
              'occurredOn': '2026-10-23',
              'source': 'self_report',
              'note': null,
              'nextAction': null,
              'responsibleParty': null,
              'followUpOn': null,
              'revision': 1,
              'caseRevision': 1,
              'recordedAt': '2026-10-24T12:00:00.000Z',
              'recordedBy': 'fictional-reporter',
            },
      'proposal': null,
      'retired': retired,
      'ruleVersion': null,
      'unresolvedRequirements': 0,
      'requirements': null,
    });

NextStepTask task(String id, {String? dueOn, String state = 'pending'}) =>
    NextStepTask.fromJson({
      'id': id,
      'programId': null,
      'findingId': null,
      'formId': null,
      'title': 'Fictional $id',
      'kind': 'documents',
      'state': state,
      'responsiblePerson': null,
      'dueOn': dueOn,
      'basedOnCaseRevision': 1,
      'basedOnRuleVersion': null,
      'revision': 1,
      'sourceEventId': null,
      'needsReview': false,
    });

PlanNextStep later({List<NextStepTask> tasks = const []}) => planNextStep(
  PlanProgressFacts(
    answered: 4,
    questions: 4,
    suggestedConcerns: 0,
    keptConcerns: 1,
    programs: [program('done', status: 'approved')],
    tasks: tasks,
  ),
);

PlanNextStep step({
  int answered = 4,
  int questions = 4,
  int suggested = 0,
  int kept = 1,
  List<TrackedProgram> programs = const [],
  List<NextStepTask> tasks = const [],
}) => planNextStep(
  PlanProgressFacts(
    answered: answered,
    questions: questions,
    suggestedConcerns: suggested,
    keptConcerns: kept,
    programs: programs,
    tasks: tasks,
  ),
);

void main() {
  group('priority', () {
    test('a new plan starts with resident details, even if programs exist', () {
      for (final programs in [
        const <TrackedProgram>[],
        [program('a')],
      ]) {
        final next = step(answered: 0, kept: 0, programs: programs);
        expect(next.title, 'Add resident details');
        expect(next.action, 'Start');
        expect(next.target, PlanStepTarget.profile);
        expect(next.programId, isNull);
      }
    });

    test(
      'suggested concerns: 1 is singular, many is plural, both beat programs',
      () {
        final one = step(answered: 0, suggested: 1, kept: 0);
        expect(one.title, 'Review the suggested concern');
        expect(one.target, PlanStepTarget.rooms);
        expect(one.values['count'], 1);
        final many = step(suggested: 3, programs: [program('a')]);
        expect(many.title, 'Review {count} suggested concerns');
        expect(many.values['count'], 3);
        expect(many.target, PlanStepTarget.rooms);
        expect(step(suggested: 0).title, isNot(contains('suggested')));
      },
    );

    test('active program continues, skipping retired and closed ones', () {
      final next = step(
        answered: 1,
        kept: 0,
        programs: [
          program('retired', retired: true),
          for (final status in ['approved', 'denied', 'withdrawn'])
            program(status, status: status),
          program('open'),
          program('later', status: 'submitted'),
        ],
      );
      expect(next.title, 'Continue {program}');
      expect(next.values['program'], 'Fictional open');
      expect(next.programId, 'open');
      expect(next.target, PlanStepTarget.program);
      expect(next.message, 'Pick up where you left off.');

      for (final status in ['preparing', 'submitted', 'needs_information']) {
        final reported = step(programs: [program('a', status: status)]);
        expect(reported.programId, 'a', reason: status);
        expect(
          reported.message,
          'Record what happens next, such as a reply from the program.',
        );
      }
    });

    test('a retired program with an open status is still ignored', () {
      final next = step(programs: [program('r', retired: true)]);
      expect(next.target, isNot(PlanStepTarget.program));
    });

    test(
      'unanswered questions: count is the remainder; answered == questions skips',
      () {
        final next = step(answered: 3, questions: 5, kept: 0);
        expect(next.title, 'Finish resident details');
        expect(next.target, PlanStepTarget.profile);
        expect(next.values['count'], 2);
        expect(step(answered: 4, questions: 5).values['count'], 1);
        expect(
          step(answered: 5, questions: 5).title,
          isNot('Finish resident details'),
        );
        expect(step(answered: 0, questions: 5).values['count'], 5);
      },
    );

    test('no kept concerns once details are done: check a room', () {
      final next = step(kept: 0);
      expect(next.title, 'Check a room');
      expect(next.target, PlanStepTarget.rooms);
    });

    test('kept concerns without programs: find help, singular vs plural', () {
      final one = step(kept: 1);
      expect(one.title, 'Find help for 1 concern');
      expect(one.target, PlanStepTarget.help);
      final many = step(kept: 4);
      expect(many.title, 'Find help for {count} concerns');
      expect(many.values['count'], 4);
      expect(step(kept: 2, tasks: [task('t')]).target, PlanStepTarget.help);
    });

    test('open tasks: earliest due first, dated before undated', () {
      final next = later(
        tasks: [
          task('undated'),
          task('late', dueOn: '2030-03-01'),
          task('done', dueOn: '2029-01-01', state: 'completed'),
          task('dropped', dueOn: '2029-01-02', state: 'cancelled'),
          task('soon', dueOn: '2030-01-05'),
        ],
      );
      expect(next.title, '{task}');
      expect(next.values['task'], 'Fictional soon');
      expect(next.values['date'], '2030-01-05');
      expect(next.message, 'Due {date}');
      expect(next.target, PlanStepTarget.tasks);

      final undated = later(tasks: [task('first'), task('second')]);
      expect(undated.values['task'], 'Fictional first');
      expect(undated.message, 'On your task list');

      final blocked = later(tasks: [task('b', state: 'blocked')]);
      expect(blocked.target, PlanStepTarget.tasks);
    });

    test('nothing left: all caught up', () {
      for (final tasks in [
        const <NextStepTask>[],
        [task('done', state: 'completed'), task('x', state: 'cancelled')],
      ]) {
        final next = later(tasks: tasks);
        expect(next.title, 'All caught up');
        expect(next.target, PlanStepTarget.help);
      }
    });
  });

  test('every returned key is translated in every supported language', () {
    final steps = [
      step(answered: 0, kept: 0),
      step(suggested: 1),
      step(suggested: 2),
      step(programs: [program('a')]),
      step(programs: [program('a', status: 'submitted')]),
      step(answered: 1),
      step(kept: 0),
      step(kept: 1),
      step(kept: 2),
      later(tasks: [task('a', dueOn: '2030-01-05')]),
      later(tasks: [task('a')]),
      later(),
    ];
    expect(steps.map((s) => s.title).toSet(), hasLength(10));
    final keys = {
      for (final s in steps) ...[s.title, s.message, s.action],
    }..remove('{task}');
    for (final key in keys) {
      final row = AppLocalizations.translations[key];
      expect(row, isNotNull, reason: 'missing catalog row: $key');
      for (final code in ['es', 'zh-Hans', 'zh-Hant', 'vi', 'fil']) {
        expect(row![code], isNotNull, reason: '$key → $code');
        expect(row[code], isNotEmpty, reason: '$key → $code');
      }
    }
  });
}
