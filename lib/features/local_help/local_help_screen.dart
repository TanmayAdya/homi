import '../../shared/presentation/sah_floating_nav.dart';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/live_app.dart';
import '../../l10n/app_localizations.dart';
import '../tracking/program_progress_screen.dart';
import 'referral_task_import.dart';
import '../../shared/presentation/sah_components.dart';
import 'local_help_record.dart';
import 'local_help_repository.dart';
import 'referral_directory.dart';
import 'help_finder.dart';
import 'nationwide_help_browser.dart';

class LocalHelpButton extends StatelessWidget {
  const LocalHelpButton({super.key, required this.services, this.findingId});
  final AppServices services;
  final String? findingId;
  @override
  Widget build(BuildContext context) => !services.config.localHelpEnabled
      ? const SizedBox.shrink()
      : IconButton(
          tooltip: context.tr('Find local help'),
          icon: const Icon(Icons.support_agent),
          onPressed:
              !services.coordinator.busy &&
                  !services.coordinator.hasUndurableEdits
              ? () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) =>
                        services.coordinator.isCurrent &&
                            services.coordinator.draft != null
                        ? LocalHelpScreen(
                            services: services,
                            findingId: findingId,
                          )
                        : const NationwideHelpBrowser(),
                  ),
                )
              : null,
        );
}

class LocalHelpScreen extends StatefulWidget {
  const LocalHelpScreen({
    super.key,
    required this.services,
    this.findingId,
    this.openExternal,
    this.directory = const OfficialReferralDirectory(),
    this.now,
    this.embedded = false,
    this.header,
    this.checklist,
  });
  final AppServices services;
  final String? findingId;

  final VoidCallback? Function(String programId)? checklist;

  final Future<bool> Function(Uri)? openExternal;
  final ReferralDirectory directory;
  final DateTime Function()? now;
  final bool embedded;
  final Widget? header;
  @override
  LocalHelpScreenState createState() => LocalHelpScreenState();
}

class LocalHelpScreenState extends State<LocalHelpScreen> {
  bool get canLeave => !_working;

  LocalHelpRepository? _repository;
  LocalHelpRecord? _record;
  Map<String, Object?> _receipts = {};
  bool _working = false;
  String? _error;
  bool get _current => _repository?.isCurrent == true;
  @override
  void initState() {
    super.initState();
    if (widget.services.config.localHelpEnabled &&
        widget.services.coordinator.isCurrent &&
        widget.services.coordinator.draft != null) {
      _repository = LocalHelpRepository(
        widget.services.coordinator,
        directory: widget.directory,
      );
      widget.services.coordinator.addListener(_changed);
      widget.services.profileResponses.addListener(_changed);
      _load();
    }
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.services.coordinator.removeListener(_changed);
    widget.services.profileResponses.removeListener(_changed);
    super.dispose();
  }

  HelpLocation? _resident;
  String? _residentKey;

  HelpLocation? _residentLocation() {
    final draft = widget.services.coordinator.draft;
    if (draft == null) return null;
    final saved = widget.services.profileResponses.currentFor(
      draft.caseId,
      draft.profile,
    );
    final key = jsonEncode([
      draft.profile.city,
      draft.profile.county,
      saved.stateCode,
      saved.zip,
    ]);
    if (key == _residentKey) return _resident;
    _residentKey = key;
    try {
      _resident = HelpLocation(
        city: draft.profile.city ?? '',
        county: draft.profile.county ?? '',
        zip: saved.zip,
        stateCode: saved.stateCode,
      );
    } on FormatException {
      _resident = null;
    }
    return _resident;
  }

  Future<void> _load() async {
    await _run(() async {
      final draft = widget.services.coordinator.currentDraft();
      try {
        await widget.services.profileResponses.read(
          draft.caseId,
          draft.profile,
        );
      } catch (_) {}
      final r = await _repository!.load();
      final receipts = await ReferralTaskImport(
        widget.services,
        _repository!,
      ).receipts();
      if (!mounted || !_current) return;
      setState(() {
        _record = r;
        _receipts = receipts;
      });
    });
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_working || !_current) return;
    setState(() {
      _working = true;
      _error = null;
    });
    try {
      await action();
    } catch (_) {
      if (mounted && _current) {
        setState(
          () => _error =
              'Local help could not be saved or opened. Your previous saved information is kept. Try again.',
        );
      }
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _save(Future<LocalHelpRecord> Function() action) async {
    final next = await action();
    if (!mounted || !_current) throw StateError('Plan changed.');
    setState(() => _record = next);
  }

  Future<bool> _openUri(Uri uri) async {
    var opened = false;
    await _run(() async {
      try {
        opened =
            await (widget.openExternal?.call(uri) ??
                launchUrl(uri, mode: LaunchMode.externalApplication));
        if (!opened) throw StateError('Unavailable external application.');
      } catch (_) {
        opened = false;
        if (mounted && _current) {
          setState(
            () => _error =
                'Could not open this link or dialer. Check your connection, try the official locator, or use the phone number or website shown below.',
          );
        }
      }
    });
    return opened;
  }

  Future<void> _open(ReferralProvider provider, {bool phone = false}) =>
      _openUri(referralDestination(provider, phone: phone));
  Future<void> _contact(ReferralProvider p, SavedHelpContact? saved) async {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _HelpEditor(
        title: p.name,
        note: saved?.note ?? '',
        onSave: (note) => _save(() => _repository!.saveContact(p.id, note)),
      ),
    );
  }

  Future<void> _task(String providerId, [HelpFollowUp? previous]) async {
    if (widget.services.progress == null ||
        widget.services.coordinator.snapshot == null ||
        widget.services.coordinator.hasUnsavedChanges ||
        widget.services.coordinator.uncertain ||
        widget.services.coordinator.conflict) {
      setState(
        () => _error =
            'Save this plan online and enable My next steps to manage referral tasks. Saved local follow-ups are kept.',
      );
      return;
    }
    if (!_current || _working) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ProgramProgressScreen(
          services: widget.services,
          tasksFirst: true,
          referralId: providerId,
          findingId: previous == null ? widget.findingId : null,
        ),
      ),
    );
    if (mounted && _current) await _load();
  }

  Future<void> _import(HelpFollowUp source) async {
    if (widget.services.progress == null ||
        widget.services.coordinator.snapshot == null) {
      await _task(source.providerId, source);
      return;
    }
    bool keepDueDate = false;
    final contactNote =
        _record!.contacts
            .where((c) => c.providerId == source.providerId)
            .firstOrNull
            ?.note ??
        '';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, change) => AlertDialog(
          scrollable: true,
          title: Text(ctx.tr('Import local follow-up')),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(source.title),
              Text(
                ctx.tr(
                  'A copy of this follow-up and the contact note below will be saved online with the task. Review them before importing.',
                ),
              ),
              if (contactNote.isNotEmpty) Text(contactNote),
              Text(
                ctx.tr(
                  'The original stays on this device. Completion is your report, not proof of repairs or an agency decision. No reminder is enabled by importing.',
                ),
              ),
              if (source.findingId != null &&
                  !widget.services.coordinator.currentCase().findings.any(
                    (f) => f.id == source.findingId,
                  ))
                Text(
                  ctx.tr(
                    'The original concern is no longer present. Its reference is retained in the import history.',
                  ),
                ),
              if (source.dueDate != null)
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  value: keepDueDate,
                  onChanged: (value) =>
                      change(() => keepDueDate = value == true),
                  title: Text(
                    ctx.tr('Keep original target date: {date}', {
                      'date': _date(source.dueDate!),
                    }),
                  ),
                ),
              Text(
                ctx.tr(
                  'To request a reminder, open the saved task in My next steps and choose Device reminder.',
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
              child: Text(ctx.tr('Import follow-up')),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true || !mounted || !_current) return;
    await _run(() async {
      await ReferralTaskImport(widget.services, _repository!).import(
        source,
        keepDueDate: keepDueDate,
        confirmedContactNote: contactNote,
      );
      final receipts = await ReferralTaskImport(
        widget.services,
        _repository!,
      ).receipts();
      if (mounted && _current) setState(() => _receipts = receipts);
    });
  }

  String _date(String date) =>
      MaterialLocalizations.of(context).formatMediumDate(DateTime.parse(date));
  @override
  Widget build(BuildContext context) {
    final r = _record;
    final repository = _repository;
    final available = widget.services.config.localHelpEnabled && _current;
    final resident = _residentLocation();
    final body = SahContent(
      child: !available
          ? Center(
              child: Text(
                context.tr('Reopen the selected plan to use local help.'),
              ),
            )
          : ListView(
              padding: sahFloatingContentPadding(context),
              children: [
                if (widget.header != null) widget.header!,
                if (_error != null) ...[
                  SahNotice(
                    message: context.tr(_error!),
                    tone: SahNoticeTone.warning,
                  ),
                  if (r == null)
                    TextButton(
                      onPressed: _working ? null : _load,
                      child: Text(context.tr('Retry')),
                    ),
                ],
                if (_working) const LinearProgressIndicator(),
                if (r != null) ...[
                  HelpFinder(
                    directory: repository!.directory,
                    now: widget.now?.call() ?? DateTime.now(),
                    location:
                        r.location ??
                        (referralState(resident?.stateCode)?.routingSupported ==
                                true
                            ? resident
                            : null),
                    residentLocation: resident,
                    onLocation: (location) => _run(
                      () => _save(() => repository.confirmLocation(location)),
                    ),
                    actions: HelpActions(
                      open: _openUri,
                      save: (p) => _contact(
                        p,
                        _record?.contacts
                            .where((c) => c.providerId == p.id)
                            .firstOrNull,
                      ),
                      followUp: (p) => _task(p.id),
                      isSaved: (p) =>
                          _record?.contacts.any((c) => c.providerId == p.id) ??
                          false,
                      busy: _working,
                      checklist: widget.checklist,
                    ),
                  ),
                  SahSectionHeading(
                    title: context.tr('Saved contacts'),
                    description: context.tr(
                      'Saved on this phone only for this plan. Signing out removes them. Follow-ups use My next steps and its separate reminder controls.',
                    ),
                  ),
                  if (r.contacts.isEmpty)
                    Text(context.tr('No contacts saved yet.')),
                  for (final c in r.contacts)
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(
                              repository.directory
                                      .provider(c.providerId)
                                      ?.name ??
                                  context.tr('Organization no longer listed'),
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                            if (c.note.isNotEmpty) Text(c.note),
                            if (repository.directory.provider(c.providerId)
                                case ReferralProvider(:final phone?))
                              SelectableText(phone),
                            Wrap(
                              spacing: 8,
                              children: [
                                if (repository.directory.provider(c.providerId)
                                    case final p?) ...[
                                  if (p.phone != null)
                                    TextButton(
                                      onPressed: _working
                                          ? null
                                          : () => _open(p, phone: true),
                                      child: Text(
                                        context.tr('Call organization'),
                                      ),
                                    ),
                                  TextButton(
                                    onPressed: _working ? null : () => _open(p),
                                    child: Text(
                                      context.tr(referralWebsiteLabel(p)),
                                    ),
                                  ),
                                  TextButton(
                                    onPressed: _working
                                        ? null
                                        : () => _contact(p, c),
                                    child: Text(
                                      context.tr('Edit contact note'),
                                    ),
                                  ),
                                  TextButton(
                                    onPressed: _working
                                        ? null
                                        : () => _task(c.providerId),
                                    child: Text(context.tr('Add follow-up')),
                                  ),
                                ],
                                TextButton(
                                  onPressed: _working
                                      ? null
                                      : () => _run(
                                          () => _save(
                                            () => repository.removeContact(
                                              c.providerId,
                                            ),
                                          ),
                                        ),
                                  child: Text(
                                    context.tr('Remove saved contact'),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  SahSectionHeading(
                    title: context.tr('Original local follow-ups'),
                  ),
                  if (r.tasks.isEmpty) Text(context.tr('No follow-ups yet.')),
                  for (final t in r.tasks) _taskCard(t, repository),
                ],
              ],
            ),
    );
    if (widget.embedded) return body;
    return PopScope(
      canPop: !_working,
      child: Scaffold(
        appBar: AppBar(title: Text(context.tr('Find local help'))),
        body: SafeArea(child: body),
      ),
    );
  }

  Widget _taskCard(HelpFollowUp t, LocalHelpRepository repository) => Card(
    key: ValueKey(t.id),
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(t.title, style: Theme.of(context).textTheme.titleMedium),
          Text(
            repository.directory.provider(t.providerId)?.name ??
                context.tr('Organization no longer listed'),
          ),
          Text(
            context.tr(
              t.completedAt != null
                  ? 'Completed'
                  : t.overdue(DateTime.now())
                  ? 'Overdue'
                  : 'Open',
            ),
          ),
          if (t.responsible.isNotEmpty)
            Text(
              context.tr('Responsible: {person}', {'person': t.responsible}),
            ),
          Text(
            t.dueDate == null
                ? context.tr('No due date')
                : context.tr('Due {date}', {'date': _date(t.dueDate!)}),
          ),
          if (t.findingId != null) Text(context.tr('Linked to a concern')),
          if (_receipts.containsKey(t.id))
            Text(
              context.tr(
                'Imported earlier. Open My next steps to check current saved state.',
              ),
            ),
          Wrap(
            spacing: 8,
            children: [
              if (!_receipts.containsKey(t.id))
                TextButton(
                  onPressed: _working ? null : () => _import(t),
                  child: Text(context.tr('Import local follow-up')),
                ),
              TextButton(
                onPressed: _working ? null : () => _task(t.providerId, t),
                child: Text(context.tr('Open My next steps')),
              ),
              if (repository.directory.provider(t.providerId) case final p?)
                TextButton(
                  onPressed: _working ? null : () => _open(p),
                  child: Text(context.tr('Open official website')),
                ),
            ],
          ),
        ],
      ),
    ),
  );
}

class _HelpEditor extends StatefulWidget {
  const _HelpEditor({
    required this.title,
    required this.note,
    required this.onSave,
  });
  final String title, note;
  final Future<void> Function(String) onSave;
  @override
  State<_HelpEditor> createState() => _HelpEditorState();
}

class _HelpEditorState extends State<_HelpEditor> {
  late final _note = TextEditingController(text: widget.note);
  bool _saving = false, _failed = false;
  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _failed = false;
    });
    try {
      await widget.onSave(_note.text.trim());
      if (mounted) Navigator.pop(context);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_saving,
    child: AlertDialog(
      scrollable: true,
      title: Text(context.tr(widget.title)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextFormField(
            controller: _note,
            enabled: !_saving,
            maxLength: 500,
            decoration: InputDecoration(
              labelText: context.tr('Contact note (optional)'),
            ),
          ),
          if (_failed)
            Text(
              context.tr('Could not save. Keep this editor open and retry.'),
            ),
          if (_saving) const LinearProgressIndicator(),
        ],
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: Text(context.tr('Cancel')),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: Text(context.tr('Save on this device')),
        ),
      ],
    ),
  );
}
