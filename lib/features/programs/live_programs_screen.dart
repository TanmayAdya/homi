import 'dart:async';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../app/live_app.dart';
import '../../shared/models/contracts.dart';
import '../../shared/presentation/sah_components.dart';
import '../../shared/services/packet_preparation_service.dart';
import 'program_intake_screen.dart';
import '../requests/draft_packet_screen.dart';
import '../requests/form_review_screen.dart';
import '../requests/private_export_screen.dart';
import '../requests/request_history_screen.dart';

class LiveProgramsScreen extends StatefulWidget {
  const LiveProgramsScreen({super.key, required this.services});
  final AppServices services;
  @override
  State<LiveProgramsScreen> createState() => _LiveProgramsScreenState();
}

class _LiveProgramsScreenState extends State<LiveProgramsScreen>
    with WidgetsBindingObserver {
  MatchResponse? _result;
  bool _busy = false;
  String? _error;
  Timer? _timer;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.services.coordinator.addListener(_changed);
    _load();
    _timer = Timer.periodic(const Duration(seconds: 30), (_) => _changed());
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _changed();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.services.coordinator.removeListener(_changed);
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final c = widget.services.coordinator;
      final result = await widget.services.matching.matchCase(
        c.currentCase(),
        currentCase: c.currentCase,
      );
      if (mounted) setState(() => _result = result);
    } catch (error) {
      if (mounted) setState(() => _error = safeOperationMessage(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _open(Widget screen) => Navigator.of(
    context,
  ).push(MaterialPageRoute<void>(builder: (_) => screen));

  Future<void> _openSource(String value) async {
    final uri = Uri.tryParse(value);
    try {
      if (uri == null ||
          uri.scheme != 'https' ||
          uri.host.isEmpty ||
          uri.userInfo.isNotEmpty ||
          !await launchUrl(uri, mode: LaunchMode.externalApplication)) {
        throw const FormatException();
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => _error =
              'The official page could not be opened. You can copy its address from Program sources.',
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.services.coordinator;
    final result = _result;
    final same =
        result != null &&
        c.snapshot != null &&
        result.caseId == c.snapshot!.caseId &&
        result.caseRevision == c.snapshot!.revision &&
        !c.hasUnsavedChanges;
    return Scaffold(
      appBar: AppBar(title: const Text('Possible assistance')),
      body: SafeArea(
        child: SahContent(
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              const SahStepIndicator(
                currentStep: 2,
                labels: ['Details', 'Home', 'Programs', 'Draft'],
              ),
              const SahPageHeader(
                title: 'Explore possible assistance',
                description:
                    'See what is known, what needs confirmation, and how to prepare each route.',
              ),
              const SahNotice(
                message:
                    'Program review is still required. These checks do not promise funding or approval.',
              ),
              if (_busy)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: LinearProgressIndicator(
                    semanticsLabel: 'Checking possible assistance',
                  ),
                ),
              if (_error != null)
                SahNotice(message: _error!, tone: SahNoticeTone.warning),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                key: const ValueKey('program-refresh'),
                onPressed: _busy ? null : _load,
                icon: const Icon(Icons.refresh_rounded),
                label: const Text(
                  'Refresh program checks',
                  textAlign: TextAlign.center,
                ),
              ),
              if (result != null && !same)
                const SahNotice(
                  message:
                      'The case changed. Refresh these results before preparing a draft.',
                  tone: SahNoticeTone.warning,
                ),
              if (result != null &&
                  same &&
                  !result.isFreshFor(
                    c.currentCase(),
                    now: DateTime.now().toUtc(),
                  ))
                const SahNotice(
                  message:
                      'Some policy details or deadlines still need confirmation. Review each unresolved requirement.',
                  tone: SahNoticeTone.warning,
                ),
              if (result != null && result.matches.isEmpty)
                const SahEmptyState(
                  title: 'No routes to review yet',
                  message:
                      'No program routes are currently configured for this case. Your saved assessment is still available.',
                  icon: Icons.search_rounded,
                ),
              if (result != null && result.matches.isNotEmpty)
                SahSectionHeading(
                  title:
                      '${result.matches.length} ${result.matches.length == 1 ? 'program route' : 'program routes'} to review',
                ),
              if (result != null)
                for (final match in result.matches)
                  Card(
                    key: ValueKey('program-${match.programId}'),
                    margin: const EdgeInsets.only(bottom: 24),
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Semantics(
                            header: true,
                            child: Text(
                              match.programName,
                              style: Theme.of(context).textTheme.titleLarge,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            switch (match.status) {
                              'meets_known_criteria' =>
                                'Matches the known checks',
                              'does_not_meet_criterion' =>
                                'A known criterion is not met',
                              _ => 'More information is needed',
                            },
                            style: Theme.of(context).textTheme.titleMedium
                                ?.copyWith(
                                  color: match.status == 'meets_known_criteria'
                                      ? Theme.of(context).colorScheme.primary
                                      : Theme.of(context).colorScheme.tertiary,
                                ),
                          ),
                          const SizedBox(height: 12),
                          Text(
                            '${match.checks.where((check) => check.status == 'pass').length} met · '
                            '${match.checks.where((check) => check.status == 'fail').length} not met · '
                            '${match.checks.where((check) => check.status == 'unknown').length} need confirmation',
                          ),
                          const SizedBox(height: 8),
                          const Text(
                            'Open Eligibility checks to review every reason. Preparing a draft does not confirm eligibility.',
                          ),
                          const SahSectionHeading(
                            title: 'Prepare this route',
                            description:
                                'Review reported facts and required documents before making a draft.',
                          ),
                          OutlinedButton(
                            key: ValueKey('program-${match.programId}-intake'),
                            onPressed: !same
                                ? null
                                : () => _open(
                                    ProgramIntakeScreen(
                                      services: widget.services,
                                      program: match,
                                    ),
                                  ),
                            child: const Text('Review program questions'),
                          ),
                          const SizedBox(height: 10),
                          OutlinedButton(
                            onPressed: !same
                                ? null
                                : () => _open(
                                    DraftPacketScreen(
                                      snapshot: c.currentCase(),
                                      program: match,
                                      service: ApiPacketPreparationService(
                                        widget.services.packets,
                                      ),
                                      currentCase: c.currentCase,
                                      caseChanges: c,
                                    ),
                                  ),
                            child: const Text('Draft checklist'),
                          ),
                          const SizedBox(height: 10),
                          OutlinedButton(
                            key: ValueKey('program-${match.programId}-answers'),
                            onPressed: !same
                                ? null
                                : () => _open(
                                    FormReviewScreen(
                                      services: widget.services,
                                      program: match,
                                    ),
                                  ),
                            child: const Text(
                              'Review administrative answers',
                              textAlign: TextAlign.center,
                            ),
                          ),
                          const SizedBox(height: 16),
                          FilledButton(
                            key: ValueKey('program-${match.programId}-export'),
                            onPressed: !same
                                ? null
                                : () => _open(
                                    PrivateExportScreen(
                                      services: widget.services,
                                      program: match,
                                    ),
                                  ),
                            child: const Text(
                              'Review evidence and draft PDF',
                              textAlign: TextAlign.center,
                            ),
                          ),
                          const SizedBox(height: 8),
                          TextButton(
                            key: ValueKey('program-${match.programId}-history'),
                            onPressed: !same
                                ? null
                                : () => _open(
                                    RequestHistoryScreen(
                                      services: widget.services,
                                      program: match,
                                    ),
                                  ),
                            child: const Text('Manual request history'),
                          ),
                          const SizedBox(height: 16),
                          ExpansionTile(
                            key: ValueKey('program-${match.programId}-checks'),
                            tilePadding: EdgeInsets.zero,
                            title: const Text('Eligibility checks'),
                            subtitle: Text(
                              '${match.checks.length} reasons to review',
                            ),
                            children: [
                              for (final check in match.checks)
                                ListTile(
                                  key: ValueKey(
                                    'program-${match.programId}-check-${check.id}',
                                  ),
                                  contentPadding: EdgeInsets.zero,
                                  minLeadingWidth: 24,
                                  leading: ExcludeSemantics(
                                    child: Icon(
                                      switch (check.status) {
                                        'pass' =>
                                          Icons.check_circle_outline_rounded,
                                        'fail' =>
                                          Icons.do_not_disturb_on_outlined,
                                        _ => Icons.help_outline_rounded,
                                      },
                                      color: check.status == 'pass'
                                          ? Theme.of(
                                              context,
                                            ).colorScheme.primary
                                          : Theme.of(
                                              context,
                                            ).colorScheme.tertiary,
                                    ),
                                  ),
                                  title: Text(switch (check.status) {
                                    'pass' => 'Met',
                                    'fail' => 'Not met',
                                    _ => 'Needs confirmation',
                                  }),
                                  subtitle: Text(check.explanation),
                                ),
                            ],
                          ),
                          ExpansionTile(
                            tilePadding: EdgeInsets.zero,
                            title: const Text(
                              'Program sources and review dates',
                            ),
                            children: [
                              ListTile(
                                title: Text(
                                  'Availability: ${match.availability.replaceAll('_', ' ')}',
                                ),
                                subtitle: Text(
                                  'Rule version: ${match.ruleVersion}',
                                ),
                              ),
                              for (final source in match.sources)
                                ListTile(
                                  title: Text(source.title),
                                  trailing: const Icon(
                                    Icons.open_in_new,
                                    semanticLabel: 'Opens in your browser',
                                  ),
                                  onTap: () => _openSource(source.url),
                                  subtitle: SelectableText(
                                    'Reviewed ${source.reviewedOn}\nEffective from: ${source.effectiveFrom ?? 'not specified'}\nEffective until: ${source.effectiveUntil ?? 'not specified'}\n${source.url}',
                                  ),
                                ),
                              if (match.sources.isEmpty)
                                const ListTile(
                                  title: Text(
                                    'No verified source references are supplied for this route.',
                                  ),
                                ),
                            ],
                          ),
                          if (match.intake != null) ...[
                            const SizedBox(height: 12),
                            Text(match.intake!),
                          ],
                          if (match.programId == 'rtp-home-repair')
                            OutlinedButton.icon(
                              onPressed: () => _openSource(
                                'https://rebuildingtogetherpeninsula.my.salesforce-sites.com/HomeownerApplication',
                              ),
                              icon: const Icon(Icons.open_in_new),
                              label: const Text(
                                'Open RTP’s official application',
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
            ],
          ),
        ),
      ),
    );
  }
}
