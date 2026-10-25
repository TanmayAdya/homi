import 'package:flutter/material.dart';
import '../../app/theme.dart';
import 'package:safe_at_home/l10n/app_localizations.dart';

import '../../shared/models/contracts.dart';
import '../../shared/presentation/sah_components.dart';
import '../../shared/services/demo_scenario_service.dart';
import '../../shared/services/packet_preparation_service.dart';
import '../requests/draft_packet_screen.dart';

class DemoProgramsScreen extends StatefulWidget {
  const DemoProgramsScreen({
    super.key,
    required this.service,
    required this.packetService,
  });

  final DemoScenarioService service;
  final PacketPreparationService packetService;

  @override
  State<DemoProgramsScreen> createState() => _DemoProgramsScreenState();
}

class _DemoProgramsScreenState extends State<DemoProgramsScreen> {
  late Future<List<DemoScenario>> _scenarios;
  String? _selectedId;

  @override
  void initState() {
    super.initState();
    _scenarios = widget.service.loadScenarios();
  }

  void _retry() {
    final scenarios = widget.service.loadScenarios();
    setState(() {
      _scenarios = scenarios;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Safe at Home')),
      body: SafeArea(
        child: FutureBuilder<List<DemoScenario>>(
          future: _scenarios,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return Center(
                child: CircularProgressIndicator(
                  semanticsLabel: context.tr('Loading examples'),
                ),
              );
            }
            if (snapshot.hasError ||
                !snapshot.hasData ||
                snapshot.data!.isEmpty) {
              return Center(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(24),
                  child: SahEmptyState(
                    title: context.tr('Examples unavailable'),
                    message: context.tr(
                      'The example cases could not be loaded.',
                    ),
                    icon: Icons.cloud_off_outlined,
                    action: FilledButton(
                      onPressed: _retry,
                      child: Text(context.tr('Try again')),
                    ),
                  ),
                ),
              );
            }
            final scenarios = snapshot.data!;
            final selected = scenarios.firstWhere(
              (scenario) => scenario.id == _selectedId,
              orElse: () => scenarios.first,
            );
            return SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 720),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SahFeaturePanel(
                        eyebrow: context.tr('EXPLORE THE APP'),
                        title: context.tr('Explore possible support'),
                        description: context.tr(
                          'Fictional demo · These saved examples show how results will work. They do not assess eligibility for a real program.',
                        ),
                      ),
                      const SizedBox(height: 24),
                      Text(
                        context.tr('Choose an example'),
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final scenario in scenarios)
                            ChoiceChip(
                              key: ValueKey('scenario-${scenario.id}'),
                              label: Text(scenario.title),
                              selected: selected.id == scenario.id,
                              onSelected: (_) =>
                                  setState(() => _selectedId = scenario.id),
                            ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      Text(selected.description),
                      const SizedBox(height: 16),
                      Container(
                        padding: const EdgeInsets.all(18),
                        decoration: BoxDecoration(
                          color: Theme.of(
                            context,
                          ).colorScheme.surfaceContainerLow,
                          borderRadius: BorderRadius.circular(SahRadius.large),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              context.tr('Resident details'),
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                            const SizedBox(height: 8),
                            Text(
                              context.tr('{label}: {value}', {
                                'label': context.tr('City'),
                                'value':
                                    selected.caseSnapshot.profile.city ??
                                    context.tr('Not provided'),
                              }),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              context.tr('{label}: {value}', {
                                'label': context.tr('Health plan'),
                                'value':
                                    selected.caseSnapshot.profile.healthPlan ??
                                    context.tr('Not provided'),
                              }),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 24),
                      if (selected.matchResponse.matches.isEmpty)
                        _Panel(
                          child: Text(
                            context.tr(
                              'This example contains no program results.',
                            ),
                          ),
                        ),
                      for (final match in selected.matchResponse.matches)
                        _ProgramCard(
                          match: match,
                          onOpenDraft: () {
                            Navigator.of(context).push<void>(
                              MaterialPageRoute(
                                builder: (_) => DraftPacketScreen(
                                  snapshot: selected.caseSnapshot,
                                  program: match,
                                  service: widget.packetService,
                                  currentCase: () => scenarios
                                      .firstWhere(
                                        (scenario) =>
                                            scenario.id == _selectedId,
                                        orElse: () => scenarios.first,
                                      )
                                      .caseSnapshot,
                                ),
                              ),
                            );
                          },
                        ),
                      const SizedBox(height: 12),
                      Text(
                        context.tr(
                          'Saved example from {date}. Availability has not been checked. A program must review any real application.',
                          {'date': selected.matchResponse.evaluationDate},
                        ),
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _ProgramCard extends StatelessWidget {
  const _ProgramCard({required this.match, required this.onOpenDraft});

  final ProgramMatch match;
  final VoidCallback onOpenDraft;

  @override
  Widget build(BuildContext context) {
    final (icon, label) = switch (match.status) {
      'meets_known_criteria' => (
        Icons.check_circle_outline,
        'Meets the example criteria',
      ),
      'does_not_meet_criterion' => (
        Icons.info_outline,
        'An example criterion is not met',
      ),
      _ => (Icons.help_outline, 'More information is needed'),
    };
    return _Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            match.programName,
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 12),
          SahStatusBadge(
            label: context.tr(label),
            icon: icon,
            tone: match.status == 'meets_known_criteria'
                ? SahNoticeTone.success
                : SahNoticeTone.warning,
          ),
          const SizedBox(height: 16),
          const Divider(height: 1),
          for (final check in match.checks) ...[
            const SizedBox(height: 16),
            _CheckDetail(check: check),
          ],
          const SizedBox(height: 20),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: onOpenDraft,
              icon: const Icon(Icons.checklist_outlined),
              label: Text(
                context.tr('View draft checklist'),
                textAlign: TextAlign.center,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CheckDetail extends StatelessWidget {
  const _CheckDetail({required this.check});

  final RequirementCheck check;

  @override
  Widget build(BuildContext context) {
    final label = switch (check.status) {
      'pass' => 'Met',
      'fail' => 'Not met',
      _ => 'Needs confirmation',
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          context.tr(label),
          style: Theme.of(context).textTheme.labelLarge?.copyWith(
            color: check.status == 'pass'
                ? Theme.of(context).colorScheme.primary
                : Theme.of(context).colorScheme.tertiary,
          ),
        ),
        const SizedBox(height: 4),
        Text(check.explanation),
        if (check.status == 'unknown') ...[
          const SizedBox(height: 8),
          Text(
            context.tr(switch (check.resolvedBy) {
              'resident' => 'Next step: confirm the missing resident details.',
              'professional' =>
                'Next step: request a qualified professional’s review.',
              'program' =>
                'Next step: confirm this requirement with the program.',
              _ => 'Next step: identify who can confirm this requirement.',
            }),
          ),
        ],
      ],
    );
  }
}

class _Panel extends StatelessWidget {
  const _Panel({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 20),
      child: Padding(padding: const EdgeInsets.all(20), child: child),
    );
  }
}
