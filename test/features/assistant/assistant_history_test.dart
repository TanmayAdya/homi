import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/features/assistant/assistant_context.dart';
import 'package:safe_at_home/features/assistant/assistant_controller.dart';
import 'package:safe_at_home/features/assistant/assistant_history.dart';
import 'package:safe_at_home/features/assistant/assistant_model.dart';
import 'package:safe_at_home/shared/services/local_private_store.dart';
import 'package:safe_at_home/shared/services/case_coordinator.dart';
import 'package:safe_at_home/shared/services/case_discovery_api_client.dart';

import '../../app/local_private_store_test.dart' show MemorySecrets;
import '../../app/case_coordinator_test.dart' show FakeSession, FakeTransport;
import '../../services/case_evidence_api_client_test.dart' as http;
import 'assistant_test.dart' show FakeModel;

class _Store extends LocalPrivateStore {
  _Store(
    Directory directory,
    MemorySecrets secrets, {
    String account = 'fictional-owner',
  }) : super(directory: directory, secrets: secrets, accountId: account);
  bool failWrite = false, failRead = false, failDelete = false;
  @override
  Future<void> writeBytes(String key, Uint8List bytes) {
    if (failWrite) return Future.error(StateError('Fictional full device'));
    return super.writeBytes(key, bytes);
  }

  @override
  Future<Uint8List?> readBytes(String key) {
    if (failRead) {
      return Future.error(StateError('Fictional unreadable device'));
    }
    return super.readBytes(key);
  }

  @override
  Future<void> delete(String key) {
    if (failDelete) return Future.error(StateError('Fictional delete failure'));
    return super.delete(key);
  }
}

void main() {
  const caseId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
  const otherCase = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
  late Directory directory;
  late _Store store;
  late MemorySecrets secrets;
  var current = true;
  AssistantContext? context;
  final controllers = <AssistantController>[];
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('homi-chat-test-');
    secrets = MemorySecrets();
    store = _Store(directory, secrets);
    current = true;
    context = const AssistantContext(
      key: 'fictional-context-v1',
      findings: ['Fictional private finding'],
    );
  });
  tearDown(() async {
    for (final controller in controllers) {
      controller.dispose();
    }
    controllers.clear();
    await store.close();
    await directory.delete(recursive: true);
  });
  AssistantHistoryStore history({
    String? plan = caseId,
    String participant = 'owner:fictional-owner',
  }) => AssistantHistoryStore(
    store: store,
    caseId: plan,
    participantId: participant,
    isCurrent: () => current,
  );
  AssistantController controller({
    FakeModel? model,
    AssistantHistoryStore? saved,
  }) {
    final c = AssistantController(
      model: model ?? FakeModel(),
      contextProvider: () => context,
      locale: 'en',
      historyStore: saved ?? history(),
    );
    controllers.add(c);
    return c;
  }

  test(
    'saved replies and draft restore privately without model regeneration',
    () async {
      final c = controller();
      await c.check();
      await c.send('Fictional private question');
      c.setDraft('Unsent fictional draft');
      await c.persist();
      final unavailable = FakeModel()
        ..status = AssistantAvailability.unavailable;
      final reopened = controller(model: unavailable);
      await reopened.check();
      expect(reopened.turns.single.question, 'Fictional private question');
      expect(reopened.draft, 'Unsent fictional draft');
      expect(unavailable.requests, isEmpty);
      final stored = await directory
          .list()
          .where((file) => file is File)
          .cast<File>()
          .toList();
      for (final file in stored) {
        expect(
          await file.readAsString(),
          isNot(contains('Fictional private question')),
        );
        expect(
          await file.readAsString(),
          isNot(contains('Unsent fictional draft')),
        );
      }
    },
  );

  test(
    'pending reply survives interruption and late completion cannot replace it',
    () async {
      final model = FakeModel()..pending = Completer<String>();
      final c = controller(model: model);
      await c.check();
      final response = c.send('Fictional unfinished question');
      while (model.requests.isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      c.stop();
      await c.persist();
      model.pending!.complete('Late forbidden reply');
      await response;
      final reopened = controller();
      await reopened.check();
      expect(reopened.turns, isEmpty);
      expect(reopened.interruptedQuestion, 'Fictional unfinished question');
      expect((reopened.model as FakeModel).requests, isEmpty);
    },
  );

  test(
    'new chat and previous conversation selection survive reopening',
    () async {
      final c = controller();
      await c.check();
      await c.send('First chat question');
      final first = c.conversationId;
      await c.newChat();
      await c.send('Second chat question');
      expect(c.conversations, hasLength(2));
      await c.openConversation(first);
      final reopened = controller();
      await reopened.check();
      expect(reopened.conversationId, first);
      expect(reopened.turns.single.question, 'First chat question');
    },
  );

  test(
    'erasing the last unsent draft removes its persisted snapshot',
    () async {
      final c = controller();
      await c.check();
      c.setDraft('Draft that must stay erased');
      await c.persist();
      c.setDraft('');
      await c.persist();
      expect(await store.readBytes(history().key), isNull);
      final reopened = controller();
      await reopened.check();
      expect(reopened.draft, isEmpty);
      expect(reopened.conversations, isEmpty);
    },
  );

  for (final changeConsent in [false, true]) {
    test(
      'pending tenth draft reserves capacity before ${changeConsent ? 'consent change' : 'new chat'}',
      () async {
        final c = controller();
        await c.check();
        for (var i = 0; i < 9; i++) {
          await c.send('Saved chat $i');
          await c.newChat();
        }
        final tenth = c.conversationId;
        c.setDraft('Tenth draft before the debounce fires');
        if (changeConsent) {
          c.useFindings(true);
          await c.persist();
        } else {
          await c.newChat();
        }
        expect(c.conversationId, tenth);
        expect(c.draft, 'Tenth draft before the debounce fires');
        expect(c.errorCode, 'HISTORY_LIMIT');
        expect(c.includeFindings, false);
        expect(c.conversations, hasLength(10));
        await c.send(c.draft);
        final reopened = controller();
        await reopened.check();
        expect(reopened.historyLoadFailed, false);
        expect(reopened.conversations, hasLength(10));
        expect(
          reopened.turns.single.question,
          'Tenth draft before the debounce fires',
        );
      },
    );
  }

  test(
    'clear fences a late reply and remains cleared after reopening',
    () async {
      final model = FakeModel()..pending = Completer<String>();
      final c = controller(model: model);
      await c.check();
      final response = c.send('Question to erase');
      while (model.requests.isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      await c.clearHistory();
      model.pending!.complete('Must never return');
      await response;
      expect(await store.readBytes(history().key), isNull);
      final reopened = controller();
      await reopened.check();
      expect(reopened.turns, isEmpty);
      expect(reopened.conversations, isEmpty);
    },
  );

  test('save, read and clear failures remain distinct and retryable', () async {
    final c = controller();
    await c.check();
    store.failWrite = true;
    await c.send('Retained failed question');
    expect(c.saveFailed, true);
    expect(c.canSend, false);
    expect((c.model as FakeModel).requests, isEmpty);
    expect(c.interruptedQuestion, 'Retained failed question');
    store.failWrite = false;
    await c.retryHistory();
    expect(c.saveFailed, false);
    store.failDelete = true;
    await c.clearHistory();
    expect(c.clearFailed, true);
    store.failDelete = false;
    await c.retryHistory();
    expect(c.clearFailed, false);
    store.failRead = true;
    final unreadable = controller();
    await unreadable.check();
    expect(unreadable.historyLoadFailed, true);
    expect(unreadable.canSend, false);
    store.failRead = false;
    await unreadable.retryHistory();
    expect(unreadable.historyLoadFailed, false);
  });

  test(
    'plans, app help and participants never inherit another history',
    () async {
      final owner = controller();
      await owner.check();
      await owner.send('Owner plan question');
      for (final saved in [
        history(plan: otherCase),
        history(plan: null),
        history(participant: 'helper:fictional-helper'),
      ]) {
        final other = controller(saved: saved);
        await other.check();
        expect(other.turns, isEmpty);
      }
      final otherAccount = _Store(
        directory,
        secrets,
        account: 'another-fictional-owner',
      );
      final otherHistory = AssistantHistoryStore(
        store: otherAccount,
        caseId: caseId,
        participantId: 'owner:fictional-owner',
        isCurrent: () => true,
      );
      expect((await otherHistory.read()).conversations, isEmpty);
      await otherAccount.close();
    },
  );

  test(
    'changed context retains historical display but excludes stale and nonconsented model history',
    () async {
      final model = FakeModel();
      final c = controller(model: model);
      await c.check();
      c.useFindings(true);
      await c.send('Explain the confirmed finding');
      final reopened = controller(model: model);
      await reopened.check();
      expect(reopened.includeFindings, false);
      await reopened.send('Where is Help?');
      expect(model.requests.last['history'], '[]');
      context = const AssistantContext(key: 'fictional-context-v2');
      reopened.refreshContext();
      expect(reopened.turns, hasLength(2));
      await reopened.send('Where is Rooms?');
      expect(model.requests.last['history'], '[]');
    },
  );

  test(
    'revoked scope clears memory and rejects late writes; cleanup removes history',
    () async {
      final model = FakeModel()..pending = Completer<String>();
      final c = controller(model: model);
      await c.check();
      final response = c.send('Revoked question');
      while (model.requests.isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      current = false;
      context = null;
      c.refreshContext();
      await store.delete(history().key);
      model.pending!.complete('Late revoked answer');
      await response;
      await c.persist();
      expect(c.turns, isEmpty);
      expect(c.context, isNull);
      expect(await store.readBytes(history().key), isNull);
    },
  );

  test(
    'saved message identities survive interruption, retry and restart',
    () async {
      final model = FakeModel()..pending = Completer<String>();
      final c = controller(model: model);
      await c.check();
      final operation = c.send('Retry this same question');
      while (model.requests.isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      c.stop();
      await c.persist();
      final interrupted = (await history().read()).conversations.single;
      final retry = controller();
      await retry.check();
      await retry.send('Retry this same question');
      final turn = retry.turns.single;
      expect(turn.id, interrupted.interruptedId);
      expect(turn.createdAt, interrupted.interruptedCreatedAt);
      expect(turn.questionId, '${turn.id}-question');
      expect(turn.answerId, '${turn.id}-answer');
      expect(
        DateTime.parse(
          turn.answeredAt!,
        ).isBefore(DateTime.parse(turn.createdAt)),
        false,
      );
      model.pending!.complete('Late discarded answer');
      await operation;
      final reopened = controller();
      await reopened.check();
      expect(reopened.turns.single.toJson(), turn.toJson());
    },
  );

  test(
    'saved capacity blocks new work without deleting earlier chats or messages',
    () async {
      final model = FakeModel();
      final c = controller(model: model);
      await c.check();
      for (var i = 0; i < 12; i++) {
        await c.send('First chat question $i');
      }
      final firstId = c.conversationId;
      final ids = c.turns.map((turn) => turn.id).toList();
      expect(c.conversationFull, true);
      await c.send('Must not evict the first message');
      expect(model.requests, hasLength(12));
      for (var i = 1; i < 10; i++) {
        await c.newChat();
        await c.send('Chat $i question');
      }
      expect(c.historyFull, true);
      final active = c.conversationId;
      await c.newChat();
      expect(c.conversationId, active);
      expect(c.errorCode, 'HISTORY_LIMIT');
      final saved = await history().read();
      expect(saved.conversations, hasLength(10));
      expect(
        saved.conversations
            .firstWhere((chat) => chat.id == firstId)
            .turns
            .map((turn) => turn.id),
        ids,
      );
      await c.openConversation(firstId);
      expect(c.turns.first.question, 'First chat question 0');
    },
  );

  test(
    'asking a different question retains the interrupted question as incomplete history',
    () async {
      final model = FakeModel()..failure = const AssistantFailure('TIMEOUT');
      final c = controller(model: model);
      await c.check();
      await c.send('Incomplete question');
      final id = c.interruptedId;
      model.failure = null;
      await c.send('A different question');
      expect(c.turns, hasLength(2));
      expect(c.turns.first.question, 'Incomplete question');
      expect(c.turns.first.id, id);
      expect(c.turns.first.answer, isEmpty);
      expect(c.turns.first.answeredAt, isNull);
      expect(model.requests.last['history'], '[]');
      final reopened = controller();
      await reopened.check();
      expect(reopened.turns, hasLength(2));
    },
  );

  test(
    'case cleanup removes only that plan chat using the existing serialized store',
    () async {
      final auth = FakeSession();
      final transport = FakeTransport(
        (_) async => throw StateError('No network is expected'),
      );
      final coordinator = CaseCoordinator(
        session: auth,
        store: store,
        cases: http.clientFor(transport),
        discovery: CaseDiscoveryApiClient(
          listCasesEndpoint: Uri.parse('https://example.org/v1/list-cases'),
          caseEndpoint: Uri.parse('https://example.org/v1/read-case'),
          tokenProvider: auth.accessToken,
          transport: transport,
        ),
      );
      await coordinator.createDraft();
      final id = coordinator.draft!.caseId;
      final c = controller(saved: history(plan: id));
      await c.check();
      await c.send('Plan to delete');
      final retained = controller(saved: history(plan: otherCase));
      await retained.check();
      await retained.send('Plan to retain');
      current = false;
      context = null;
      c.refreshContext();
      retained.refreshContext();
      await coordinator.clearSelected();
      expect(await store.readBytes(history(plan: id).key), isNull);
      expect(await store.readBytes(history(plan: otherCase).key), isNotNull);
      coordinator.dispose();
      auth.dispose();
    },
  );
}
