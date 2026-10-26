import '../../shared/presentation/sah_floating_nav.dart';
import 'package:flutter/material.dart';
import '../../app/live_app.dart';
import '../../l10n/app_localizations.dart';
import '../../shared/models/case_draft.dart';
import '../../shared/models/request_tracking.dart';
import '../../shared/presentation/sah_components.dart';
import '../../shared/services/matching_api_client.dart';
import 'progress_models.dart';
import 'device_reminders.dart';
import 'reminder_recovery_notice.dart';
import 'progress_service.dart';
import 'task_editor_screen.dart';
import '../local_help/referral_directory.dart';

class ProgramProgressScreen extends StatefulWidget {
  const ProgramProgressScreen({
    super.key,
    required this.services,
    this.tasksFirst = false,
    this.workspaceMode = false,
    this.embedded = false,
    this.findingId,
    this.referralId,
  });
  final AppServices services;
  final bool tasksFirst;
  final bool workspaceMode;
  final bool embedded;
  final String? findingId, referralId;
  @override
  State<ProgramProgressScreen> createState() => ProgramProgressScreenState();
}

class ProgramProgressScreenState extends State<ProgramProgressScreen> {
  late final String _caseId = widget.services.coordinator.currentCase().caseId;
  late final int _generation = widget.services.coordinator.generation;
  late bool _tasks =
      widget.tasksFirst ||
      widget.findingId != null ||
      widget.referralId != null;
  bool _busy = true, _fresh = false;
  bool get canLeave => !_busy;
  String? _assistantTaskId;
  void openAssistantTask(String id) {
    if (!current || saved?.tasks.any((t) => t.id == id) != true) return;
    setState(() {
      _tasks = true;
      _assistantTaskId = id;
    });
  }

  String? _error;
  String? _loadError, _loadFailureCode;
  final _quick = TextEditingController();
  ProgressService get service => widget.services.progress!;
  ProgressSnapshot? get saved => service.cached[_caseId];
  bool get current =>
      mounted &&
      widget.services.coordinator.isCurrent &&
      widget.services.coordinator.generation == _generation &&
      widget.services.coordinator.snapshot?.caseId == _caseId;
  bool get editable =>
      current &&
      _fresh &&
      service.feedback == null &&
      !_busy &&
      !widget.services.coordinator.hasUnsavedChanges &&
      (widget.findingId == null ||
          widget.services.coordinator.currentCase().findings.any(
            (f) => f.id == widget.findingId,
          )) &&
      saved?.caseRevision == widget.services.coordinator.snapshot?.revision &&
      !service.pending.containsKey(_caseId);
  @override
  void initState() {
    super.initState();
    service.addListener(_progressChanged);
    _load();
  }

  void _progressChanged() {
    if (!current) return;
    setState(() {
      if (service.feedback != null) _fresh = false;
      if (_fresh && saved == null) {
        _fresh = false;
        _loadFailureCode = 'CASE_NOT_FOUND';
        _loadError = MatchingApiException.forCode('CASE_NOT_FOUND').message;
      }
    });
  }

  @override
  void dispose() {
    service.removeListener(_progressChanged);
    _quick.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (!current) return;
    setState(() {
      _busy = true;
      _fresh = false;
      _error = null;
      _loadError = null;
      _loadFailureCode = null;
    });
    try {
      await widget.services.progressReady;
      if (!current) return;
      await service.refresh(_caseId);
      if (current) _fresh = true;
    } catch (e) {
      if (current) {
        _loadFailureCode = e is MatchingApiException ? e.code : null;
        _loadError = e is ReminderSettingsException
            ? e.message
            : safeOperationMessage(e);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _run(Future<void> Function() work) async {
    if (_busy || !current) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await work();
    } catch (e) {
      if (current) {
        _error = e is ReminderSettingsException
            ? e.message
            : safeOperationMessage(e);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save(Map<String, Object?> operation) async {
    await service.mutate(
      _caseId,
      widget.services.coordinator.currentCase().revision,
      operation,
    );
  }

  Future<void> _edit({
    NextStepTask? task,
    TrackedProgram? program,
    Map<String, Object?>? proposal,
  }) async {
    if (!editable) return;
    final operation = await Navigator.push<Map<String, Object?>>(
      context,
      MaterialPageRoute(
        builder: (_) => TaskEditorScreen(
          services: widget.services,
          snapshot: saved!,
          task: task,
          program: program,
          proposal: proposal,
          initialFindingId: widget.findingId,
          referralId: widget.referralId,
        ),
      ),
    );
    if (!current || operation == null) return;
    await _run(() async {
      await _save(operation);
      await widget.services.store.delete('progress-edit.$_caseId');
    });
  }

  Future<void> _history(TrackedProgram program) async {
    if (!editable) return;
    await _run(() async {
      final reports = <Map<String, Object?>>[];
      int offset = 0;
      do {
        final page = await service.api.history(
          _caseId,
          program.id,
          isCurrent: () => current,
          revision: saved!.revision,
          caseRevision: saved!.caseRevision,
          historyVersion: saved!.pages.first.historyVersion,
          offset: offset,
        );
        reports.addAll(
          (page['reports'] as List).map(
            (r) => Map<String, Object?>.from(r as Map),
          ),
        );
        if (page['nextOffset'] == null) break;
        offset = page['nextOffset'] as int;
      } while (offset <= 1000);
      if (!mounted || !current) return;
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          scrollable: true,
          title: Text(program.name),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                ctx.tr(
                  'Manual reports do not verify submission, eligibility, approval, or completed repairs.',
                ),
              ),
              if (reports.isEmpty)
                Text(ctx.tr('Not started / no update recorded')),
              for (final r in reports)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(
                    ctx.tr(requestStatusLabel(r['status'] as String)),
                  ),
                  subtitle: Text(
                    [
                      r['occurredOn'],
                      ctx.tr('Reported by: {person}', {
                        'person':
                            r['recordedBy'] ??
                            ctx.tr('Legacy report; reporter not recorded'),
                      }),
                      r['recordedAt'],
                      ctx.tr(requestSourceLabel(r['source'] as String)),
                      r['note'],
                      r['nextAction'],
                    ].whereType<String>().join('\n'),
                  ),
                ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(ctx.tr('Close')),
            ),
          ],
        ),
      );
    });
  }

  Future<void> _report(TrackedProgram program) async {
    final note = TextEditingController();
    String status = 'preparing', source = 'self_report';
    final today = DateTime.now().toUtc().toIso8601String().substring(0, 10);
    String occurredOn = today;
    try {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => StatefulBuilder(
          builder: (ctx, change) => AlertDialog(
            scrollable: true,
            title: Text(ctx.tr('Report program status')),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  ctx.tr(
                    'Manual reports do not verify submission, eligibility, approval, or completed repairs.',
                  ),
                ),
                DropdownButtonFormField<String>(
                  initialValue: status,
                  isExpanded: true,
                  decoration: InputDecoration(labelText: ctx.tr('Status')),
                  items: [
                    for (final s in [
                      'preparing',
                      'submitted',
                      'received',
                      'needs_information',
                      'approved',
                      'denied',
                      'withdrawn',
                    ])
                      DropdownMenuItem(
                        value: s,
                        child: Text(ctx.tr(requestStatusLabel(s))),
                      ),
                  ],
                  onChanged: (v) => change(() => status = v!),
                ),
                DropdownButtonFormField<String>(
                  initialValue: source,
                  isExpanded: true,
                  decoration: InputDecoration(labelText: ctx.tr('Source')),
                  items: [
                    for (final s in [
                      'self_report',
                      'program_contact',
                      'document',
                    ])
                      DropdownMenuItem(
                        value: s,
                        child: Text(ctx.tr(requestSourceLabel(s))),
                      ),
                  ],
                  onChanged: (v) => change(() => source = v!),
                ),
                ListTile(
                  key: const ValueKey('report-date'),
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.event_outlined),
                  title: Text(ctx.tr('When did this happen?')),
                  subtitle: Text(localDay(ctx, occurredOn)),
                  onTap: () async {
                    final picked = await pickIsoDay(
                      ctx,
                      initial: occurredOn,
                      last: DateTime.parse(today),
                    );
                    if (picked != null) change(() => occurredOn = picked);
                  },
                ),
                TextField(
                  controller: note,
                  maxLength: 500,
                  decoration: InputDecoration(
                    labelText: ctx.tr('Note (optional)'),
                  ),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text(ctx.tr('Cancel')),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: Text(ctx.tr('Save')),
              ),
            ],
          ),
        ),
      );
      if (!current || confirmed != true) return;
      final update = RequestUpdate(
        updateId: newUuidV4(),
        status: status,
        occurredOn: occurredOn,
        source: source,
        note: note.text.trim().isEmpty ? null : note.text.trim(),
      );
      await _run(
        () => _save({
          'type': 'report_status',
          'programId': program.id,
          'update': update.toJson(),
        }),
      );
    } finally {
      note.dispose();
    }
  }

  String? get _contextFinding =>
      widget.findingId != null &&
          widget.services.coordinator.currentCase().findings.any(
            (f) => f.id == widget.findingId,
          )
      ? widget.findingId
      : null;

  String? _organization(String? id) =>
      id == null ? null : const OfficialReferralDirectory().provider(id)?.name;

  Future<bool> _add(String title, {String? programId, String? kind}) async {
    final text = String.fromCharCodes(title.trim().runes.take(200)).trim();
    if (!editable || text.isEmpty) return false;
    final referral = widget.referralId;
    await _run(
      () => _save(
        putTaskOperation(
          snapshot: saved!,
          id: newUuidV4(),
          title: text,
          kind:
              kind ??
              (referral != null
                  ? 'follow_up'
                  : _contextFinding != null
                  ? 'room_review'
                  : 'other'),
          programId: programId,
          findingId: _contextFinding,
          referralId: referral,
        ),
      ),
    );
    return _error == null;
  }

  Future<void> _quickAdd() async {
    if (await _add(_quick.text) && mounted) _quick.clear();
  }

  Future<void> _toggle(NextStepTask task) => _run(
    () => _save({
      'type': 'put_task',
      'expectedTaskRevision': task.revision,
      'task': {
        ...task.toJson(),
        'state': task.open ? 'completed' : 'pending',
        'revision': task.revision + 1,
      },
    }),
  );

  List<_Suggestion> _suggestions(BuildContext context, ProgressSnapshot state) {
    final titles = state.tasks.map((t) => t.title).toSet();
    final out = <_Suggestion>[];
    final organization = _organization(widget.referralId);
    if (organization != null &&
        !state.tasks.any((t) => t.open && t.referralId == widget.referralId)) {
      final title = context.tr('Contact {organization}', {
        'organization': organization,
      });
      if (!titles.contains(title)) {
        out.add(
          _Suggestion(
            title: title,
            why: context.tr('From a help contact you saved'),
            add: () => _add(title, kind: 'contact'),
          ),
        );
      }
    }
    if (widget.findingId == null && widget.referralId == null) {
      for (final p in state.programs.where((p) => !p.retired)) {
        if (p.proposal != null) {
          out.add(
            _Suggestion(
              title: p.proposal!['title'] as String,
              why: context.tr(
                'Suggested from an earlier update for {program}',
                {'program': p.name},
              ),
              add: () => _edit(program: p, proposal: p.proposal),
              dismiss: () => _run(
                () => _save({
                  'type': 'dismiss_proposal',
                  'eventId': p.proposal!['eventId'],
                }),
              ),
            ),
          );
        } else if (p.unresolved > 0 &&
            !state.tasks.any((t) => t.open && t.programId == p.id)) {
          final title = context.tr('Confirm what {program} still needs', {
            'program': p.name,
          });
          if (titles.contains(title)) continue;
          out.add(
            _Suggestion(
              title: title,
              why: context.tr('Unresolved program requirements: {count}', {
                'count': p.unresolved,
              }),
              add: () => _add(title, programId: p.id, kind: 'documents'),
            ),
          );
        }
      }
    }
    return out.take(3).toList();
  }

  Widget _taskRow(
    BuildContext context,
    ProgressSnapshot? state,
    NextStepTask task,
    String today,
  ) {
    final reminder =
        task.open &&
        service.reminders.forTask(_caseId, task.id)?.enabled == true;
    final program = task.programId == null
        ? null
        : state?.programs.where((p) => p.id == task.programId).firstOrNull;
    final details = [
      if (task.dueOn != null)
        context.tr(
          task.open && task.dueOn!.compareTo(today) < 0
              ? 'Overdue target: {date}'
              : 'Target date: {date}',
          {'date': localDay(context, task.dueOn!)},
        ),
      if (task.state != 'pending' && task.state != 'completed')
        context.tr(taskStateLabel(task.state)),
      if (reminder) context.tr('Reminder on this phone'),
      if (task.responsiblePerson != null)
        context.tr('For: {person}', {'person': task.responsiblePerson}),
      ?program?.name,
      if (_organization(task.referralId) case final organization?)
        context.tr('Referral: {organization}', {'organization': organization}),
    ];
    final canToggle = editable && !task.needsReview;
    return ListTile(
      key: ValueKey('task-${task.id}'),
      contentPadding: const EdgeInsetsDirectional.only(start: 4, end: 12),
      leading: Checkbox(
        key: ValueKey('task-done-${task.id}'),
        value: !task.open,
        semanticLabel: context.tr(
          task.open ? 'Mark done: {task}' : 'Mark not done: {task}',
          {'task': task.title},
        ),
        onChanged: canToggle ? (_) => _toggle(task) : null,
      ),
      title: Text(
        task.title,
        style: task.open
            ? null
            : const TextStyle(decoration: TextDecoration.lineThrough),
      ),
      subtitle: details.isEmpty && !task.needsReview
          ? null
          : Text(
              [
                ...details,
                if (task.needsReview)
                  context.tr('Plan changed. Review this task.'),
              ].join(' · '),
            ),
      trailing: const Icon(Icons.chevron_right),
      onTap: editable ? () => _edit(task: task) : null,
    );
  }

  List<Widget> _taskSection(
    BuildContext context,
    ProgressSnapshot? state,
    List<NextStepTask> tasks,
    String today,
  ) {
    final open = tasks.where((t) => t.open).toList(),
        done = tasks.where((t) => !t.open).toList();
    final suggestions = state == null || !_fresh || !editable
        ? const <_Suggestion>[]
        : _suggestions(context, state);
    return [
      if (_assistantTaskId != null)
        TextButton(
          onPressed: () => setState(() => _assistantTaskId = null),
          child: Text(context.tr('All tasks')),
        ),
      const SizedBox(height: 8),
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: TextField(
              key: const ValueKey('task-quick-add'),
              controller: _quick,
              enabled: editable,
              maxLength: 200,
              textInputAction: TextInputAction.done,
              decoration: InputDecoration(
                hintText: context.tr('Add a task…'),
                labelText: context.tr('Add a task…'),
                floatingLabelBehavior: FloatingLabelBehavior.never,
                counterText: '',
              ),
              onSubmitted: (_) => _quickAdd(),
            ),
          ),
          const SizedBox(width: 8),
          FilledButton(
            key: const ValueKey('task-quick-add-button'),
            onPressed: editable ? _quickAdd : null,
            child: Text(context.tr('Add')),
          ),
        ],
      ),
      Align(
        alignment: AlignmentDirectional.centerStart,
        child: TextButton(
          onPressed: editable ? () => _edit() : null,
          child: Text(context.tr('Add with details')),
        ),
      ),
      if (suggestions.isNotEmpty)
        SahListGroup(
          title: context.tr('Suggested for you'),
          children: [
            for (final s in suggestions)
              ListTile(
                leading: const Icon(Icons.lightbulb_outline),
                title: Text(s.title),
                subtitle: Text(s.why),
                trailing: Wrap(
                  children: [
                    if (s.dismiss != null)
                      IconButton(
                        tooltip: context.tr('No longer needed'),
                        onPressed: editable ? s.dismiss : null,
                        icon: const Icon(Icons.close),
                      ),
                    TextButton(
                      onPressed: editable ? s.add : null,
                      child: Text(context.tr('Add')),
                    ),
                  ],
                ),
              ),
          ],
        ),
      if (_fresh && state != null && tasks.isEmpty)
        SahEmptyState(
          icon: Icons.checklist_rounded,
          title: context.tr('Nothing to do yet'),
          message: context.tr(
            'Suggestions appear here from programs you track and help contacts you save. You can also add your own task above.',
          ),
        ),
      if (open.isNotEmpty)
        SahListGroup(
          title: context.tr('To do'),
          children: [
            for (final task in open) _taskRow(context, state, task, today),
          ],
        ),
      if (done.isNotEmpty)
        ExpansionTile(
          key: const ValueKey('tasks-done'),
          tilePadding: const EdgeInsets.symmetric(horizontal: 4),
          title: Text(context.tr('Done ({count})', {'count': done.length})),
          children: [
            SahListGroup(
              children: [
                for (final task in done) _taskRow(context, state, task, today),
              ],
            ),
          ],
        ),
      if (widget.workspaceMode && (state?.programs.isNotEmpty ?? false))
        SahListGroup(
          title: context.tr('Tracked programs'),
          children: [
            for (final p in state!.programs)
              ListTile(
                leading: const Icon(Icons.assignment_outlined),
                title: Text(p.name),
                subtitle: Text(
                  [
                    context.tr(
                      p.latest == null
                          ? 'Not started / no update recorded'
                          : requestStatusLabel(p.latest!['status'] as String),
                    ),
                    if (p.unresolved > 0)
                      context.tr('Unresolved program requirements: {count}', {
                        'count': p.unresolved,
                      }),
                  ].join(' · '),
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) =>
                        ProgramProgressScreen(services: widget.services),
                  ),
                ),
              ),
          ],
        ),
      const SizedBox(height: 16),
      ExpansionTile(
        title: Text(context.tr('About tasks and reminders')),
        children: [
          for (final text in [
            'Manual reports do not verify submission, eligibility, approval, or completed repairs.',
            'Due dates are personal targets. They are not verified agency deadlines. A responsible person label does not share this plan or assign a signed-in helper.',
            'Reminders are local to this device. Open the app to sync remote changes. Device settings may delay or prevent delivery.',
          ])
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(context.tr(text)),
            ),
        ],
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    if (!current) {
      final stale = Center(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Text(
            context.tr(
              'The plan changed. Reopen it before editing next steps.',
            ),
          ),
        ),
      );
      if (widget.embedded) return stale;
      return Scaffold(
        appBar: AppBar(title: Text(context.tr('Tasks'))),
        body: SafeArea(child: stale),
      );
    }
    final state = saved;
    final tasks =
        state?.tasks
            .where(
              (t) =>
                  (_assistantTaskId == null || t.id == _assistantTaskId) &&
                  (widget.findingId == null ||
                      t.data['findingId'] == widget.findingId) &&
                  (widget.referralId == null ||
                      t.referralId == widget.referralId),
            )
            .toList() ??
        <NextStepTask>[];
    tasks.sort((a, b) {
      final open = (a.open ? 0 : 1).compareTo(b.open ? 0 : 1);
      return open != 0
          ? open
          : (a.dueOn ?? '9999').compareTo(b.dueOn ?? '9999');
    });
    final today = DateTime.now().toIso8601String().substring(0, 10);
    final appBar = AppBar(
      title: Text(
        context.tr(
          widget.workspaceMode
              ? 'Tasks'
              : _tasks
              ? 'My next steps'
              : 'Program progress',
        ),
      ),
      actions: [
        IconButton(
          onPressed: _busy ? null : _load,
          icon: const Icon(Icons.refresh),
          tooltip: context.tr('Refresh'),
        ),
      ],
    );
    final body = SahContent(
      child: ListView(
        padding: sahFloatingContentPadding(context),
        children: [
          if (widget.embedded && widget.workspaceMode)
            SahPageHeader(title: context.tr('Tasks')),
          if (widget.embedded)
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: TextButton.icon(
                onPressed: _busy ? null : _load,
                icon: const Icon(Icons.refresh),
                label: Text(context.tr('Refresh')),
              ),
            ),
          if (!widget.workspaceMode)
            Text(
              context.tr(
                'Manual reports do not verify submission, eligibility, approval, or completed repairs.',
              ),
            ),
          const SizedBox(height: 12),
          if (widget.findingId != null) ...[
            Text(context.tr('Next steps for this concern')),
            Text(
              widget.services.coordinator
                      .currentCase()
                      .findings
                      .where((f) => f.id == widget.findingId)
                      .firstOrNull
                      ?.observation ??
                  context.tr('Concern not present'),
            ),
          ],
          if (widget.referralId != null)
            Text(
              context.tr('Next steps for {organization}', {
                'organization':
                    const OfficialReferralDirectory()
                        .provider(widget.referralId!)
                        ?.name ??
                    widget.referralId!,
              }),
            ),
          if (!widget.workspaceMode &&
              widget.findingId == null &&
              widget.referralId == null)
            SegmentedButton<bool>(
              segments: [
                ButtonSegment(
                  value: false,
                  label: Text(context.tr('Programs')),
                ),
                ButtonSegment(value: true, label: Text(context.tr('Tasks'))),
              ],
              selected: {_tasks},
              onSelectionChanged: (s) => setState(() => _tasks = s.first),
            ),
          if (_busy) ...[
            LinearProgressIndicator(
              semanticsLabel: context.tr('Loading tasks and program progress'),
            ),
            if (state == null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(context.tr('Loading tasks and program progress')),
              ),
          ],
          if (_loadError != null) ...[
            SahActionFeedback(
              key: const ValueKey('progress-load-feedback'),
              message: context.tr(switch (_loadFailureCode) {
                'NOT_FOUND' =>
                  'Tasks are unavailable on this service. Try again after the service is updated.',
                'SERVICE_UNAVAILABLE' =>
                  'Tasks are temporarily unavailable. Try again later.',
                'NETWORK_ERROR' || 'TIMEOUT' =>
                  state == null
                      ? 'Cannot connect to load tasks. Check your connection and try again.'
                      : 'Cannot connect. Showing the last saved tasks; refresh before making changes.',
                _ => _loadError!,
              }),
            ),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton.icon(
                key: const ValueKey('progress-retry-load'),
                onPressed: _busy ? null : _load,
                icon: const Icon(Icons.refresh),
                label: Text(context.tr('Try again')),
              ),
            ),
          ],
          if (_error != null) SahActionFeedback(message: context.tr(_error!)),
          if (!_fresh && state != null && _loadError == null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                context.tr('Saved copy. Refresh before changing tasks.'),
              ),
            ),
          if (state != null &&
              state.caseRevision !=
                  widget.services.coordinator.snapshot?.revision)
            SahNotice(
              message: context.tr(
                'The plan changed. Reopen it before editing next steps.',
              ),
            ),
          if (service.feedback != null)
            SahNotice(message: context.tr(service.feedback!)),
          if (service.reminders.feedback != null)
            SahNotice(message: context.tr(service.reminders.feedback!)),
          if (service.reminders.requiresReset)
            ReminderRecoveryNotice(
              enabled: current && !_busy,
              onReset: () => _run(() async {
                await service.reminders.reset();
                if (current) await service.reconcileReminders();
              }),
            ),
          if (service.pending.containsKey(_caseId))
            _ProgressCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    context.tr(
                      'A save is pending. Retry the same change or refresh and review saved state before discarding it.',
                    ),
                  ),
                  TextButton(
                    onPressed: _busy
                        ? null
                        : () => _run(() async {
                            await service.retry(_caseId);
                            _fresh = true;
                          }),
                    child: Text(context.tr('Retry pending save')),
                  ),
                  TextButton(
                    onPressed: _busy
                        ? null
                        : () async {
                            final yes = await showDialog<bool>(
                              context: context,
                              builder: (ctx) => AlertDialog(
                                title: Text(ctx.tr('Discard pending change?')),
                                content: Text(
                                  ctx.tr(
                                    'Review saved state first. Discarding this attempt does not undo a change already saved online.',
                                  ),
                                ),
                                actions: [
                                  TextButton(
                                    onPressed: () => Navigator.pop(ctx, false),
                                    child: Text(ctx.tr('Cancel')),
                                  ),
                                  FilledButton(
                                    onPressed: () => Navigator.pop(ctx, true),
                                    child: Text(ctx.tr('Discard')),
                                  ),
                                ],
                              ),
                            );
                            if (yes == true && current) {
                              await _run(() => service.discard(_caseId));
                            }
                          },
                    child: Text(context.tr('Review and discard pending save')),
                  ),
                ],
              ),
            ),
          if (_tasks)
            ..._taskSection(context, state, tasks, today)
          else ...[
            if (_fresh && state != null && state.programs.isEmpty)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  context.tr(
                    'No tracked programs. Choose Track program under possible assistance.',
                  ),
                ),
              ),
            for (final p in state?.programs ?? <TrackedProgram>[])
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: _ProgressCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        p.name,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      if (p.retired)
                        Text(
                          context.tr(
                            'No longer in the current program registry. History is retained.',
                          ),
                        ),
                      Text(
                        context.tr(
                          p.latest == null
                              ? 'Not started / no update recorded'
                              : requestStatusLabel(
                                  p.latest!['status'] as String,
                                ),
                        ),
                      ),
                      if (p.latest != null)
                        Text(
                          context.tr('Reported {date} by {person}', {
                            'date': p.latest!['recordedAt'],
                            'person':
                                p.latest!['recordedBy'] ??
                                context.tr(
                                  'Legacy report; reporter not recorded',
                                ),
                          }),
                        ),
                      Text(
                        context.tr('Unresolved program requirements: {count}', {
                          'count': p.unresolved,
                        }),
                      ),
                      Text(
                        context.tr('Open tasks: {count}', {
                          'count': tasks
                              .where((t) => t.programId == p.id && t.open)
                              .length,
                        }),
                      ),
                      if (tasks
                              .where((t) => t.programId == p.id && t.open)
                              .firstOrNull
                          case final next?)
                        Text(
                          context.tr('Next: {task} · {date}', {
                            'task': next.title,
                            'date': next.dueOn ?? context.tr('No target date'),
                          }),
                        ),
                      if (p.requirements != null) ...[
                        for (final requirement in p.requirements!)
                          Text(
                            '${context.tr(requirement['status'] == 'fail' ? 'Not met' : 'Needs confirmation')}: ${requirement['explanation']}',
                          ),
                      ],
                      Wrap(
                        spacing: 8,
                        children: [
                          TextButton(
                            onPressed: editable
                                ? () => _edit(program: p)
                                : null,
                            child: Text(context.tr('Add next step')),
                          ),
                          TextButton(
                            onPressed: editable ? () => _report(p) : null,
                            child: Text(context.tr('Report program status')),
                          ),
                          TextButton(
                            onPressed: editable ? () => _history(p) : null,
                            child: Text(context.tr('Manual request history')),
                          ),
                        ],
                      ),
                      if (p.proposal != null) ...[
                        Text(
                          context.tr('Is this old next action still needed?'),
                        ),
                        Text(p.proposal!['title'] as String),
                        Wrap(
                          spacing: 8,
                          children: [
                            TextButton(
                              onPressed: editable
                                  ? () =>
                                        _edit(program: p, proposal: p.proposal)
                                  : null,
                              child: Text(context.tr('Review and add task')),
                            ),
                            TextButton(
                              onPressed: editable
                                  ? () => _run(
                                      () => _save({
                                        'type': 'dismiss_proposal',
                                        'eventId': p.proposal!['eventId'],
                                      }),
                                    )
                                  : null,
                              child: Text(context.tr('No longer needed')),
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
              ),
          ],
        ],
      ),
    );
    if (widget.embedded) return body;
    return Scaffold(
      appBar: appBar,
      body: SafeArea(child: body),
    );
  }
}

String taskStateLabel(String state) => switch (state) {
  'pending' => 'Pending',
  'in_progress' => 'In progress',
  'blocked' => 'Blocked',
  'completed' => 'Completed',
  _ => 'Cancelled',
};
String taskKindLabel(String kind) => switch (kind) {
  'profile' => 'Profile completion',
  'room_review' => 'Room review',
  'documents' => 'Documents',
  'contact' => 'Contact a provider',
  'draft_review' => 'Draft review',
  'follow_up' => 'Follow up',
  _ => 'Other',
};

String requestStatusLabel(String value) => switch (value) {
  'preparing' => 'Preparing',
  'submitted' => 'Submitted',
  'received' => 'Received',
  'needs_information' => 'Needs info',
  'approved' => 'Approved',
  'denied' => 'Denied',
  _ => 'Withdrawn',
};
String requestSourceLabel(String value) => switch (value) {
  'self_report' => 'Self report',
  'program_contact' => 'Program contact',
  _ => 'Document',
};

class _ProgressCard extends StatelessWidget {
  const _ProgressCard({required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => Card(
    child: Padding(padding: const EdgeInsets.all(16), child: child),
  );
}

class _Suggestion {
  const _Suggestion({
    required this.title,
    required this.why,
    required this.add,
    this.dismiss,
  });
  final String title, why;
  final VoidCallback add;
  final VoidCallback? dismiss;
}
