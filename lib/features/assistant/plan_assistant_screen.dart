import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../../l10n/app_language.dart';
import '../../l10n/app_localizations.dart';
import '../../shared/presentation/sah_components.dart';
import '../../shared/services/case_coordinator.dart';
import '../assessment/domain/assessment_location.dart';
import 'assistant_context.dart';
import 'assistant_context_v2.dart';
import '../../shared/navigation/homi_destination.dart';
import 'assistant_controller.dart';
import 'assistant_model.dart';
import 'assistant_history.dart';
import 'assistant_message_text.dart';

class PlanAssistantScreen extends StatefulWidget {
  const PlanAssistantScreen({
    super.key,
    required this.onSection,
    this.coordinator,
    this.appContextProvider,
    this.onTarget,
    this.model = const OnDeviceAssistantModel(),
    this.embedded = false,
  });

  final bool embedded;
  final ValueChanged<int> onSection;
  final CaseCoordinator? coordinator;
  final AssistantModel model;
  final AssistantContextV2? Function()? appContextProvider;
  final ValueChanged<HomiTarget>? onTarget;

  @override
  State<PlanAssistantScreen> createState() => _PlanAssistantScreenState();
}

class _PlanAssistantScreenState extends State<PlanAssistantScreen>
    with WidgetsBindingObserver {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  final _focus = FocusNode();
  AssistantController? _controller;
  int _draftEpoch = 0;
  String _conversationStamp = '';
  bool _showLatest = false;
  String? _locale;
  String? _scope;
  String? _inputConversation;
  bool _settingInput = false, _canPop = false;
  _AppHelpTopic? _guidanceTopic;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _input.addListener(_draftChanged);
    widget.coordinator?.addListener(_sourceChanged);
    widget.coordinator?.session.addListener(_sourceChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _configure();
  }

  @override
  void didUpdateWidget(PlanAssistantScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.coordinator != widget.coordinator ||
        oldWidget.model != widget.model) {
      oldWidget.coordinator?.removeListener(_sourceChanged);
      oldWidget.coordinator?.session.removeListener(_sourceChanged);
      widget.coordinator?.addListener(_sourceChanged);
      widget.coordinator?.session.addListener(_sourceChanged);
      _locale = null;
      _configure();
    }
  }

  String get _scopeKey {
    final source = widget.coordinator;
    return source == null
        ? 'demo'
        : '${source.session.epoch}:${source.isCurrent}:${source.draft?.caseId ?? 'app-help'}';
  }

  void _setInput(String value) {
    _settingInput = true;
    _input.text = value;
    _settingInput = false;
  }

  void _draftChanged() {
    if (!_settingInput) _controller?.setDraft(_input.text);
  }

  void _configure() {
    final locale = AppLanguage.forLocale(
      AppLocalizations.of(context).locale,
    ).code;
    if (locale == _locale && _scope == _scopeKey) return;
    _locale = locale;
    _scope = _scopeKey;
    _controller?.removeListener(_chatChanged);
    _controller?.dispose();
    _draftEpoch++;
    _setInput('');
    _inputConversation = null;
    _guidanceTopic = null;
    final source = widget.coordinator;
    final caseId = source?.draft?.caseId;
    final accountEpoch = source?.session.epoch;
    final history = source != null && source.isCurrent
        ? AssistantHistoryStore(
            store: source.store,
            caseId: caseId,
            participantId: 'owner:${source.store.accountId}',
            isCurrent: () =>
                source.isCurrent &&
                source.session.epoch == accountEpoch &&
                source.draft?.caseId == caseId,
          )
        : null;
    _controller = AssistantController(
      historyStore: history,
      model: widget.model,
      locale: locale,
      appContextProvider: widget.appContextProvider,
      contextProvider: _legacyContext,
    );
    _controller!.addListener(_chatChanged);
    unawaited(_controller!.check());
  }

  AssistantContext? _legacyContext() {
    final base = widget.coordinator == null
        ? const AssistantContext(key: 'app-help')
        : !widget.coordinator!.isCurrent
        ? null
        : widget.coordinator!.draft == null
        ? const AssistantContext(key: 'app-help')
        : assistantContextFor(widget.coordinator!);
    final app = widget.appContextProvider?.call();
    if (base == null ||
        (widget.appContextProvider != null && app?.authorized != true)) {
      return null;
    }
    return AssistantContext(
      key: '${base.key}:${app?.key ?? ''}',
      findings: base.findings,
    );
  }

  void _sourceChanged() {
    if (_scope != _scopeKey) {
      _configure();
      return;
    }
    if (_controller?.refreshContext() == true) {
      _draftEpoch++;
      _setInput(_controller?.draft ?? '');
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _sourceChanged();
      unawaited(_controller?.check());
    } else {
      _controller?.stop();
      _focus.unfocus();
      unawaited(_controller?.persist());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.coordinator?.removeListener(_sourceChanged);
    widget.coordinator?.session.removeListener(_sourceChanged);
    _controller?.removeListener(_chatChanged);
    _controller?.dispose();
    _input.removeListener(_draftChanged);
    _input.dispose();
    _scroll.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _chatChanged() {
    final c = _controller!;
    if (_inputConversation != c.conversationId && !c.historyLoading) {
      _inputConversation = c.conversationId;
      _setInput(c.draft);
    }
    final stamp =
        '${c.conversationId}:${c.turns.length}:${c.busy}:${c.errorCode}:${c.interruptedQuestion}:${c.turns.lastOrNull?.answer}';
    if (stamp == _conversationStamp) return;
    _conversationStamp = stamp;
    if (c.turns.isEmpty &&
        c.pendingQuestion == null &&
        c.interruptedQuestion == null &&
        c.errorCode == null) {
      if (_showLatest && mounted) setState(() => _showLatest = false);
      return;
    }
    final nearEnd = !_scroll.hasClients || _scroll.position.extentAfter < 100;
    if (nearEnd) {
      _latest();
    } else if (mounted) {
      setState(() => _showLatest = true);
    }
  }

  void _latest() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      if (_showLatest) setState(() => _showLatest = false);
      if (MediaQuery.disableAnimationsOf(context)) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      } else {
        unawaited(
          _scroll.animateTo(
            _scroll.position.maxScrollExtent,
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
          ),
        );
      }
    });
  }

  Future<void> _send([String? suggestion]) async {
    final c = _controller!;
    final question = suggestion ?? _input.text;
    if (!c.canSend || question.trim().isEmpty) return;
    final epoch = _draftEpoch;
    final scope = c.context?.key;
    _input.clear();
    final response = c.send(question);
    _latest();
    await response;
    if (!mounted ||
        c != _controller ||
        epoch != _draftEpoch ||
        scope != c.context?.key) {
      return;
    }
    if (c.errorCode != null && _input.text.isEmpty) _input.text = question;
  }

  void _stop() {
    final question = _controller!.pendingQuestion;
    _controller!.stop();
    if (question != null && _input.text.isEmpty) _input.text = question;
  }

  Future<bool> _saveBeforeLeaving() async {
    final c = _controller!;
    if (c.clearing || c.historyLoading || c.clearFailed) return false;
    c.stop();
    await c.persist();
    return mounted &&
        !c.saveFailed &&
        !c.historyLoadFailed &&
        !c.clearing &&
        !c.historyLoading;
  }

  Future<void> _close() async {
    if (!await _saveBeforeLeaving() || !mounted) return;
    setState(() => _canPop = true);
    await WidgetsBinding.instance.endOfFrame;
    if (mounted) Navigator.maybePop(context);
  }

  Future<void> _openSection(int index, {VoidCallback? beforeNavigate}) async {
    beforeNavigate?.call();
    if (!await _saveBeforeLeaving() || !mounted) return;
    widget.onSection(index);
  }

  Future<void> _clearHistory() async {
    final accepted = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        scrollable: true,
        title: Text(context.tr('Clear chat history?')),
        content: Text(
          context.tr(
            'This removes all saved chats for this plan and your account on this phone. It does not change your plan.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(context.tr('Cancel')),
          ),
          FilledButton(
            key: const ValueKey('assistant-confirm-clear'),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(context.tr('Clear history')),
          ),
        ],
      ),
    );
    if (accepted != true || !mounted) return;
    _draftEpoch++;
    _setInput('');
    _focus.unfocus();
    await _controller!.clearHistory();
  }

  Future<void> _history() async {
    final c = _controller!;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (sheetContext) => ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(sheetContext).height * .85,
        ),
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.all(20),
          children: [
            Text(
              context.tr('Previous conversations'),
              style: Theme.of(context).textTheme.titleLarge,
            ),
            for (final conversation in c.conversations.reversed)
              ListTile(
                key: ValueKey('assistant-history-${conversation.id}'),
                title: Text(
                  assistantExcerpt(
                    conversation.turns.firstOrNull?.question ??
                        conversation.interruptedQuestion ??
                        conversation.draft,
                    70,
                  ),
                ),
                subtitle: Text(
                  [
                    MaterialLocalizations.of(context).formatMediumDate(
                      DateTime.parse(conversation.updatedAt).toLocal(),
                    ),
                    context.tr(
                      conversation.turns.length >= 12
                          ? '{count} of 12 exchanges · full'
                          : '{count} of 12 exchanges',
                      {'count': conversation.turns.length},
                    ),
                  ].join(' · '),
                ),
                selected: conversation.id == c.conversationId,
                onTap: () async {
                  Navigator.pop(sheetContext);
                  _draftEpoch++;
                  await c.openConversation(conversation.id);
                  if (mounted) _setInput(c.draft);
                },
              ),
            if (c.conversations.isEmpty)
              Text(context.tr('No saved chats yet.')),
            const SizedBox(height: 8),
            Text(
              context.tr(
                'This phone can save 10 chats with 12 replies each. Saved chats stay available until you clear history.',
              ),
              style: Theme.of(context).textTheme.bodySmall,
            ),
            TextButton(
              onPressed: () => Navigator.pop(sheetContext),
              child: Text(context.tr('Close')),
            ),
          ],
        ),
      ),
    );
  }

  Future<T?> _sheet<T>(Widget Function(BuildContext sheetContext) body) {
    _focus.unfocus();
    return showModalBottomSheet<T>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (sheetContext) => ListenableBuilder(
        listenable: _controller!,
        builder: (_, _) => ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(sheetContext).height * .85,
          ),
          child: body(sheetContext),
        ),
      ),
    );
  }

  Widget _sheetTitle(BuildContext sheetContext, String title) => Row(
    children: [
      Expanded(
        child: Semantics(
          header: true,
          child: Text(title, style: Theme.of(context).textTheme.titleLarge),
        ),
      ),
      IconButton(
        tooltip: context.tr('Close'),
        onPressed: () => Navigator.pop(sheetContext),
        icon: const Icon(Icons.close),
      ),
    ],
  );

  Future<void> _options() async {
    final c = _controller!;
    await _sheet<void>(
      (sheetContext) => SingleChildScrollView(
        key: const ValueKey('assistant-options-list'),

        padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _sheetTitle(sheetContext, context.tr('Chat options')),
            ListTile(
              leading: const Icon(Icons.edit_square),
              title: Text(context.tr('New chat')),
              onTap:
                  c.historyLoading ||
                      c.historyLoadFailed ||
                      c.clearing ||
                      c.saveFailed
                  ? null
                  : () async {
                      Navigator.pop(sheetContext);
                      _draftEpoch++;
                      await c.newChat();
                      if (mounted) _setInput(c.draft);
                    },
            ),
            ListTile(
              leading: const Icon(Icons.history),
              title: Text(context.tr('Previous conversations')),
              onTap: c.historyLoading
                  ? null
                  : () {
                      Navigator.pop(sheetContext);
                      _history();
                    },
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: Text(context.tr('Clear history')),
              onTap: c.historyLoading || c.clearing
                  ? null
                  : () {
                      Navigator.pop(sheetContext);
                      _clearHistory();
                    },
            ),
            ListTile(
              key: const ValueKey('assistant-options-context'),
              leading: const Icon(Icons.info_outline),
              title: Text(context.tr('What the assistant uses')),
              onTap: () {
                Navigator.pop(sheetContext);
                _contextSheet();
              },
            ),
            ListTile(
              key: const ValueKey('assistant-options-guide'),
              leading: const Icon(Icons.menu_book_outlined),
              title: Text(context.tr('App guide — not AI')),
              onTap: () {
                Navigator.pop(sheetContext);
                _guideSheet();
              },
            ),
            ExpansionTile(
              title: Text(context.tr('Privacy and limits')),
              children: [
                for (final text in [
                  'Generated replies can be wrong. Confirm details in your plan.',
                  'Replies use this phone’s on-device model. Saved chats are encrypted on this phone for your account and plan. They are not shared or included in exports. Only two recent exchanges from unchanged plan context are used for follow-up questions. The assistant cannot change your plan, decide eligibility, or submit an application.',
                  if (defaultTargetPlatform == TargetPlatform.android)
                    'Google ML Kit handles Android model updates and sends device, app, diagnostic and usage metrics to Google. Chat text and replies stay on this phone.',
                ])
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(context.tr(text)),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  bool get _usesApp => widget.appContextProvider != null;

  String _contextLabel(AssistantController c) => context.tr(
    !_usesApp
        ? 'Uses: your question and recent messages'
        : c.includeFindings
        ? 'Uses: plan counts, statuses and concern notes'
        : 'Uses: plan counts and statuses',
  );

  Future<void> _contextSheet() async {
    final c = _controller!;
    Widget item(String text, bool included) => ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        included ? Icons.check_rounded : Icons.block_rounded,
        color: included
            ? Theme.of(context).colorScheme.primary
            : Theme.of(context).colorScheme.onSurfaceVariant,
      ),
      title: Text(context.tr(text)),
    );
    final findings = c.context?.findings ?? const <String>[];
    final canToggle =
        findings.isNotEmpty &&
        !c.busy &&
        !c.historyLoading &&
        !c.historyLoadFailed &&
        !c.clearing &&
        !c.saveFailed;
    await _sheet<void>(
      (sheetContext) => SingleChildScrollView(
        key: const ValueKey('assistant-context-sheet'),

        padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _sheetTitle(sheetContext, context.tr('What the assistant uses')),
            Text(
              context.tr(
                'It runs on this phone. Your questions and its replies stay on this phone.',
              ),
            ),
            if (defaultTargetPlatform == TargetPlatform.android) ...[
              const SizedBox(height: 8),
              Text(
                context.tr(
                  'Google ML Kit handles Android model updates and sends device, app, diagnostic and usage metrics to Google. Chat text and replies stay on this phone.',
                ),
              ),
            ],
            SahSectionHeading(title: context.tr('It can use')),
            if (_usesApp) ...[
              item('Which app sections and phone features are available', true),
              item(
                'Room types, how many questions are answered, how many concerns each room has, and whether a scan is saved',
                true,
              ),
              item('Concern review status', true),
              item('Task types, statuses and due dates', true),
              item(
                'Program check counts, and application and draft status',
                true,
              ),
            ],
            item('Your question and the last two exchanges in this chat', true),
            if (c.includeFindings) ...[
              item('Short notes from up to 4 confirmed concerns', true),
              for (final finding in findings)
                Padding(
                  padding: const EdgeInsetsDirectional.only(
                    start: 40,
                    bottom: 8,
                  ),
                  child: Text(finding),
                ),
            ],
            SahSectionHeading(title: context.tr('It can’t see')),
            item('Resident details', false),
            item('Photos, scans and measurements', false),
            item(
              c.includeFindings
                  ? 'Documents and other notes'
                  : 'Notes and documents',
              false,
            ),
            if (findings.isNotEmpty) ...[
              const SizedBox(height: 8),
              SwitchListTile.adaptive(
                key: const ValueKey('assistant-include-findings'),
                contentPadding: EdgeInsets.zero,
                title: Text(
                  context.tr(
                    'Include short notes from confirmed concerns (up to 4)',
                  ),
                ),
                subtitle: Text(context.tr('Changing this starts a new chat.')),
                value: c.includeFindings,
                onChanged: canToggle ? _confirmFindings : null,
              ),
            ],
            const SizedBox(height: 8),
            Text(
              context.tr(
                'It can make mistakes, and it doesn’t decide eligibility.',
              ),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmFindings(bool value) async {
    final accepted = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        scrollable: true,
        title: Text(
          context.tr(
            value
                ? 'Start a new chat with concern notes?'
                : 'Start a new chat without concern notes?',
          ),
        ),
        content: Text(
          context.tr(
            _controller!.historyStore == null
                ? 'The current chat will be cleared so earlier answers aren’t mixed up.'
                : 'The current chat stays in Previous conversations so earlier answers aren’t mixed up.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(context.tr('Cancel')),
          ),
          FilledButton(
            key: const ValueKey('assistant-confirm-findings'),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(context.tr('Start new chat')),
          ),
        ],
      ),
    );
    if (accepted == true && mounted) _controller!.useFindings(value);
  }

  Future<void> _guideSheet() async {
    _AppHelpTopic? topic;
    await _sheet<void>(
      (sheetContext) => StatefulBuilder(
        builder: (_, setSheet) => SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _sheetTitle(sheetContext, context.tr('App guide')),
              _appGuidance(
                _controller!,
                topic: topic,
                onTopic: (value) => setSheet(() => topic = value),
                beforeNavigate: () => Navigator.pop(sheetContext),
              ),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _shortcuts({VoidCallback? beforeNavigate}) => [
    if (!_usesApp)
      SahActionTile(
        key: const ValueKey('assistant-next-step'),
        title: context.tr('What should I do next?'),
        icon: Icons.arrow_forward_rounded,
        onTap: () => _openSection(0, beforeNavigate: beforeNavigate),
      ),
    SahActionTile(
      key: const ValueKey('assistant-rooms'),
      title: context.tr('Where are my scans and concerns?'),
      icon: Icons.view_in_ar,
      onTap: () => _openSection(1, beforeNavigate: beforeNavigate),
    ),
    SahActionTile(
      key: const ValueKey('assistant-help'),
      title: context.tr('Where can I find assistance?'),
      icon: Icons.support_agent_outlined,
      onTap: () => _openSection(2, beforeNavigate: beforeNavigate),
    ),
  ];

  String _availabilityText(AssistantAvailability value) => switch (value) {
    AssistantAvailability.ready => 'On-device chat',
    AssistantAvailability.requiresIos26 => 'Plan chat needs iOS 26 or later.',
    AssistantAvailability.requiresAndroid26 =>
      'Plan chat needs Android 8 or later. The other app tools still work.',
    AssistantAvailability.modelDownloadable =>
      'Download the on-device model to use chat. Wi-Fi is recommended. No chat text is included in the download.',
    AssistantAvailability.modelDownloading =>
      'The on-device model is downloading. Check again when it finishes.',
    AssistantAvailability.unsupportedDevice =>
      defaultTargetPlatform == TargetPlatform.android
          ? 'On-device chat is not supported on this Android phone.'
          : 'This iPhone does not support Apple Intelligence.',
    AssistantAvailability.disabled =>
      'Turn on Apple Intelligence in iPhone Settings, then check again.',
    AssistantAvailability.modelNotReady =>
      defaultTargetPlatform == TargetPlatform.android
          ? 'The on-device model is not ready. Update Android AICore, then check again.'
          : 'Apple’s on-device model is not ready. Check Apple Intelligence in Settings, then try again.',
    AssistantAvailability.unsupportedLanguage =>
      'The on-device model does not support the selected app language. You can keep using the help tools below.',
    AssistantAvailability.unsupportedPlatform =>
      'Plan chat needs a compatible iPhone or Android phone. You can keep using the help tools below.',
    AssistantAvailability.unavailable =>
      'Plan chat is unavailable right now. You can still use the help tools below.',
  };

  String _errorText(String code) => switch (code) {
    'CONVERSATION_LIMIT' =>
      'This chat is full. Start a new chat or clear history to send more questions.',
    'HISTORY_LIMIT' =>
      'Saved chat storage is full. Clear history to start another chat.',
    'REFUSED' =>
      'The model could not answer that request. Try asking about an app step or a confirmed finding.',
    'QUESTION_LIMIT' =>
      'Try a shorter question, or clear the conversation and ask again.',
    'CONTEXT_LIMIT' =>
      'This phone’s model cannot fit the current app context. Start a new chat without included findings, or use App guidance.',
    'INVALID_RESPONSE' =>
      'The model returned a reply the app could not verify. Try again or use App guidance.',
    'INVALID_INPUT' =>
      'The app could not prepare this request. Use App guidance or reopen the assistant.',
    'UNAVAILABLE' =>
      'The on-device model is unavailable. Check availability, or use App guidance.',
    'LANGUAGE' => 'The model cannot answer in that language on this phone.',
    'TIMEOUT' =>
      'The response took too long. Your question is still here to retry.',
    'BUSY' => 'The model is busy. Wait a moment, then try again.',
    'CANCELLED' => 'Response stopped.',
    'CONTEXT_CHANGED' => 'Context changed. Ask again for current information.',
    _ =>
      'The response could not be completed. Check availability and try again.',
  };

  Widget _appGuidance(
    AssistantController c, {
    required _AppHelpTopic? topic,
    required ValueChanged<_AppHelpTopic> onTopic,
    VoidCallback? beforeNavigate,
  }) {
    final current = widget.appContextProvider?.call();
    final reply = current == null || topic == null
        ? null
        : topic == _AppHelpTopic.prepareDraft
        ? current.draftPreparationReply()
        : current.deterministicReply();
    final enabled = !c.busy && c.context != null;
    final topics = [
      if (_usesApp)
        (
          _AppHelpTopic.nextStep,
          'What should I do next?',
          Icons.arrow_forward_rounded,
        ),
      (
        _AppHelpTopic.prepareDraft,
        'How do I prepare a draft?',
        Icons.description_outlined,
      ),
    ];
    return Column(
      key: const ValueKey('assistant-app-guidance'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SahSectionHeading(
          title: context.tr('App guide — not AI'),
          description: context.tr(
            'These app steps do not use a language model.',
          ),
        ),
        SahListGroup(
          children: [
            for (final (item, label, icon) in topics)
              SahActionTile(
                key: ValueKey('assistant-app-help-${item.name}'),
                title: context.tr(label),
                icon: icon,
                enabled: enabled,
                onTap: () {
                  _focus.unfocus();
                  onTopic(item);
                },
              ),
            ..._shortcuts(beforeNavigate: beforeNavigate),
          ],
        ),
        if (reply != null && current!.authorized)
          _sourceActions(
            current,
            reply,
            guidance: true,
            beforeNavigate: beforeNavigate,
          )
        else if (topic != null && c.context != null && current == null) ...[
          Text(
            context.tr(
              topic == _AppHelpTopic.prepareDraft
                  ? 'Open Help, choose a program, then open Prepare forms. Review the required answers and documents. Saving or sharing a draft does not submit an application.'
                  : 'Open Plan to create or select a plan.',
            ),
          ),
          const SizedBox(height: 8),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: OutlinedButton.icon(
              onPressed: () => _openSection(
                topic == _AppHelpTopic.prepareDraft ? 2 : 0,
                beforeNavigate: beforeNavigate,
              ),
              icon: const Icon(Icons.open_in_new),
              label: Text(
                context.tr('Open {section}', {
                  'section': context.tr(
                    topic == _AppHelpTopic.prepareDraft ? 'Help' : 'Plan',
                  ),
                }),
              ),
            ),
          ),
        ],
        const SizedBox(height: 16),
      ],
    );
  }

  Widget _savedSources(AssistantTurn turn) {
    final app = widget.appContextProvider?.call();
    if (app == null || app.key != turn.appContextKey) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: Text(
          context.tr(
            'This reply uses an earlier app state. Ask again for current sources.',
          ),
          style: Theme.of(context).textTheme.bodySmall,
        ),
      );
    }
    try {
      final reply = app.decodeReply(turn.appReplyJson!);
      if (reply.text != turn.answer) return const SizedBox.shrink();
      return _sourceActions(app, reply);
    } on FormatException {
      return const SizedBox.shrink();
    }
  }

  String _sectionLabel(HomiDestination d) => switch (d) {
    HomiDestination.plan => 'Plan',
    HomiDestination.rooms => 'Rooms',
    HomiDestination.help => 'Help',
    HomiDestination.tasks => 'Tasks',
    HomiDestination.settings => 'Account',
  };

  static const _programNames = {
    'scfhp-eaa': 'SCFHP',
    'hpsm-eaa': 'HPSM',
    'rtp-home-repair': 'RTP',
  };

  String _roomLabel(AssistantContextV2 app, String? roomId) {
    final type = app.sources
        .where(
          (s) =>
              s.kind == AssistantSourceKind.room && s.target.roomId == roomId,
        )
        .firstOrNull
        ?.facts['type'];
    final location = AssessmentLocation.values
        .where((l) => l.name == type)
        .firstOrNull;
    return context.tr(location?.title ?? 'Room');
  }

  String _sourceLabel(AssistantContextV2 app, AssistantSource s) {
    final program = _programNames[s.facts['program']];
    return switch (s.kind) {
      AssistantSourceKind.guide => context.tr(
        _sectionLabel(s.target.destination),
      ),
      AssistantSourceKind.room => _roomLabel(app, s.target.roomId),
      AssistantSourceKind.concern => context.tr('{room} concern', {
        'room': _roomLabel(app, s.target.roomId),
      }),
      AssistantSourceKind.task => context.tr('Task'),
      AssistantSourceKind.program => program ?? context.tr('Program'),
      AssistantSourceKind.preparation => context.tr('{program} application', {
        'program': program ?? context.tr('Program'),
      }),
    };
  }

  IconData _sourceIcon(AssistantSourceKind kind) => switch (kind) {
    AssistantSourceKind.guide => Icons.open_in_new,
    AssistantSourceKind.room => Icons.meeting_room_outlined,
    AssistantSourceKind.concern => Icons.report_outlined,
    AssistantSourceKind.task => Icons.checklist_rounded,
    AssistantSourceKind.program => Icons.support_agent_outlined,
    AssistantSourceKind.preparation => Icons.description_outlined,
  };

  Future<void> _openSource(
    AssistantReply reply,
    String sourceId, {
    VoidCallback? beforeNavigate,
  }) async {
    HomiTarget? validated() {
      final current = widget.appContextProvider?.call();
      if (current == null || !current.isReplyCurrent(reply)) return null;
      final source = current.sources.where((s) => s.id == sourceId).firstOrNull;
      return source == null ||
              !source.available ||
              source.target.caseId != current.caseId
          ? null
          : source.target;
    }

    if (validated() == null) return;
    beforeNavigate?.call();
    if (!await _saveBeforeLeaving() || !mounted) return;
    final target = validated();
    if (target != null) widget.onTarget?.call(target);
  }

  Widget _sourceActions(
    AssistantContextV2 app,
    AssistantReply reply, {
    bool guidance = false,
    VoidCallback? beforeNavigate,
  }) {
    final target = app.resolveOpen(reply);
    final sources = [
      for (final id in reply.sourceIds)
        ?app.sources.where((s) => s.id == id).firstOrNull,
    ];
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (guidance) ...[
            Text(context.tr(reply.text)),
            const SizedBox(height: 8),
            if (target != null && widget.onTarget != null)
              OutlinedButton.icon(
                icon: const Icon(Icons.open_in_new),
                label: Text(
                  context.tr('Open {section}', {
                    'section': context.tr(_sectionLabel(target.destination)),
                  }),
                ),
                onPressed: () => _openSource(
                  reply,
                  reply.openSourceId!,
                  beforeNavigate: beforeNavigate,
                ),
              ),
          ] else if (sources.isNotEmpty)
            Semantics(
              container: true,
              label: context.tr('Sources'),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final source in sources)
                    ActionChip(
                      key: ValueKey('assistant-source-${source.id}'),
                      avatar: Icon(_sourceIcon(source.kind), size: 18),
                      label: Text(_sourceLabel(app, source)),
                      tooltip: context.tr('Open {section}', {
                        'section': context.tr(
                          _sectionLabel(source.target.destination),
                        ),
                      }),
                      onPressed:
                          widget.onTarget == null ||
                              !source.available ||
                              source.target.caseId != app.caseId
                          ? null
                          : () => _openSource(reply, source.id),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _notCompleted(AssistantController c, {bool retry = false}) => Padding(
    padding: const EdgeInsets.only(bottom: 20),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          context.tr(
            'This response was not completed. Send the question again when you are ready.',
          ),
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        if (retry && c.availability == AssistantAvailability.ready) ...[
          const SizedBox(height: 4),
          OutlinedButton.icon(
            key: const ValueKey('assistant-retry-question'),
            onPressed: c.canSend ? () => _send(c.interruptedQuestion!) : null,
            icon: const Icon(Icons.refresh),
            label: Text(context.tr('Retry question')),
          ),
        ],
      ],
    ),
  );

  Widget _contextChip(AssistantController c) => Align(
    alignment: AlignmentDirectional.centerStart,
    child: Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: ActionChip(
        key: const ValueKey('assistant-context'),
        avatar: const Icon(Icons.info_outline, size: 18),
        label: Text(_contextLabel(c)),
        tooltip: context.tr('What the assistant uses'),
        onPressed: _contextSheet,
      ),
    ),
  );

  Widget _statusArea(AssistantController c) {
    if (c.checking) {
      return Semantics(
        liveRegion: true,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const LinearProgressIndicator(),
            const SizedBox(height: 12),
            Text(context.tr('Checking on-device chat…')),
          ],
        ),
      );
    }
    return SahNotice(
      key: const ValueKey('assistant-status'),
      title: context.tr('The assistant isn’t available'),
      message: context.tr(_availabilityText(c.availability)),
      action: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (c.errorCode != null && !c.busy) ...[
            Text(context.tr(_errorText(c.errorCode!))),
            const SizedBox(height: 8),
          ],
          if (c.busy) ...[
            const LinearProgressIndicator(),
            TextButton(onPressed: c.stop, child: Text(context.tr('Cancel'))),
          ],
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (c.availability == AssistantAvailability.modelDownloadable)
                FilledButton(
                  key: const ValueKey('assistant-download-model'),
                  onPressed: c.busy ? null : c.downloadModel,
                  child: Text(context.tr('Download on-device model')),
                ),
              OutlinedButton(
                key: const ValueKey('assistant-check-availability'),
                onPressed: c.busy ? null : () => c.check(),
                child: Text(context.tr('Check availability')),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _emptyState(AssistantController c) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            context.tr('How can I help?'),
            style: theme.textTheme.headlineSmall,
          ),
          const SizedBox(height: 8),
          Text(
            context.tr(
              'Ask about your plan or how to use the app. It can make mistakes, so check important answers.',
            ),
          ),
          const SizedBox(height: 8),
          Text(
            context.tr(
              c.historyStore == null
                  ? 'Chat stays on this phone and isn’t saved.'
                  : 'Chats save privately on this phone. You can reopen or clear them in Chat options.',
            ),
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 16),
          for (final (i, question) in const [
            'What should I do next?',
            'What does “Not sure” mean?',
            'How do drafts and sending work?',
          ].indexed)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: ActionChip(
                key: ValueKey('assistant-starter-$i'),
                label: Text(context.tr(question)),
                onPressed: c.canSend ? () => _send(context.tr(question)) : null,
              ),
            ),
        ],
      ),
    );
  }

  Widget _conversation(AssistantController c) {
    final available = c.availability == AssistantAvailability.ready;
    return ListView(
      key: const ValueKey('assistant-messages'),
      controller: _scroll,
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
      children: [
        if (c.historyLoading || c.clearing) const LinearProgressIndicator(),
        if (c.historyLoadFailed || c.saveFailed) ...[
          SahNotice(
            tone: SahNoticeTone.error,
            message: context.tr(
              c.historyLoadFailed
                  ? 'Saved chats could not be opened. Retry before starting another chat.'
                  : c.clearFailed
                  ? 'Chat history could not be cleared. Retry to finish removing it from this phone.'
                  : 'Chat could not be saved on this phone. Keep it open and retry.',
            ),
          ),
          TextButton(
            onPressed: c.clearing ? null : c.retryHistory,
            child: Text(context.tr('Retry')),
          ),
        ],
        if (!c.checking && available) _contextChip(c),
        if (c.checking || !available) _statusArea(c),
        if (c.conversationFull)
          SahNotice(
            message: context.tr(
              'This chat is full. Start a new chat or clear history to send more questions.',
            ),
          ),
        for (var i = 0; i < c.turns.length; i++) ...[
          _ChatMessage(text: c.turns[i].question, reply: false),
          if (c.turns[i].answer.isEmpty)
            _notCompleted(c)
          else
            _ChatMessage(
              text: c.turns[i].answer,
              reply: true,
              announce: i == c.turns.length - 1,
              footer: c.turns[i].appReplyJson != null
                  ? _savedSources(c.turns[i])
                  : null,
            ),
        ],
        if (c.interruptedQuestion != null && !c.busy) ...[
          _ChatMessage(text: c.interruptedQuestion!, reply: false),
          _notCompleted(c, retry: true),
        ],
        if (c.checking || !available) ...[
          if (!c.checking)
            _appGuidance(
              c,
              topic: _guidanceTopic,
              onTopic: (value) => setState(() => _guidanceTopic = value),
            ),
        ] else if (c.context == null)
          SahNotice(
            message: context.tr(
              'Reopen your plan to start a new conversation.',
            ),
          )
        else ...[
          if (c.turns.isEmpty &&
              c.interruptedQuestion == null &&
              !c.busy &&
              c.errorCode == null)
            _emptyState(c),
          if (c.busy) ...[
            _ChatMessage(text: c.pendingQuestion!, reply: false),
            Semantics(
              liveRegion: true,
              child: Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(
                  context.tr('Thinking on your phone…'),
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
            ),
          ],
          if (c.errorCode != null)
            Semantics(
              liveRegion: true,
              child: SahNotice(
                message: context.tr(_errorText(c.errorCode!)),
                action: TextButton.icon(
                  key: const ValueKey('assistant-check-availability'),
                  onPressed: c.busy || c.checking ? null : c.check,
                  icon: const Icon(Icons.refresh),
                  label: Text(context.tr('Check availability')),
                ),
              ),
            ),
        ],
      ],
    );
  }

  Widget _composer(AssistantController c, {required bool compact}) => Material(
    color: Theme.of(context).colorScheme.surface,
    child: Padding(
      padding: EdgeInsets.fromLTRB(12, compact ? 4 : 12, 12, compact ? 4 : 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: TextField(
              key: const ValueKey('assistant-input'),
              controller: _input,
              focusNode: _focus,
              readOnly:
                  c.busy ||
                  c.historyLoading ||
                  c.historyLoadFailed ||
                  c.clearing ||
                  c.clearFailed,
              minLines: 1,
              maxLines: compact ? 1 : 4,
              maxLength: 600,
              textInputAction: TextInputAction.send,
              enableSuggestions: false,
              autocorrect: false,
              decoration: InputDecoration(
                hintText: context.tr(
                  compact ? 'Ask…' : 'Message the assistant…',
                ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 12,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(24),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(24),
                  borderSide: BorderSide(
                    color: Theme.of(context).colorScheme.primary,
                    width: 1.5,
                  ),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(24),
                  borderSide: BorderSide(
                    color: Theme.of(context).colorScheme.outlineVariant,
                  ),
                ),
              ),
              buildCounter:
                  (
                    _, {
                    required currentLength,
                    required isFocused,
                    maxLength,
                  }) => !compact && isFocused && currentLength >= 500
                  ? Text('$currentLength / $maxLength')
                  : null,
              onEditingComplete: () {},
              onSubmitted: (_) => _send(),
              onTapOutside: (_) => _focus.unfocus(),
            ),
          ),
          const SizedBox(width: 8),
          Padding(
            padding: const EdgeInsets.only(bottom: 2),
            child: ValueListenableBuilder<TextEditingValue>(
              valueListenable: _input,
              builder: (_, value, _) => IconButton.filled(
                key: ValueKey(c.busy ? 'assistant-stop' : 'assistant-send'),
                constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                tooltip: context.tr(c.busy ? 'Stop response' : 'Send question'),
                onPressed: c.busy
                    ? _stop
                    : c.canSend && value.text.trim().isNotEmpty
                    ? () => _send()
                    : null,
                icon: Icon(
                  c.busy ? Icons.stop_rounded : Icons.arrow_upward_rounded,
                ),
              ),
            ),
          ),
        ],
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final c = _controller!;
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) => PopScope(
        canPop: widget.embedded || _canPop,
        onPopInvokedWithResult: (didPop, result) {
          if (!didPop && !widget.embedded) _close();
        },
        child: Scaffold(
          appBar: AppBar(
            title: Text(context.tr('Assistant')),
            automaticallyImplyLeading: false,
            leading: widget.embedded
                ? null
                : IconButton(
                    tooltip: context.tr('Close'),
                    onPressed: c.clearing || c.historyLoading ? null : _close,
                    icon: const Icon(Icons.close),
                  ),
            actions: [
              if (MediaQuery.viewInsetsOf(context).bottom > 0)
                IconButton(
                  key: const ValueKey('assistant-hide-keyboard'),
                  tooltip: context.tr('Hide keyboard'),
                  onPressed: _focus.unfocus,
                  icon: const Icon(Icons.keyboard_hide_outlined),
                ),
              IconButton(
                key: const ValueKey('assistant-options'),
                tooltip: context.tr('Chat options'),
                onPressed: _options,
                icon: const Icon(Icons.more_horiz),
              ),
            ],
          ),
          body: SafeArea(
            child: SahContent(
              maxWidth: 760,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final compact =
                      constraints.maxHeight < 360 ||
                      MediaQuery.textScalerOf(context).scale(17) > 30;
                  return Column(
                    children: [
                      Expanded(child: _conversation(c)),
                      if (_showLatest && !compact)
                        TextButton.icon(
                          onPressed: _latest,
                          icon: const Icon(Icons.arrow_downward, size: 18),
                          label: Text(context.tr('Latest message')),
                        ),
                      if (!c.checking &&
                          c.availability == AssistantAvailability.ready &&
                          c.context != null)
                        _composer(c, compact: compact),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}

enum _AppHelpTopic { nextStep, prepareDraft }

class _ChatMessage extends StatelessWidget {
  const _ChatMessage({
    required this.text,
    required this.reply,
    this.announce = false,
    this.footer,
  });
  final String text;
  final bool reply, announce;
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Align(
        alignment: reply
            ? AlignmentDirectional.centerStart
            : AlignmentDirectional.centerEnd,
        child: FractionallySizedBox(
          widthFactor: reply ? 1 : .88,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Semantics(
                container: true,
                liveRegion: announce,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      context.tr(reply ? 'Assistant' : 'You'),
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Container(
                      padding: EdgeInsets.symmetric(
                        horizontal: reply ? 0 : 16,
                        vertical: 12,
                      ),
                      decoration: BoxDecoration(
                        color: reply
                            ? null
                            : theme.colorScheme.secondaryContainer,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: SelectableText.rich(
                        reply
                            ? assistantMessageText(text)
                            : TextSpan(text: text),
                        style: theme.textTheme.bodyLarge?.copyWith(
                          color: reply
                              ? theme.colorScheme.onSurface
                              : theme.colorScheme.onSecondaryContainer,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              ?footer,
            ],
          ),
        ),
      ),
    );
  }
}
