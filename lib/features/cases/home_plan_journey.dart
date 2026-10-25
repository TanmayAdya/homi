import 'package:flutter/material.dart';
import '../../l10n/app_localizations.dart';

enum HomePlanStep { profile, assessment, assistance }

class HomePlanJourney extends StatelessWidget {
  const HomePlanJourney({
    super.key,
    this.currentStep,
    this.onProfile,
    this.onAssessment,
    this.onAssistance,
  });

  final HomePlanStep? currentStep;
  final VoidCallback? onProfile;
  final VoidCallback? onAssessment;
  final VoidCallback? onAssistance;

  @override
  Widget build(BuildContext context) => Card(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _JourneyStep(
          step: HomePlanStep.profile,
          title: context.tr('Resident details'),
          description: context.tr(
            'Add what you know about the resident and their home.',
          ),
          current: currentStep == HomePlanStep.profile,
          onTap: onProfile,
        ),
        const Divider(height: 1),
        _JourneyStep(
          step: HomePlanStep.assessment,
          title: context.tr('Rooms and concerns'),
          description: context.tr(
            'Choose an area and describe what feels difficult.',
          ),
          current: currentStep == HomePlanStep.assessment,
          onTap: onAssessment,
        ),
        const Divider(height: 1),
        _JourneyStep(
          step: HomePlanStep.assistance,
          title: context.tr('Improvements and assistance'),
          description: context.tr(
            'Review possible changes and explore help with them.',
          ),
          current: currentStep == HomePlanStep.assistance,
          onTap: onAssistance,
        ),
      ],
    ),
  );
}

class _JourneyStep extends StatelessWidget {
  const _JourneyStep({
    required this.step,
    required this.title,
    required this.description,
    required this.current,
    this.onTap,
  });

  final HomePlanStep step;
  final String title;
  final String description;
  final bool current;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final number = step.index + 1;
    final enlarged = MediaQuery.textScalerOf(context).scale(14) > 20;
    return Semantics(
      key: ValueKey('home-plan-step-${step.name}'),
      container: true,
      button: onTap != null,
      label: context.tr(
        current
            ? 'Step {number} of 3. Next step. {title}. {description}'
            : 'Step {number} of 3. {title}. {description}',
        {'number': number, 'title': title, 'description': description},
      ),
      onTap: onTap,
      child: ExcludeSemantics(
        child: Ink(
          color: current ? theme.colorScheme.primaryContainer : null,
          child: InkWell(
            excludeFromSemantics: true,
            onTap: onTap,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 64),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            context.tr(
                              current
                                  ? 'Step {number} · Next step'
                                  : 'Step {number}',
                              {'number': number},
                            ),
                            style: theme.textTheme.labelMedium?.copyWith(
                              color: theme.colorScheme.primary,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(title, style: theme.textTheme.titleMedium),
                          const SizedBox(height: 4),
                          Text(
                            description,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (onTap != null && !enlarged) ...[
                      const SizedBox(width: 8),
                      Icon(
                        Icons.chevron_right_rounded,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
