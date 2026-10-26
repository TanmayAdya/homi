import '../tracking/progress_models.dart';

enum PlanStepTarget { profile, rooms, help, program, tasks }

/// Describe the next action for the selected plan
class PlanNextStep {
  const PlanNextStep({
    required this.title,
    required this.message,
    required this.action,
    required this.target,
    this.values = const {},
    this.programId,
  });
  final String title, message, action;
  final PlanStepTarget target;
  final Map<String, Object?> values;
  final String? programId;
}

class PlanProgressFacts {
  const PlanProgressFacts({
    required this.answered,
    required this.questions,
    required this.suggestedConcerns,
    required this.keptConcerns,
    this.programs = const [],
    this.tasks = const [],
  });
  final int answered, questions, suggestedConcerns, keptConcerns;
  final List<TrackedProgram> programs;
  final List<NextStepTask> tasks;

  List<TrackedProgram> get activePrograms => [
    for (final program in programs)
      if (!program.retired && !_closed.contains(program.latest?['status']))
        program,
  ];
  List<NextStepTask> get openTasks => [
    for (final task in tasks)
      if (task.open) task,
  ];
  static const _closed = {'approved', 'denied', 'withdrawn'};
}

PlanNextStep planNextStep(PlanProgressFacts facts) {
  if (facts.answered == 0 &&
      facts.suggestedConcerns == 0 &&
      facts.keptConcerns == 0) {
    return const PlanNextStep(
      title: 'Add resident details',
      message: 'About 3 minutes. You can skip any question.',
      action: 'Start',
      target: PlanStepTarget.profile,
    );
  }
  if (facts.suggestedConcerns > 0) {
    return PlanNextStep(
      title: facts.suggestedConcerns == 1
          ? 'Review the suggested concern'
          : 'Review {count} suggested concerns',
      message:
          'Keep the ones that are real and remove the rest. You can change this later.',
      action: 'Review concerns',
      target: PlanStepTarget.rooms,
      values: {'count': facts.suggestedConcerns},
    );
  }
  final active = facts.activePrograms;
  if (active.isNotEmpty) {
    final program = active.first;
    return PlanNextStep(
      title: 'Continue {program}',
      message: program.latest == null
          ? 'Pick up where you left off.'
          : 'Record what happens next, such as a reply from the program.',
      action: 'Continue',
      target: PlanStepTarget.program,
      values: {'program': program.name},
      programId: program.id,
    );
  }
  if (facts.answered < facts.questions) {
    return PlanNextStep(
      title: 'Finish resident details',
      message: '{count} not answered. “Not sure” is a fine answer.',
      action: 'Continue',
      target: PlanStepTarget.profile,
      values: {'count': facts.questions - facts.answered},
    );
  }
  if (facts.keptConcerns == 0) {
    return const PlanNextStep(
      title: 'Check a room',
      message: 'Scan it, add photos, or answer a few questions.',
      action: 'Open rooms',
      target: PlanStepTarget.rooms,
    );
  }
  if (facts.programs.isEmpty) {
    return PlanNextStep(
      title: facts.keptConcerns == 1
          ? 'Find help for 1 concern'
          : 'Find help for {count} concerns',
      message: 'See programs and services near the resident.',
      action: 'Find help',
      target: PlanStepTarget.help,
      values: {'count': facts.keptConcerns},
    );
  }
  final tasks = facts.openTasks;
  if (tasks.isNotEmpty) {
    final dated = [...tasks.where((task) => task.dueOn != null)]
      ..sort((a, b) => a.dueOn!.compareTo(b.dueOn!));
    final task = dated.isEmpty ? tasks.first : dated.first;
    return PlanNextStep(
      title: '{task}',
      message: task.dueOn == null ? 'On your task list' : 'Due {date}',
      action: 'Open tasks',
      target: PlanStepTarget.tasks,
      values: {'task': task.title, 'date': task.dueOn},
    );
  }
  return const PlanNextStep(
    title: 'All caught up',
    message: 'Add a room or look for more help any time.',
    action: 'Find help',
    target: PlanStepTarget.help,
  );
}
