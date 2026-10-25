import 'dart:async';

import 'package:flutter/material.dart';
import 'package:safe_at_home/l10n/app_localizations.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/live_app.dart';
import '../../shared/models/contracts.dart';
import '../../shared/models/form_answers.dart';
import '../../shared/models/program_intake.dart';
import '../../shared/models/request_tracking.dart';
import '../../shared/presentation/sah_components.dart';
import '../../shared/services/matching_api_client.dart';
import '../../shared/services/packet_preparation_service.dart';
import '../cases/profile_editor_screen.dart';
import '../programs/program_intake_screen.dart';
import '../tracking/task_editor_screen.dart';
import 'draft_packet_screen.dart';
import 'form_review_screen.dart';
import 'private_export_screen.dart';
import 'request_history_screen.dart';

bool programHasFormWorkflow(ProgramMatch match) =>
    match.isDemo ||
    const {
      'scfhp-eaa',
      'hpsm-eaa',
      'rtp-home-repair',
    }.contains(match.programId);

SahOutputKind programOutputKind(ProgramMatch match) =>
    !programHasFormWorkflow(match)
    ? SahOutputKind.checklist
    : match.programId == 'rtp-home-repair'
    ? SahOutputKind.preparationWorksheet
    : SahOutputKind.officialFormDraft;

String programShortName(ProgramMatch match) => switch (match.programId) {
  'scfhp-eaa' => 'SCFHP',
  'hpsm-eaa' => 'HPSM',
  'rtp-home-repair' => 'Rebuilding Together Peninsula',
  'usda-section-504' => 'USDA Section 504',
  'va-hisa' => 'VA HISA',
  _ => match.programName,
};

String programOverviewName(
  BuildContext context,
  String programId,
  String fallbackName,
) => switch (programId) {
  'scfhp-eaa' => context.tr('SCFHP home accessibility'),
  'hpsm-eaa' => context.tr('HPSM home modifications'),
  'rtp-home-repair' => 'Rebuilding Together Peninsula',
  'usda-section-504' => context.tr('USDA Section 504 home repair'),
  'va-hisa' => context.tr('VA HISA home changes'),
  _ => fallbackName,
};

Future<bool> launchProgramSource(String value) async {
  final uri = Uri.tryParse(value);
  try {
    return uri != null &&
        uri.scheme == 'https' &&
        uri.host.isNotEmpty &&
        uri.userInfo.isEmpty &&
        await launchUrl(uri, mode: LaunchMode.externalApplication);
  } catch (_) {
    return false;
  }
}

Future<void> addProgramTask(
  BuildContext context,
  AppServices services,
  ProgramMatch program,
  String title,
) async {
  final progress = services.progress;
  if (progress == null) return;
  try {
    final caseId = services.coordinator.currentCase().caseId;
    await services.progressReady;
    final saved = await progress.refresh(caseId);
    if (!context.mounted) return;
    final operation = await Navigator.of(context).push<Map<String, Object?>>(
      MaterialPageRoute(
        builder: (_) => TaskEditorScreen(
          services: services,
          snapshot: saved,
          program: saved.programs
              .where((p) => p.id == program.programId)
              .firstOrNull,
          proposal: {
            'title': String.fromCharCodes(title.trim().runes.take(200)).trim(),
          },
        ),
      ),
    );
    if (operation == null) return;
    await progress.mutate(
      caseId,
      services.coordinator.currentCase().revision,
      operation,
    );
    await services.store.delete('progress-edit.$caseId');
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(context.tr('Task added'))));
    }
  } catch (error) {
    if (context.mounted) await showOperationError(context, error);
  }
}

Future<void> openResidentDetails(BuildContext context, AppServices services) =>
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ProfileEditorScreen(services: services),
      ),
    );

const _rtpApplication =
    'https://rebuildingtogetherpeninsula.my.salesforce-sites.com/HomeownerApplication';

class IsoDateField extends StatelessWidget {
  const IsoDateField({
    super.key,
    required this.controller,
    required this.label,
    this.enabled = true,
    this.onChanged,
    this.optional = false,
    this.errorText,
    this.focusNode,
  });
  final TextEditingController controller;
  final String label;
  final bool enabled, optional;
  final VoidCallback? onChanged;
  final String? errorText;
  final FocusNode? focusNode;

  Future<void> _pick(BuildContext context) async {
    final now = DateTime.now();
    final current = DateTime.tryParse(controller.text.trim());
    final last = DateTime(now.year + 5, 12, 31);
    final picked = await showDatePicker(
      context: context,
      initialDate: current == null || current.isAfter(last)
          ? now
          : current.isBefore(DateTime(1900))
          ? DateTime(1900)
          : current,
      firstDate: DateTime(1900),
      lastDate: last,
      helpText: label,
    );
    if (picked == null) return;
    controller.text = picked.toIso8601String().substring(0, 10);
    onChanged?.call();
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: controller,
    builder: (context, value, _) {
      final parsed = DateTime.tryParse(value.text.trim());
      final shown = value.text.trim().isEmpty
          ? context.tr(optional ? 'Not set' : 'Not provided')
          : parsed == null
          ? value.text
          : MaterialLocalizations.of(context).formatFullDate(parsed);
      return Row(
        children: [
          Expanded(
            child: Semantics(
              button: true,
              label: '$label, $shown',
              excludeSemantics: true,
              child: InkWell(
                focusNode: focusNode,
                onTap: enabled ? () => _pick(context) : null,
                child: InputDecorator(
                  isEmpty: false,
                  decoration: InputDecoration(
                    enabled: enabled,
                    errorText: errorText,
                    suffixIcon: const Icon(Icons.calendar_today_outlined),
                  ),
                  child: Text(shown),
                ),
              ),
            ),
          ),
          if (value.text.trim().isNotEmpty)
            IconButton(
              tooltip: context.tr('Clear date'),
              onPressed: enabled
                  ? () {
                      controller.clear();
                      onChanged?.call();
                    }
                  : null,
              icon: const Icon(Icons.close_rounded),
            ),
        ],
      );
    },
  );
}

enum _Step { questions, check, create, send, updates }

enum _Draft { none, current, stale, interrupted }

class ApplicationWorkspaceScreen extends StatefulWidget {
  const ApplicationWorkspaceScreen({
    super.key,
    required this.services,
    required this.program,
  });
  final AppServices services;
  final ProgramMatch program;

  @override
  State<ApplicationWorkspaceScreen> createState() =>
      _ApplicationWorkspaceScreenState();
}

class _ApplicationWorkspaceScreenState
    extends State<ApplicationWorkspaceScreen> {
  ProgramIntakeResponse? _intake;
  FormAnswersResponse? _answers;
  RequestHistory? _history;
  Map<String, Object?>? _export;
  bool _busy = true, _partial = false, _opening = false;
  int? _loadedRevision;
  late final String _caseId;
  late final int _generation;

  AppServices get _services => widget.services;
  ProgramMatch get _program => widget.program;
  bool get _worksheet =>
      programOutputKind(_program) == SahOutputKind.preparationWorksheet;

  @override
  void initState() {
    super.initState();
    _caseId = _services.coordinator.currentCase().caseId;
    _generation = _services.coordinator.generation;
    _services.coordinator.addListener(_changed);
    _load();
  }

  @override
  void dispose() {
    _services.coordinator.removeListener(_changed);
    super.dispose();
  }

  bool get _scopeCurrent {
    final c = _services.coordinator;
    return mounted &&
        c.isCurrent &&
        c.generation == _generation &&
        c.snapshot?.caseId == _caseId &&
        !c.hasUnsavedChanges;
  }

  CaseSnapshot _case() {
    if (!_scopeCurrent) throw MatchingApiException.forCode('STALE_RESPONSE');
    return _services.coordinator.currentCase();
  }

  void _changed() {
    if (!mounted) return;
    if (!_busy &&
        !_opening &&
        _scopeCurrent &&
        _services.coordinator.snapshot?.revision != _loadedRevision) {
      _load();
    } else {
      setState(() {});
    }
  }

  Future<void> _load() async {
    if (!_scopeCurrent) {
      setState(() => _busy = false);
      return;
    }
    setState(() => _busy = true);
    final snapshot = _case();
    final id = _program.programId;
    var partial = false;
    ProgramIntakeResponse? intake;
    FormAnswersResponse? answers;
    RequestHistory? history;
    Map<String, Object?>? export;
    try {
      intake = await _services.intake.readIntake(
        snapshot,
        programId: id,
        isCurrent: () => _scopeCurrent,
      );
    } catch (_) {
      partial = true;
    }
    try {
      answers = await _services.answers.readAnswers(
        _case(),
        programId: id,
        currentCase: _case,
        currentProgramId: () => id,
        currentContext: () => null,
      );
    } catch (_) {
      partial = true;
    }
    try {
      history = await _services.history.readHistory(
        ReadRequestHistoryRequest(
          caseId: snapshot.caseId,
          expectedCaseRevision: snapshot.revision,
          programId: id,
        ),
        currentCase: _case,
        currentProgramId: () => id,
        currentHistory: () => null,
        isCurrent: () => _scopeCurrent,
      );
    } catch (_) {
      partial = true;
    }
    try {
      export = await _services.store.readJson('export.$_caseId.$id');
    } catch (_) {
      export = null;
    }
    if (!mounted) return;
    setState(() {
      _intake = intake;
      _answers = answers;
      _history = history;
      _export = export;
      _partial = partial;
      _loadedRevision = snapshot.revision;
      _busy = false;
    });
  }

  bool get _questionsDone =>
      _intake != null &&
      (_intake!.definition.questions.isEmpty ||
          _intake!.saved?.questionnaireVersion ==
              _intake!.definition.questionnaireVersion);

  bool get _checked {
    final saved = _answers?.saved;
    return saved != null &&
        _answers!.isCurrent &&
        saved.answers.any((a) => a.value != null) &&
        saved.answers.every(
          (a) => a.value == null || a.reviewState == 'reviewed',
        );
  }

  bool get _sent =>
      _history?.events.any((e) => e.update.status == 'submitted') ?? false;

  _Draft get _draft {
    final request = _export?['request'];
    final snapshot = _services.coordinator.snapshot;
    if (request is! Map || snapshot == null) return _Draft.none;
    final matches =
        request['expectedCaseRevision'] == snapshot.revision &&
        _answers != null &&
        request['expectedFormContextId'] == _answers!.context.formContextId &&
        request['expectedAnswerRevision'] ==
            (_answers!.saved?.answerRevision ?? 0);
    if (!matches) return _Draft.stale;
    return _export?['completed'] == true ? _Draft.current : _Draft.interrupted;
  }

  _Step get _now => _sent
      ? _Step.updates
      : !_questionsDone
      ? _Step.questions
      : !_checked
      ? _Step.check
      : _draft != _Draft.current
      ? _Step.create
      : _Step.send;

  Iterable<RequirementCheck> _waiting(String? resolver) => _program.checks
      .where((c) => c.status == 'unknown' && c.resolvedBy == resolver);

  Future<void> _open(Widget screen) async {
    if (_opening) return;
    _opening = true;
    try {
      await Navigator.of(
        context,
      ).push(MaterialPageRoute<void>(builder: (_) => screen));
    } finally {
      _opening = false;
    }
    if (mounted && _scopeCurrent) await _load();
  }

  Widget _screenFor(_Step step) => switch (step) {
    _Step.questions => ProgramIntakeScreen(
      services: _services,
      program: _program,
    ),
    _Step.check => FormReviewScreen(services: _services, program: _program),
    _Step.create => PrivateExportScreen(services: _services, program: _program),
    _Step.send => SendApplicationScreen(services: _services, program: _program),
    _Step.updates => RequestHistoryScreen(
      services: _services,
      program: _program,
    ),
  };

  String _createLabel(BuildContext context) =>
      context.tr(_worksheet ? 'Create worksheet' : 'Create draft PDF');

  String _sendLabel(BuildContext context) => _worksheet
      ? context.tr('Contact {program}', {'program': programShortName(_program)})
      : context.tr('Send it yourself');

  String _stepTitle(BuildContext context, _Step step) => switch (step) {
    _Step.questions => context.tr('Program questions'),
    _Step.check => context.tr('Check answers'),
    _Step.create =>
      _draft == _Draft.stale
          ? context.tr('Update draft')
          : _draft == _Draft.interrupted
          ? context.tr('Finish draft')
          : _createLabel(context),
    _Step.send => _sendLabel(context),
    _Step.updates => context.tr('Updates'),
  };

  String _stepMessage(BuildContext context, _Step step) => switch (step) {
    _Step.questions => context.tr(
      'Answer what you know. “Not sure” is fine. Saved as you go.',
    ),
    _Step.check => context.tr(
      'Check the details that go on the draft, then confirm them once.',
    ),
    _Step.create => context.tr(
      _worksheet
          ? 'The worksheet uses the answers you confirmed. It is not the program’s application.'
          : 'The draft uses the answers you confirmed. Signature, consent and the professional’s sections stay blank.',
    ),
    _Step.send => context.tr(
      _worksheet
          ? 'Bring the worksheet when you contact them. The app can’t apply for you.'
          : 'The app can’t send it. Ask the program how they accept it.',
    ),
    _Step.updates => context.tr(
      'Add what happens: received, needs information, approved or denied.',
    ),
  };

  @override
  Widget build(BuildContext context) {
    final short = programShortName(_program);
    final current = _scopeCurrent;
    final now = _now;
    final draft = _draft;
    final professional = _waiting('professional').isNotEmpty;
    final others =
        _waiting('program').length +
        _waiting('professional').length +
        _waiting(null).length;
    var number = 0;
    SahStepTile step(
      _Step? target,
      String title,
      String subtitle, {
      bool done = false,
      bool isNow = false,
      String? tag,
      Key? key,
    }) => SahStepTile(
      key: key,
      number: ++number,
      title: title,
      subtitle: subtitle,
      state: done
          ? SahStepState.done
          : isNow
          ? SahStepState.inProgress
          : SahStepState.notStarted,
      current: isNow,
      tag: tag,
      onTap: target == null || !current || _busy
          ? null
          : () => _open(_screenFor(target)),
    );
    final questionCount = _intake?.definition.questions.length ?? 0;
    final answered =
        _intake?.saved?.answers.where((a) => a.value != null).length ?? 0;
    return Scaffold(
      appBar: AppBar(title: Text(short)),
      body: SafeArea(
        child: SahContent(
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              SahPageHeader(title: short),
              Wrap(
                spacing: 12,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  SahOutputLabel(kind: programOutputKind(_program)),
                  SahTag(label: context.tr('Prepared in English')),
                  SahTag(
                    key: const ValueKey('workspace-status'),
                    label: context.tr(
                      _sent ? 'Sent (you recorded)' : 'Draft · not sent',
                    ),
                    tone: _sent ? SahNoticeTone.success : SahNoticeTone.warning,
                  ),
                ],
              ),
              const SizedBox(height: 8),
              if (_busy)
                LinearProgressIndicator(
                  semanticsLabel: context.tr('Checking your application steps'),
                ),
              if (!current)
                SahNotice(
                  message: context.tr(
                    'The case changed. Refresh these results before preparing a draft.',
                  ),
                  tone: SahNoticeTone.warning,
                ),
              if (_partial && !_busy && current)
                SahNotice(
                  message: context.tr(
                    'Some steps couldn’t be checked. Check your connection, then refresh.',
                  ),
                  tone: SahNoticeTone.warning,
                  action: TextButton(
                    key: const ValueKey('workspace-refresh'),
                    onPressed: _load,
                    child: Text(context.tr('Refresh')),
                  ),
                ),
              if (!_busy && draft == _Draft.interrupted && !_sent)
                SahNotice(
                  title: context.tr('The draft wasn’t finished'),
                  message: context.tr(
                    'The app closed while making it. Nothing was shared.',
                  ),
                  tone: SahNoticeTone.warning,
                ),
              if (!_busy && draft == _Draft.stale && !_sent)
                SahNotice(
                  key: const ValueKey('workspace-stale-draft'),
                  title: context.tr(
                    'Something changed after this draft was made',
                  ),
                  message: context.tr(
                    'Answers or concerns changed. Update the draft so it matches before you share or send it.',
                  ),
                  tone: SahNoticeTone.warning,
                ),
              if (!_busy)
                SahNextStepCard(
                  label: context.tr('Now'),
                  title: _stepTitle(context, now),
                  message: _stepMessage(context, now),
                  actionLabel: context.tr(
                    now == _Step.create && draft == _Draft.stale
                        ? 'Update draft'
                        : now == _Step.create && draft == _Draft.interrupted
                        ? 'Finish draft'
                        : 'Continue',
                  ),
                  actionKey: const ValueKey('workspace-now'),
                  onAction: current ? () => _open(_screenFor(now)) : null,
                ),
              SahListGroup(
                children: [
                  step(
                    _Step.questions,
                    context.tr('Program questions'),
                    _questionsDone
                        ? context.tr('Done')
                        : context.tr('{answered} of {total} answered', {
                            'answered': answered,
                            'total': questionCount,
                          }),
                    done: _questionsDone,
                    isNow: now == _Step.questions,
                    key: const ValueKey('workspace-step-questions'),
                  ),
                  step(
                    _Step.check,
                    context.tr('Check answers'),
                    _checked
                        ? context.tr('Confirmed')
                        : context.tr('Names, dates and contact details'),
                    done: _checked,
                    isNow: now == _Step.check,
                    key: const ValueKey('workspace-step-check'),
                  ),
                  step(
                    _Step.create,
                    context.tr('Photos and measurements'),
                    context.tr(
                      'Optional · only confirmed concerns can be included',
                    ),
                    key: const ValueKey('workspace-step-photos'),
                  ),
                  if (professional)
                    step(
                      null,
                      context.tr('Professional review'),
                      context.tr(
                        'Outside the app · a qualified professional completes their part',
                      ),
                      tag: context.tr('You arrange'),
                    ),
                  step(
                    _Step.create,
                    _createLabel(context),
                    switch (draft) {
                      _Draft.none => context.tr('After checking answers'),
                      _Draft.current => context.tr(
                        'Made from your current answers',
                      ),
                      _Draft.stale => context.tr('Out of date — update it'),
                      _Draft.interrupted => context.tr(
                        'Not finished — finish it',
                      ),
                    },
                    done: draft == _Draft.current,
                    isNow: now == _Step.create,
                    key: const ValueKey('workspace-step-create'),
                  ),
                  step(
                    _Step.send,
                    _sendLabel(context),
                    _sent
                        ? context.tr('You recorded that it was sent')
                        : context.tr('You send it — the app can’t'),
                    done: _sent,
                    isNow: now == _Step.send,
                    key: const ValueKey('workspace-step-send'),
                  ),
                  step(
                    _Step.updates,
                    context.tr('Updates'),
                    _history?.events.isNotEmpty == true
                        ? context.tr('{count} recorded', {
                            'count': _history!.events.length,
                          })
                        : context.tr('None yet'),
                    isNow: now == _Step.updates,
                    key: const ValueKey('workspace-step-updates'),
                  ),
                ],
              ),
              if (others > 0)
                SahListGroup(
                  title: context.tr('Waiting on others'),
                  children: [
                    SahActionTile(
                      key: const ValueKey('workspace-waiting'),
                      icon: Icons.groups_outlined,
                      title: context.tr(
                        others == 1
                            ? '1 thing the program or a professional must confirm'
                            : '{count} things the program or a professional must confirm',
                        {'count': others},
                      ),
                      subtitle: context.tr(
                        'Refreshing won’t change these. Ask the program.',
                      ),
                      enabled: current,
                      onTap: () => _open(
                        DraftPacketScreen(
                          snapshot: _services.coordinator.currentCase(),
                          program: _program,
                          service: ApiPacketPreparationService(
                            _services.packets,
                          ),
                          currentCase: _services.coordinator.currentCase,
                          caseChanges: _services.coordinator,
                          onResidentDetails: () =>
                              openResidentDetails(context, _services),
                          onAddTask: _services.progress == null
                              ? null
                              : (title) => addProgramTask(
                                  context,
                                  _services,
                                  _program,
                                  title,
                                ),
                        ),
                      ),
                    ),
                  ],
                ),
              ExpansionTile(
                key: const ValueKey('workspace-about'),
                tilePadding: EdgeInsets.zero,
                title: Text(
                  context.tr(
                    _worksheet ? 'About this worksheet' : 'About this form',
                  ),
                ),
                expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
                childrenPadding: const EdgeInsets.only(bottom: 12),
                children: [
                  Text(
                    _program.programName,
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    context.tr(
                      _worksheet
                          ? 'An app-made summary of the resident, rooms and concerns. It is not the program’s application form.'
                          : 'A draft of the program’s form, filled from answers you confirm.',
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    context.tr(
                      'Prepared in English; your saved answers aren’t translated. Signature, consent and the professional’s sections are always left blank for you to complete by hand.',
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    context.tr('Rule version: {version}', {
                      'version': _program.ruleVersion,
                    }),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class SendApplicationScreen extends StatefulWidget {
  const SendApplicationScreen({
    super.key,
    required this.services,
    required this.program,
  });
  final AppServices services;
  final ProgramMatch program;

  @override
  State<SendApplicationScreen> createState() => _SendApplicationScreenState();
}

class _SendApplicationScreenState extends State<SendApplicationScreen> {
  String? _error;

  Future<void> _source(String url) async {
    final ok = await launchProgramSource(url);
    if (!ok && mounted) {
      setState(
        () => _error =
            'The official page could not be opened. You can copy its address from Program sources.',
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final program = widget.program;
    final short = programShortName(program);
    final worksheet =
        programOutputKind(program) == SahOutputKind.preparationWorksheet;
    final professional = program.checks.any(
      (c) => c.status == 'unknown' && c.resolvedBy == 'professional',
    );
    return Scaffold(
      appBar: AppBar(
        title: Text(worksheet ? short : context.tr('Send it yourself')),
      ),
      body: SafeArea(
        child: SahContent(
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              SahPageHeader(
                title: worksheet
                    ? context.tr('Contact {program}', {'program': short})
                    : context.tr('Send it to {program} yourself', {
                        'program': short,
                      }),
                description: context.tr(
                  'The app can’t send applications. You choose how to send it.',
                ),
              ),
              if (_error != null)
                SahNotice(
                  message: context.tr(_error!),
                  tone: SahNoticeTone.error,
                ),
              SahNotice(
                title: worksheet
                    ? context.tr('Bring the worksheet when you apply')
                    : context.tr('Ask {program} how to send it', {
                        'program': short,
                      }),
                message:
                    program.intake ??
                    context.tr(
                      'Contact instructions are not supplied. Use the program sources to confirm the accepted intake route.',
                    ),
                tone: SahNoticeTone.warning,
              ),
              SahListGroup(
                title: context.tr('Before you send'),
                children: [
                  if (professional)
                    SahActionTile(
                      icon: Icons.badge_outlined,
                      title: context.tr(
                        'A qualified professional completes their section',
                      ),
                      subtitle: context.tr('Outside the app'),
                    ),
                  SahActionTile(
                    icon: Icons.draw_outlined,
                    title: worksheet
                        ? context.tr('The program’s own application')
                        : context.tr('The resident signs by hand'),
                    subtitle: worksheet
                        ? context.tr('The worksheet doesn’t replace it')
                        : context.tr('The app never signs'),
                  ),
                ],
              ),
              if (program.programId == 'rtp-home-repair')
                OutlinedButton.icon(
                  onPressed: () => _source(_rtpApplication),
                  icon: const Icon(Icons.open_in_new),
                  label: Text(context.tr('Open RTP’s official application')),
                ),
              for (final source in program.sources)
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: TextButton.icon(
                    onPressed: () => _source(source.url),
                    icon: const Icon(Icons.open_in_new),
                    label: Text(source.title),
                  ),
                ),
              SahSectionHeading(
                title: context.tr(
                  worksheet ? 'After you apply' : 'After you send it',
                ),
              ),
              FilledButton(
                key: const ValueKey('workspace-record-sent'),
                onPressed: () async {
                  final navigator = Navigator.of(context);
                  await navigator.push(
                    MaterialPageRoute<void>(
                      builder: (_) => RequestHistoryScreen(
                        services: widget.services,
                        program: program,
                        initialStatus: 'submitted',
                      ),
                    ),
                  );
                  if (mounted) navigator.pop();
                },
                child: Text(
                  context.tr(worksheet ? 'I applied with them' : 'I sent it'),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                context.tr(
                  'This records what you did. The app can’t see whether the program received it.',
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
