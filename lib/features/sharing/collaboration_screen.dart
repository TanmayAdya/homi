part of 'sharing_screens.dart';

class CollaborationScreen extends StatefulWidget {
  const CollaborationScreen({
    super.key,
    required this.services,
    required this.membership,
    required this.ownerView,
  });
  final AppServices services;
  final CaseMembership membership;
  final bool ownerView;
  @override
  State<CollaborationScreen> createState() => _CollaborationState();
}

class _CollaborationState extends _OnlineState<CollaborationScreen> {
  @override
  AppServices get services => widget.services;
  late CaseMembership _grant;
  CollaborationState? work;
  final selected = <String>{}, assigned = <String>{};
  bool taskProgress = false,
      statusProposals = false,
      dirty = false,
      preview = false,
      uncertain = false;
  String? programId;
  String proposedStatus = 'preparing';
  final occurred = TextEditingController(
    text: DateTime.now().toIso8601String().substring(0, 10),
  );
  final proposalNote = TextEditingController();
  String? _pendingRoute;
  Map<String, Object?>? _pending;
  Timer? _timer;
  @override
  void initState() {
    super.initState();
    _grant = widget.membership;
    unawaited(reload());
    _timer = Timer.periodic(const Duration(seconds: 20), (_) {
      if (current && !dirty && !uncertain) unawaited(reload());
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    occurred.dispose();
    proposalNote.dispose();
    super.dispose();
  }

  @override
  void clearContent() {
    work = null;
    selected.clear();
    assigned.clear();
    _pending = null;
    _pendingRoute = null;
    uncertain = false;
    preview = false;
    dirty = false;
    proposalNote.clear();
  }

  @override
  Future<void> reload() => run((valid) async {
    setState(() => work = null);
    final metadata = await call(
      widget.ownerView ? 'list-sharing' : 'list-shared-cases',
      widget.ownerView ? {'caseId': widget.membership.caseId} : {},
      valid,
    );
    if (!valid()) return;
    _grant =
        (widget.ownerView
                ? metadata.shares.map((s) => s.membership)
                : metadata.memberships)
            .firstWhere((m) => m.id == widget.membership.id);
    final response = await call('read-collaboration', {
      'membershipId': _grant.id,
      'expectedPermissionRevision': _grant.revision,
    }, valid);
    if (valid()) setState(() => _acceptResponse(response.collaboration!));
  });
  void _acceptResponse(CollaborationState value) {
    work = value;
    selected
      ..clear()
      ..addAll(value.scope.taskIds);
    assigned
      ..clear()
      ..addAll(
        value.tasks
            .where(
              (t) =>
                  t.assigneeUserId == _grant.recipientId &&
                  selected.contains(t.id),
            )
            .map((t) => t.id),
      );
    taskProgress = value.scope.allowTaskProgress;
    statusProposals = value.scope.allowStatusProposals;
    programId = _grant.scope.programIds.contains(programId)
        ? programId
        : (_grant.scope.programIds.firstOrNull);
    dirty = false;
    preview = false;
    uncertain = false;
    _pending = null;
    _pendingRoute = null;
  }

  String _person(BuildContext context, String id) {
    if (id == (widget.ownerView ? _grant.grantorId : _grant.recipientId)) {
      return context.tr('You');
    }
    if (id == _grant.recipientId) {
      return _grant.recipientLabel ?? context.tr('The person you shared with');
    }
    if (id == _grant.grantorId) {
      return _grant.ownerLabel ?? context.tr('The plan owner');
    }
    return context.tr('Someone else');
  }

  Map<String, Object?> _writeBinding() => {
    'membershipId': _grant.id,
    'expectedPermissionRevision': work!.permissionRevision,
    'expectedCaseRevision': work!.caseRevision,
    'expectedCollaborationRevision': work!.revision,
    'mutationId': newUuidV4(),
  };
  Future<void> _write(String route, Map<String, Object?> fields) =>
      run((valid) async {
        _pendingRoute = route;
        _pending = fields;
        await _sendPending(valid);
      });
  Future<void> _sendPending(bool Function() valid) async {
    try {
      final response = await call(_pendingRoute!, _pending!, valid);
      if (valid()) {
        setState(() {
          _acceptResponse(response.collaboration!);
          proposalNote.clear();
        });
      }
    } on MatchingApiException catch (error) {
      if (error.code == 'SHARING_SAVE_UNCERTAIN' && valid()) {
        setState(() {
          uncertain = true;
          work = null;
        });
        return;
      }
      rethrow;
    }
  }

  Future<void> _retry() => run(_sendPending);
  bool eligible(SharedTask task) =>
      (task.programId == null ||
          _grant.scope.programIds.contains(task.programId)) &&
      (task.findingId == null ||
          _grant.scope.findingIds.contains(task.findingId));
  void change(void Function() action) => setState(() {
    action();
    dirty = true;
    preview = false;
  });
  Future<void> _configure() async {
    final state = work!;
    await _write('configure-collaboration', {
      ..._writeBinding(),
      'expectedProgressRevision': state.progressRevision,
      'collaborationScope': CollaborationScope(
        taskIds: selected.toList(),
        allowTaskProgress: taskProgress,
        allowStatusProposals: statusProposals,
      ).toJson(),
      'assignedTaskIds': assigned.where(selected.contains).toList(),
    });
  }

  Future<void> _taskState(SharedTask task, String state) =>
      _write('update-shared-task', {
        ..._writeBinding(),
        'taskId': task.id,
        'expectedTaskRevision': task.revision,
        'state': state,
      });
  Future<void> _propose() async {
    if (programId == null) return;
    try {
      final update = RequestUpdate(
        updateId: newUuidV4(),
        status: proposedStatus,
        occurredOn: occurred.text.trim(),
        source: 'self_report',
        note: proposalNote.text.trim().isEmpty
            ? null
            : proposalNote.text.trim(),
      );
      await _write('propose-shared-status', {
        ..._writeBinding(),
        'programId': programId,
        'update': update.toJson(),
      });
    } catch (_) {
      if (current) {
        setState(
          () => error = 'Review the date and note before proposing a status.',
        );
      }
    }
  }

  Future<void> _review(SharedStatusProposal proposal, String decision) =>
      _write('review-shared-status', {
        ..._writeBinding(),
        'expectedProgressRevision': work!.progressRevision,
        'proposalId': proposal.id,
        'decision': decision,
      });
  @override
  Widget build(BuildContext context) {
    final value = work, helper = _grant.role == 'helper';
    return Scaffold(
      appBar: AppBar(
        title: Text(context.tr('Shared tasks and proposals')),
        actions: [
          IconButton(
            tooltip: context.tr('Refresh access'),
            onPressed: busy || uncertain ? null : reload,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            ...status(),
            Text(
              context.tr(
                'A helper can update only selected tasks assigned to their signed-in account. Status proposals need owner review.',
              ),
            ),
            if (uncertain) ...[
              Text(
                context.tr(
                  'This save could not be confirmed. Retry the same change to avoid duplicates.',
                ),
              ),
              FilledButton(
                onPressed: busy ? null : _retry,
                child: Text(context.tr('Retry same change')),
              ),
              TextButton(
                onPressed: busy
                    ? null
                    : () {
                        setState(clearContent);
                        unawaited(reload());
                      },
                child: Text(context.tr('Reload saved sharing')),
              ),
            ],
            if (value != null) ...[
              if (value.canManage) ...[
                Text(
                  context.tr('Select tasks for this person'),
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                for (final task in value.tasks.where(eligible))
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      CheckboxListTile(
                        value: selected.contains(task.id),
                        title: Text(task.title),
                        subtitle: Text(context.tr(task.state)),
                        onChanged: busy
                            ? null
                            : (v) => change(() {
                                v!
                                    ? selected.add(task.id)
                                    : selected.remove(task.id);
                                if (v != true) assigned.remove(task.id);
                              }),
                      ),
                      if (helper && taskProgress && selected.contains(task.id))
                        CheckboxListTile(
                          value: assigned.contains(task.id),
                          title: Text(
                            context.tr('Assign to this signed-in helper'),
                          ),
                          onChanged: busy
                              ? null
                              : (v) => change(() {
                                  v!
                                      ? assigned.add(task.id)
                                      : assigned.remove(task.id);
                                }),
                        ),
                    ],
                  ),
                if (helper) ...[
                  CheckboxListTile(
                    value: taskProgress,
                    title: Text(context.tr('Allow assigned task progress')),
                    onChanged: busy
                        ? null
                        : (v) => change(() {
                            taskProgress = v!;
                            if (!taskProgress) assigned.clear();
                          }),
                  ),
                  CheckboxListTile(
                    value: statusProposals,
                    title: Text(
                      context.tr(
                        'Allow status proposals for selected programs',
                      ),
                    ),
                    onChanged: busy
                        ? null
                        : (v) => change(() => statusProposals = v!),
                  ),
                ],
                OutlinedButton(
                  onPressed: busy ? null : () => setState(() => preview = true),
                  child: Text(context.tr('Preview task access')),
                ),
                if (preview) ...[
                  Text(
                    context.tr(
                      'This person will see only the selected task details below.',
                    ),
                  ),
                  for (final task in value.tasks.where(
                    (t) => selected.contains(t.id),
                  ))
                    SharedTaskDetails(
                      task: task,
                      assignee: task.assigneeUserId == null
                          ? null
                          : _person(context, task.assigneeUserId!),
                    ),
                  FilledButton(
                    onPressed: busy ? null : _configure,
                    child: Text(context.tr('Save task access')),
                  ),
                ],
              ] else ...[
                for (final task in value.tasks) ...[
                  SharedTaskDetails(
                    task: task,
                    assignee: task.assigneeUserId == null
                        ? null
                        : _person(context, task.assigneeUserId!),
                  ),
                  if (helper &&
                      value.scope.allowTaskProgress &&
                      task.assigneeUserId == services.store.accountId &&
                      !task.needsReview)
                    DropdownButtonFormField<String>(
                      key: ValueKey('shared-task-${task.id}-${task.revision}'),
                      initialValue: task.state,
                      decoration: InputDecoration(
                        labelText: context.tr('Task progress'),
                      ),
                      items: [
                        for (final state in sharedTaskStates)
                          DropdownMenuItem(
                            value: state,
                            child: Text(context.tr(state)),
                          ),
                      ],
                      onChanged: busy
                          ? null
                          : (state) {
                              if (state != null && state != task.state) {
                                unawaited(_taskState(task, state));
                              }
                            },
                    ),
                ],
                if (helper &&
                    value.scope.allowStatusProposals &&
                    _grant.scope.programIds.isNotEmpty) ...[
                  Text(
                    context.tr('Propose a reported program status'),
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  DropdownButtonFormField<String>(
                    key: ValueKey('proposal-program-$programId'),
                    initialValue: programId,
                    decoration: InputDecoration(
                      labelText: context.tr('Program'),
                    ),
                    items: [
                      for (final id in _grant.scope.programIds)
                        DropdownMenuItem(
                          value: id,
                          child: Text(id, overflow: TextOverflow.ellipsis),
                        ),
                    ],
                    onChanged: busy
                        ? null
                        : (id) => setState(() => programId = id),
                  ),
                  DropdownButtonFormField<String>(
                    initialValue: proposedStatus,
                    decoration: InputDecoration(
                      labelText: context.tr('Proposed status'),
                    ),
                    items: [
                      for (final state in [
                        'preparing',
                        'submitted',
                        'received',
                        'needs_information',
                        'approved',
                        'denied',
                        'withdrawn',
                      ])
                        DropdownMenuItem(
                          value: state,
                          child: Text(context.tr(state)),
                        ),
                    ],
                    onChanged: busy
                        ? null
                        : (s) => setState(() => proposedStatus = s!),
                  ),
                  TextField(
                    controller: occurred,
                    enabled: !busy,
                    decoration: InputDecoration(
                      labelText: context.tr('Reported date (YYYY-MM-DD)'),
                    ),
                  ),
                  TextField(
                    controller: proposalNote,
                    enabled: !busy,
                    maxLength: 500,
                    decoration: InputDecoration(
                      labelText: context.tr('Optional proposal note'),
                    ),
                  ),
                  FilledButton(
                    onPressed: busy ? null : _propose,
                    child: Text(context.tr('Send for owner review')),
                  ),
                ],
              ],
              const SizedBox(height: 16),
              Text(
                context.tr('Status proposal history'),
                style: Theme.of(context).textTheme.titleLarge,
              ),
              for (final proposal in value.proposals)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _programNames(context, services, _grant.caseId, [
                            proposal.programId,
                          ])[proposal.programId]!,
                        ),
                        Text(context.tr(proposal.update.status)),
                        Text(context.tr(proposal.state)),
                        Text(
                          context.tr('Proposed by {name} on {date}', {
                            'name': _person(context, proposal.proposedBy),
                            'date': _day(context, proposal.proposedAt),
                          }),
                        ),
                        if (proposal.update.note != null)
                          Text(proposal.update.note!),
                        if (proposal.reviewedBy != null)
                          Text(
                            context.tr('Reviewed by {name} on {date}', {
                              'name': _person(context, proposal.reviewedBy!),
                              'date': _day(context, proposal.reviewedAt!),
                            }),
                          ),
                        if (value.canManage && proposal.state == 'pending')
                          Wrap(
                            spacing: 8,
                            children: [
                              FilledButton(
                                onPressed: busy
                                    ? null
                                    : () => _review(proposal, 'accepted'),
                                child: Text(
                                  context.tr('Accept reported status'),
                                ),
                              ),
                              OutlinedButton(
                                onPressed: busy
                                    ? null
                                    : () => _review(proposal, 'rejected'),
                                child: Text(context.tr('Reject proposal')),
                              ),
                            ],
                          ),
                      ],
                    ),
                  ),
                ),
              Text(
                context.tr(
                  'Completing a task does not report a repair, a safe home, agency receipt, or approval.',
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class SharedTaskDetails extends StatelessWidget {
  const SharedTaskDetails({super.key, required this.task, this.assignee});
  final SharedTask task;

  final String? assignee;
  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(task.title, style: Theme.of(context).textTheme.titleMedium),
          Text(context.tr(task.state)),
          Text(context.tr(task.kind)),
          if (task.programId != null)
            Text(context.tr('Linked to a tracked program')),
          if (task.findingId != null) Text(context.tr('Linked to a concern')),
          if (task.responsiblePerson != null) Text(task.responsiblePerson!),
          if (task.dueOn != null) Text(task.dueOn!),
          if (task.assigneeUserId != null)
            Text(
              context.tr('Assigned to {name}', {
                'name': assignee ?? context.tr('Someone else'),
              }),
            ),
          if (task.needsReview)
            Text(
              context.tr(
                'The owner must review this task before helper progress can change.',
              ),
            ),
        ],
      ),
    ),
  );
}
