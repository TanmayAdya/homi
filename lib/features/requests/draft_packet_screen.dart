import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:safe_at_home/l10n/app_localizations.dart';

import '../../shared/models/contracts.dart';
import '../../shared/models/draft_packet.dart';
import '../../shared/presentation/sah_components.dart';
import '../../shared/services/matching_api_client.dart';
import '../../shared/services/packet_preparation_service.dart';
import 'application_workspace_screen.dart';

class DraftPacketScreen extends StatefulWidget {
  const DraftPacketScreen({
    super.key,
    required this.snapshot,
    required this.program,
    required this.service,
    required this.currentCase,
    this.caseChanges,
    this.now,
    this.onContact,
    this.onUpdates,
    this.onResidentDetails,
    this.onAddTask,
  });

  final CaseSnapshot snapshot;
  final ProgramMatch program;
  final PacketPreparationService service;
  final CaseSnapshot Function() currentCase;

  final Listenable? caseChanges;
  final DateTime Function()? now;

  final VoidCallback? onContact, onUpdates;

  final VoidCallback? onResidentDetails;
  final void Function(String title)? onAddTask;

  @override
  State<DraftPacketScreen> createState() => _DraftPacketScreenState();
}

class _DraftPacketScreenState extends State<DraftPacketScreen>
    with WidgetsBindingObserver {
  late String _generationKey;
  late Future<DraftPacket> _preparation;
  Timer? _expiryTimer;

  DateTime _now() => (widget.now ?? DateTime.now)().toUtc();

  void _refresh() {
    if (mounted) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh();
  }

  @override
  void dispose() {
    _expiryTimer?.cancel();
    widget.caseChanges?.removeListener(_refresh);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.caseChanges?.addListener(_refresh);
    _generationKey = _newKey();
    _preparation = _prepare();
  }

  @override
  void didUpdateWidget(covariant DraftPacketScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.caseChanges != widget.caseChanges) {
      oldWidget.caseChanges?.removeListener(_refresh);
      widget.caseChanges?.addListener(_refresh);
    }
    if (oldWidget.snapshot.caseId != widget.snapshot.caseId ||
        oldWidget.snapshot.revision != widget.snapshot.revision ||
        oldWidget.program.programId != widget.program.programId ||
        oldWidget.program.ruleVersion != widget.program.ruleVersion ||
        oldWidget.service != widget.service) {
      _expiryTimer?.cancel();
      _generationKey = _newKey();
      _preparation = _prepare();
    }
  }

  String _newKey() {
    final random = Random.secure();
    return base64UrlEncode(List.generate(24, (_) => random.nextInt(256)));
  }

  Future<DraftPacket> _prepare() async {
    final key = _generationKey;
    final packet = await widget.service.prepare(
      widget.snapshot,
      programId: widget.program.programId,
      generationKey: _generationKey,
      currentCase: widget.currentCase,
    );
    final current = widget.currentCase();
    if (packet.caseId != current.caseId ||
        packet.caseRevision != current.revision ||
        packet.programId != widget.program.programId) {
      throw MatchingApiException.forCode('STALE_RESPONSE');
    }
    if (packet.isDemo != widget.program.isDemo) {
      throw MatchingApiException.forCode('UNEXPECTED_RESPONSE');
    }
    if (mounted && key == _generationKey && !widget.service.isSavedExample) {
      _armExpiry(packet, key);
    }
    return packet;
  }

  void _armExpiry(DraftPacket packet, String key) {
    _expiryTimer?.cancel();
    final deadline = packet.recheckAfter;
    if (deadline == null) return;
    final remaining = DateTime.parse(deadline).difference(_now());
    if (remaining <= Duration.zero) return;
    final delay = Duration(
      milliseconds: (remaining.inMicroseconds + 999) ~/ 1000,
    );
    _expiryTimer = Timer(delay, () {
      if (!mounted || key != _generationKey) return;
      _armExpiry(packet, key);
      _refresh();
    });
  }

  void _retry({bool newGeneration = false}) {
    setState(() {
      if (newGeneration) _generationKey = _newKey();
      _preparation = _prepare();
    });
  }

  Widget _errorPanel(Object? error) {
    final code = error is MatchingApiException ? error.code : null;
    final stale = code == 'CASE_REVISION_MISMATCH' || code == 'STALE_RESPONSE';
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SahNotice(
              title: context.tr('Checklist unavailable'),
              message: error is MatchingApiException
                  ? context.tr(error.message)
                  : context.tr(
                      'The draft checklist could not be loaded. Please try again.',
                    ),
              tone: SahNoticeTone.warning,
            ),
            const SizedBox(height: 16),
            if (!stale)
              FilledButton(
                onPressed: () =>
                    _retry(newGeneration: code == 'PACKET_GENERATION_CONFLICT'),
                child: Text(
                  code == 'PACKET_GENERATION_CONFLICT'
                      ? context.tr('Prepare a new draft')
                      : context.tr('Try again'),
                ),
              ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(context.tr('Return to program results')),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(
        context.tr(
          programHasFormWorkflow(widget.program)
              ? 'What’s still needed'
              : 'Checklist',
        ),
      ),
    ),

    body: SafeArea(
      child: FutureBuilder<DraftPacket>(
        future: _preparation,
        builder: (context, state) {
          if (state.connectionState != ConnectionState.done) {
            return Center(
              child: CircularProgressIndicator(
                semanticsLabel: context.tr('Preparing draft checklist'),
              ),
            );
          }
          if (state.hasError || !state.hasData) return _errorPanel(state.error);
          final CaseSnapshot current;
          try {
            current = widget.currentCase();
          } catch (_) {
            return _errorPanel(MatchingApiException.forCode('STALE_RESPONSE'));
          }
          if (state.data!.caseId != current.caseId ||
              state.data!.caseRevision != current.revision) {
            return _errorPanel(MatchingApiException.forCode('STALE_RESPONSE'));
          }
          return _Checklist(
            packet: state.data!,
            program: widget.program,
            snapshot: current,
            now: _now(),
            savedExample: widget.service.isSavedExample,
            onContact: widget.onContact,
            onUpdates: widget.onUpdates,
            onResidentDetails: widget.onResidentDetails,
            onAddTask: widget.onAddTask,
          );
        },
      ),
    ),
  );
}

class _Checklist extends StatelessWidget {
  const _Checklist({
    required this.packet,
    required this.program,
    required this.snapshot,
    required this.savedExample,
    required this.now,
    this.onContact,
    this.onUpdates,
    this.onResidentDetails,
    this.onAddTask,
  });
  final VoidCallback? onContact, onUpdates, onResidentDetails;
  final void Function(String title)? onAddTask;
  final DraftPacket packet;
  final ProgramMatch program;
  final CaseSnapshot snapshot;
  final bool savedExample;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final checklistRoute = !programHasFormWorkflow(program);
    final fresh = packet.isFreshFor(
      snapshot,
      programId: program.programId,
      ruleVersion: program.ruleVersion,
      formVersion: null,
      mappingVersion: null,
      now: now,
    );
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SahFeaturePanel(
                title: programShortName(program),
                description: context.tr(
                  checklistRoute
                      ? 'Checklist — no form in this app'
                      : 'Draft only · Nothing has been submitted.',
                ),
              ),
              if (programShortName(program) != program.programName)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(program.programName),
                ),
              if (Localizations.localeOf(context).languageCode != 'en')
                SahNotice(
                  message: context.tr(
                    'Program information and official forms may remain in English. Your saved answers are not translated.',
                  ),
                ),
              const SizedBox(height: 20),
              if (packet.isDemo) ...[
                Align(
                  alignment: Alignment.centerLeft,
                  child: SahStatusBadge(
                    label: savedExample
                        ? context.tr('Fictional saved example')
                        : context.tr('Fictional demo'),
                    icon: Icons.science_outlined,
                  ),
                ),
                const SizedBox(height: 12),
              ],
              if (savedExample)
                SahNotice(
                  message: context.tr(
                    'This saved checklist shows the next steps. It is not an application for a real program.',
                  ),
                )
              else if (!fresh)
                SahNotice(
                  message: context.tr(
                    'This draft needs a fresh review. Refresh program results first.',
                  ),
                  tone: SahNoticeTone.warning,
                )
              else
                const SizedBox.shrink(),
              const SizedBox(height: 16),
              if (program.status == 'does_not_meet_criterion')
                SahNotice(
                  message: context.tr(
                    'A requirement was not met. Review that result with the program before proceeding.',
                  ),
                  tone: SahNoticeTone.warning,
                )
              else if (program.status == 'needs_confirmation')
                SahNotice(
                  message: context.tr(
                    'Some requirements still need confirmation.',
                  ),
                  tone: SahNoticeTone.warning,
                ),
              SahSectionHeading(title: context.tr('Your draft materials')),
              _MaterialSummary(
                icon: Icons.description_outlined,
                title: context.tr(
                  program.programId == 'rtp-home-repair'
                      ? 'Preparation worksheet'
                      : 'Application form',
                ),
                message: program.programId == 'rtp-home-repair'
                    ? context.tr(
                        'App-generated worksheet, not an RTP application. Complete the official intake separately.',
                      )
                    : checklistRoute
                    ? context.tr(
                        'This route has no form in the app. Use this checklist, then apply with the program.',
                      )
                    : packet.formVersion == null ||
                          packet.mappingVersion == null ||
                          packet.storageReference == null
                    ? context.tr(
                        'Official form not prepared. Its fields are unverified.',
                      )
                    : context.tr(
                        'Still a draft. Nothing is opened or submitted here.',
                      ),
              ),
              const SizedBox(height: 16),
              _MaterialSummary(
                icon: Icons.photo_library_outlined,
                title: context.tr('Supporting evidence'),
                message: packet.attachments.isEmpty
                    ? context.tr('No evidence files attached.')
                    : context.tr(
                        packet.attachments.length == 1
                            ? '1 evidence reference recorded. Files are not shown here.'
                            : '{count} evidence references recorded. Files are not shown here.',
                        {'count': packet.attachments.length},
                      ),
              ),
              SahSectionHeading(title: context.tr('What is needed next')),
              if (packet.missingItems.isEmpty)
                Text(
                  context.tr(
                    'No checklist items were returned. The program must still review any application.',
                  ),
                ),
              for (final role in const ['resident', 'professional', 'program'])
                if (packet.missingItems.any((i) => i.resolvedBy == role)) ...[
                  const SizedBox(height: 8),
                  _RoleHeading(
                    role: role,
                    count: packet.missingItems
                        .where((i) => i.resolvedBy == role)
                        .length,
                  ),
                  for (final item in packet.missingItems.where(
                    (i) => i.resolvedBy == role,
                  ))
                    if (role == 'program' && onContact != null)
                      Padding(
                        padding: const EdgeInsets.only(left: 24),
                        child: ListTile(
                          key: ValueKey('checklist-item-${item.id}'),
                          contentPadding: const EdgeInsets.only(left: 12),
                          title: Text(
                            item.description,
                            style: theme.textTheme.bodyLarge,
                          ),
                          subtitle: Text(context.tr('Ask the program')),
                          trailing: const Icon(Icons.chevron_right_rounded),
                          onTap: onContact,
                        ),
                      )
                    else if (role != 'program' && onAddTask != null)
                      Padding(
                        padding: const EdgeInsets.only(left: 24),
                        child: ListTile(
                          key: ValueKey('checklist-item-${item.id}'),
                          contentPadding: const EdgeInsets.only(left: 12),
                          title: Text(
                            item.description,
                            style: theme.textTheme.bodyLarge,
                          ),
                          subtitle: Text(
                            context.tr(
                              role == 'professional'
                                  ? 'Ask a doctor or therapist'
                                  : onResidentDetails != null
                                  ? 'Update resident details or add a task'
                                  : 'Add it to your tasks',
                            ),
                          ),
                          onTap: role == 'resident'
                              ? onResidentDetails ??
                                    () => onAddTask!(item.description)
                              : () => onAddTask!(item.description),
                          trailing: TextButton.icon(
                            key: ValueKey('checklist-add-task-${item.id}'),
                            onPressed: () => onAddTask!(item.description),
                            icon: const Icon(Icons.add_task_rounded),
                            label: Text(context.tr('Add task')),
                          ),
                        ),
                      )
                    else
                      Padding(
                        padding: const EdgeInsets.only(left: 36, bottom: 12),
                        child: Text(
                          item.description,
                          style: theme.textTheme.bodyLarge,
                        ),
                      ),
                ],
              if (onContact != null || onUpdates != null) ...[
                SahSectionHeading(title: context.tr('Apply with the program')),
                if (onContact != null)
                  FilledButton.icon(
                    key: const ValueKey('checklist-contact'),
                    onPressed: onContact,
                    icon: const Icon(Icons.call_outlined),
                    label: Text(context.tr('Contact program')),
                  ),
                if (onUpdates != null) ...[
                  const SizedBox(height: 8),
                  OutlinedButton(
                    key: const ValueKey('checklist-updates'),
                    onPressed: onUpdates,
                    child: Text(context.tr('Record an update')),
                  ),
                ],
                const SizedBox(height: 8),
                Text(
                  context.tr(
                    'The app doesn’t apply for you. Record what happens after you contact the program.',
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _RoleHeading extends StatelessWidget {
  const _RoleHeading({required this.role, required this.count});
  final String role;
  final int count;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ExcludeSemantics(
            child: Icon(switch (role) {
              'resident' => Icons.person_outline_rounded,
              'professional' => Icons.badge_outlined,
              _ => Icons.groups_outlined,
            }, color: theme.colorScheme.primary),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Semantics(
              header: true,
              child: Text(
                '${context.tr(switch (role) {
                  'resident' => 'For the resident',
                  'professional' => 'For a qualified professional',
                  _ => 'For the program team',
                })} · ${context.tr('{count} still needed', {'count': count})}',
                style: theme.textTheme.titleMedium,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MaterialSummary extends StatelessWidget {
  const _MaterialSummary({
    required this.icon,
    required this.title,
    required this.message,
  });
  final IconData icon;
  final String title, message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ExcludeSemantics(
          child: Icon(icon, color: theme.colorScheme.primary, size: 24),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: theme.textTheme.titleMedium),
              const SizedBox(height: 6),
              Text(message),
            ],
          ),
        ),
      ],
    );
  }
}
