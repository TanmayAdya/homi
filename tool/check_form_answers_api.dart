import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:safe_at_home/shared/models/contracts.dart';
import 'package:safe_at_home/shared/models/form_answers.dart';
import 'package:safe_at_home/shared/services/form_answers_api_client.dart';
import 'package:safe_at_home/shared/services/io_matching_transport.dart';
import 'package:safe_at_home/shared/services/matching_api_client.dart';
import 'package:safe_at_home/shared/services/packet_api_client.dart';

Future<void> main(List<String> arguments) async {
  if (arguments.isNotEmpty &&
      (arguments.length != 2 || arguments[0] != '--backend')) {
    stderr.writeln(
      'Usage: dart run tool/check_form_answers_api.dart [--backend PATH]',
    );
    exitCode = 1;
    return;
  }
  final backend = Directory(
    arguments.isEmpty ? 'backend' : arguments[1],
  ).absolute;
  final serverFile = File('${backend.path}/src/api/demo-server.ts');
  final fixtures = File('contracts/v1/fixtures/scenarios.json').absolute;
  if (!serverFile.existsSync() || !fixtures.existsSync()) {
    stderr.writeln(
      'Run from the Flutter root and provide the backend directory with --backend if needed.',
    );
    exitCode = 1;
    return;
  }
  Process? process;
  StreamSubscription<String>? output;
  StreamSubscription<List<int>>? errors;
  try {
    process = await Process.start('node', [
      serverFile.path,
      '--fixtures',
      fixtures.path,
      '--port',
      '0',
      '--machine',
      '--form-answers',
    ], workingDirectory: backend.path);
    final ready = Completer<Map<String, dynamic>>();
    output = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          (line) {
            try {
              final message = jsonDecode(line);
              if (message is Map<String, dynamic> &&
                  message['type'] == 'demo-ready' &&
                  !ready.isCompleted) {
                ready.complete(message);
              }
            } catch (_) {
              if (!ready.isCompleted) {
                ready.completeError(StateError('Invalid startup response.'));
              }
            }
          },
          onDone: () {
            if (!ready.isCompleted) {
              ready.completeError(
                StateError('Local server exited before startup.'),
              );
            }
          },
        );
    errors = process.stderr.listen((_) {});
    final config = await ready.future.timeout(const Duration(seconds: 10));
    FormAnswersApiClient client(String token) => FormAnswersApiClient(
      caseEndpoint: Uri.parse(config['caseEndpoint'] as String),
      readEndpoint: Uri.parse(config['formAnswersReadEndpoint'] as String),
      saveEndpoint: Uri.parse(config['formAnswersSaveEndpoint'] as String),
      tokenProvider: () async => token,
      transport: IoMatchingTransport(),
      allowInsecureLoopback: true,
    );
    final alice = client(config['alice'] as String);
    final bob = client(config['bob'] as String);
    final packetClient = PacketApiClient(
      endpoint: Uri.parse(config['packetEndpoint'] as String),
      tokenProvider: () async => config['alice'] as String,
      transport: IoMatchingTransport(),
      allowInsecureLoopback: true,
    );
    final scenarios =
        jsonDecode(await fixtures.readAsString()) as List<dynamic>;
    final original = CaseSnapshot.fromJson(scenarios.first['case']);
    var current = original;
    const programId = 'demo-home-support';
    FormAnswerContext? selectedContext;
    Future<FormAnswersResponse> read(FormAnswersApiClient caller) =>
        caller.readAnswers(
          current,
          programId: programId,
          currentCase: () => current,
          currentProgramId: () => programId,
          currentContext: () => selectedContext,
        );
    Future<FormAnswersResponse> save(
      List<FormAnswerInput> answers,
      int answerRevision,
    ) => alice.saveAnswers(
      current,
      context: selectedContext!,
      expectedAnswerRevision: answerRevision,
      answers: answers,
      currentCase: () => current,
      currentProgramId: () => programId,
      currentContext: () => selectedContext,
    );
    void adopt(FormAnswersResponse response) {
      require(
        response.caseRevision == current.revision + 1,
        'Save must advance exactly one case revision.',
      );
      current = CaseSnapshot.fromJson({
        ...Map<String, dynamic>.from(scenarios.first['case'] as Map),
        'revision': response.caseRevision,
      });
      selectedContext = response.context;
    }

    final initial = await read(alice);
    require(
      initial.saved == null &&
          !initial.isCurrent &&
          initial.caseRevision == current.revision,
      'An untouched form must have no saved answers.',
    );
    selectedContext = initial.context;
    final before = await packetClient.preparePacket(
      current,
      programId: programId,
      generationKey: 'answers-smoke-before',
      currentCase: () => current,
    );
    require(
      before.missingItems.any((item) => item.id == 'form-field:0'),
      'Initial draft must request the missing answer.',
    );
    final first = await save([
      FormAnswerInput.fromJson({
        'key': 'memberFirstName',
        'value': 'Alex',
        'reviewState': 'reviewed',
      }),
    ], 0);
    require(
      first.isCurrent &&
          first.saved?.answerRevision == 1 &&
          first.saved?.answers.single.value == 'Alex',
      'Saved answer/provenance did not round trip.',
    );
    adopt(first);
    final checked = await read(alice);
    require(
      checked.isCurrentFor(current, selectedContext!),
      'Read did not bind current saved answers.',
    );
    final populated = await packetClient.preparePacket(
      current,
      programId: programId,
      generationKey: 'answers-smoke-reviewed',
      currentCase: () => current,
    );
    require(
      !populated.missingItems.any((item) => item.id == 'form-field:0'),
      'Reviewed answer did not update the checklist.',
    );
    require(
      !populated.missingItems.any((item) => item.description.contains('Alex')),
      'A packet exposed a raw form answer.',
    );
    await expectCode(
      () => packetClient.preparePacket(
        original,
        programId: programId,
        generationKey: 'answers-smoke-oldcase',
        currentCase: () => original,
      ),
      'CASE_REVISION_MISMATCH',
    );
    stdout.writeln(
      'PASS: reviewed answers round trip over Dart/HTTP, advance the case and invalidate old drafts.',
    );

    await expectCode(() => read(bob), 'CASE_NOT_FOUND');
    await expectCode(
      () => bob.saveAnswers(
        current,
        context: selectedContext!,
        expectedAnswerRevision: 1,
        answers: [],
        currentCase: () => current,
        currentProgramId: () => programId,
        currentContext: () => selectedContext,
      ),
      'CASE_NOT_FOUND',
    );
    await expectCode(
      () => read(client('invalid-demo-token')),
      'UNAUTHENTICATED',
    );
    await expectCode(() => save([], 0), 'FORM_ANSWERS_CONFLICT');
    final staleContext = FormAnswerContext.fromJson({
      ...selectedContext!.toJson(),
      'formContextId': '0' * 64,
    });
    await expectCode(
      () => alice.saveAnswers(
        current,
        context: staleContext,
        expectedAnswerRevision: 1,
        answers: [],
        currentCase: () => current,
        currentProgramId: () => programId,
        currentContext: () => staleContext,
      ),
      'FORM_CONTEXT_MISMATCH',
    );
    stdout.writeln(
      'PASS: cross-user reads/writes, invalid sessions, stale revisions and changed form context are rejected.',
    );

    adopt(
      await save([
        FormAnswerInput.fromJson({
          'key': 'memberFirstName',
          'value': 'Alex',
          'reviewState': 'needs_review',
        }),
      ], 1),
    );
    final unreviewed = await packetClient.preparePacket(
      current,
      programId: programId,
      generationKey: 'answers-smoke-unreviewed',
      currentCase: () => current,
    );
    require(
      unreviewed.missingItems.any((item) => item.id == 'form-field:0'),
      'An unreviewed answer must remain a task.',
    );
    adopt(await save([], 2));
    require(
      (await read(alice)).saved!.answers.isEmpty,
      'Full replacement did not clear omitted answers.',
    );
    final attempts = await Future.wait(
      [1, 2].map((_) async {
        try {
          return await save([], 3);
        } on MatchingApiException catch (error) {
          return error.code;
        }
      }),
    );
    require(
      attempts.whereType<FormAnswersResponse>().length == 1 &&
          attempts.whereType<String>().single == 'CASE_REVISION_MISMATCH',
      'Concurrent saves must not overwrite each other.',
    );
    adopt(attempts.whereType<FormAnswersResponse>().single);
    require(
      (await read(alice)).saved!.answerRevision == 4,
      'Concurrent save advanced more than once.',
    );
    stdout.writeln(
      'PASS: unreviewed answers, clearing replacements and concurrent writes preserve revision rules.',
    );
    final lostResponse = FormAnswersApiClient(
      caseEndpoint: Uri.parse(config['caseEndpoint'] as String),
      readEndpoint: Uri.parse(config['formAnswersReadEndpoint'] as String),
      saveEndpoint: Uri.parse(config['formAnswersSaveEndpoint'] as String),
      tokenProvider: () async => config['alice'] as String,
      transport: _LoseSaveResponse(),
      allowInsecureLoopback: true,
    );
    final beforeLostSave = current.revision;
    await expectCode(
      () => lostResponse.saveAnswers(
        current,
        context: selectedContext!,
        expectedAnswerRevision: 4,
        answers: [
          FormAnswerInput.fromJson({
            'key': 'memberFirstName',
            'value': 'Alex',
            'reviewState': 'reviewed',
          }),
        ],
        currentCase: () => current,
        currentProgramId: () => programId,
        currentContext: () => selectedContext,
      ),
      'FORM_SAVE_UNCERTAIN',
    );
    await expectCode(() => read(alice), 'CASE_REVISION_MISMATCH');
    current = await alice.reloadCase(
      current.caseId,
      currentCase: () => current,
    );
    final recovered = await read(alice);
    require(
      current.revision == beforeLostSave + 1 &&
          recovered.saved!.answerRevision == 5 &&
          recovered.saved!.answers.single.value == 'Alex',
      'Reload must recover the committed save without retrying it.',
    );
    await expectCode(
      () => bob.reloadCase(current.caseId, currentCase: () => current),
      'CASE_NOT_FOUND',
    );
    stdout.writeln(
      'PASS: a lost save response is recovered through owner-scoped case reload without a duplicate write.',
    );
  } catch (_) {
    stderr.writeln(
      'Form-answer integration check failed. No session or answer details were logged.',
    );
    exitCode = 1;
  } finally {
    await output?.cancel();
    await errors?.cancel();
    if (process != null) {
      process.kill(ProcessSignal.sigterm);
      try {
        await process.exitCode.timeout(const Duration(seconds: 3));
      } on TimeoutException {
        process.kill(ProcessSignal.sigkill);
      }
    }
  }
}

Future<void> expectCode(Future<Object?> Function() action, String code) async {
  try {
    await action();
  } on MatchingApiException catch (error) {
    if (error.code == code) return;
    throw StateError('Unexpected safe error code.');
  }
  throw StateError('Expected request rejection.');
}

void require(bool condition, String message) {
  if (!condition) throw StateError(message);
}

class _LoseSaveResponse implements MatchingTransport {
  final _delegate = IoMatchingTransport();
  @override
  MatchingExchange post(MatchingHttpRequest request) {
    final exchange = _delegate.post(request);
    return MatchingExchange(
      response: exchange.response.then((response) {
        if (request.endpoint.path == '/v1/save-form-answers' &&
            response.statusCode == 200) {
          throw const MatchingTransportException(
            MatchingTransportFailure.network,
          );
        }
        return response;
      }),
      cancel: exchange.cancel,
    );
  }
}
