import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:safe_at_home/shared/models/account_plan_name.dart';
import 'package:safe_at_home/shared/services/case_discovery_api_client.dart';
import 'package:safe_at_home/shared/services/io_matching_transport.dart';
import 'package:safe_at_home/shared/services/matching_api_client.dart';
import 'package:safe_at_home/shared/services/plan_names_api_client.dart';

Future<void> main(List<String> arguments) async {
  if (arguments.length != 2 || arguments.first != '--backend') {
    stderr.writeln(
      'Usage: dart run tool/check_plan_names_api.dart --backend PATH',
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
    process = await Process.start('node', [
      '${backend.path}/src/api/demo-server.ts',
      '--fixtures',
      File('contracts/v1/fixtures/scenarios.json').absolute.path,
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
              final value = jsonDecode(line);
              if (value is! Map<String, dynamic> ||
                  value['type'] != 'demo-ready') {
                throw const FormatException(
                  'Unexpected local readiness response.',
                );
              }
              if (!ready.isCompleted) ready.complete(value);
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
          onError: (Object _) {
            if (!ready.isCompleted) {
              ready.completeError(StateError('Demo output could not be read.'));
            }
          },
        );
    errors = process.stderr.listen((_) {});
    final config = await ready.future.timeout(const Duration(seconds: 10));
    final base = Uri.parse(Uri.parse(config['endpoint'] as String).origin);
    _require(
      base.scheme == 'http' && base.host == '127.0.0.1' && base.port > 0,
    );
    PlanNamesApiClient client(String token) => PlanNamesApiClient(
      baseUri: base,
      tokenProvider: () async => token,
      transport: IoMatchingTransport(),
      timeout: const Duration(seconds: 3),
      allowInsecureLoopback: true,
    );
    final first = client(config['alice'] as String);
    final second = client(config['alice'] as String);
    final outsider = client(config['bob'] as String);
    final discovery = CaseDiscoveryApiClient(
      listCasesEndpoint: base.resolve('/v1/list-cases'),
      caseEndpoint: base.resolve('/v1/read-case'),
      tokenProvider: () async => config['alice'] as String,
      transport: IoMatchingTransport(),
      allowInsecureLoopback: true,
    );

    stage = 'fresh clients and paginated names';
    final initialPage = await first.listCases(limit: 1, isCurrent: () => true);
    _require(
      initialPage.cases.length == 1 && initialPage.nextAfterCaseId != null,
    );
    final selected = initialPage.cases.single;
    _require(
      selected.name == null &&
          selected.nameRevision == 0 &&
          selected.lastMutationId == null,
    );
    final caseId = selected.caseId;
    final initial = await second.readName(caseId, isCurrent: () => true);
    _same(initial, AccountPlanName.initial(caseId));
    final nextPage = await second.listCases(
      limit: 1,
      afterCaseId: initialPage.nextAfterCaseId,
      isCurrent: () => true,
    );
    _require(
      nextPage.cases.length == 1 && nextPage.cases.single.caseId != caseId,
    );
    final original = await discovery.resumeCase(
      caseId,
      minimumCaseRevision: selected.caseRevision,
      currentCaseId: () => caseId,
      currentCase: () => null,
      isCurrent: () => true,
    );

    Future<AccountPlanName> save(
      PlanNamesApiClient api,
      int revision,
      String mutation,
      String? name,
    ) => api.saveName(
      caseId,
      expectedNameRevision: revision,
      mutationId: mutation,
      name: name,
      isCurrent: () => true,
    );
    stage = 'rename and exact retry across clients';
    final named = await save(
      first,
      0,
      'fictional-name-check-first',
      'Fictional Cedar 🏠',
    );
    _require(named.nameRevision == 1 && named.name == 'Fictional Cedar 🏠');
    _same(await second.readName(caseId, isCurrent: () => true), named);
    _same(
      await save(second, 0, 'fictional-name-check-first', 'Fictional Cedar 🏠'),
      named,
    );
    await _expectCode(
      () => save(second, 0, 'fictional-name-check-first', 'Altered retry'),
      'PLAN_NAME_CONFLICT',
    );
    await _expectCode(
      () => save(second, 0, 'fictional-name-check-stale', 'Stale proposal'),
      'PLAN_NAME_CONFLICT',
    );
    final renamed = await save(
      second,
      1,
      'fictional-name-check-second',
      'Fictional Maple plan',
    );
    _require(renamed.nameRevision == 2);
    _same(
      await first.readName(
        caseId,
        minimumNameRevision: 2,
        isCurrent: () => true,
      ),
      renamed,
    );
    final refreshed = await client(
      config['alice'] as String,
    ).listCases(isCurrent: () => true);
    final refreshedRow = refreshed.cases.singleWhere(
      (row) => row.caseId == caseId,
    );
    _same(refreshedRow.planName, renamed);
    _require(refreshedRow.caseRevision == selected.caseRevision);

    stage = 'owner isolation';
    await _expectCode(
      () => outsider.readName(caseId, isCurrent: () => true),
      'CASE_NOT_FOUND',
    );
    await _expectCode(
      () =>
          save(outsider, 2, 'fictional-name-check-outsider', 'Rejected owner'),
      'CASE_NOT_FOUND',
    );
    final otherPage = await outsider.listCases(isCurrent: () => true);
    _require(
      otherPage.cases.length == 1 &&
          otherPage.cases.single.caseId == config['caseIds']['bob'] &&
          otherPage.cases.single.nameRevision == 0,
    );
    _same(await first.readName(caseId, isCurrent: () => true), renamed);
    await _expectCode(
      () => client('invalid-demo-token').listCases(isCurrent: () => true),
      'UNAUTHENTICATED',
    );

    stage = 'revisioned reset and stale import';
    final reset = await save(second, 2, 'fictional-name-check-reset', null);
    _require(
      reset.name == null &&
          reset.nameRevision == 3 &&
          reset.lastMutationId == 'fictional-name-check-reset',
    );
    _same(await save(first, 2, 'fictional-name-check-reset', null), reset);
    _same(await first.readName(caseId, isCurrent: () => true), reset);
    final resetPage = await second.listCases(isCurrent: () => true);
    _same(
      resetPage.cases.singleWhere((row) => row.caseId == caseId).planName,
      reset,
    );
    await _expectCode(
      () => save(first, 0, 'fictional-name-check-import', 'Old phone name'),
      'PLAN_NAME_CONFLICT',
    );
    await _expectCode(
      () =>
          first.readName(caseId, minimumNameRevision: 4, isCurrent: () => true),
      'STALE_RESPONSE',
    );

    stage = 'unchanged v1 case and discovery';
    final reloaded = await discovery.resumeCase(
      caseId,
      minimumCaseRevision: selected.caseRevision,
      currentCaseId: () => caseId,
      currentCase: () => original,
      isCurrent: () => true,
    );
    _require(jsonEncode(reloaded.toJson()) == jsonEncode(original.toJson()));
    final v1Page = await discovery.listCases(isCurrent: () => true);
    _require(
      v1Page.cases.singleWhere((row) => row.caseId == caseId).caseRevision ==
          selected.caseRevision,
    );
    stdout.writeln(
      'PASS: Dart/HTTP account plan names, independent clients, exact retry, stale conflicts, revisioned reset, owner isolation and unchanged v1 cases.',
    );
  } catch (error) {
    stderr.writeln(
      'Plan-name integration failed at $stage. No tokens, case IDs, names or private response bodies were logged.',
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

void _require(bool condition) {
  if (!condition) throw StateError('Unexpected fictional contract result.');
}

void _same(AccountPlanName actual, AccountPlanName expected) =>
    _require(jsonEncode(actual.toJson()) == jsonEncode(expected.toJson()));
Future<void> _expectCode(Future<Object?> Function() action, String code) async {
  try {
    await action();
  } on MatchingApiException catch (error) {
    _require(error.code == code);
    return;
  }
  throw StateError('Expected request rejection.');
}
