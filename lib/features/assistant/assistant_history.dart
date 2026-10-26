import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../../shared/models/case_draft.dart';
import '../../shared/services/local_private_store.dart';

class AssistantTurn {
  const AssistantTurn(
    this.question,
    this.answer, {
    required this.id,
    required this.createdAt,
    required this.answeredAt,
    this.contextKey = '',
    this.includedFindings = false,
    this.appReplyJson,
    this.appContextKey,
  });
  final String question, answer, contextKey, id, createdAt;
  final String? answeredAt;
  final String? appReplyJson, appContextKey;
  String get questionId => '$id-question';
  String get answerId => '$id-answer';
  final bool includedFindings;

  Map<String, Object?> toJson() => {
    'id': id,
    'createdAt': createdAt,
    'answeredAt': answeredAt,
    'question': question,
    'answer': answer,
    'contextKey': contextKey,
    'includedFindings': includedFindings,
    if (appReplyJson != null) 'appReplyJson': appReplyJson,
    if (appContextKey != null) 'appContextKey': appContextKey,
  };
  factory AssistantTurn.fromJson(Object? raw) {
    final value = _object(
      raw,
      {
        'id',
        'createdAt',
        'answeredAt',
        'question',
        'answer',
        'contextKey',
        'includedFindings',
      },
      optional: {'appReplyJson', 'appContextKey'},
    );
    if ((value['appReplyJson'] == null) != (value['appContextKey'] == null)) {
      throw const FormatException('Invalid saved source context.');
    }
    if (value['includedFindings'] is! bool) {
      throw const FormatException('Invalid chat consent.');
    }
    final answer = _text(value['answer'], 2400, empty: true);
    if (answer.isEmpty != (value['answeredAt'] == null)) {
      throw const FormatException('Invalid reply state.');
    }
    return AssistantTurn(
      _text(value['question'], 600),
      answer,
      id: _id(value['id']),
      createdAt: _date(value['createdAt']),
      answeredAt: value['answeredAt'] == null
          ? null
          : _date(value['answeredAt']),
      contextKey: _text(value['contextKey'], 256, empty: true),
      includedFindings: value['includedFindings'] as bool,
      appReplyJson: value['appReplyJson'] == null
          ? null
          : _text(value['appReplyJson'], 8192),
      appContextKey: value['appContextKey'] == null
          ? null
          : _text(value['appContextKey'], 64),
    );
  }
}

class AssistantConversation {
  AssistantConversation({
    required this.id,
    required this.updatedAt,
    this.turns = const [],
    this.interruptedQuestion,
    this.interruptedId,
    this.interruptedCreatedAt,
    this.draft = '',
  });
  final String id, updatedAt, draft;
  final List<AssistantTurn> turns;
  final String? interruptedQuestion, interruptedId, interruptedCreatedAt;

  Map<String, Object?> toJson() => {
    'id': id,
    'updatedAt': updatedAt,
    'turns': turns.map((turn) => turn.toJson()).toList(),
    'interruptedQuestion': interruptedQuestion,
    'interruptedId': interruptedId,
    'interruptedCreatedAt': interruptedCreatedAt,
    'draft': draft,
  };

  factory AssistantConversation.fromJson(Object? raw) {
    final value = _object(raw, {
      'id',
      'updatedAt',
      'turns',
      'interruptedQuestion',
      'interruptedId',
      'interruptedCreatedAt',
      'draft',
    });
    final id = _text(value['id'], 36);
    final updatedAt = _text(value['updatedAt'], 40);
    final turns = value['turns'];
    if (!isCaseUuidV4(id) ||
        DateTime.tryParse(updatedAt) == null ||
        turns is! List ||
        turns.length > 12) {
      throw const FormatException('Invalid saved conversation.');
    }
    if ((value['interruptedQuestion'] == null) !=
            (value['interruptedId'] == null) ||
        (value['interruptedQuestion'] == null) !=
            (value['interruptedCreatedAt'] == null)) {
      throw const FormatException('Invalid interrupted message identity.');
    }
    final parsedTurns = turns.map(AssistantTurn.fromJson).toList();
    if (parsedTurns.map((turn) => turn.id).toSet().length !=
        parsedTurns.length) {
      throw const FormatException('Duplicate saved message identity.');
    }
    return AssistantConversation(
      id: id,
      updatedAt: updatedAt,
      turns: parsedTurns,
      interruptedQuestion: value['interruptedQuestion'] == null
          ? null
          : _text(value['interruptedQuestion'], 600),
      interruptedId: value['interruptedId'] == null
          ? null
          : _id(value['interruptedId']),
      interruptedCreatedAt: value['interruptedCreatedAt'] == null
          ? null
          : _date(value['interruptedCreatedAt']),
      draft: _text(value['draft'], 600, empty: true),
    );
  }
}

class AssistantHistory {
  AssistantHistory({required this.activeId, required this.conversations});
  final String? activeId;
  final List<AssistantConversation> conversations;
}

/// Store account and plan chat history in encrypted local storage
class AssistantHistoryStore {
  AssistantHistoryStore({
    required this.store,
    required this.caseId,
    required this.participantId,
    required this.isCurrent,
  }) {
    if (caseId != null && !isCaseUuidV4(caseId!)) {
      throw const FormatException('Invalid chat scope.');
    }
    if (participantId.isEmpty || participantId.length > 256) {
      throw const FormatException('Invalid chat participant.');
    }
  }
  final LocalPrivateStore store;
  final String? caseId;
  final String participantId;
  final bool Function() isCurrent;
  bool _invalidated = false;
  bool get authorized => !_invalidated && isCurrent();
  String get key =>
      'assistant-history.${caseId ?? 'app-help'}.${sha256.convert(utf8.encode(participantId))}';
  void invalidate() => _invalidated = true;
  void _guard() {
    if (!authorized) throw StateError('Chat scope expired.');
  }

  Future<AssistantHistory> read() async {
    _guard();
    final bytes = await store.readBytes(key);
    if (bytes != null && bytes.length > 2 * 1024 * 1024) {
      throw const FormatException('Saved chat is too large.');
    }
    final raw = bytes == null ? null : jsonDecode(utf8.decode(bytes));
    _guard();
    if (raw == null) {
      return AssistantHistory(activeId: null, conversations: const []);
    }
    final value = _object(raw, {
      'version',
      'accountId',
      'caseId',
      'participantId',
      'activeId',
      'conversations',
    });
    if (value['version'] != 1 ||
        value['accountId'] != store.accountId ||
        value['caseId'] != caseId ||
        value['participantId'] != participantId) {
      throw const FormatException('Saved chat belongs to another scope.');
    }
    final records = value['conversations'];
    if (records is! List || records.length > 10) {
      throw const FormatException('Invalid saved chat.');
    }
    final conversations = records.map(AssistantConversation.fromJson).toList();
    final ids = conversations.map((c) => c.id).toSet();
    final activeId = value['activeId'];
    if (ids.length != conversations.length ||
        (activeId != null &&
            (activeId is! String || !ids.contains(activeId)))) {
      throw const FormatException('Invalid active chat.');
    }
    return AssistantHistory(
      activeId: activeId as String?,
      conversations: conversations,
    );
  }

  Future<void> write(AssistantHistory history) {
    _guard();
    if (history.conversations.length > 10 ||
        history.conversations.any(
          (conversation) => conversation.turns.length > 12,
        )) {
      throw const FormatException('Saved chat storage is full.');
    }
    final bytes = Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'version': 1,
          'accountId': store.accountId,
          'caseId': caseId,
          'participantId': participantId,
          'activeId': history.activeId,
          'conversations': history.conversations
              .map((c) => c.toJson())
              .toList(),
        }),
      ),
    );
    if (bytes.length > 2 * 1024 * 1024) {
      throw const FormatException('Saved chat is too large.');
    }
    return store.writeBytes(key, bytes);
  }

  Future<void> clear() {
    _guard();
    return store.delete(key);
  }
}

Map<String, Object?> _object(
  Object? raw,
  Set<String> keys, {
  Set<String> optional = const {},
}) {
  if (raw is! Map ||
      raw.keys.toSet().difference({...keys, ...optional}).isNotEmpty ||
      keys.difference(raw.keys.toSet()).isNotEmpty) {
    throw const FormatException('Invalid saved chat fields.');
  }
  return Map<String, Object?>.from(raw);
}

String _text(Object? value, int maximum, {bool empty = false}) {
  if (value is! String ||
      (!empty && value.trim().isEmpty) ||
      value.runes.length > maximum) {
    throw const FormatException('Invalid saved chat text.');
  }
  return value;
}

String _id(Object? value) {
  if (value is! String || !isCaseUuidV4(value)) {
    throw const FormatException('Invalid saved message identity.');
  }
  return value;
}

String _date(Object? value) {
  final text = _text(value, 40);
  if (DateTime.tryParse(text) == null) {
    throw const FormatException('Invalid saved message timestamp.');
  }
  return text;
}
