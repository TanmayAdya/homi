import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:safe_at_home/shared/models/contracts.dart';
import 'package:safe_at_home/shared/models/request_tracking.dart';
import 'package:safe_at_home/shared/services/io_matching_transport.dart';
import 'package:safe_at_home/shared/services/matching_api_client.dart';
import 'package:safe_at_home/shared/services/request_tracking_api_client.dart';

Future<void> main(List<String> arguments) async {
  if (arguments.length != 2 || arguments.first != '--backend') {
    stderr.writeln(
      'Usage: dart run tool/check_request_tracking_api.dart --backend PATH',
    );
    exitCode = 1;
    return;
  }
  Process? process;
  StreamSubscription<String>? output;
  StreamSubscription<List<int>>? errors;
  var stage = 'startup';
  try {
    final backend = Directory(arguments[1]).absolute;
    final fixtures = File('contracts/v1/fixtures/scenarios.json').absolute;
    process = await Process.start('node', [
      '${backend.path}/src/api/demo-server.ts',
      '--fixtures',
      fixtures.path,
      '--port',
      '0',
      '--machine',
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
                ready.completeError(StateError('Invalid readiness response.'));
              }
            }
          },
          onDone: () {
            if (!ready.isCompleted) {
              ready.completeError(StateError('Demo exited before readiness.'));
            }
          },
        );
    errors = process.stderr.listen((_) {});
    final config = await ready.future.timeout(const Duration(seconds: 10));
    final transport = IoMatchingTransport();
    RequestTrackingApiClient client(String token, {MatchingTransport? wire}) =>
        RequestTrackingApiClient(
          readHistoryEndpoint: Uri.parse(
            config['readRequestHistoryEndpoint'] as String,
          ),
          appendUpdateEndpoint: Uri.parse(
            config['appendRequestUpdateEndpoint'] as String,
          ),
          tokenProvider: () async => token,
          transport: wire ?? transport,
          allowInsecureLoopback: true,
        );
    final alice = client(config['alice'] as String),
        bob = client(config['bob'] as String);
    final scenarios =
        jsonDecode(await fixtures.readAsString()) as List<dynamic>;
    var current = CaseSnapshot.fromJson(scenarios.first['case']);
    const program = 'demo-home-support';
    RequestHistory? history;
    ReadRequestHistoryRequest context() => ReadRequestHistoryRequest(
      caseId: current.caseId,
      expectedCaseRevision: current.revision,
      programId: program,
    );
    Future<RequestHistory> read(RequestTrackingApiClient using) =>
        using.readHistory(
          context(),
          currentCase: () => current,
          currentProgramId: () => program,
          currentHistory: () => history,
          isCurrent: () => true,
        );
    Future<RequestHistory> append(
      RequestTrackingApiClient using,
      PendingRequestUpdate pending,
    ) => using.appendUpdate(
      pending,
      currentCase: () => current,
      currentProgramId: () => program,
      currentHistory: () => history,
      isCurrent: () => true,
    );
    PendingRequestUpdate pending(
      int number,
      String status, {
      String? note,
      String? action,
      String? party,
      String? date,
    }) => PendingRequestUpdate(
      request: context(),
      expectedRequestRevision: number - 1,
      update: RequestUpdate(
        updateId:
            '12345678-1234-4123-8123-${number.toString().padLeft(12, '0')}',
        status: status,
        occurredOn:
            date ?? DateTime.now().toUtc().toIso8601String().substring(0, 10),
        source: 'self_report',
        note: note,
        nextAction: action,
        responsibleParty: party,
        followUpOn: action == null ? null : '2099-01-01',
      ),
    );
    stage = 'empty and manual append';
    history = await read(alice);
    require(
      history.requestRevision == 0 && history.events.isEmpty,
      'New history is not empty.',
    );
    final first = pending(
      1,
      'preparing',
      action: 'Review the fictional draft',
      party: 'resident',
    );
    history = await append(alice, first);
    require(
      history.acknowledges(first) &&
          history.caseRevision == current.revision &&
          history.provenance == 'user_reported',
      'Manual append changed its meaning or case revision.',
    );
    final second = pending(
      2,
      'submitted',
      note: 'Fictional manually reported submission; no agency contacted.',
    );
    history = await append(alice, second);
    final retry = await append(alice, first);
    require(
      retry.requestRevision == 2 && retry.acknowledges(first),
      'Exact retry duplicated an event.',
    );

    stage = 'owner isolation and concurrency';
    await expectCode(() => read(bob), 'CASE_NOT_FOUND');
    await expectCode(() => append(bob, first), 'CASE_NOT_FOUND');
    await expectCode(
      () => read(client('invalid-demo-token')),
      'UNAUTHENTICATED',
    );
    final wrongReuse = PendingRequestUpdate(
      request: context(),
      expectedRequestRevision: 0,
      update: RequestUpdate.fromJson({
        ...first.update.toJson(),
        'status': 'received',
      }),
    );
    await expectCode(
      () => append(alice, wrongReuse),
      'REQUEST_UPDATE_CONFLICT',
    );
    final wrongRevision = PendingRequestUpdate(
      request: context(),
      expectedRequestRevision: 0,
      update: pending(3, 'received').update,
    );
    await expectCode(
      () => append(alice, wrongRevision),
      'REQUEST_REVISION_MISMATCH',
    );

    stage = 'uncertain append and explicit reconciliation';
    final lost = pending(
      3,
      'needs_information',
      action: 'Ask the program which document is missing',
      party: 'caregiver',
    );
    final drop = _DropSuccessfulAppendTransport();
    await expectCode(
      () => append(client(config['alice'] as String, wire: drop), lost),
      'REQUEST_UPDATE_UNCERTAIN',
    );
    require(drop.requests == 1, 'Uncertain append was automatically retried.');
    history = await read(alice);
    require(
      history.requestRevision == 3 && history.acknowledges(lost),
      'Read did not reconcile the retained update.',
    );

    stage = 'case edit and original-event recovery';
    final saveBody = {...current.toJson()}..remove('revision');
    saveBody['expectedCaseRevision'] = current.revision;
    final saveExchange = transport.post(
      MatchingHttpRequest(
        endpoint: Uri.parse(config['saveCaseEndpoint'] as String),
        bearerToken: config['alice'] as String,
        body: utf8.encode(jsonEncode(saveBody)),
        maxResponseBytes: 64 * 1024,
      ),
    );
    try {
      final response = await saveExchange.response.timeout(
        const Duration(seconds: 15),
      );
      require(response.statusCode == 200, 'Fictional case save failed.');
      current = CaseSnapshot.fromJson(jsonDecode(utf8.decode(response.body)));
    } finally {
      saveExchange.cancel();
    }
    history = null;
    history = await read(alice);
    require(
      history.acknowledges(lost) && history.caseRevision == current.revision,
      'Case edit lost original event provenance.',
    );
    final last = pending(4, 'received', date: '2020-01-01');
    history = await append(alice, last);
    require(
      history.latest!.update.status == 'received' &&
          history.latest!.revision == 4,
      'Backdated report did not preserve recorded order.',
    );

    stage = 'fresh client and late-selection guard';
    final reopened = client(
      config['alice'] as String,
      wire: IoMatchingTransport(),
    );
    history = null;
    history = await read(reopened);
    require(
      history.requestRevision == 4 && history.acknowledges(lost),
      'Fresh client lost saved history.',
    );
    var epochCurrent = true;
    final delayed = client(
      config['alice'] as String,
      wire: _AfterResponseTransport(() => epochCurrent = false),
    );
    await expectCode(
      () => delayed.readHistory(
        context(),
        currentCase: () => current,
        currentProgramId: () => program,
        currentHistory: () => history,
        isCurrent: () => epochCurrent,
      ),
      'STALE_RESPONSE',
    );
    stdout.writeln(
      'PASS: Dart/HTTP manual request history, owner isolation, idempotency, conflicts, uncertain-write reconciliation, case edits and late-response rejection.',
    );
  } catch (error) {
    stderr.writeln(
      'Request history integration failed at $stage. '
      'No session values, case IDs or private response bodies were logged.',
    );
    if (error is MatchingApiException) {
      stderr.writeln('Safe error code: ${error.code}');
    }
    exitCode = 1;
  } finally {
    if (process != null) {
      process.kill(ProcessSignal.sigterm);
      try {
        await process.exitCode.timeout(const Duration(seconds: 3));
      } on TimeoutException {
        process.kill(ProcessSignal.sigkill);
        await process.exitCode;
      }
    }
    await output?.cancel();
    await errors?.cancel();
  }
}

void require(bool condition, String message) {
  if (!condition) throw StateError(message);
}

Future<void> expectCode(Future<Object?> Function() action, String code) async {
  try {
    await action();
  } on MatchingApiException catch (error) {
    require(error.code == code, 'Unexpected safe API error code.');
    return;
  }
  throw StateError('Expected request rejection.');
}

class _DropSuccessfulAppendTransport implements MatchingTransport {
  final _delegate = IoMatchingTransport();
  var requests = 0;
  @override
  MatchingExchange post(MatchingHttpRequest request) {
    requests++;
    final exchange = _delegate.post(request);
    return MatchingExchange(
      response: exchange.response.then((response) {
        if (response.statusCode == 200) {
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

class _AfterResponseTransport implements MatchingTransport {
  _AfterResponseTransport(this.after);
  final void Function() after;
  final _delegate = IoMatchingTransport();
  @override
  MatchingExchange post(MatchingHttpRequest request) {
    final exchange = _delegate.post(request);
    return MatchingExchange(
      response: exchange.response.then((response) {
        after();
        return response;
      }),
      cancel: exchange.cancel,
    );
  }
}
