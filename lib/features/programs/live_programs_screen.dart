import 'dart:async';
import 'package:flutter/material.dart';
import '../tracking/program_progress_screen.dart';
import '../local_help/local_help_screen.dart';
import 'package:safe_at_home/l10n/app_localizations.dart';
import '../../app/live_app.dart';
import '../../shared/models/contracts.dart';
import '../../shared/presentation/sah_components.dart';
import '../../shared/presentation/sah_floating_nav.dart';
import '../../shared/services/packet_preparation_service.dart';
import 'program_intake_screen.dart';
import '../requests/application_workspace_screen.dart';
import '../requests/draft_packet_screen.dart';
import '../requests/request_history_screen.dart';

class LiveProgramsScreen extends StatefulWidget {
  const LiveProgramsScreen({
    super.key,
    required this.services,
    this.workspaceMode = false,
    this.header,
    this.embedded = false,
  });
  final AppServices services;
  final bool workspaceMode;
  final Widget? header;
  final bool embedded;
  @override
  LiveProgramsScreenState createState() => LiveProgramsScreenState();
}

class LiveProgramsScreenState extends State<LiveProgramsScreen>
    with WidgetsBindingObserver {
  MatchResponse? _result;
  bool _busy = false;
  bool _tracking = false;

  bool get canLeave => !_tracking;

  MatchResponse? get assistantMatches {
    final c = widget.services.coordinator;
    final snapshot = c.snapshot;
    return c.isCurrent &&
            !_busy &&
            _error == null &&
            snapshot != null &&
            !c.hasUnsavedChanges &&
            _result?.isFreshFor(snapshot, now: DateTime.now()) == true
        ? _result
        : null;
  }

  String? _assistantProgramId;
  void openAssistantProgram(String id) {
    if (!mounted ||
        !canLeave ||
        assistantMatches?.matches.any((m) => m.programId == id) != true) {
      return;
    }
    setState(() => _assistantProgramId = id);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted &&
          assistantMatches?.matches.any((m) => m.programId == id) == true) {
        _detailsController(id).expand();
      }
    });
  }

  String? _error;
  Timer? _timer;
  int? _autoRevision;
  final _detailsControllers = <String, ExpansibleController>{};
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.services.coordinator.addListener(_changed);
    _load();
    _timer = Timer.periodic(const Duration(seconds: 30), (_) => _changed());
  }

  void _changed() {
    if (!mounted) return;
    setState(() {});
    final c = widget.services.coordinator;
    final snapshot = c.snapshot, result = _result;
    if (_busy ||
        result == null ||
        snapshot == null ||
        c.hasUnsavedChanges ||
        (result.caseId == snapshot.caseId &&
            result.caseRevision == snapshot.revision) ||
        _autoRevision == snapshot.revision) {
      return;
    }
    _autoRevision = snapshot.revision;
    _load();
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
    for (final controller in _detailsControllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final c = widget.services.coordinator;
    final generation = c.generation;
    try {
      final result = await widget.services.matching.matchCase(
        c.currentCase(),
        currentCase: c.currentCase,
      );
      if (mounted && c.isCurrent && c.generation == generation) {
        setState(() => _result = result);
        scheduleMicrotask(_changed);
        unawaited(_loadStarted());
      }
    } catch (error) {
      if (mounted && c.isCurrent && c.generation == generation) {
        setState(() => _error = safeOperationMessage(error));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _open(Widget screen) => Navigator.of(
    context,
  ).push(MaterialPageRoute<void>(builder: (_) => screen));

  Future<void> _openSource(String value) async {
    if (!await launchProgramSource(value) && mounted) {
      setState(
        () => _error =
            'The official page could not be opened. You can copy its address from Program sources.',
      );
    }
  }

  Widget _checklist(ProgramMatch match) => DraftPacketScreen(
    snapshot: widget.services.coordinator.currentCase(),
    program: match,
    service: ApiPacketPreparationService(widget.services.packets),
    currentCase: widget.services.coordinator.currentCase,
    caseChanges: widget.services.coordinator,
    onContact: () => _contactProgram(match),
    onUpdates: () => _open(_history(match)),
    onResidentDetails: () => openResidentDetails(context, widget.services),
    onAddTask: widget.services.progress == null
        ? null
        : (title) => addProgramTask(context, widget.services, match, title),
  );

  Widget _history(ProgramMatch match) =>
      RequestHistoryScreen(services: widget.services, program: match);

  Future<void> _start(ProgramMatch match) async {
    if (!programHasFormWorkflow(match)) {
      _open(_checklist(match));
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ApplicationWorkspaceScreen(
          services: widget.services,
          program: match,
        ),
      ),
    );
    if (mounted) _loadStarted();
  }

  final _started = <String>{};
  Future<void> _loadStarted() async {
    final result = _result;
    if (result == null) return;
    final found = <String>{};
    for (final match in result.matches) {
      try {
        if (await widget.services.store.readJson(
              'intake.${result.caseId}.${match.programId}',
            ) !=
            null) {
          found.add(match.programId);
        }
      } catch (_) {}
    }
    if (mounted && identical(result, _result)) {
      setState(
        () => _started
          ..clear()
          ..addAll(found),
      );
    }
  }

  Future<void> _trackProgram(ProgramMatch match) async {
    if (_tracking) return;
    final c = widget.services.coordinator;
    final generation = c.generation;
    if (!c.isCurrent || c.snapshot == null || c.hasUnsavedChanges) return;
    final snapshot = c.currentCase();
    if (_result?.caseId != snapshot.caseId ||
        _result?.caseRevision != snapshot.revision) {
      return;
    }
    bool current() =>
        mounted &&
        c.isCurrent &&
        c.generation == generation &&
        c.snapshot?.caseId == snapshot.caseId &&
        c.snapshot?.revision == snapshot.revision &&
        !c.hasUnsavedChanges;
    setState(() => _tracking = true);
    try {
      await widget.services.progressReady;
      if (!current()) return;
      await widget.services.progress!.refresh(snapshot.caseId);
      if (!current()) return;
      await widget.services.progress!.mutate(
        snapshot.caseId,
        snapshot.revision,
        {'type': 'track_program', 'programId': match.programId},
      );
      if (current()) _open(ProgramProgressScreen(services: widget.services));
    } catch (error) {
      if (mounted && current()) await showOperationError(context, error);
    } finally {
      if (mounted) setState(() => _tracking = false);
    }
  }

  ExpansibleController _detailsController(String programId) =>
      _detailsControllers.putIfAbsent(programId, ExpansibleController.new);

  String _purpose(ProgramMatch match) => switch (match.programId) {
    'scfhp-eaa' =>
      'May help SCFHP Medi-Cal members with home changes needed for safety and independence.',
    'hpsm-eaa' =>
      'May help HPSM members with home changes needed for safety and independence.',
    'rtp-home-repair' =>
      'May help homeowners with no-cost safety repairs, if RTP accepts the project.',
    'usda-section-504' =>
      'May offer rural homeowners repair loans; grants are only for people 62 or older.',
    'va-hisa' =>
      'May help veterans and some servicemembers with medically needed home changes; needs a VA prescription.',
    _ => 'Possible help: review the program’s service scope.',
  };

  String? _limit(ProgramMatch match) => switch (match.programId) {
    'scfhp-eaa' || 'hpsm-eaa' =>
      'Needs a professional order and a physical or occupational therapy evaluation.',
    'rtp-home-repair' => 'RTP typically can’t do emergency repairs.',
    'usda-section-504' =>
      'Under 62, only a loan is possible, and it must be repaid.',
    'va-hisa' =>
      'A VA physician must write or approve the prescription before any work.',
    _ => null,
  };

  String _where(ProgramMatch match) => switch (match.programId) {
    'scfhp-eaa' =>
      'Santa Clara County · SCFHP Medi-Cal or DualConnect members only',
    'hpsm-eaa' =>
      'San Mateo County · HPSM Medi-Cal or CareAdvantage members only',
    'rtp-home-repair' =>
      'San Mateo County, Palo Alto, Mountain View, Los Altos · RTP confirms the address',
    'usda-section-504' => 'Rural areas in the U.S. · USDA confirms the address',
    'va-hisa' => 'Nationwide · VA confirms benefit eligibility',
    _ => 'Confirm your address with the program',
  };

  String _title(ProgramMatch match) => programShortName(match);

  String _primaryLabel(ProgramMatch match) => _started.contains(match.programId)
      ? 'Continue'
      : switch (programOutputKind(match)) {
          SahOutputKind.officialFormDraft => 'Start application',
          SahOutputKind.preparationWorksheet => 'Prepare worksheet',
          _ => 'See checklist',
        };

  String _summary(BuildContext context, ProgramMatch match) {
    int count(bool Function(RequirementCheck) test) =>
        match.checks.where(test).length;
    final values = {
      'met': count((c) => c.status == 'pass'),
      'answer': count(
        (c) => c.status == 'unknown' && c.resolvedBy == 'resident',
      ),
      'others': count(
        (c) => c.status == 'unknown' && c.resolvedBy != 'resident',
      ),
      'notMet': count((c) => c.status == 'fail'),
    };
    return context.tr(
      values['notMet'] == 0
          ? '{met} looks met · {answer} for you to answer · {others} others must confirm'
          : '{notMet} not met · {met} looks met · {answer} for you to answer · {others} others must confirm',
      values,
    );
  }

  Future<void> _contactProgram(ProgramMatch match) => showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(context.tr('Contact program')),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(match.programName),
            const SizedBox(height: 12),
            SelectableText(
              match.intake ??
                  context.tr(
                    'Contact instructions are not supplied. Use the program sources to confirm the accepted intake route.',
                  ),
            ),
            for (final source in match.sources)
              TextButton.icon(
                onPressed: () {
                  Navigator.of(context).pop();
                  _openSource(source.url);
                },
                icon: const Icon(Icons.open_in_new),
                label: Text(source.title),
              ),
            if (match.sources.isEmpty)
              Text(
                context.tr(
                  'No verified source references are supplied for this route.',
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(context.tr('Close')),
        ),
      ],
    ),
  );

  static String _firstSentence(String text) {
    final match = RegExp(r'^(.+?[.!?])\s').firstMatch(text.trim());
    return match?.group(1) ?? text.trim();
  }

  List<Widget> _requirements(
    BuildContext context,
    ProgramMatch match,
    bool same,
  ) {
    Widget heading(String label, int count) => Padding(
      padding: const EdgeInsets.only(top: 16, bottom: 4),
      child: Semantics(
        header: true,
        child: Text(
          context.tr('{group} ({count})', {
            'group': context.tr(label),
            'count': count,
          }),
          style: Theme.of(context).textTheme.titleMedium,
        ),
      ),
    );
    Widget checkTile(RequirementCheck check) {
      final line = _firstSentence(check.explanation);
      final sources = match.sources.where(
        (source) => check.sourceIds.contains(source.id),
      );
      final key = ValueKey('program-${match.programId}-check-${check.id}');
      if (line == check.explanation.trim() && sources.isEmpty) {
        return ListTile(
          key: key,
          contentPadding: EdgeInsets.zero,
          title: Text(line),
        );
      }
      return ExpansionTile(
        key: key,
        tilePadding: EdgeInsets.zero,
        title: Text(line),
        subtitle: Text(
          context.tr('Why'),
          style: Theme.of(context).textTheme.labelLarge,
        ),
        expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
        childrenPadding: const EdgeInsets.only(bottom: 12),
        children: [
          Text(check.explanation),
          for (final source in sources)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                context.tr('Source: {source} · reviewed {reviewed}', {
                  'source': source.title,
                  'reviewed': source.reviewedOn,
                }),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
        ],
      );
    }

    final groups = <(String, String?, Iterable<RequirementCheck>)>[
      ('Looks met', null, match.checks.where((c) => c.status == 'pass')),
      (
        'You can answer',
        'Answer what you know. Reported answers do not replace required consent or documents.',
        match.checks.where(
          (c) => c.status == 'unknown' && c.resolvedBy == 'resident',
        ),
      ),
      (
        'The program must confirm',
        'The program must confirm its policy, coverage and current availability. Refreshing won’t change these.',
        match.checks.where(
          (c) => c.status == 'unknown' && c.resolvedBy == 'program',
        ),
      ),
      (
        'A professional must confirm',
        'A qualified professional must review these items. Home observations do not establish medical necessity.',
        match.checks.where(
          (c) => c.status == 'unknown' && c.resolvedBy == 'professional',
        ),
      ),
      ('Not met', null, match.checks.where((c) => c.status == 'fail')),
      (
        'Reviewer not specified',
        'Next step: identify who can confirm this requirement.',
        match.checks.where(
          (c) => c.status == 'unknown' && c.resolvedBy == null,
        ),
      ),
    ];
    return [
      const SizedBox(height: 8),
      Text(
        context.tr(
          'Checks, not decisions. Each program still reviews the case.',
        ),
      ),
      for (final (label, guidance, checks) in groups)
        if (checks.isNotEmpty) ...[
          heading(label, checks.length),
          if (guidance != null)
            Text(
              context.tr(guidance),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          if (label == 'You can answer' && programHasFormWorkflow(match))
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton(
                key: ValueKey('program-${match.programId}-missing-answers'),
                onPressed: same
                    ? () => _open(
                        ProgramIntakeScreen(
                          services: widget.services,
                          program: match,
                        ),
                      )
                    : null,
                child: Text(context.tr('Answer missing questions')),
              ),
            ),
          if (label == 'The program must confirm')
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton(
                key: ValueKey('program-${match.programId}-contact'),
                onPressed: () => _contactProgram(match),
                child: Text(context.tr('Contact program')),
              ),
            ),
          for (final check in checks) checkTile(check),
        ],
    ];
  }

  Widget _details(BuildContext context, ProgramMatch match, bool same) {
    return ExpansionTile(
      key: ValueKey('program-${match.programId}-details'),
      controller: _detailsController(match.programId),
      tilePadding: EdgeInsets.zero,
      title: Text(
        context.tr('Details'),
        semanticsLabel: context.tr('Details for {program}', {
          'program': _title(match),
        }),
      ),
      expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_title(match) != match.programName) ...[
          Text(match.programName),
          const SizedBox(height: 8),
        ],
        Text(
          context.tr(switch (match.availability) {
            'accepting' =>
              'Intake is listed as open. Confirm current availability with the program.',
            'not_accepting' =>
              'Intake is listed as closed. Ask the program about next steps.',
            _ =>
              'Current availability is unverified. Confirm it with the program.',
          }),
        ),
        const SizedBox(height: 8),
        Text(
          context.tr(switch (match.status) {
            'meets_known_criteria' => 'Matches the known checks',
            'does_not_meet_criterion' => 'A known criterion is not met',
            _ => 'More information is needed',
          }),
        ),
        const SizedBox(height: 8),
        Text(
          context.tr(
            'Preparation only. Nothing has been submitted by this app.',
          ),
        ),
        if (!programHasFormWorkflow(match))
          Text(
            context.tr(
              'This app-generated checklist is not an official application form. Review requirements with the program.',
            ),
          ),
        ..._requirements(context, match, same),
        const SizedBox(height: 16),
        if (!programHasFormWorkflow(match))
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton(
              key: ValueKey('program-${match.programId}-history'),
              onPressed: same ? () => _open(_history(match)) : null,
              child: Text(context.tr('Updates')),
            ),
          ),
        if (widget.services.config.trackingEnabled)
          TextButton.icon(
            onPressed: !same || _tracking ? null : () => _trackProgram(match),
            icon: const Icon(Icons.playlist_add),
            label: Text(context.tr('Track program')),
          ),
        Padding(
          padding: const EdgeInsets.only(top: 12, bottom: 4),
          child: Text(
            context.tr('Program sources and review dates'),
            style: Theme.of(context).textTheme.titleSmall,
          ),
        ),
        ListTile(
          title: Text(
            context.tr('Availability: {availability}', {
              'availability': context.tr(switch (match.availability) {
                'accepting' => 'accepting',
                'not_accepting' => 'not accepting',
                _ => 'unverified',
              }),
            }),
          ),
          subtitle: Text(
            context.tr('Rule version: {version}', {
              'version': match.ruleVersion,
            }),
          ),
        ),
        for (final source in match.sources)
          ListTile(
            title: Text(source.title),
            trailing: Icon(
              Icons.open_in_new,
              semanticLabel: context.tr('Opens in your browser'),
            ),
            onTap: () => _openSource(source.url),
            subtitle: SelectableText(
              context.tr(
                'Reviewed {reviewed}\nEffective from: {from}\nEffective until: {until}\n{url}',
                {
                  'reviewed': source.reviewedOn,
                  'from': source.effectiveFrom ?? context.tr('not specified'),
                  'until': source.effectiveUntil ?? context.tr('not specified'),
                  'url': source.url,
                },
              ),
            ),
          ),
        if (match.sources.isEmpty)
          ListTile(
            title: Text(
              context.tr(
                'No verified source references are supplied for this route.',
              ),
            ),
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
            label: Text(context.tr('Open RTP’s official application')),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.services.coordinator;
    final result = c.isCurrent && c.snapshot?.caseId == _result?.caseId
        ? _result
        : null;
    final same =
        result != null &&
        c.snapshot != null &&
        result.caseId == c.snapshot!.caseId &&
        result.caseRevision == c.snapshot!.revision &&
        !c.hasUnsavedChanges;
    final now = DateTime.now().toUtc();
    final datedChecksExpired =
        result != null &&
        (now.isBefore(DateTime.parse(result.evaluatedAt)) ||
            result.matches.any(
              (match) =>
                  match.recheckAfter != null &&
                  !now.isBefore(DateTime.parse(match.recheckAfter!)),
            ));
    final body = SahContent(
      child: ListView(
        padding: sahFloatingContentPadding(context),
        children: [
          if (widget.header != null) widget.header!,
          if (!widget.workspaceMode)
            SahPageHeader(title: context.tr('Possible assistance')),
          if (widget.embedded && !widget.workspaceMode)
            LocalHelpButton(services: widget.services),
          if (widget.services.config.trackingEnabled)
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton.icon(
                onPressed: same
                    ? () => _open(
                        ProgramProgressScreen(services: widget.services),
                      )
                    : null,
                icon: const Icon(Icons.view_list_outlined),
                label: Text(context.tr('Program progress')),
              ),
            ),
          if (Localizations.localeOf(context).languageCode != 'en')
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                context.tr(
                  'Program information and official forms may remain in English. Your saved answers are not translated.',
                ),
              ),
            ),
          if (_busy)
            Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: LinearProgressIndicator(
                semanticsLabel: context.tr('Checking possible assistance'),
              ),
            ),
          if (_error != null)
            SahNotice(
              message: context.tr(_error!),
              tone: SahNoticeTone.warning,
            ),
          if (result != null && !same && !_busy)
            SahNotice(
              message: context.tr(
                c.hasUnsavedChanges
                    ? 'These results update once the case changes are saved.'
                    : 'The case changed. Refresh these results before preparing a draft.',
              ),
              tone: SahNoticeTone.warning,
            ),
          if (same && datedChecksExpired)
            SahStatusBadge(
              label: context.tr('Some policy details are unconfirmed'),
              icon: Icons.info_outline_rounded,
              tone: SahNoticeTone.warning,
            ),
          if (!_busy &&
              (_error != null ||
                  result == null ||
                  (datedChecksExpired && !c.hasUnsavedChanges) ||
                  (!same && !c.hasUnsavedChanges)))
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton.icon(
                key: const ValueKey('program-refresh'),
                onPressed: _load,
                icon: const Icon(Icons.refresh_rounded),
                label: Text(
                  context.tr('Refresh program checks'),
                  textAlign: TextAlign.center,
                ),
              ),
            ),
          if (result != null && result.matches.isEmpty)
            SahEmptyState(
              title: context.tr('No routes to review yet'),
              message: context.tr(
                'No program routes are currently configured for this case. Your saved assessment is still available.',
              ),
              icon: Icons.search_rounded,
            ),
          if (result != null && result.matches.isNotEmpty) ...[
            SahSectionHeading(
              title: context.tr(
                result.matches.length == 1
                    ? '{count} program'
                    : '{count} programs',
                {'count': result.matches.length},
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: Text(
                context.tr('Eligibility and availability need confirmation.'),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ],
          if (_assistantProgramId != null)
            TextButton(
              onPressed: () => setState(() => _assistantProgramId = null),
              child: Text(context.tr('All programs')),
            ),
          if (result != null)
            for (final match in result.matches.where(
              (m) =>
                  _assistantProgramId == null ||
                  m.programId == _assistantProgramId,
            ))
              Card(
                key: ValueKey('program-${match.programId}'),
                margin: const EdgeInsets.only(bottom: 16),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Semantics(
                        header: true,
                        child: Text(
                          _title(match),
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(context.tr(_purpose(match))),
                      if (_limit(match) case final limit?) ...[
                        const SizedBox(height: 4),
                        Text(
                          context.tr(limit),
                          key: ValueKey('program-limit-${match.programId}'),
                        ),
                      ],
                      const SizedBox(height: 4),
                      Text(
                        context.tr('Where: {where}', {
                          'where': context.tr(_where(match)),
                        }),
                      ),
                      const SizedBox(height: 8),
                      SahOutputLabel(kind: programOutputKind(match)),
                      const SizedBox(height: 8),
                      if (match.availability == 'not_accepting') ...[
                        Text(
                          context.tr(
                            'Intake is listed as closed. Ask the program about next steps.',
                          ),
                        ),
                        const SizedBox(height: 8),
                      ],
                      if (match.status == 'does_not_meet_criterion') ...[
                        Text(context.tr('A known criterion is not met')),
                        const SizedBox(height: 8),
                      ],
                      Text(
                        _summary(context, match),
                        key: ValueKey('program-${match.programId}-summary'),
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      const SizedBox(height: 12),
                      FilledButton(
                        key: ValueKey('program-${match.programId}-start'),
                        onPressed: same ? () => _start(match) : null,
                        child: Text(context.tr(_primaryLabel(match))),
                      ),
                      _details(context, match, same),
                    ],
                  ),
                ),
              ),
        ],
      ),
    );
    if (widget.embedded) return body;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          context.tr(widget.workspaceMode ? 'Help' : 'Possible assistance'),
        ),
        actions: [
          if (!widget.workspaceMode) LocalHelpButton(services: widget.services),
        ],
      ),
      body: SafeArea(child: body),
    );
  }
}
