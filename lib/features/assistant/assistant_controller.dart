import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import '../../shared/models/case_draft.dart';
import 'assistant_context.dart';
import 'assistant_context_v2.dart';
import 'assistant_model.dart';
import 'assistant_history.dart';
export 'assistant_history.dart' show AssistantTurn;

class AssistantController extends ChangeNotifier {
  AssistantController({
    required this.model,
    required this.contextProvider,
    required this.locale,
    this.historyStore,
    this.appContextProvider,
  }) : context = contextProvider();

  final AssistantHistoryStore? historyStore;
  final List<AssistantConversation> _conversations = [];
  String _conversationId = newUuidV4();
  String draft = '';
  String? interruptedQuestion, interruptedId, interruptedCreatedAt;
  String? _pendingMessageId, _pendingCreatedAt;
  bool get conversationFull => historyStore != null && _turns.length >= 12;
  bool get historyFull => historyStore != null && _conversations.length >= 10;
  bool historyLoading = false,
      historyLoadFailed = false,
      saveFailed = false,
      clearFailed = false,
      clearing = false;
  Future<void>? _historyReady;
  Timer? _draftTimer;
  int _saveEpoch = 0;
  List<AssistantConversation> get conversations =>
      List.unmodifiable(_conversations);
  String get conversationId => _conversationId;

  Future<void> loadHistory() => _historyReady ??= _loadHistory();
  Future<void> _loadHistory() async {
    final store = historyStore;
    if (store == null) return;
    historyLoading = true;
    _changed();
    try {
      final saved = await store.read();
      if (_disposed || !store.authorized) return;
      _conversations
        ..clear()
        ..addAll(saved.conversations);
      final active =
          _conversations.where((c) => c.id == saved.activeId).firstOrNull ??
          (historyFull ? _conversations.last : null);
      if (active != null) _restoreConversation(active);
      historyLoadFailed = false;
    } catch (_) {
      if (!_disposed && store.authorized) historyLoadFailed = true;
    } finally {
      if (!_disposed) {
        historyLoading = false;
        _changed();
      }
    }
  }

  Future<void> retryHistory() async {
    if (clearFailed) {
      await clearHistory();
      return;
    }
    if (historyLoadFailed) {
      _historyReady = null;
      await loadHistory();
      return;
    }
    await persist();
  }

  void _restoreConversation(AssistantConversation conversation) {
    _conversationId = conversation.id;
    _turns
      ..clear()
      ..addAll(conversation.turns);
    interruptedQuestion = conversation.interruptedQuestion;
    interruptedId = conversation.interruptedId;
    interruptedCreatedAt = conversation.interruptedCreatedAt;
    draft = conversation.draft;
    includeFindings = false;
    errorCode = null;
  }

  void _recordCurrent() {
    if (_turns.isEmpty &&
        pendingQuestion == null &&
        interruptedQuestion == null &&
        draft.isEmpty) {
      _conversations.removeWhere((c) => c.id == _conversationId);
      return;
    }
    final record = AssistantConversation(
      id: _conversationId,
      updatedAt: DateTime.now().toUtc().toIso8601String(),
      turns: List.of(_turns),
      interruptedQuestion: pendingQuestion ?? interruptedQuestion,
      interruptedId: pendingQuestion == null
          ? interruptedId
          : _pendingMessageId,
      interruptedCreatedAt: pendingQuestion == null
          ? interruptedCreatedAt
          : _pendingCreatedAt,
      draft: draft,
    );
    _conversations.removeWhere((c) => c.id == _conversationId);
    _conversations.add(record);
  }

  Future<void> persist() async {
    _draftTimer?.cancel();
    final store = historyStore;
    if (store == null ||
        _disposed ||
        !store.authorized ||
        historyLoadFailed ||
        historyLoading ||
        clearing ||
        clearFailed) {
      return;
    }
    _recordCurrent();
    final epoch = ++_saveEpoch;
    try {
      if (_conversations.isEmpty) {
        await store.clear();
      } else {
        await store.write(
          AssistantHistory(
            activeId: _conversations.any((c) => c.id == _conversationId)
                ? _conversationId
                : null,
            conversations: List.of(_conversations),
          ),
        );
      }
      if (!_disposed && epoch == _saveEpoch && store.authorized) {
        saveFailed = false;
      }
    } catch (_) {
      if (!_disposed && epoch == _saveEpoch && store.authorized) {
        saveFailed = true;
      }
    }
    _changed();
  }

  void setDraft(String value) {
    if (_disposed ||
        historyLoading ||
        historyLoadFailed ||
        clearing ||
        clearFailed) {
      return;
    }
    draft = String.fromCharCodes(value.runes.take(600));
    _draftTimer?.cancel();
    if (historyStore != null) {
      _draftTimer = Timer(
        const Duration(milliseconds: 350),
        () => unawaited(persist()),
      );
    }
  }

  Future<void> newChat() async {
    if (historyLoading || historyLoadFailed || clearing || saveFailed) return;
    stop();
    _recordCurrent();
    if (historyFull) {
      errorCode = 'HISTORY_LIMIT';
      await persist();
      _changed();
      return;
    }
    _conversationId = newUuidV4();
    _turns.clear();
    interruptedQuestion = null;
    interruptedId = null;
    interruptedCreatedAt = null;
    draft = '';
    errorCode = null;
    includeFindings = false;
    await persist();
    _changed();
  }

  Future<void> openConversation(String id) async {
    if (historyLoading || historyLoadFailed || clearing || saveFailed) return;
    final target = _conversations.where((c) => c.id == id).firstOrNull;
    if (target == null) return;
    stop();
    _recordCurrent();
    _restoreConversation(target);
    await persist();
    _changed();
  }

  Future<void> clearHistory() async {
    if (clearing || historyLoading) return;
    stop(persistInterrupted: false);
    _draftTimer?.cancel();
    ++_saveEpoch;
    clearing = true;
    _turns.clear();
    _conversations.clear();
    interruptedQuestion = null;
    interruptedId = null;
    interruptedCreatedAt = null;
    draft = '';
    errorCode = null;
    includeFindings = false;
    _conversationId = newUuidV4();
    _changed();
    try {
      await historyStore?.clear();
      historyLoadFailed = false;
      saveFailed = false;
      clearFailed = false;
    } catch (_) {
      if (!_disposed && historyStore?.authorized == true) {
        saveFailed = true;
        clearFailed = true;
      }
    } finally {
      clearing = false;
      _changed();
    }
  }

  final AssistantModel model;
  final AssistantContext? Function() contextProvider;
  final String locale;
  final AssistantContextV2? Function()? appContextProvider;
  AssistantContext? context;
  AssistantAvailability availability = AssistantAvailability.unavailable;
  final List<AssistantTurn> _turns = [];
  List<AssistantTurn> get turns => List.unmodifiable(_turns);
  bool checking = true, busy = false, includeFindings = false;
  String? errorCode, pendingQuestion;
  String? _requestId;
  int _epoch = 0, _checkEpoch = 0;
  bool _disposed = false;
  bool get canSend =>
      !_disposed &&
      !checking &&
      !busy &&
      !historyLoading &&
      !historyLoadFailed &&
      !saveFailed &&
      !clearing &&
      !conversationFull &&
      context != null &&
      (historyStore?.authorized ?? true) &&
      availability == AssistantAvailability.ready;

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  Future<void> check() async {
    await loadHistory();
    if (_disposed) return;
    final epoch = ++_checkEpoch;
    checking = true;
    _changed();
    AssistantAvailability result;
    try {
      result = await model.availability(locale);
    } catch (_) {
      result = AssistantAvailability.unavailable;
    }
    if (_disposed || epoch != _checkEpoch) return;
    availability = result;
    checking = false;
    _changed();
  }

  Future<void> downloadModel() async {
    final source = model;
    if (_disposed ||
        busy ||
        checking ||
        availability != AssistantAvailability.modelDownloadable ||
        source is! DownloadableAssistantModel) {
      return;
    }
    final epoch = ++_epoch;
    final id = newUuidV4();
    _requestId = id;
    busy = true;
    errorCode = null;
    _changed();
    try {
      await (source as DownloadableAssistantModel).download(id);
    } catch (error) {
      if (!_disposed && epoch == _epoch) {
        errorCode = error is AssistantFailure ? error.code : 'FAILED';
      }
    } finally {
      if (!_disposed && epoch == _epoch) {
        _requestId = null;
        busy = false;
        await check();
      }
    }
  }

  bool refreshContext() {
    final next = contextProvider();
    if (next?.key == context?.key && (historyStore?.authorized ?? true)) {
      return false;
    }
    context = next;
    if (historyStore == null) {
      clear();
    } else if (next == null || !historyStore!.authorized) {
      stop(persistInterrupted: false);
      historyStore!.invalidate();
      _draftTimer?.cancel();
      _turns.clear();
      _conversations.clear();
      draft = '';
      interruptedQuestion = null;
      interruptedId = null;
      interruptedCreatedAt = null;
      includeFindings = false;
      _changed();
    } else {
      stop();
      includeFindings = false;
    }
    return true;
  }

  void useFindings(bool value) {
    if (busy ||
        value == includeFindings ||
        historyLoading ||
        historyLoadFailed ||
        clearing ||
        saveFailed) {
      return;
    }
    if (historyStore == null) {
      clear();
    } else {
      _recordCurrent();
      if (historyFull) {
        errorCode = 'HISTORY_LIMIT';
        unawaited(persist());
        _changed();
        return;
      }
      _conversationId = newUuidV4();
      _turns.clear();
      interruptedQuestion = null;
      interruptedId = null;
      interruptedCreatedAt = null;
      draft = '';
      errorCode = null;
    }
    includeFindings = value && context?.findings.isNotEmpty == true;
    unawaited(persist());
    _changed();
  }

  void stop({bool persistInterrupted = true}) {
    _epoch++;
    final id = _requestId;
    _requestId = null;
    busy = false;
    if (persistInterrupted && pendingQuestion != null) {
      interruptedQuestion = pendingQuestion;
      interruptedId = _pendingMessageId;
      interruptedCreatedAt = _pendingCreatedAt;
    }
    _pendingMessageId = null;
    _pendingCreatedAt = null;
    pendingQuestion = null;
    if (id != null) unawaited(model.cancel(id));
    final runtime = model;
    if (runtime is ReleasableAssistantModel) {
      unawaited(
        (runtime as ReleasableAssistantModel).unload().catchError(
          (Object _) {},
        ),
      );
    }
    if (persistInterrupted) unawaited(persist());
    _changed();
  }

  void clear() {
    stop(persistInterrupted: false);
    _turns.clear();
    interruptedQuestion = null;
    interruptedId = null;
    interruptedCreatedAt = null;
    draft = '';
    errorCode = null;
    includeFindings = false;
    _changed();
  }

  Future<void> send(String input) async {
    refreshContext();
    if (!canSend) return;
    final question = input.trim();
    if (question.isEmpty || question.runes.length > 600) {
      errorCode = 'QUESTION_LIMIT';
      _changed();
      return;
    }
    if (interruptedQuestion != null && question != interruptedQuestion) {
      _turns.add(
        AssistantTurn(
          interruptedQuestion!,
          '',
          id: interruptedId!,
          createdAt: interruptedCreatedAt!,
          answeredAt: null,
        ),
      );
      interruptedQuestion = null;
      interruptedId = null;
      interruptedCreatedAt = null;
      if (conversationFull) {
        errorCode = 'CONVERSATION_LIMIT';
        await persist();
        _changed();
        return;
      }
    }
    final id = newUuidV4();
    final epoch = ++_epoch;
    final scope = context!.key;
    final appContext = appContextProvider?.call();
    _requestId = id;
    busy = true;
    errorCode = null;
    final messageId = question == interruptedQuestion && interruptedId != null
        ? interruptedId!
        : newUuidV4();
    final createdAt =
        question == interruptedQuestion && interruptedCreatedAt != null
        ? interruptedCreatedAt!
        : DateTime.now().toUtc().toIso8601String();
    _pendingMessageId = messageId;
    _pendingCreatedAt = createdAt;
    pendingQuestion = question;
    interruptedQuestion = null;
    interruptedId = null;
    interruptedCreatedAt = null;
    draft = '';
    final relevant = _turns
        .where(
          (turn) =>
              turn.answer.isNotEmpty &&
              (historyStore == null || turn.contextKey == scope) &&
              (!turn.includedFindings || includeFindings) &&
              (appContext == null || turn.appContextKey == appContext.key),
        )
        .toList();
    final recent = relevant.skip(relevant.length > 2 ? relevant.length - 2 : 0);
    final history = jsonEncode([
      for (final turn in recent)
        {
          'question': assistantExcerpt(turn.question, 160),
          'answer': assistantExcerpt(turn.answer, 320),
        },
    ]);
    final findings = includeFindings ? context!.modelFindings : '[]';
    _changed();
    try {
      if (historyStore != null) {
        await persist();
        if (_disposed || epoch != _epoch || historyStore?.authorized != true) {
          return;
        }
        if (saveFailed) {
          interruptedQuestion = question;
          interruptedId = messageId;
          interruptedCreatedAt = createdAt;
          return;
        }
      }
      final contextual = model;
      if (appContextProvider != null &&
          (appContext?.authorized != true ||
              contextual is! ContextualAssistantModel)) {
        throw const AssistantFailure('UNAVAILABLE');
      }
      final raw = appContext != null && contextual is ContextualAssistantModel
          ? await (contextual as ContextualAssistantModel).respondWithContext(
              requestId: id,
              locale: locale,
              question: question,
              history: history,
              findings: findings,
              appContext: appContext.modelJson,
              guide: AssistantContextV2.trustedGuide,
            )
          : await model.respond(
              requestId: id,
              locale: locale,
              question: question,
              history: history,
              findings: findings,
            );
      if (_disposed || epoch != _epoch) return;
      if (contextProvider()?.key != scope) {
        refreshContext();
        return;
      }
      if (appContext != null &&
          appContextProvider?.call()?.key != appContext.key) {
        throw const AssistantFailure('CONTEXT_CHANGED');
      }
      AssistantReply? reply;
      if (appContext != null) {
        try {
          reply = appContext.decodeReply(raw);
        } on FormatException {
          throw const AssistantFailure('INVALID_RESPONSE');
        }
      }
      final answer = reply?.text ?? raw;
      if (answer.trim().isEmpty || answer.runes.length > 2400) {
        throw const AssistantFailure('INVALID_RESPONSE');
      }
      _turns.add(
        AssistantTurn(
          question,
          answer.trim(),
          id: messageId,
          createdAt: createdAt,
          answeredAt: DateTime.now().toUtc().toIso8601String(),
          contextKey: scope,
          includedFindings: includeFindings,
          appReplyJson: reply == null ? null : raw,
          appContextKey: reply?.contextKey,
        ),
      );
      if (historyStore == null && _turns.length > 12) _turns.removeAt(0);
    } catch (error) {
      if (_disposed || epoch != _epoch) return;
      if (contextProvider()?.key != scope) {
        refreshContext();
        return;
      }
      errorCode = error is AssistantFailure ? error.code : 'FAILED';
      interruptedQuestion = question;
      interruptedId = messageId;
      interruptedCreatedAt = createdAt;
    } finally {
      if (!_disposed && epoch == _epoch) {
        _requestId = null;
        busy = false;
        pendingQuestion = null;
        _pendingMessageId = null;
        _pendingCreatedAt = null;
        await persist();
        _changed();
      }
    }
  }

  @override
  void dispose() {
    stop();
    _draftTimer?.cancel();
    _disposed = true;
    ++_checkEpoch;
    _turns.clear();
    _conversations.clear();
    draft = '';
    interruptedQuestion = null;
    interruptedId = null;
    interruptedCreatedAt = null;
    context = null;
    super.dispose();
  }
}
