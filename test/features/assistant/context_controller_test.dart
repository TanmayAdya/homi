import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/features/assessment/domain/assessment_location.dart';
import 'package:safe_at_home/features/assistant/assistant_context.dart';
import 'package:safe_at_home/features/assistant/assistant_context_v2.dart';
import 'package:safe_at_home/features/assistant/assistant_controller.dart';
import 'package:safe_at_home/features/assistant/assistant_history.dart';
import 'package:safe_at_home/features/assistant/assistant_model.dart';
import 'package:safe_at_home/shared/navigation/homi_destination.dart';
import 'package:safe_at_home/shared/services/local_private_store.dart';

import '../../app/local_private_store_test.dart' show MemorySecrets;

class _ContextModel implements AssistantModel, ContextualAssistantModel {
  AssistantAvailability status = AssistantAvailability.ready;
  final requests = <Map<String, String>>[];
  final cancelled = <String>[];
  final started = Completer<void>();
  Completer<String>? pending;
  int legacyCalls = 0;
  String raw = jsonEncode({
    'text': 'Open Rooms to review your recorded concerns.',
    'sourceIds': ['app.rooms'],
    'openSourceId': 'app.rooms',
  });

  @override
  Future<AssistantAvailability> availability(String locale) async => status;
  @override
  Future<void> cancel(String requestId) async => cancelled.add(requestId);
  @override
  Future<String> respond({
    required String requestId,
    required String locale,
    required String question,
    required String history,
    required String findings,
  }) async {
    legacyCalls++;
    return 'Legacy response must not be used for contextual generation.';
  }

  @override
  Future<String> respondWithContext({
    required String requestId,
    required String locale,
    required String question,
    required String history,
    required String findings,
    required String appContext,
    required String guide,
  }) async {
    requests.add({
      'id': requestId,
      'locale': locale,
      'question': question,
      'history': history,
      'findings': findings,
      'appContext': appContext,
      'guide': guide,
    });
    if (!started.isCompleted) started.complete();
    return pending == null ? raw : pending!.future;
  }
}

AssistantContextV2 _context({
  String account = 'fictional-owner',
  int revision = 1,
  bool authorized = true,
  FeatureAvailability rooms = FeatureAvailability.supported,
  int roomCount = 1,
}) => AssistantContextV2.fromAuthorizedRecords(
  scopeKey: '$account:session-1',
  authorized: authorized,
  access: const AssistantRecordAccess.owner(),
  destination: HomiDestination.rooms,
  caseId: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
  caseRevision: revision,
  capabilities: {
    for (final destination in HomiDestination.values)
      destination: FeatureAvailability.supported,
    HomiDestination.rooms: rooms,
  },
  filteredRecords: AssistantFilteredRecords(
    caseId: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
    caseRevision: revision,
    revisionKey: 'record-revision-$revision',
    records: [
      for (var i = 0; i < roomCount; i++)
        AssistantRecord.room(
          id: 'fictional-room-$i',
          type: AssessmentLocation.bathroom,
        ),
    ],
  ),
);

void main() {
  late Directory directory;
  late LocalPrivateStore store;
  late AssistantContextV2 appContext;
  final controllers = <AssistantController>[];
  var authorized = true;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('homi-context-chat-');
    store = LocalPrivateStore(
      directory: directory,
      secrets: MemorySecrets(),
      accountId: 'fictional-owner',
    );
    appContext = _context();
    authorized = true;
  });
  tearDown(() async {
    for (final controller in controllers) {
      controller.dispose();
    }
    controllers.clear();
    await store.close();
    await directory.delete(recursive: true);
  });
  AssistantHistoryStore history() => AssistantHistoryStore(
    store: store,
    caseId: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
    participantId: 'owner:fictional-owner',
    isCurrent: () => authorized,
  );
  AssistantController controller(
    _ContextModel model, {
    bool persist = true,
    bool combineScope = true,
  }) {
    final c = AssistantController(
      model: model,
      locale: 'zh-Hant',
      contextProvider: () => AssistantContext(
        key: combineScope ? 'legacy:${appContext.key}' : 'legacy-stable',
        findings: const ['Fictional note must stay excluded without consent.'],
      ),
      appContextProvider: () => appContext,
      historyStore: persist ? history() : null,
    );
    controllers.add(c);
    return c;
  }

  test(
    'contextual dispatch separates trusted guide, bounded app facts and recent history',
    () async {
      appContext = _context(roomCount: 60);
      final model = _ContextModel();
      final c = controller(model);
      await c.check();
      for (var i = 0; i < 4; i++) {
        await c.send('Fictional question $i');
      }
      expect(model.legacyCalls, 0);
      final request = model.requests.last;
      expect(request['guide'], AssistantContextV2.trustedGuide);
      expect(request['appContext'], appContext.modelJson);
      expect(
        utf8.encode(request['appContext']!).length,
        lessThanOrEqualTo(AssistantContextV2.maxModelBytes),
      );
      expect(
        (jsonDecode(request['appContext']!) as Map)['sources'],
        hasLength(appContext.sources.length),
      );
      expect(request['locale'], 'zh-Hant');
      expect(request['findings'], '[]');
      expect(request['appContext'], isNot(contains('Fictional note')));
      final history = (jsonDecode(request['history']!) as List).cast<Map>();
      expect(history.map((turn) => turn['question']), [
        'Fictional question 1',
        'Fictional question 2',
      ]);
      expect(
        history.every(
          (turn) =>
              turn.keys.toSet().difference({'question', 'answer'}).isEmpty,
        ),
        isTrue,
      );
    },
  );

  test(
    'validated raw reply and its exact context key survive encrypted history reopening',
    () async {
      final model = _ContextModel();
      final c = controller(model);
      await c.check();
      await c.send('Where are my rooms?');
      expect(c.errorCode, isNull);
      final turn = c.turns.single;
      expect(turn.answer, 'Open Rooms to review your recorded concerns.');
      expect(turn.appReplyJson, model.raw);
      expect(turn.appContextKey, appContext.key);
      final saved = await history().read();
      final persisted = saved.conversations.single.turns.single;
      expect(persisted.appReplyJson, turn.appReplyJson);
      expect(persisted.appContextKey, turn.appContextKey);
      final unavailable = _ContextModel()
        ..status = AssistantAvailability.unavailable;
      final reopened = controller(unavailable);
      await reopened.check();
      expect(reopened.turns.single.toJson(), turn.toJson());
      expect(unavailable.requests, isEmpty);
      expect(reopened.canSend, isFalse);
      expect(
        appContext
            .resolveOpen(
              appContext.decodeReply(reopened.turns.single.appReplyJson!),
            )!
            .destination,
        HomiDestination.rooms,
      );
    },
  );

  for (final invalid in <String>[
    'plain text without a typed answer',
    '{"text":"Open","sourceIds":["admin:override"],"openSourceId":"admin:override"}',
    '{"text":"Open","sourceIds":["app.plan"],"openSourceId":"app.rooms"}',
    '{"text":"Open","sourceIds":["app.rooms"],"caseId":"foreign-case"}',
    '{"text":"Submit","sourceIds":[],"command":"submit_application"}',
  ]) {
    test(
      'invalid typed response is neither shown nor saved: $invalid',
      () async {
        final model = _ContextModel()..raw = invalid;
        final c = controller(model);
        await c.check();
        await c.send('Fictional query');
        expect(c.errorCode, 'INVALID_RESPONSE');
        expect(c.turns, isEmpty);
        expect(c.interruptedQuestion, 'Fictional query');
        final saved = await history().read();
        expect(saved.conversations.single.turns, isEmpty);
        expect(
          saved.conversations.single.interruptedQuestion,
          'Fictional query',
        );
      },
    );
  }

  for (final change in ['revision', 'account', 'revocation', 'capability']) {
    test(
      '$change during generation independently rejects late contextual output',
      () async {
        final model = _ContextModel()..pending = Completer<String>();
        final c = controller(model, combineScope: false);
        await c.check();
        final pending = c.send('A fictional question');
        await model.started.future.timeout(const Duration(seconds: 5));
        appContext = switch (change) {
          'revision' => _context(revision: 2),
          'account' => _context(account: 'another-fictional-owner'),
          'revocation' => _context(authorized: false),
          _ => _context(rooms: FeatureAvailability.configuredOff),
        };
        model.pending!.complete(model.raw);
        await pending;
        expect(c.turns, isEmpty);
        expect(c.errorCode, 'CONTEXT_CHANGED');
        expect(c.busy, isFalse);
        expect((await history().read()).conversations.single.turns, isEmpty);
      },
    );
  }

  test(
    'refreshed app context excludes historical source truth from a new generation',
    () async {
      final model = _ContextModel();
      final c = controller(model);
      await c.check();
      await c.send('Original fictional question');
      final previous = c.turns.single;
      appContext = _context(revision: 2);
      expect(c.refreshContext(), isTrue);
      expect(c.turns.single.answer, previous.answer);
      expect(c.turns.single.appContextKey, isNot(appContext.key));
      await c.send('What is current now?');
      expect(model.requests.last['history'], '[]');
      expect(model.requests.last['appContext'], appContext.modelJson);
      expect(c.turns.last.appContextKey, appContext.key);
    },
  );

  test(
    'old version-one histories restore without optional contextual metadata',
    () async {
      const old = AssistantTurn(
        'Old fictional question',
        'Historical answer without typed sources',
        id: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
        createdAt: '2026-10-26T10:00:00Z',
        answeredAt: '2026-10-26T10:00:01Z',
        contextKey: 'old-context',
      );
      final oldJson = old.toJson();
      expect(oldJson.containsKey('appReplyJson'), isFalse);
      expect(oldJson.containsKey('appContextKey'), isFalse);
      const conversationId = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';
      await history().write(
        AssistantHistory(
          activeId: conversationId,
          conversations: [
            AssistantConversation(
              id: conversationId,
              updatedAt: '2026-10-26T10:00:01Z',
              turns: [AssistantTurn.fromJson(oldJson)],
            ),
          ],
        ),
      );
      final c = controller(_ContextModel());
      await c.check();
      expect(c.turns.single.answer, old.answer);
      expect(c.turns.single.appReplyJson, isNull);
      expect(c.turns.single.appContextKey, isNull);
      for (final orphaned in [
        {...oldJson, 'appReplyJson': '{"text":"unbound","sourceIds":[]}'},
        {...oldJson, 'appContextKey': appContext.key},
      ]) {
        expect(() => AssistantTurn.fromJson(orphaned), throwsFormatException);
      }
    },
  );

  test(
    'V2 history is filtered independently when the legacy scope does not change',
    () async {
      final model = _ContextModel();
      final c = controller(model, combineScope: false);
      await c.check();
      await c.send('A previous fictional question');
      final historical = c.turns.single;
      appContext = _context(revision: 2);
      expect(c.refreshContext(), isFalse);
      await c.send('Use only current app information');
      expect(model.requests.last['history'], '[]');
      expect(c.turns.first.toJson(), historical.toJson());
      expect(c.turns.last.appContextKey, appContext.key);
    },
  );
}
