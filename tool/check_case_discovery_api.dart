import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:safe_at_home/shared/models/case_list.dart';
import 'package:safe_at_home/shared/models/contracts.dart';
import 'package:safe_at_home/shared/services/case_discovery_api_client.dart';
import 'package:safe_at_home/shared/services/io_matching_transport.dart';
import 'package:safe_at_home/shared/services/matching_api_client.dart';

Future<void> main(List<String> arguments) async {
  if (arguments.length != 2 || arguments.first != '--backend') {
    stderr.writeln(
      'Usage: dart run tool/check_case_discovery_api.dart --backend PATH',
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
    final wire = _InspectTransport();
    CaseDiscoveryApiClient client(
      String token, {
      MatchingTransport? transport,
    }) => CaseDiscoveryApiClient(
      listCasesEndpoint: Uri.parse(config['listCasesEndpoint'] as String),
      caseEndpoint: Uri.parse(config['caseEndpoint'] as String),
      tokenProvider: () async => token,
      transport: transport ?? wire,
      allowInsecureLoopback: true,
    );
    final alice = client(config['alice'] as String);
    final bob = client(config['bob'] as String);
    final scenarios =
        jsonDecode(await fixtures.readAsString()) as List<dynamic>;
    final expected = scenarios
        .map((scenario) => CaseSnapshot.fromJson(scenario['case']))
        .toList();
    require(expected.length == 3, 'Expected the three shared fictional cases.');
    expected.sort((left, right) => left.caseId.compareTo(right.caseId));

    stage = 'paginated owner discovery';
    final discovered = <CaseSummary>[];
    String? afterCaseId;
    for (var pageNumber = 0; pageNumber < 3; pageNumber++) {
      final page = await alice.listCases(
        limit: 1,
        afterCaseId: afterCaseId,
        isCurrent: () => true,
      );
      require(page.cases.length == 1, 'A fictional page is missing its case.');
      discovered.add(page.cases.single);
      afterCaseId = page.nextAfterCaseId;
      require(
        pageNumber == 2 ? afterCaseId == null : afterCaseId != null,
        'Unexpected pagination boundary.',
      );
    }
    for (var index = 0; index < expected.length; index++) {
      require(
        discovered[index].caseId == expected[index].caseId &&
            discovered[index].caseRevision == expected[index].revision,
        'Discovery changed the fictional case identity or revision.',
      );
    }
    final end = await alice.listCases(
      limit: 1,
      afterCaseId: discovered.last.caseId,
      isCurrent: () => true,
    );
    require(
      end.cases.isEmpty && end.nextAfterCaseId == null,
      'End page is not empty.',
    );

    stage = 'separate owner and private summaries';
    final bobPage = await bob.listCases(isCurrent: () => true);
    require(
      bobPage.cases.length == 1 &&
          bobPage.cases.single.caseId == config['caseIds']['bob'] &&
          bobPage.nextAfterCaseId == null &&
          discovered.every(
            (item) => item.caseId != bobPage.cases.single.caseId,
          ),
      'Owner collections overlap or contain unexpected records.',
    );
    require(
      wire.listResponses == 5,
      'Expected all list responses to be inspected.',
    );

    stage = 'resume from list with no local snapshot';
    for (var index = 0; index < discovered.length; index++) {
      final summary = discovered[index];
      final resumed = await alice.resumeCase(
        summary.caseId,
        minimumCaseRevision: summary.caseRevision,
        currentCaseId: () => summary.caseId,
        currentCase: () => null,
        isCurrent: () => true,
      );
      require(
        jsonEncode(resumed.toJson()) == jsonEncode(expected[index].toJson()),
        'Resume did not load the complete authoritative fictional snapshot.',
      );
    }
    final selected = discovered.first;
    await expectCode(
      () => bob.resumeCase(
        selected.caseId,
        minimumCaseRevision: selected.caseRevision,
        currentCaseId: () => selected.caseId,
        currentCase: () => null,
        isCurrent: () => true,
      ),
      'CASE_NOT_FOUND',
    );
    await expectCode(
      () => client('invalid-demo-token').listCases(isCurrent: () => true),
      'UNAUTHENTICATED',
    );

    stage = 'fresh client discovery and resume';
    final reopened = client(
      config['alice'] as String,
      transport: IoMatchingTransport(),
    );
    final freshPage = await reopened.listCases(isCurrent: () => true);
    require(
      freshPage.cases.length == 3 && freshPage.nextAfterCaseId == null,
      'A fresh client could not rediscover saved cases.',
    );
    final fresh = await reopened.resumeCase(
      selected.caseId,
      minimumCaseRevision: selected.caseRevision,
      currentCaseId: () => selected.caseId,
      currentCase: () => null,
      isCurrent: () => true,
    );
    require(
      fresh.revision == selected.caseRevision,
      'Reopened revision changed.',
    );

    stage = 'revision and request-generation guards';
    await expectCode(
      () => reopened.resumeCase(
        selected.caseId,
        minimumCaseRevision: selected.caseRevision + 1,
        currentCaseId: () => selected.caseId,
        currentCase: () => null,
        isCurrent: () => true,
      ),
      'STALE_RESPONSE',
    );
    var currentGeneration = true;
    final superseded = client(
      config['alice'] as String,
      transport: _InspectTransport(
        afterResponse: () => currentGeneration = false,
      ),
    );
    await expectCode(
      () => superseded.listCases(isCurrent: () => currentGeneration),
      'STALE_RESPONSE',
    );
    CaseSnapshot? current = fresh;
    final changedRevision = client(
      config['alice'] as String,
      transport: _InspectTransport(
        afterResponse: () => current = CaseSnapshot.fromJson({
          ...fresh.toJson(),
          'revision': fresh.revision + 1,
        }),
      ),
    );
    await expectCode(
      () => changedRevision.resumeCase(
        selected.caseId,
        minimumCaseRevision: selected.caseRevision,
        currentCaseId: () => selected.caseId,
        currentCase: () => current,
        isCurrent: () => true,
      ),
      'STALE_RESPONSE',
    );
    stdout.writeln(
      'PASS: Dart/HTTP private pagination, owner isolation, fresh-client resume, '
      'minimum revisions and late-response rejection.',
    );
  } catch (error) {
    stderr.writeln(
      'Case discovery integration failed at $stage. '
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

class _InspectTransport implements MatchingTransport {
  _InspectTransport({this.afterResponse});
  final void Function()? afterResponse;
  final _delegate = IoMatchingTransport();
  var listResponses = 0;

  @override
  MatchingExchange post(MatchingHttpRequest request) {
    final exchange = _delegate.post(request);
    return MatchingExchange(
      response: exchange.response.then((response) {
        if (request.endpoint.path == '/v1/list-cases' &&
            response.statusCode == 200) {
          final body = jsonDecode(utf8.decode(response.body));
          require(
            body is Map<String, dynamic> &&
                _exactKeys(body, {
                  'schemaVersion',
                  'cases',
                  'nextAfterCaseId',
                }) &&
                body['cases'] is List,
            'List response contains unexpected top-level data.',
          );
          for (final item in body['cases'] as List) {
            require(
              item is Map<String, dynamic> &&
                  _exactKeys(item, {'caseId', 'caseRevision'}),
              'A summary exposed additional resident data.',
            );
          }
          listResponses++;
        }
        afterResponse?.call();
        return response;
      }),
      cancel: exchange.cancel,
    );
  }
}

bool _exactKeys(Map<String, dynamic> value, Set<String> expected) =>
    value.length == expected.length && value.keys.every(expected.contains);
