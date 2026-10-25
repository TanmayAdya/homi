import 'dart:async';
import 'package:flutter/material.dart';
import 'package:safe_at_home/l10n/app_localizations.dart';
import '../../app/live_app.dart';
import '../../shared/models/case_draft.dart';
import '../../shared/models/contracts.dart';
import '../../shared/models/request_tracking.dart';
import '../../shared/presentation/sah_components.dart';
import '../../shared/presentation/draft_exit_guard.dart';
import '../../shared/services/draft_save_tracker.dart';
import '../../shared/services/matching_api_client.dart';
import 'application_workspace_screen.dart';

class RequestHistoryScreen extends StatefulWidget {
  const RequestHistoryScreen({
    super.key,
    required this.services,
    required this.program,
    this.initialStatus,
  });
  final AppServices services;
  final ProgramMatch program;

  final String? initialStatus;
  @override
  State<RequestHistoryScreen> createState() => _RequestHistoryScreenState();
}

class _RequestHistoryScreenState extends State<RequestHistoryScreen> {
  RequestHistory? _history;
  PendingRequestUpdate? _pending;
  bool _busy = false, _reconciledPending = false, _restoring = true;
  bool _feedbackAtAction = false;
  bool _editing = false;
  late final String _caseId;
  late final int _generation;
  late final DraftSaveTracker _draftSaves;
  String get _editKey => 'history-edit.$_caseId.${widget.program.programId}';
  String? _error;
  final _date = TextEditingController(
        text: DateTime.now().toIso8601String().substring(0, 10),
      ),
      _note = TextEditingController(),
      _action = TextEditingController(),
      _follow = TextEditingController();
  String _status = 'preparing', _source = 'self_report', _party = 'resident';
  String get _key => 'history.$_caseId.${widget.program.programId}';
  @override
  void initState() {
    super.initState();
    _caseId = widget.services.coordinator.currentCase().caseId;
    _generation = widget.services.coordinator.generation;
    _draftSaves = DraftSaveTracker(isCurrent: () => _isCurrent);
    _load(initial: true);
  }

  @override
  void dispose() {
    _draftSaves.dispose();
    _date.dispose();
    _note.dispose();
    _action.dispose();
    _follow.dispose();
    super.dispose();
  }

  ReadRequestHistoryRequest _request() {
    final c = _screenCase();
    return ReadRequestHistoryRequest(
      caseId: c.caseId,
      expectedCaseRevision: c.revision,
      programId: widget.program.programId,
    );
  }

  bool get _isCurrent {
    final c = widget.services.coordinator;
    return mounted &&
        c.isCurrent &&
        c.generation == _generation &&
        c.snapshot?.caseId == _caseId &&
        !c.hasUnsavedChanges;
  }

  CaseSnapshot _screenCase() {
    if (!_isCurrent) throw MatchingApiException.forCode('STALE_RESPONSE');
    return widget.services.coordinator.currentCase();
  }

  Future<void> _load({bool initial = false}) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _feedbackAtAction = false;
    });
    try {
      final request = _request();
      if (initial) {
        final value = await widget.services.store.readJson(_key);
        _screenCase();
        if (value != null) _pending = PendingRequestUpdate.fromJson(value);
        final edit = await widget.services.store.readJson(_editKey);
        _screenCase();
        if (edit != null) {
          _date.text = edit['date'] as String? ?? _date.text;
          _note.text = edit['note'] as String? ?? '';
          _action.text = edit['action'] as String? ?? '';
          _follow.text = edit['follow'] as String? ?? '';
          _status = edit['status'] as String? ?? 'preparing';
          _source = edit['source'] as String? ?? 'self_report';
          _party = edit['party'] as String? ?? 'resident';
          _editing = true;
        } else if (widget.initialStatus != null) {
          _status = widget.initialStatus!;
        }
      }
      final history = await widget.services.history.readHistory(
        request,
        currentCase: _screenCase,
        currentProgramId: () => widget.program.programId,
        currentHistory: () => _history,
        isCurrent: () => _isCurrent,
      );
      _screenCase();
      _history = history;
      _reconciledPending = true;
      if (_pending != null && history.acknowledges(_pending!)) {
        await _clearAcknowledgedJournal();
        _pending = null;
        _note.clear();
        _action.clear();
        _follow.clear();
        _error = 'The pending update was already saved.';
      }
    } catch (error) {
      if (mounted) _error = safeOperationMessage(error);
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _restoring = false;
        });
        if (initial &&
            widget.initialStatus != null &&
            _pending == null &&
            _history != null &&
            _history!.requestRevision < 50) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && _isCurrent) setState(() => _editing = true);
          });
        }
      }
    }
  }

  bool get _canRetry =>
      _reconciledPending &&
      _pending != null &&
      _history != null &&
      _pending!.request.expectedCaseRevision == _history!.caseRevision &&
      _pending!.expectedRequestRevision == _history!.requestRevision;

  void _stash() {
    if (_restoring || !_isCurrent) return;
    if (_feedbackAtAction && _error != null) {
      setState(() => _error = null);
    }
    final value = <String, Object?>{
      'date': _date.text,
      'note': _note.text,
      'action': _action.text,
      'follow': _follow.text,
      'status': _status,
      'source': _source,
      'party': _party,
    };
    unawaited(
      _draftSaves
          .track(() => widget.services.store.writeJson(_editKey, value))
          .catchError((Object _) {
            if (mounted) {
              setState(
                () => _error =
                    'Unfinished edits could not be saved on this device.',
              );
            }
          }),
    );
  }

  Future<void> _clearAcknowledgedJournal() => _draftSaves.track(() async {
    _screenCase();
    await widget.services.store.delete(_key);
    _screenCase();
    await widget.services.store.delete(_editKey);
    _screenCase();
  });

  Future<void> _discardPending() async {
    if (_busy || _pending == null || !_reconciledPending || !_isCurrent) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        scrollable: true,
        title: Text(ctx.tr('Return this update to the editor?')),
        content: Text(
          ctx.tr(
            'Review the latest history above first. This discards the old pending attempt; a future save creates a new update.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(ctx.tr('Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(ctx.tr('Return to editor')),
          ),
        ],
      ),
    );
    if (confirmed != true ||
        _busy ||
        !_isCurrent ||
        _pending == null ||
        !_reconciledPending) {
      return;
    }
    final u = _pending!.update;
    setState(() {
      _busy = true;
      _error = null;
      _feedbackAtAction = true;
    });
    try {
      final value = <String, Object?>{
        'date': u.occurredOn,
        'note': u.note ?? '',
        'action': u.nextAction ?? '',
        'follow': u.followUpOn ?? '',
        'status': u.status,
        'source': u.source,
        'party': u.responsibleParty ?? 'resident',
      };
      await _draftSaves.track(() async {
        _screenCase();
        await widget.services.store.writeJson(_editKey, value);
        _screenCase();
        await widget.services.store.delete(_key);
        _screenCase();
      });
      _date.text = u.occurredOn;
      _note.text = u.note ?? '';
      _action.text = u.nextAction ?? '';
      _follow.text = u.followUpOn ?? '';
      _status = u.status;
      _source = u.source;
      _party = u.responsibleParty ?? 'resident';
      setState(() {
        _pending = null;
        _editing = true;
      });
    } catch (error) {
      if (mounted) setState(() => _error = safeOperationMessage(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _append() async {
    if (_busy || _history == null || (_pending != null && !_canRetry)) return;
    setState(() {
      _busy = true;
      _error = null;
      _feedbackAtAction = true;
    });
    try {
      _screenCase();
      final nextAction = _action.text.trim();
      _pending ??= PendingRequestUpdate(
        request: _request(),
        expectedRequestRevision: _history!.requestRevision,
        update: RequestUpdate(
          updateId: newUuidV4(),
          status: _status,
          occurredOn: _date.text.trim(),
          source: _source,
          note: _note.text.trim().isEmpty ? null : _note.text.trim(),
          nextAction: nextAction.isEmpty ? null : nextAction,
          responsibleParty: nextAction.isEmpty ? null : _party,
          followUpOn: _follow.text.trim().isEmpty ? null : _follow.text.trim(),
        ),
      );
      final pendingValue = _pending!.toJson();
      await _draftSaves.track(
        () => widget.services.store.writeJson(_key, pendingValue),
      );
      _screenCase();
      _reconciledPending = false;
      final c = widget.services.coordinator;
      final history = await c.serialize(
        () => widget.services.history.appendUpdate(
          _pending!,
          currentCase: _screenCase,
          currentProgramId: () => widget.program.programId,
          currentHistory: () => _history,
          isCurrent: () => _isCurrent,
        ),
      );
      _screenCase();
      _history = history;
      await _clearAcknowledgedJournal();
      _pending = null;
      _note.clear();
      _action.clear();
      _follow.clear();
      _error = 'Manual update saved. This is not verified agency status.';
    } catch (error) {
      if (mounted) _error = safeOperationMessage(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _date10(BuildContext context, String iso) {
    final parsed = DateTime.tryParse(iso);
    return parsed == null
        ? iso
        : MaterialLocalizations.of(context).formatFullDate(parsed);
  }

  Widget _choices<T>({
    required Key key,
    required String label,
    required T value,
    required List<T> options,
    required bool enabled,
    required ValueChanged<T> onChanged,
  }) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(label, style: Theme.of(context).textTheme.titleMedium),
      DropdownButtonFormField<T>(
        key: key,
        initialValue: value,
        isExpanded: true,
        isDense: false,
        itemHeight: null,
        decoration: InputDecoration(
          labelText: label,
          floatingLabelBehavior: FloatingLabelBehavior.never,
        ),
        items: [
          for (final option in options)
            DropdownMenuItem(
              value: option,
              child: Text(_label(context, option as String)),
            ),
        ],
        onChanged: enabled
            ? (v) {
                if (v != null) onChanged(v);
              }
            : null,
      ),
    ],
  );

  bool get _saved =>
      _error == 'Manual update saved. This is not verified agency status.' ||
      _error == 'The pending update was already saved.';

  Widget _editor(BuildContext context, bool exiting) {
    final enabled = !_busy && !exiting;
    void changed(VoidCallback update) {
      setState(update);
      _stash();
    }

    final theme = Theme.of(context);
    return Column(
      key: const ValueKey('history-editor'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          header: true,
          child: Text(
            context.tr('Add update'),
            style: theme.textTheme.titleLarge,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          context.tr(
            'This is your own record. The app doesn’t receive agency decisions.',
          ),
        ),
        const SizedBox(height: 16),
        Text(context.tr('What happened?'), style: theme.textTheme.titleMedium),
        RadioGroup<String>(
          key: const ValueKey('history-status'),
          groupValue: _status,
          onChanged: (v) {
            if (!enabled || v == null) return;
            changed(() => _status = v);
          },
          child: Column(
            children: [
              for (final value in const [
                'preparing',
                'submitted',
                'received',
                'needs_information',
                'approved',
                'denied',
                'withdrawn',
              ])
                RadioListTile<String>(
                  key: ValueKey('history-status-$value'),
                  value: value,
                  enabled: enabled,
                  contentPadding: EdgeInsets.zero,
                  title: Text(_label(context, value)),
                ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Text(
          context.tr('Date it happened'),
          style: theme.textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        IsoDateField(
          key: const ValueKey('history-date'),
          controller: _date,
          label: context.tr('Date it happened'),
          enabled: enabled,
          onChanged: () => changed(() {}),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _note,
          onChanged: (_) => _stash(),
          enabled: enabled,
          maxLength: 500,
          minLines: 2,
          maxLines: 5,
          decoration: InputDecoration(labelText: context.tr('Optional note')),
        ),
        ExpansionTile(
          key: const ValueKey('history-more'),
          tilePadding: EdgeInsets.zero,
          initiallyExpanded:
              _action.text.isNotEmpty ||
              _follow.text.isNotEmpty ||
              _source != 'self_report',
          title: Text(context.tr('Follow-up and source')),
          expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _choices<String>(
              key: ValueKey('source-$_restoring'),
              label: context.tr('Your source'),
              value: _source,
              options: const ['self_report', 'program_contact', 'document'],
              enabled: enabled,
              onChanged: (v) => changed(() => _source = v),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _action,
              onChanged: (_) => _stash(),
              enabled: enabled,
              maxLength: 250,
              minLines: 1,
              maxLines: 3,
              decoration: InputDecoration(
                labelText: context.tr('Optional next action'),
              ),
            ),
            const SizedBox(height: 8),
            _choices<String>(
              key: ValueKey('party-$_restoring'),
              label: context.tr('Who handles the next action?'),
              value: _party,
              options: const [
                'resident',
                'caregiver',
                'program',
                'clinician',
                'contractor',
                'other',
              ],
              enabled: enabled,
              onChanged: (v) => changed(() => _party = v),
            ),
            const SizedBox(height: 16),
            Text(
              context.tr('Optional follow-up date'),
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            IsoDateField(
              key: const ValueKey('history-follow-up'),
              controller: _follow,
              label: context.tr('Optional follow-up date'),
              optional: true,
              enabled: enabled,
              onChanged: () => changed(() {}),
            ),
            Text(
              context.tr('Needs a next action too'),
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
        const SizedBox(height: 16),
        if (_error != null && _feedbackAtAction)
          SahActionFeedback(
            key: const ValueKey('history-save-feedback'),
            message: context.tr(_error!),
          ),
        FilledButton(
          key: const ValueKey('history-save'),
          onPressed:
              !enabled ||
                  _history == null ||
                  _history!.requestRevision >= 50 ||
                  _pending != null
              ? null
              : () async {
                  await _append();
                  if (mounted && _pending == null && _saved) {
                    setState(() => _editing = false);
                  }
                },
          child: Text(context.tr('Save update')),
        ),
        TextButton(
          key: const ValueKey('history-cancel'),
          onPressed: _busy ? null : () => setState(() => _editing = false),
          child: Text(context.tr('Cancel')),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => DraftExitGuard(
    tracker: _draftSaves,
    builder: (context, requestExit, exiting) {
      final events = [...?_history?.events]
        ..sort((a, b) => b.revision.compareTo(a.revision));
      final success =
          _error ==
              'Manual update saved. This is not verified agency status.' ||
          _error == 'The pending update was already saved.';
      return Scaffold(
        appBar: AppBar(
          leading: BackButton(onPressed: requestExit),
          title: Text(context.tr('Updates')),
        ),
        body: SafeArea(
          child: SahContent(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SahPageHeader(
                    title: context.tr('Updates'),
                    eyebrow: programShortName(widget.program),
                    description: context.tr(
                      'What you’ve recorded. The app doesn’t receive agency decisions.',
                    ),
                  ),
                  SahStatusBadge(
                    label: context.tr('Reported by you · not agency status'),
                    icon: Icons.edit_note_rounded,
                  ),
                  if (_busy)
                    Padding(
                      padding: EdgeInsets.symmetric(vertical: 12),
                      child: LinearProgressIndicator(
                        semanticsLabel: context.tr('Updating request history'),
                      ),
                    ),
                  if (_error != null && !_feedbackAtAction)
                    SahNotice(message: context.tr(_error!)),
                  if (!_busy &&
                      (_pending != null ||
                          _history == null ||
                          (_error != null && !success))) ...[
                    const SizedBox(height: 8),
                    OutlinedButton(
                      key: const ValueKey('history-reconcile'),
                      onPressed: _busy || exiting ? null : () => _load(),
                      child: Text(
                        context.tr('Reload history and check pending update'),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ],
                  if (_history != null)
                    SahSectionHeading(title: context.tr('Timeline')),
                  if (_history?.events.isEmpty == true)
                    Text(context.tr('No updates yet.')),
                  if (events.isNotEmpty)
                    SahListGroup(
                      children: [
                        for (final event in events)
                          ListTile(
                            key: ValueKey(
                              'history-event-${event.update.updateId}',
                            ),
                            leading: ExcludeSemantics(
                              child: Icon(
                                event.update.status == 'submitted'
                                    ? Icons.send_outlined
                                    : Icons.event_note_outlined,
                                color: Theme.of(context).colorScheme.primary,
                              ),
                            ),
                            title: Text(
                              context.tr('{status} · {date}', {
                                'status': _label(context, event.update.status),
                                'date': _date10(
                                  context,
                                  event.update.occurredOn,
                                ),
                              }),
                            ),
                            subtitle: Text(
                              [
                                context.tr('You recorded'),
                                event.update.note,
                                if (event.update.nextAction != null)
                                  context.tr('Next action: {action}', {
                                    'action': event.update.nextAction,
                                  }),
                                if (event.update.responsibleParty != null)
                                  context.tr('Responsible: {party}', {
                                    'party': _label(
                                      context,
                                      event.update.responsibleParty!,
                                    ),
                                  }),
                                if (event.update.followUpOn != null)
                                  context.tr('Follow-up: {date}', {
                                    'date': _date10(
                                      context,
                                      event.update.followUpOn!,
                                    ),
                                  }),
                              ].whereType<String>().join('\n'),
                            ),
                          ),
                      ],
                    ),
                  if (_pending != null) ...[
                    SahSectionHeading(title: context.tr('Pending update')),
                    SahNotice(
                      message: context.tr(
                        'An update may already have been saved. Reload history before retrying the exact pending update.',
                      ),
                      tone: SahNoticeTone.warning,
                    ),
                    Text(
                      context.tr('{status} · {date}', {
                        'status': _label(context, _pending!.update.status),
                        'date': _date10(context, _pending!.update.occurredOn),
                      }),
                    ),
                    Text(_pending!.update.note ?? ''),
                    if (_error != null && _feedbackAtAction)
                      SahActionFeedback(
                        key: const ValueKey('history-save-feedback'),
                        message: context.tr(_error!),
                      ),
                    FilledButton(
                      onPressed: _busy || exiting || !_canRetry
                          ? null
                          : _append,
                      child: Text(
                        context.tr('Retry exact pending update'),
                        textAlign: TextAlign.center,
                      ),
                    ),
                    if (_reconciledPending && !_canRetry)
                      TextButton(
                        onPressed: _busy || exiting ? null : _discardPending,
                        child: Text(
                          context.tr('Review against changed history and edit'),
                        ),
                      ),
                  ] else if (_history != null) ...[
                    const SizedBox(height: 16),
                    if (_history!.requestRevision >= 50)
                      SahNotice(
                        message: context.tr(
                          'This request history has reached its limit of 50 updates. Your saved history remains available.',
                        ),
                        tone: SahNoticeTone.warning,
                      ),
                    if (_editing)
                      _editor(context, exiting)
                    else ...[
                      if (_error != null && _feedbackAtAction)
                        SahActionFeedback(
                          key: const ValueKey('history-save-feedback'),
                          message: context.tr(_error!),
                        ),
                      FilledButton.icon(
                        key: const ValueKey('history-add'),
                        onPressed:
                            _busy || exiting || _history!.requestRevision >= 50
                            ? null
                            : () => setState(() {
                                _editing = true;
                                _error = null;
                                _feedbackAtAction = false;
                              }),
                        icon: const Icon(Icons.add_rounded),
                        label: Text(context.tr('Add update')),
                      ),
                    ],
                  ],
                ],
              ),
            ),
          ),
        ),
      );
    },
  );
}

String _label(BuildContext context, String text) => context.tr(switch (text) {
  'needs_information' => 'Needs info',
  'program_contact' => 'Program contact',
  'self_report' => 'Self report',
  _ =>
    text.isEmpty
        ? text
        : '${text[0].toUpperCase()}${text.substring(1).replaceAll('_', ' ')}',
});
