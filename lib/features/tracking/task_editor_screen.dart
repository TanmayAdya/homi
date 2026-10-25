import 'dart:async';
import 'package:flutter/material.dart';
import 'package:timezone/timezone.dart' as tz;
import '../../app/live_app.dart';
import '../../l10n/app_localizations.dart';
import '../../shared/models/case_draft.dart';
import '../../shared/services/draft_save_tracker.dart';
import '../../shared/presentation/draft_exit_guard.dart';
import '../../shared/presentation/sah_components.dart';
import '../local_help/referral_directory.dart';
import 'device_reminders.dart';
import 'progress_models.dart';
import 'progress_service.dart';
import 'program_progress_screen.dart';

Map<String, Object?> putTaskOperation({
  required ProgressSnapshot snapshot,
  NextStepTask? task,
  required String id,
  required String title,
  required String kind,
  String state = 'pending',
  String? programId,
  String? findingId,
  String? person,
  String? dueOn,
  String? referralId,
  String? sourceEventId,
}) => {
  'type': 'put_task',
  'expectedTaskRevision': task?.revision ?? 0,
  'task': {
    'id': id,
    if (task?.referral != null || referralId != null)
      'referral': task?.referral ?? {'providerId': referralId!},
    'programId': programId,
    'findingId': findingId,
    'formId': task?.data['formId'],
    'title': title,
    'kind': kind,
    'state': state,
    'responsiblePerson': person == null || person.isEmpty ? null : person,
    'dueOn': dueOn == null || dueOn.isEmpty ? null : dueOn,
    'basedOnCaseRevision': snapshot.caseRevision,
    'basedOnRuleVersion': snapshot.programs
        .where((p) => p.id == programId)
        .firstOrNull
        ?.ruleVersion,
    'revision': (task?.revision ?? 0) + 1,
    'sourceEventId': sourceEventId,
  },
};

String isoDay(DateTime d) =>
    DateTime(d.year, d.month, d.day).toIso8601String().substring(0, 10);

String localDay(BuildContext context, String iso) {
  final day = DateTime.parse(iso), l = MaterialLocalizations.of(context);
  return day.year == DateTime.now().year
      ? l.formatMediumDate(day)
      : l.formatFullDate(day);
}

Future<String?> pickIsoDay(
  BuildContext context, {
  String? initial,
  DateTime? first,
  DateTime? last,
}) async {
  final firstDate = first ?? DateTime(2000), lastDate = last ?? DateTime(2100);
  var start = initial == null ? DateTime.now() : DateTime.parse(initial);
  if (start.isBefore(firstDate)) start = firstDate;
  if (start.isAfter(lastDate)) start = lastDate;
  final picked = await showDatePicker(
    context: context,
    initialDate: start,
    firstDate: firstDate,
    lastDate: lastDate,
  );
  return picked == null ? null : isoDay(picked);
}

class TaskEditorScreen extends StatefulWidget {
  const TaskEditorScreen({
    super.key,
    required this.services,
    required this.snapshot,
    this.task,
    this.program,
    this.proposal,
    this.initialFindingId,
    this.referralId,
  });
  final AppServices services;
  final ProgressSnapshot snapshot;
  final NextStepTask? task;
  final TrackedProgram? program;
  final Map<String, Object?>? proposal;
  final String? initialFindingId, referralId;
  @override
  State<TaskEditorScreen> createState() => _TaskEditorScreenState();
}

class _TaskEditorScreenState extends State<TaskEditorScreen> {
  final _form = GlobalKey<FormState>();
  final _title = TextEditingController(), _person = TextEditingController();
  String _due = '';
  late final DraftSaveTracker _saves;
  late final int _generation = widget.services.coordinator.generation;
  late String _taskId = widget.task?.id ?? newUuidV4();
  String _kind = 'other', _state = 'pending';
  String? _programId, _findingId, _sourceEventId;
  bool _ready = false, _reviewed = false, _reminderBusy = false;
  String? _error;
  String get _key => 'progress-edit.${widget.snapshot.caseId}';
  String get _caseId => widget.snapshot.caseId;
  DeviceReminders get _reminders => widget.services.progress!.reminders;
  bool get current =>
      mounted &&
      widget.services.coordinator.isCurrent &&
      widget.services.coordinator.generation == _generation &&
      widget.services.coordinator.snapshot?.caseId == widget.snapshot.caseId;
  @override
  void initState() {
    super.initState();
    _saves = DraftSaveTracker(isCurrent: () => current);
    _restore();
  }

  Future<void> _restore() async {
    final task = widget.task;
    _programId = task?.programId ?? widget.program?.id;
    _title.text = task?.title ?? widget.proposal?['title'] as String? ?? '';
    _person.text =
        task?.responsiblePerson ??
        widget.proposal?['responsiblePerson'] as String? ??
        '';
    _due = task?.dueOn ?? '';
    _kind =
        task?.kind ??
        (widget.referralId != null
            ? 'follow_up'
            : widget.initialFindingId == null
            ? 'other'
            : 'room_review');
    _state = task?.state ?? 'pending';
    _findingId = task?.data['findingId'] as String? ?? widget.initialFindingId;
    if (!widget.services.coordinator.currentCase().findings.any(
      (f) => f.id == _findingId,
    )) {
      _findingId = null;
    }
    _sourceEventId =
        task?.data['sourceEventId'] as String? ??
        widget.proposal?['eventId'] as String?;
    try {
      final old = await widget.services.store.readJson(_key);
      if (!current) return;
      if (old != null &&
          old['editingId'] == widget.task?.id &&
          old['editingRevision'] == widget.task?.revision &&
          old['caseRevision'] == widget.snapshot.caseRevision &&
          old['programId'] == _programId &&
          old['initialFindingId'] == widget.initialFindingId &&
          old['referralId'] == widget.referralId &&
          old['sourceEventId'] == _sourceEventId) {
        _taskId = old['id'] as String;
        _title.text = old['title'] as String;
        _person.text = old['person'] as String;
        _due = old['due'] as String;
        _kind = old['kind'] as String;
        _state = old['state'] as String;
        _findingId = old['findingId'] as String?;
      }
    } catch (_) {
      if (current) {
        _error = 'Unfinished edits could not be saved on this device.';
      }
    }
    if (mounted) setState(() => _ready = true);
  }

  void _stash() {
    if (!_ready || !current) return;
    final value = <String, Object?>{
      'id': _taskId,
      'editingId': widget.task?.id,
      'editingRevision': widget.task?.revision,
      'caseRevision': widget.snapshot.caseRevision,
      'title': _title.text,
      'person': _person.text,
      'due': _due,
      'kind': _kind,
      'state': _state,
      'programId': _programId,
      'findingId': _findingId,
      'sourceEventId': _sourceEventId,
      'initialFindingId': widget.initialFindingId,
      'referralId': widget.referralId,
    };
    unawaited(
      _saves
          .track(() => widget.services.store.writeJson(_key, value))
          .catchError((Object _) {
            if (current) {
              setState(
                () => _error =
                    'Unfinished edits could not be saved on this device.',
              );
            }
          }),
    );
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate() || !current || !_ready) return;
    if (widget.task?.needsReview == true && !_reviewed) {
      setState(
        () =>
            _error = 'Review this task against the current plan before saving.',
      );
      return;
    }
    try {
      if (!await _saves.settle()) throw StateError('Device save failed.');
      if (!mounted || !current) return;
      Navigator.pop(
        context,
        putTaskOperation(
          snapshot: widget.snapshot,
          task: widget.task,
          id: _taskId,
          title: _title.text.trim(),
          kind: _kind,
          state: _state,
          programId: _programId,
          findingId: _findingId,
          person: _person.text.trim(),
          dueOn: _due,
          referralId: widget.referralId,
          sourceEventId: _sourceEventId,
        ),
      );
    } catch (_) {
      if (current) {
        setState(
          () => _error = 'Unfinished edits could not be saved on this device.',
        );
      }
    }
  }

  Future<void> _pickDue() async {
    final picked = await pickIsoDay(
      context,
      initial: _due.isEmpty ? null : _due,
    );
    if (picked == null || !current) return;
    setState(() => _due = picked);
    _stash();
  }

  Future<void> _reminder(Future<void> Function() work) async {
    if (_reminderBusy || !current) return;
    setState(() {
      _reminderBusy = true;
      _error = null;
    });
    try {
      await work();
      if (current) await widget.services.progress!.reconcileReminders();
    } on FormatException {
      if (current) {
        _error = 'Choose a valid future date, time, and IANA time zone.';
      }
    } catch (e) {
      if (current) {
        _error = e is ReminderSettingsException
            ? e.message
            : safeOperationMessage(e);
      }
    } finally {
      if (mounted) setState(() => _reminderBusy = false);
    }
  }

  Future<void> _setReminder(NextStepTask task, {bool snooze = false}) async {
    if (_reminderBusy || !current) return;
    final old = _reminders.forTask(_caseId, task.id);
    final String zone;
    try {
      zone = old?.zone ?? await _reminders.device.timeZone();
    } catch (e) {
      if (current) setState(() => _error = safeOperationMessage(e));
      return;
    }
    if (!mounted || !current) return;
    final now = tz.TZDateTime.now(tz.getLocation(zone));
    final start = tz.TZDateTime.from(
      DateTime.now().add(Duration(hours: snooze ? 24 : 1)),
      tz.getLocation(zone),
    );
    String two(int v) => v.toString().padLeft(2, '0');
    final due = task.dueOn;
    final useDue =
        !snooze && old == null && due != null && due.compareTo(isoDay(now)) > 0;
    final values = await showDialog<Map<String, String>>(
      context: context,
      builder: (_) => _ReminderDialog(
        snooze: snooze,
        date: snooze || old == null
            ? (useDue ? due : start.toIso8601String().substring(0, 10))
            : old.data['date'] as String,
        zone: zone,
        time: snooze
            ? '${two(start.hour)}:${two(start.minute)}'
            : old?.data['time'] as String? ??
                  (useDue
                      ? '09:00'
                      : '${two(start.hour)}:${two(start.minute)}'),
      ),
    );
    if (!current || values == null) return;
    await _reminder(
      () => _reminders.configure(
        _caseId,
        task.id,
        values['date']!,
        values['time']!,
        values['zone']!,
      ),
    );
  }

  @override
  void dispose() {
    _saves.dispose();
    _title.dispose();
    _person.dispose();
    super.dispose();
  }

  Widget _reminderSection(BuildContext context, NextStepTask task) {
    final pref = _reminders.forTask(_caseId, task.id);
    final on = pref?.enabled == true;
    final enabled = _ready && !_reminderBusy && !_reminders.requiresReset;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.notifications_outlined),
          title: Text(context.tr('Reminder on this phone')),
          subtitle: Text(
            on
                ? context.tr('Reminder requested: {time} ({zone})', {
                    'time':
                        '${localDay(context, pref!.data['date'] as String)} ${pref.data['time']}',
                    'zone': pref.zone,
                  })
                : context.tr('Off'),
          ),
          onTap: enabled ? () => _setReminder(task) : null,
        ),
        if (on)
          Wrap(
            spacing: 8,
            children: [
              TextButton(
                onPressed: enabled
                    ? () => _setReminder(task, snooze: true)
                    : null,
                child: Text(context.tr('Snooze reminder')),
              ),
              TextButton(
                onPressed: enabled
                    ? () =>
                          _reminder(() => _reminders.disable(_caseId, task.id))
                    : null,
                child: Text(context.tr('Disable reminder')),
              ),
            ],
          )
        else
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton(
              onPressed: enabled ? () => _setReminder(task) : null,
              child: Text(context.tr('Device reminder')),
            ),
          ),
        Text(
          context.tr(
            'Reminders are local to this device. Open the app to sync remote changes. Device settings may delay or prevent delivery.',
          ),
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final task = widget.task;
    final findings = widget.services.coordinator.currentCase().findings;
    final referralId = task?.referralId ?? widget.referralId;
    final imported = task?.referral?['imported'] as Map?;
    return DraftExitGuard(
      tracker: _saves,
      builder: (context, requestExit, exiting) => Scaffold(
        appBar: AppBar(
          title: Text(context.tr(task == null ? 'New task' : 'Task')),
        ),
        body: SafeArea(
          child: Form(
            key: _form,
            child: ListView(
              padding: const EdgeInsets.all(20),
              children: [
                if (!_ready || _reminderBusy) const LinearProgressIndicator(),
                if (_error != null) SahNotice(message: context.tr(_error!)),
                if (task?.needsReview == true) ...[
                  SahNotice(
                    message: context.tr('Plan changed. Review this task.'),
                  ),
                  CheckboxListTile(
                    value: _reviewed,
                    title: Text(
                      context.tr(
                        'I reviewed this task against the current plan.',
                      ),
                    ),
                    onChanged: (v) => setState(() => _reviewed = v!),
                  ),
                ],
                TextFormField(
                  controller: _title,
                  enabled: _ready,
                  maxLength: 200,
                  autofocus: task == null && _title.text.isEmpty,
                  style: Theme.of(context).textTheme.titleLarge,
                  decoration: InputDecoration(
                    labelText: context.tr('What needs doing?'),
                  ),
                  onChanged: (_) => _stash(),
                  validator: (v) => (v ?? '').trim().isEmpty
                      ? context.tr('Enter a next step.')
                      : null,
                ),
                SahSectionHeading(title: context.tr('Details (optional)')),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.event_outlined),
                  title: Text(context.tr('Date (optional)')),
                  subtitle: Text(
                    _due.isEmpty
                        ? context.tr('No target date')
                        : localDay(context, _due),
                  ),
                  trailing: _due.isEmpty
                      ? null
                      : IconButton(
                          tooltip: context.tr('Remove date'),
                          onPressed: _ready
                              ? () {
                                  setState(() => _due = '');
                                  _stash();
                                }
                              : null,
                          icon: const Icon(Icons.clear),
                        ),
                  onTap: _ready ? _pickDue : null,
                ),
                Text(
                  context.tr(
                    'Due dates are personal targets. They are not verified agency deadlines.',
                  ),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 12),
                if (task != null && task.open)
                  _reminderSection(context, task)
                else if (task == null)
                  Text(
                    context.tr(
                      'You can set a reminder on this phone after the task is saved.',
                    ),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _person,
                  maxLength: 100,
                  decoration: InputDecoration(
                    labelText: context.tr('For (optional note)'),
                    helperText: context.tr(
                      'A note about who it’s for. It doesn’t notify anyone or give access to the plan.',
                    ),
                    helperMaxLines: 4,
                  ),
                  onChanged: (_) => _stash(),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  key: ValueKey('program-$_ready'),
                  initialValue: _programId,
                  isExpanded: true,
                  decoration: InputDecoration(
                    labelText: context.tr('Program (optional)'),
                  ),
                  items: [
                    DropdownMenuItem(
                      value: null,
                      child: Text(context.tr('Whole plan')),
                    ),
                    for (final p in widget.snapshot.programs)
                      DropdownMenuItem(value: p.id, child: Text(p.name)),
                  ],
                  onChanged: _ready && _sourceEventId == null
                      ? (v) {
                          setState(() => _programId = v);
                          _stash();
                        }
                      : null,
                ),
                DropdownButtonFormField<String>(
                  key: ValueKey('finding-$_ready'),
                  initialValue: findings.any((f) => f.id == _findingId)
                      ? _findingId
                      : null,
                  isExpanded: true,
                  decoration: InputDecoration(
                    labelText: context.tr('Related concern (optional)'),
                  ),
                  items: [
                    DropdownMenuItem(
                      value: null,
                      child: Text(context.tr('None')),
                    ),
                    for (final f in findings)
                      DropdownMenuItem(
                        value: f.id,
                        child: Text(
                          f.observation,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: _ready
                      ? (v) {
                          setState(() => _findingId = v);
                          _stash();
                        }
                      : null,
                ),
                if (referralId != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(
                      context.tr('Referral: {organization}', {
                        'organization':
                            const OfficialReferralDirectory()
                                .provider(referralId)
                                ?.name ??
                            context.tr('Saved contact'),
                      }),
                    ),
                  ),
                if (imported != null)
                  ExpansionTile(
                    tilePadding: EdgeInsets.zero,
                    title: Text(context.tr('Original local follow-up')),
                    children: [
                      Text((imported['original'] as Map)['title'] as String),
                      Text(imported['contactNote'] as String),
                      if ((imported['original'] as Map)['dueDate'] != null)
                        Text(
                          context.tr('Original target: {date}', {
                            'date': (imported['original'] as Map)['dueDate'],
                          }),
                        ),
                      if ((imported['original'] as Map)['completedAt'] != null)
                        Text(
                          context.tr('Originally completed: {date}', {
                            'date':
                                (imported['original'] as Map)['completedAt'],
                          }),
                        ),
                    ],
                  ),
                ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  title: Text(context.tr('More options')),
                  subtitle: Text(
                    '${context.tr(taskStateLabel(_state))} · ${context.tr(taskKindLabel(_kind))}',
                  ),
                  children: [
                    DropdownButtonFormField<String>(
                      key: ValueKey('state-$_ready'),
                      initialValue: _state,
                      isExpanded: true,
                      decoration: InputDecoration(
                        labelText: context.tr('Task status'),
                      ),
                      items: [
                        for (final s in taskStates)
                          DropdownMenuItem(
                            value: s,
                            child: Text(context.tr(taskStateLabel(s))),
                          ),
                      ],
                      onChanged: _ready
                          ? (v) {
                              setState(() => _state = v!);
                              _stash();
                            }
                          : null,
                    ),
                    DropdownButtonFormField<String>(
                      key: ValueKey('kind-$_ready'),
                      initialValue: _kind,
                      isExpanded: true,
                      decoration: InputDecoration(
                        labelText: context.tr('Task type'),
                      ),
                      items: [
                        for (final k in taskKinds)
                          DropdownMenuItem(
                            value: k,
                            child: Text(context.tr(taskKindLabel(k))),
                          ),
                      ],
                      onChanged: _ready
                          ? (v) {
                              setState(() => _kind = v!);
                              _stash();
                            }
                          : null,
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: _ready ? _save : null,
                  child: Text(context.tr('Save task')),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ReminderDialog extends StatefulWidget {
  const _ReminderDialog({
    required this.snooze,
    required this.date,
    required this.time,
    required this.zone,
  });
  final bool snooze;
  final String date, time, zone;
  @override
  State<_ReminderDialog> createState() => _ReminderDialogState();
}

class _ReminderDialogState extends State<_ReminderDialog> {
  late String _date = widget.date, _time = widget.time;
  late final _zone = TextEditingController(text: widget.zone);
  @override
  void dispose() {
    _zone.dispose();
    super.dispose();
  }

  Future<void> _pickTime() async {
    final parts = _time.split(':').map(int.tryParse).toList();
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: parts.first ?? 9, minute: parts.last ?? 0),
    );
    if (picked == null || !mounted) return;
    String two(int v) => v.toString().padLeft(2, '0');
    setState(() => _time = '${two(picked.hour)}:${two(picked.minute)}');
  }

  @override
  Widget build(BuildContext context) {
    final parts = _time.split(':').map(int.tryParse).toList();
    return AlertDialog(
      scrollable: true,
      title: Text(
        context.tr(widget.snooze ? 'Snooze reminder' : 'Device reminder'),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            key: const ValueKey('reminder-date'),
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.event_outlined),
            title: Text(context.tr('Reminder date')),
            subtitle: Text(localDay(context, _date)),
            onTap: () async {
              final today = DateTime.now();
              final picked = await pickIsoDay(
                context,
                initial: _date,
                first: DateTime(today.year, today.month, today.day),
              );
              if (picked != null && mounted) setState(() => _date = picked);
            },
          ),
          ListTile(
            key: const ValueKey('reminder-time'),
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.schedule_outlined),
            title: Text(context.tr('Reminder time')),
            subtitle: Text(
              parts.length == 2 && parts.every((p) => p != null)
                  ? MaterialLocalizations.of(context).formatTimeOfDay(
                      TimeOfDay(hour: parts[0]!, minute: parts[1]!),
                    )
                  : _time,
            ),
            onTap: _pickTime,
          ),
          TextField(
            controller: _zone,
            decoration: InputDecoration(
              labelText: context.tr('Time zone (IANA)'),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            context.tr(
              'Reminders stay in the chosen time zone when you travel. A repeated daylight-saving time uses the earlier occurrence; choose another time if the clock skips it.',
            ),
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(context.tr('Cancel')),
        ),
        FilledButton(
          onPressed: () {
            FocusScope.of(context).unfocus();
            Navigator.pop(context, {
              'date': _date,
              'time': _time,
              'zone': _zone.text.trim(),
            });
          },
          child: Text(context.tr('Enable reminder')),
        ),
      ],
    );
  }
}
