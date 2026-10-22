import 'package:flutter/material.dart';

import '../../shared/models/contracts.dart';
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
              return const Center(
                child: CircularProgressIndicator(
                  semanticsLabel: 'Loading examples',
                ),
              );
            }
            if (snapshot.hasError ||
                !snapshot.hasData ||
                snapshot.data!.isEmpty) {
              return Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text('The example cases could not be loaded.'),
                      const SizedBox(height: 16),
                      FilledButton(
                        onPressed: _retry,
                        child: const Text('Try again'),
                      ),
                    ],
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
                      Text(
                        'Explore possible support',
                        style: Theme.of(context).textTheme.headlineMedium,
                      ),
                      const SizedBox(height: 12),
                      const _Panel(
                        child: Text(
                          'Fictional demo · These saved examples show how results will work. '
                          'They do not assess eligibility for a real program.',
                        ),
                      ),
                      const SizedBox(height: 24),
                      Text(
                        'Choose an example',
                        style: Theme.of(context).textTheme.titleMedium,
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
                      _Panel(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Resident details',
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                            const SizedBox(height: 8),
                            Text(
                              'City: ${selected.caseSnapshot.profile.city ?? 'Not provided'}',
                            ),
                            const SizedBox(height: 4),
                            Text(
                              'Health plan: ${selected.caseSnapshot.profile.healthPlan ?? 'Not provided'}',
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 24),
                      if (selected.matchResponse.matches.isEmpty)
                        const _Panel(
                          child: Text(
                            'This example contains no program results.',
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
                        'Saved example from ${selected.matchResponse.evaluationDate}. '
                        'Availability has not been checked. A program must review any real application.',
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
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, color: Theme.of(context).colorScheme.primary),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  label,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          const Divider(height: 1),
          for (final check in match.checks) ...[
            const SizedBox(height: 16),
            _CheckDetail(check: check),
          ],
          const SizedBox(height: 20),
          OutlinedButton.icon(
            onPressed: onOpenDraft,
            icon: const Icon(Icons.checklist_outlined),
            label: const Text('View draft checklist'),
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
        Text(label, style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 4),
        Text(check.explanation),
        if (check.status == 'unknown') ...[
          const SizedBox(height: 8),
          Text(switch (check.resolvedBy) {
            'resident' => 'Next step: confirm the missing resident details.',
            'professional' =>
              'Next step: request a qualified professional’s review.',
            'program' =>
              'Next step: confirm this requirement with the program.',
            _ => 'Next step: identify who can confirm this requirement.',
          }),
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
    final colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: colors.outlineVariant),
      ),
      child: child,
    );
  }
}
