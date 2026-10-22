import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:safe_at_home/shared/models/contracts.dart';
import 'package:safe_at_home/shared/models/evidence.dart';
import 'package:safe_at_home/shared/models/form_answers.dart';
import 'package:safe_at_home/shared/services/draft_export_api_client.dart';
import 'package:safe_at_home/shared/services/form_answers_api_client.dart';
import 'package:safe_at_home/shared/services/io_matching_transport.dart';
import 'package:safe_at_home/shared/services/matching_api_client.dart';

Future<void> main(List<String> arguments) async {
  if (arguments.length != 2 || arguments.first != '--backend') {
    stderr.writeln(
      'Usage: dart run tool/check_draft_export_api.dart --backend PATH',
    );
    exitCode = 1;
    return;
  }
  final backend = Directory(arguments[1]).absolute;
  final fixtures = File('contracts/v1/fixtures/scenarios.json').absolute;
  Process? process;
  StreamSubscription<String>? output;
  StreamSubscription<List<int>>? errors;
  try {
    process = await Process.start('node', [
      '${backend.path}/src/api/demo-server.ts',
      '--fixtures',
      fixtures.path,
      '--port',
      '0',
      '--machine',
      '--exports',
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
                ready.completeError(
                  StateError('Invalid local startup response.'),
                );
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
    DraftExportApiClient exports(
      String token, {
      MatchingTransport? transport,
    }) => DraftExportApiClient(
      evidenceEndpoint: Uri.parse(config['evidenceEndpoint'] as String),
      evidenceDownloadEndpoint: Uri.parse(
        config['evidenceDownloadEndpoint'] as String,
      ),
      exportEndpoint: Uri.parse(config['exportEndpoint'] as String),
      exportDownloadEndpoint: Uri.parse(
        config['exportDownloadEndpoint'] as String,
      ),
      tokenProvider: () async => token,
      transport: transport ?? IoMatchingTransport(),
      allowInsecureLoopback: true,
    );
    final alice = exports(config['alice'] as String),
        bob = exports(config['bob'] as String);
    final answers = FormAnswersApiClient(
      caseEndpoint: Uri.parse(config['caseEndpoint'] as String),
      readEndpoint: Uri.parse(config['formAnswersReadEndpoint'] as String),
      saveEndpoint: Uri.parse(config['formAnswersSaveEndpoint'] as String),
      tokenProvider: () async => config['alice'] as String,
      transport: IoMatchingTransport(),
      allowInsecureLoopback: true,
    );
    final scenarios =
        jsonDecode(await fixtures.readAsString()) as List<dynamic>;
    final snapshot = CaseSnapshot.fromJson(scenarios.first['case']);
    const programId = 'demo-home-support';
    final form = await answers.readAnswers(
      snapshot,
      programId: programId,
      currentCase: () => snapshot,
      currentProgramId: () => programId,
      currentContext: () => null,
    );
    final catalog = await alice.listEvidence(
      snapshot,
      currentCase: () => snapshot,
      currentCatalog: () => null,
    );
    require(catalog.evidence.length == 1, 'Expected one fictional image.');
    final image = await alice.downloadEvidence(
      snapshot,
      catalog: catalog,
      evidence: catalog.evidence.single,
      currentCase: () => snapshot,
      currentCatalog: () => catalog,
    );
    require(
      image.isNotEmpty && image.first == 137,
      'Expected sanitized PNG bytes.',
    );
    final selected = [
      EvidenceSelection.fromJson({
        'evidenceId': catalog.evidence.single.evidenceId,
        'expectedEvidenceRevision': catalog.evidence.single.evidenceRevision,
        'reviewedForExport': true,
      }),
    ];
    final state = ExportSelectionState(
      snapshot: snapshot,
      context: form.context,
      answerRevision: 0,
      catalog: catalog,
      selectedEvidence: selected,
    );
    Future<Object?> create(DraftExportApiClient caller) =>
        caller.createDraftExport(
          snapshot,
          context: form.context,
          answerRevision: 0,
          catalog: catalog,
          selectedEvidence: selected,
          generationKey: 'draft-export-smoke',
          currentState: () => state,
        );
    final artifact = await alice.createDraftExport(
      snapshot,
      context: form.context,
      answerRevision: 0,
      catalog: catalog,
      selectedEvidence: selected,
      generationKey: 'draft-export-smoke',
      currentState: () => state,
    );
    require(
      artifact.pageCount == 2 && artifact.selectedEvidence.length == 1,
      'Expected form and reviewed image pages.',
    );
    final pdf = await alice.downloadDraftExport(
      artifact,
      currentState: () => state,
      currentArtifact: () => artifact,
    );
    require(
      ascii.decode(pdf.take(5).toList()) == '%PDF-',
      'Expected private draft PDF bytes.',
    );
    final repeated = await alice.createDraftExport(
      snapshot,
      context: form.context,
      answerRevision: 0,
      catalog: catalog,
      selectedEvidence: selected,
      generationKey: 'draft-export-smoke',
      currentState: () => state,
    );
    require(
      repeated.artifactId == artifact.artifactId &&
          repeated.sha256 == artifact.sha256,
      'Exact retry changed stored artifact.',
    );
    stdout.writeln(
      'PASS: Dart/HTTP private image review, two-page draft export, digest verification and idempotent retry.',
    );
    await expectCode(
      () => bob.listEvidence(
        snapshot,
        currentCase: () => snapshot,
        currentCatalog: () => null,
      ),
      'CASE_NOT_FOUND',
    );
    await expectCode(() => create(bob), 'CASE_NOT_FOUND');
    await expectCode(
      () => bob.downloadDraftExport(
        artifact,
        currentState: () => state,
        currentArtifact: () => artifact,
      ),
      'ARTIFACT_NOT_FOUND',
    );
    await expectCode(
      () => alice.downloadEvidence(
        snapshot,
        catalog: catalog,
        evidence: catalog.evidence.single,
        currentCase: () => snapshot,
        currentCatalog: () => EvidenceCatalog.fromJson({
          ...catalog.toJson(),
          'catalogRevision': 2,
        }),
      ),
      'STALE_RESPONSE',
    );
    stdout.writeln(
      'PASS: another owner and changed evidence selection cannot access the private draft workflow.',
    );
    final lost = exports(
      config['alice'] as String,
      transport: _LoseExportResponse(),
    );
    try {
      await create(lost);
      throw StateError('Expected uncertain response.');
    } on MatchingApiException {
      // ignore: empty_catches
    }
    final recovered = await alice.createDraftExport(
      snapshot,
      context: form.context,
      answerRevision: 0,
      catalog: catalog,
      selectedEvidence: selected,
      generationKey: 'draft-export-smoke',
      currentState: () => state,
    );
    require(
      recovered.artifactId == artifact.artifactId,
      'Lost-response recovery duplicated an export.',
    );
    await answers.saveAnswers(
      snapshot,
      context: form.context,
      expectedAnswerRevision: 0,
      answers: [
        FormAnswerInput.fromJson({
          'key': 'memberFirstName',
          'value': 'Alex',
          'reviewState': 'reviewed',
        }),
      ],
      currentCase: () => snapshot,
      currentProgramId: () => programId,
      currentContext: () => form.context,
    );
    await expectCode(
      () => alice.downloadDraftExport(
        artifact,
        currentState: () => state,
        currentArtifact: () => artifact,
      ),
      'CASE_REVISION_MISMATCH',
    );
    stdout.writeln(
      'PASS: lost export response reuses the same artifact; saved answers invalidate old private downloads.',
    );
  } catch (error) {
    stderr.writeln(
      'Draft-export integration check failed. No private file or session details were logged.',
    );
    if (error is MatchingApiException) {
      stderr.writeln('Safe error code: ${error.code}');
    }
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

class _LoseExportResponse implements MatchingTransport {
  final _delegate = IoMatchingTransport();
  @override
  MatchingExchange post(MatchingHttpRequest request) {
    final exchange = _delegate.post(request);
    return MatchingExchange(
      response: exchange.response.then((response) {
        if (request.endpoint.path == '/v1/create-draft-export' &&
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
