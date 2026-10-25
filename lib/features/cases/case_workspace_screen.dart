import 'dart:async';

import '../sharing/sharing_screens.dart';
import '../assistant/plan_assistant_screen.dart';
import '../assistant/assistant_app_context.dart';
import '../assistant/assistant_context_v2.dart';
import '../../shared/navigation/homi_destination.dart';
import '../assistant/assistant_runtime.dart';
import '../../shared/services/case_coordinator.dart';
import '../../shared/presentation/sah_floating_nav.dart';
import 'package:flutter/material.dart';
import 'package:safe_at_home/l10n/app_localizations.dart';
import '../../app/live_app.dart';
import '../../shared/models/case_draft.dart';
import '../../shared/presentation/sah_components.dart';
import '../programs/live_programs_screen.dart';
import '../tracking/program_progress_screen.dart';
import '../local_help/local_help_screen.dart';
import '../assessment/domain/measurement/measurement_fields.dart';
import '../assessment/domain/home_safety/home_safety.dart';
import '../assessment/presentation/live_assessment_screen.dart';
import '../assessment/presentation/home_safety/home_safety_screen.dart';
import 'case_display_details.dart';
import 'profile_editor_screen.dart';
import 'profile_response_state.dart';
import 'plan_next_step.dart';
import '../requests/application_workspace_screen.dart';

class CaseWorkspaceScreen extends StatefulWidget {
  const CaseWorkspaceScreen({
    super.key,
    required this.services,
    this.homeSafetyCatalog,
    this.embedded = false,
    this.destination = 0,
    this.onDestinationSelected,
    this.onOpenScreensChanged,
    this.onAccount,
    this.onRename,
  });
  final AppServices services;
  final HomeSafetyCatalog? homeSafetyCatalog;
  final bool embedded;
  final int destination;
  final ValueChanged<int>? onDestinationSelected;
  final VoidCallback? onOpenScreensChanged;
  final VoidCallback? onAccount;
  final VoidCallback? onRename;

  @override
  State<CaseWorkspaceScreen> createState() => CaseWorkspaceScreenState();
}

class CaseWorkspaceScreenState extends State<CaseWorkspaceScreen> {
  AppServices get services => widget.services;
  (int, String, String)? _responseIdentity;

  @override
  void initState() {
    super.initState();
    services.coordinator.addListener(_profileChanged);
    _profileChanged();
  }

  @override
  void didUpdateWidget(CaseWorkspaceScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.services != services) {
      oldWidget.services.coordinator.removeListener(_profileChanged);
      services.coordinator.addListener(_profileChanged);
      _responseIdentity = null;
      _profileChanged();
    }
  }

  void _profileChanged() {
    final c = services.coordinator;
    final draft = c.draft;
    if (draft == null || !c.isCurrent) return;
    final identity = (
      c.generation,
      draft.caseId,
      ProfileResponseState.fingerprint(draft.profile),
    );
    if (_responseIdentity == identity) return;
    _responseIdentity = identity;
    unawaited(_readResponses(draft));
  }

  Future<void> _readResponses(CaseDraft draft) async {
    try {
      await services.profileResponses.read(draft.caseId, draft.profile);
    } catch (_) {}
  }

  @override
  void dispose() {
    services.coordinator.removeListener(_profileChanged);
    super.dispose();
  }

  int _standaloneTab = 0;
  int get _tab =>
      (widget.embedded ? widget.destination : _standaloneTab).clamp(0, 3);
  final Set<int> _visited = {0};
  bool get canLeave =>
      !services.coordinator.hasUndurableEdits &&
      !services.coordinator.busy &&
      _roomsKey.currentState?.canLeave != false &&
      _tasksKey.currentState?.canLeave != false &&
      _legacyKey.currentState?.canLeave != false &&
      _programsKey.currentState?.canLeave != false &&
      _localHelpKey.currentState?.canLeave != false;
  bool handleBack() =>
      _tab == 1 &&
      ((_roomsKey.currentState?.handleBack() ?? false) ||
          (_legacyKey.currentState?.handleBack() ?? false));
  Future<bool> prepareToLeave() async =>
      canLeave && (await _legacyKey.currentState?.prepareToLeave() ?? true);
  final _programsKey = GlobalKey<LiveProgramsScreenState>();
  final _localHelpKey = GlobalKey<LocalHelpScreenState>();
  final _legacyKey = GlobalKey<LiveAssessmentScreenState>();
  bool _showLocalHelp = false;
  bool _visitedLocalHelp = false;

  String? _roomId;
  final _roomsKey = GlobalKey<HomeSafetyScreenState>();
  final _tasksKey = GlobalKey<ProgramProgressScreenState>();
  final _tabNavigators = List.generate(
    4,
    (_) => GlobalKey<SahTabNavigatorState>(),
  );

  bool hasOpenScreensIn(int tab) =>
      tab < _tabNavigators.length &&
      _tabNavigators[tab].currentState?.hasOpenScreens == true;

  bool get hasOpenScreens =>
      _tabNavigators.any((key) => key.currentState?.hasOpenScreens == true);

  Future<bool> prepareToChangePlan() async {
    if (!await prepareToLeave()) return false;
    for (final key in _tabNavigators) {
      if (await key.currentState?.closeOpenScreens() == false) return false;
    }
    return true;
  }

  void _openScreensChanged(bool _) => widget.onOpenScreensChanged?.call();

  void _selectTab(int value) {
    if (value == _tab || !services.coordinator.isCurrent) return;
    if (!canLeave) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(context.tr('Finish saving before changing sections.')),
        ),
      );
      return;
    }
    if (_roomsKey.currentState != null) {
      _roomId = _roomsKey.currentState!.selectedRoom;
    }
    FocusManager.instance.primaryFocus?.unfocus();
    if (widget.onDestinationSelected != null) {
      widget.onDestinationSelected!(value);
    } else {
      setState(() => _standaloneTab = value);
    }
  }

  AssistantContextV2 get assistantContext =>
      assistantContextAt(HomiDestination.values[_tab]);

  AssistantContextV2 assistantContextAt(HomiDestination destination) =>
      assistantAppContext(
        services,
        destination: destination,
        rooms: _roomsKey.currentState?.session,
        matches: _programsKey.currentState?.assistantMatches,
      );

  void openAssistantTarget(HomiTarget target) {
    if (!mounted ||
        !services.coordinator.isCurrent ||
        target.caseId != services.coordinator.draft?.caseId ||
        !canLeave) {
      return;
    }
    final previousDestination = HomiDestination.values[_tab];
    final expectedContext = assistantContextAt(previousDestination).key;
    if (target.destination == HomiDestination.help) {
      setState(() => _showLocalHelp = false);
    }
    _selectTab(target.destination.index);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          !services.coordinator.isCurrent ||
          target.caseId != services.coordinator.draft?.caseId ||
          _tab != target.destination.index ||
          assistantContextAt(previousDestination).key != expectedContext) {
        return;
      }
      if (target.roomId != null) {
        _roomsKey.currentState?.openAssistantRoom(
          target.roomId!,
          findingId: target.findingId,
        );
      }
      if (target.taskId != null) {
        _tasksKey.currentState?.openAssistantTask(target.taskId!);
      }
      if (target.programId != null) {
        _programsKey.currentState?.openAssistantProgram(target.programId!);
      }
    });
  }

  void _assistant() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PlanAssistantScreen(
          coordinator: services.coordinator,
          model: assistantRuntime(),
          appContextProvider: () => assistantContext,
          onTarget: (target) {
            Navigator.of(context).pop();
            openAssistantTarget(target);
          },
          onSection: (section) {
            Navigator.of(context).pop();
            section >= HomiDestination.settings.index
                ? widget.onAccount?.call()
                : _selectTab(section);
          },
        ),
      ),
    );
  }

  Widget _helpLinks(BuildContext context) {
    void select(bool local) {
      if (!canLeave) return;
      setState(() {
        _showLocalHelp = local;
        _visitedLocalHelp = _visitedLocalHelp || local;
      });
    }

    final draft = services.coordinator.draft;
    final localEnabled = services.config.localHelpEnabled;
    final largeText = MediaQuery.textScalerOf(context).scale(14) > 17;
    String label(bool local) => context.tr(
      local ? 'Organizations and referrals' : 'Programs for this plan',
    );
    return SahContent(
      child: SahPageHeader(
        title: context.tr('Find help'),
        description: draft == null
            ? null
            : services.coordinator.planNameFor(draft.caseId) ??
                  homePlanTitle(draft, context: context),
        trailing: !localEnabled
            ? null
            : Semantics(
                container: true,
                label: context.tr('Type of results'),
                child: largeText
                    ? Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          for (final local in [false, true])
                            OutlinedButton.icon(
                              key: local
                                  ? const ValueKey('case-local-help')
                                  : const ValueKey('case-help-programs'),
                              onPressed: canLeave ? () => select(local) : null,
                              icon: Icon(
                                _showLocalHelp == local
                                    ? Icons.check_circle_outline
                                    : Icons.circle_outlined,
                              ),
                              label: Text(label(local)),
                            ),
                        ],
                      )
                    : Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final local in [false, true])
                            ChoiceChip(
                              key: local
                                  ? const ValueKey('case-local-help')
                                  : const ValueKey('case-help-programs'),
                              label: Text(label(local)),
                              selected: _showLocalHelp == local,
                              onSelected: canLeave
                                  ? (_) => select(local)
                                  : null,
                            ),
                        ],
                      ),
              ),
      ),
    );
  }

  Widget _unavailableSection(
    BuildContext context, {
    required String title,
    required String message,
    bool help = false,
  }) => Builder(
    builder: (context) => SahContent(
      child: ListView(
        padding: sahFloatingContentPadding(context),
        children: [
          if (help) _helpLinks(context),
          SahNotice(message: context.tr(message)),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: () => _selectTab(0),
            child: Text(context.tr('Return to plan')),
          ),
        ],
      ),
    ),
  );

  List<Widget> _problemNotice(
    BuildContext context,
    CaseCoordinator c,
    CaseDraft draft,
  ) => [
    SahNotice(
      key: const ValueKey('case-save-status'),
      title: c.localSaveFailed
          ? context.tr('Not saved on this device')
          : c.localWritePending
          ? context.tr('Saving on this device')
          : c.busy
          ? context.tr('Case update in progress')
          : c.conflict
          ? context.tr('Case versions need review')
          : context.tr('Save confirmation needed'),
      message: c.localSaveFailed
          ? context.tr('Keep this case open and retry.')
          : c.localWritePending
          ? context.tr('Wait before leaving this case.')
          : c.busy
          ? context.tr('Wait for confirmation.')
          : c.conflict
          ? context.tr('The saved case and this device differ.')
          : context.tr(
              'A save may already have worked. Check before saving again.',
            ),
      icon: c.localSaveFailed
          ? Icons.error_outline
          : c.localWritePending || c.busy
          ? Icons.sync_rounded
          : Icons.sync_problem_outlined,
      tone: c.localSaveFailed
          ? SahNoticeTone.error
          : c.uncertain || c.conflict
          ? SahNoticeTone.warning
          : SahNoticeTone.info,
    ),
    if (c.notice != null)
      Text(
        context.tr(c.notice!),
        key: const ValueKey('case-latest-update'),
        style: Theme.of(context).textTheme.bodyMedium,
      ),
    if (c.localSaveFailed)
      OutlinedButton.icon(
        key: const ValueKey('case-retry-device-save'),
        onPressed: c.busy || c.localWritePending
            ? null
            : () => _run(context, c.retryDeviceSave),
        icon: const Icon(Icons.save_outlined),
        label: Text(context.tr('Retry saving on this device')),
      ),
    if (c.busy)
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: LinearProgressIndicator(
          semanticsLabel: context.tr('Updating saved case'),
        ),
      ),
    if (c.conflict) ...[
      ExpansionTile(
        title: Text(context.tr('Compare versions')),
        children: [
          _CaseVersionSummary(
            title: context.tr('Saved online'),
            draft: c.snapshot == null
                ? null
                : CaseDraft.fromSnapshot(c.snapshot!),
          ),
          _CaseVersionSummary(
            title: context.tr('On this device'),
            draft: draft,
          ),
        ],
      ),
      OutlinedButton(
        onPressed: c.busy
            ? null
            : () => _run(context, () => c.resolveConflict(keepLocal: false)),
        child: Text(context.tr('Use the saved version')),
      ),
      const SizedBox(height: 8),
      OutlinedButton(
        onPressed: c.busy
            ? null
            : () => _run(context, () => c.resolveConflict(keepLocal: true)),
        child: Text(context.tr('Keep my edits for another save')),
      ),
    ],
    const SizedBox(height: 8),
    if (c.uncertain) ...[
      FilledButton(
        key: const ValueKey('case-check-saved-state'),
        onPressed: c.busy ? null : () => _run(context, c.reconcile),
        child: Text(context.tr('Check saved state')),
      ),
      const SizedBox(height: 10),
    ],
    FilledButton.icon(
      key: const ValueKey('case-save-online'),
      onPressed: c.busy || c.uncertain || c.conflict
          ? null
          : () => _run(context, c.save),
      icon: const Icon(Icons.cloud_upload_outlined),
      label: Text(context.tr('Retry sync')),
    ),
    if (!c.uncertain)
      TextButton(
        key: const ValueKey('case-check-saved-state'),
        onPressed: c.busy ? null : () => _run(context, c.reconcile),
        child: Text(context.tr('Check saved state')),
      ),
  ];

  Future<void> _run(
    BuildContext context,
    Future<void> Function() action,
  ) async {
    try {
      await action();
    } catch (error) {
      if (context.mounted) await showOperationError(context, error);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([
      services.coordinator,
      services.profileResponses,
      if (services.progress != null) services.progress!,
    ]),
    builder: (context, _) {
      final c = services.coordinator;
      final draft = c.draft;
      if (draft == null) {
        return Scaffold(
          body: SafeArea(
            child: SingleChildScrollView(
              padding: EdgeInsets.all(24),
              child: SahEmptyState(
                title: context.tr('This case is no longer selected.'),
                message: context.tr('Return to your cases to open it again.'),
                icon: Icons.folder_open_outlined,
              ),
            ),
          ),
        );
      }
      final profile = draft.profile.toJson();
      final planTitle =
          c.planNameFor(draft.caseId) ?? homePlanTitle(draft, context: context);
      final answered = services.profileResponses
          .currentFor(draft.caseId, draft.profile)
          .answeredCount(draft.profile);
      final programsBlocked =
          c.busy ||
          c.snapshot == null ||
          c.hasUnsavedChanges ||
          c.uncertain ||
          c.conflict;
      final problem =
          c.localSaveFailed ||
          c.localWritePending ||
          c.busy ||
          c.conflict ||
          c.uncertain;
      final progress = services.progress?.cached[draft.caseId];
      final suggested = draft.findings
          .where((f) => f.reviewState == 'needs_review')
          .length;
      final kept = draft.findings
          .where((f) => f.reviewState == 'confirmed')
          .length;
      final facts = PlanProgressFacts(
        answered: answered,
        questions: profile.length,
        suggestedConcerns: suggested,
        keptConcerns: kept,
        programs: progress?.programs ?? const [],
        tasks: progress?.tasks ?? const [],
      );
      final next = planNextStep(facts);
      final overview = Builder(
        builder: (context) {
          void open(Widget screen) => Navigator.of(
            context,
          ).push(MaterialPageRoute<void>(builder: (_) => screen));
          void follow(PlanStepTarget target, {String? programId}) {
            switch (target) {
              case PlanStepTarget.profile:
                if (!c.busy) open(ProfileEditorScreen(services: services));
              case PlanStepTarget.rooms:
                _selectTab(1);
              case PlanStepTarget.help:
                _selectTab(2);
              case PlanStepTarget.program:
                _selectTab(2);
                if (programId != null) {
                  WidgetsBinding.instance.addPostFrameCallback(
                    (_) => _programsKey.currentState?.openAssistantProgram(
                      programId,
                    ),
                  );
                }
              case PlanStepTarget.tasks:
                _selectTab(3);
            }
          }

          final theme = Theme.of(context);
          final programs = facts.activePrograms;
          final nextValues = {
            ...next.values,
            if (next.programId case final id?)
              'program': programOverviewName(
                context,
                id,
                '${next.values['program']}',
              ),
          };
          final openTasks = facts.openTasks;
          String programStatus(String? status) => context.tr(switch (status) {
            null || 'preparing' => 'Preparing · not sent',
            'submitted' => 'Sent (you recorded)',
            'received' => 'Received (you recorded)',
            'needs_information' => 'Needs information (you recorded)',
            'approved' => 'Approved (you recorded)',
            'denied' => 'Denied (you recorded)',
            'withdrawn' => 'Withdrawn (you recorded)',
            _ => 'Preparing · not sent',
          });
          return SahContent(
            child: ListView(
              padding: sahFloatingContentPadding(context),
              children: [
                SahPageHeader(
                  key: const ValueKey('case-plan-title'),
                  title: planTitle,
                  trailing: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (!problem)
                        SahStatusLine(
                          key: const ValueKey('case-save-badge'),
                          label: c.snapshot == null
                              ? context.tr('Saved on this device')
                              : c.hasUnsavedChanges
                              ? context.tr('Changes not saved online')
                              : context.tr('Saved online'),
                          state: c.snapshot == null || c.hasUnsavedChanges
                              ? SahSaveState.waiting
                              : SahSaveState.saved,
                        ),
                      if (!problem &&
                          c.notice != null &&
                          !c.notice!.startsWith('Saved'))
                        Semantics(
                          liveRegion: true,
                          child: Text(
                            context.tr(c.notice!),
                            key: const ValueKey('case-latest-update'),
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      Wrap(
                        spacing: 8,
                        children: [
                          TextButton(
                            key: const ValueKey('case-rename-plan'),
                            style: TextButton.styleFrom(
                              padding: EdgeInsets.zero,
                            ),
                            onPressed: c.busy || widget.onRename == null
                                ? null
                                : widget.onRename,
                            child: Text(context.tr('Edit name')),
                          ),
                          if (!problem &&
                              (c.snapshot == null || c.hasUnsavedChanges))
                            TextButton.icon(
                              key: const ValueKey('case-save-online'),
                              onPressed: () => _run(context, c.save),
                              icon: const Icon(Icons.cloud_upload_outlined),
                              label: Text(context.tr('Retry sync')),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
                if (problem) ..._problemNotice(context, c, draft),
                SahNextStepCard(
                  key: const ValueKey('plan-next-step'),
                  title: context.tr(next.title, nextValues),
                  message: context.tr(next.message, nextValues),
                  actionLabel: context.tr(next.action),
                  actionKey: const ValueKey('plan-next-step-action'),
                  onAction: () =>
                      follow(next.target, programId: next.programId),
                ),
                SahListGroup(
                  title: context.tr('Your progress'),
                  children: [
                    SahStepTile(
                      key: const ValueKey('case-profile'),
                      number: 1,
                      title: context.tr('Resident details'),
                      subtitle: answered == 0
                          ? context.tr(
                              'About 3 minutes. You can skip any question.',
                            )
                          : context.tr('{count} of {total} answered', {
                              'count': answered,
                              'total': profile.length,
                            }),
                      state: answered == 0
                          ? SahStepState.notStarted
                          : answered >= profile.length
                          ? SahStepState.done
                          : SahStepState.inProgress,
                      onTap: c.busy
                          ? null
                          : () => open(ProfileEditorScreen(services: services)),
                    ),
                    SahStepTile(
                      key: const ValueKey('case-rooms'),
                      number: 2,
                      title: context.tr('Rooms and concerns'),
                      subtitle: draft.findings.isEmpty
                          ? context.tr('Not started — you can start here')
                          : [
                              if (suggested > 0)
                                context.tr('{count} to review', {
                                  'count': suggested,
                                }),
                              if (kept > 0)
                                context.tr(
                                  kept == 1
                                      ? '1 concern kept'
                                      : '{count} concerns kept',
                                  {'count': kept},
                                ),
                              if (suggested == 0 && kept == 0)
                                context.tr('No concerns kept'),
                            ].join(' · '),
                      state: suggested > 0
                          ? SahStepState.attention
                          : draft.findings.isEmpty
                          ? SahStepState.notStarted
                          : SahStepState.inProgress,
                      onTap: () => _selectTab(1),
                    ),
                    SahStepTile(
                      key: const ValueKey('case-programs'),
                      number: 3,
                      title: context.tr('Find help'),
                      subtitle: facts.programs.isEmpty
                          ? context.tr('Works before anything else')
                          : context.tr(
                              facts.programs.length == 1
                                  ? '1 program followed'
                                  : '{count} programs followed',
                              {'count': facts.programs.length},
                            ),
                      state: facts.programs.isEmpty
                          ? SahStepState.notStarted
                          : SahStepState.inProgress,
                      onTap: () => _selectTab(2),
                    ),
                    SahStepTile(
                      key: const ValueKey('case-documents'),
                      number: 4,
                      title: context.tr('Applications'),
                      subtitle: programs.isEmpty
                          ? context.tr('Starts from Find help')
                          : programs
                                .map(
                                  (p) =>
                                      '${programOverviewName(context, p.id, p.name)} — ${programStatus(p.latest?['status'] as String?)}',
                                )
                                .join('\n'),
                      state: programs.isEmpty
                          ? SahStepState.notStarted
                          : SahStepState.inProgress,
                      onTap: () => programs.isEmpty
                          ? _selectTab(2)
                          : follow(
                              PlanStepTarget.program,
                              programId: programs.first.id,
                            ),
                    ),
                    SahStepTile(
                      key: const ValueKey('case-tasks'),
                      number: 5,
                      title: context.tr('Follow-up'),
                      subtitle: openTasks.isEmpty
                          ? context.tr('Tasks appear as you go')
                          : context.tr('{count} to do', {
                              'count': openTasks.length,
                            }),
                      state: openTasks.isEmpty
                          ? SahStepState.notStarted
                          : SahStepState.inProgress,
                      onTap: () => _selectTab(3),
                    ),
                  ],
                ),
                if (programs.isNotEmpty)
                  SahListGroup(
                    title: context.tr('Applications and documents'),
                    children: [
                      for (final program in programs)
                        SahActionTile(
                          key: ValueKey('plan-application-${program.id}'),
                          title: programOverviewName(
                            context,
                            program.id,
                            program.name,
                          ),
                          subtitle: programStatus(
                            program.latest?['status'] as String?,
                          ),
                          icon: Icons.description_outlined,
                          onTap: () => follow(
                            PlanStepTarget.program,
                            programId: program.id,
                          ),
                        ),
                    ],
                  ),
                SahListGroup(
                  title: context.tr('People with access'),
                  children: [
                    SahActionTile(
                      key: const ValueKey('plan-people-with-access'),
                      title: context.tr('People with access'),
                      subtitle: services.config.permissionSharingEnabled
                          ? context.tr(
                              'See who can open this plan, or invite someone',
                            )
                          : context.tr(
                              'Sharing isn’t available in this version.',
                            ),
                      icon: Icons.people_outline,
                      onTap:
                          programsBlocked ||
                              !services.config.permissionSharingEnabled
                          ? null
                          : () => open(
                              PeopleWithAccessScreen(services: services),
                            ),
                    ),
                  ],
                ),
              ],
            ),
          );
        },
      );
      Widget section(int tab) => switch (tab) {
        1 when c.snapshot != null && services.config.homeSafetyEnabled =>
          HomeSafetyScreen(
            key: _roomsKey,
            catalog: widget.homeSafetyCatalog,
            services: services,
            workspaceMode: true,
            embedded: true,
            initialRoomId: _roomId,
            onFindHelp: (_) => _selectTab(2),
          ),
        1 when c.snapshot != null => LiveAssessmentScreen(
          key: _legacyKey,
          services: services,
          embedded: true,
        ),
        1 => _unavailableSection(
          context,
          title: 'Rooms',
          message:
              'Sync this plan once to start. Saved rooms can then be edited offline.',
        ),
        2 => IndexedStack(
          index: _showLocalHelp ? 1 : 0,
          children: [
            c.snapshot != null
                ? LiveProgramsScreen(
                    key: _programsKey,
                    services: services,
                    workspaceMode: true,
                    embedded: true,
                    header: _helpLinks(context),
                  )
                : _unavailableSection(
                    context,
                    title: 'Help',
                    message:
                        'Sync your plan before checking assistance. Local contacts are still available.',
                    help: true,
                  ),
            _visitedLocalHelp
                ? LocalHelpScreen(
                    key: _localHelpKey,
                    services: services,
                    embedded: true,
                    header: _helpLinks(context),
                    checklist: (id) =>
                        _programsKey.currentState?.assistantMatches?.matches
                                .any((m) => m.programId == id) !=
                            true
                        ? null
                        : () {
                            setState(() => _showLocalHelp = false);
                            WidgetsBinding.instance.addPostFrameCallback(
                              (_) => _programsKey.currentState
                                  ?.openAssistantProgram(id),
                            );
                          },
                  )
                : const SizedBox.shrink(),
          ],
        ),
        3 when c.snapshot != null && services.config.trackingEnabled =>
          ProgramProgressScreen(
            key: _tasksKey,
            services: services,
            tasksFirst: true,
            workspaceMode: true,
            embedded: true,
          ),
        3 => _unavailableSection(
          context,
          title: 'Tasks',
          message: services.config.trackingEnabled
              ? 'Sync your plan before updating tasks.'
              : 'Tasks are disabled in this build. Check feature availability in Settings.',
        ),
        _ => overview,
      };
      _visited.add(_tab);
      final body = IndexedStack(
        index: _tab,
        children: [
          for (var index = 0; index < 4; index++)
            _visited.contains(index)
                ? TickerMode(
                    enabled: index == _tab,
                    child: SahTabNavigator(
                      key: _tabNavigators[index],
                      active: index == _tab,
                      onOpenScreensChanged: _openScreensChanged,
                      child: section(index),
                    ),
                  )
                : const SizedBox.shrink(),
        ],
      );
      if (widget.embedded) return body;
      return SahFloatingScaffold(
        body: body,
        selectedIndex: _tab,
        onDestinationSelected: (index) =>
            index == HomiTab.assistant.index ? _assistant() : _selectTab(index),
      );
    },
  );
}

class _CaseVersionSummary extends StatelessWidget {
  const _CaseVersionSummary({required this.title, required this.draft});
  final String title;
  final CaseDraft? draft;
  @override
  Widget build(BuildContext context) {
    final value = draft;
    if (value == null) {
      return Text(context.tr('{title}: no saved case', {'title': title}));
    }
    final names = {
      'city': context.tr('City'),
      'county': context.tr('County'),
      'healthPlan': context.tr('Health plan'),
      'tenure': context.tr('Housing'),
      'ageYears': context.tr('Age'),
      'householdSize': context.tr('Household size'),
      'annualIncomeUsd': context.tr('Annual household income (USD)'),
      'ownerConsentReported': context.tr('Owner consent reported'),
    };
    String display(String field, Object? item) => switch (item) {
      null => context.tr('Not provided'),
      true => context.tr('Yes'),
      false => context.tr('No'),
      'owner' when field == 'tenure' => context.tr('Owner'),
      'renter' when field == 'tenure' => context.tr('Renter'),
      _ => item.toString(),
    };
    String roomLabel(String value) => switch (value) {
      'bathroom' => context.tr('Bathroom'),
      'entrance' => context.tr('Entrance'),
      'other' => context.tr('Other area'),
      _ => value,
    };
    String reviewLabel(String value) => switch (value) {
      'confirmed' => context.tr('Confirmed by you'),
      'needs_review' => context.tr('Needs your review'),
      'dismissed' => context.tr('Dismissed'),
      _ => value,
    };
    String methodLabel(String value) => switch (value) {
      'manual' => context.tr('Measured'),
      'estimated' => context.tr('Your estimate'),
      _ => value,
    };
    String words(String text) => text
        .replaceAll('_', ' ')
        .replaceAllMapped(
          RegExp(r'([a-z])([A-Z])'),
          (m) => '${m[1]} ${m[2]!.toLowerCase()}',
        );
    String measurementLabel(String type) {
      final label = measurementFieldSpecFor(type)?.label;
      return label == null ? words(type) : context.tr(label);
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            for (final entry in value.profile.toJson().entries)
              Text('${names[entry.key]}: ${display(entry.key, entry.value)}'),
            const SizedBox(height: 8),
            Text(
              context.tr('{count} home findings', {
                'count': value.findings.length,
              }),
            ),
            for (final finding in value.findings)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Text(
                  '${roomLabel(finding.room)} · ${reviewLabel(finding.reviewState)}\n'
                  '${finding.observation}\n'
                  '${context.tr('{count} photos', {'count': finding.evidenceIds.length})}'
                  '${finding.measurements.isEmpty ? '' : '\n${finding.measurements.map((m) => '${measurementLabel(m.type)}: ${m.value} mm (${methodLabel(m.method)}, ${m.confirmed ? context.tr('confirmed') : context.tr('needs review')})').join('; ')}'}',
                ),
              ),
            if (value.unresolvedFields.isNotEmpty)
              Text(
                context.tr('Still to answer: {fields}', {
                  'fields': value.unresolvedFields
                      .map((field) => names[field] ?? words(field))
                      .join(', '),
                }),
              ),
          ],
        ),
      ),
    );
  }
}
