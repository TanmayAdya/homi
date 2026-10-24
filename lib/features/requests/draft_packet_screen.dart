import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';

import '../../shared/models/contracts.dart';
import '../../shared/models/draft_packet.dart';
import '../../shared/services/matching_api_client.dart';
import '../../shared/services/packet_preparation_service.dart';

class DraftPacketScreen extends StatefulWidget {
  const DraftPacketScreen({
    super.key,
    required this.snapshot,
    required this.program,
    required this.service,
    required this.currentCase,
    this.caseChanges,
    this.now,
  });

  final CaseSnapshot snapshot;
  final ProgramMatch program;
  final PacketPreparationService service;
  final CaseSnapshot Function() currentCase;

  final Listenable? caseChanges;
  final DateTime Function()? now;

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
            Text(
              error is MatchingApiException
                  ? error.message
                  : 'The draft checklist could not be loaded. Please try again.',
            ),
            const SizedBox(height: 16),
            if (!stale)
              FilledButton(
                onPressed: () =>
                    _retry(newGeneration: code == 'PACKET_GENERATION_CONFLICT'),
                child: Text(
                  code == 'PACKET_GENERATION_CONFLICT'
                      ? 'Prepare a new draft'
                      : 'Try again',
                ),
              ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Return to program results'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Draft checklist')),
    body: SafeArea(
      child: FutureBuilder<DraftPacket>(
        future: _preparation,
        builder: (context, state) {
          if (state.connectionState != ConnectionState.done) {
            return const Center(
              child: CircularProgressIndicator(
                semanticsLabel: 'Preparing draft checklist',
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
  });
  final DraftPacket packet;
  final ProgramMatch program;
  final CaseSnapshot snapshot;
  final bool savedExample;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
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
              Text(program.programName, style: theme.textTheme.headlineSmall),
              const SizedBox(height: 16),
              if (packet.isDemo)
                Text(
                  savedExample ? 'Fictional saved example' : 'Fictional demo',
                  style: theme.textTheme.titleMedium,
                ),
              const SizedBox(height: 8),
              const Text('Draft only · Nothing has been submitted.'),
              const SizedBox(height: 16),
              if (savedExample)
                const Text(
                  'This saved checklist shows the next steps. It is not an application for a real program.',
                )
              else if (!fresh)
                const Text(
                  'This draft needs a fresh review before it can be used. Return to program results to check the latest information.',
                )
              else
                const Text(
                  'Review this checklist against the latest case and program information before using it.',
                ),
              const SizedBox(height: 16),
              if (program.status == 'does_not_meet_criterion')
                const Text(
                  'A requirement was not met. Review that result with the program before proceeding.',
                )
              else if (program.status == 'needs_confirmation')
                const Text('Some requirements still need confirmation.'),
              const SizedBox(height: 16),
              Text(
                packet.formVersion == null ||
                        packet.mappingVersion == null ||
                        packet.storageReference == null
                    ? 'Official form not prepared. The current form and its fields still need verification.'
                    : 'Any prepared form remains a draft for review. This preview does not open or submit files.',
              ),
              const SizedBox(height: 8),
              Text(
                packet.attachments.isEmpty
                    ? 'No evidence files attached.'
                    : '${packet.attachments.length} evidence references recorded. Files are not shown here.',
              ),
              const SizedBox(height: 24),
              Text('What is needed next', style: theme.textTheme.titleLarge),
              const SizedBox(height: 8),
              if (packet.missingItems.isEmpty)
                const Text(
                  'No checklist items were returned. The program must still review any application.',
                ),
              for (final item in packet.missingItems)
                Card(
                  margin: const EdgeInsets.symmetric(vertical: 6),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(item.description),
                        const SizedBox(height: 8),
                        Text(switch (item.resolvedBy) {
                          'resident' => 'Who can help: resident',
                          'professional' =>
                            'Who can help: qualified professional',
                          _ => 'Who can help: program team',
                        }, style: theme.textTheme.labelLarge),
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
