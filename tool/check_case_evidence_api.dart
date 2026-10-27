import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:safe_at_home/shared/models/case_draft.dart';
import 'package:safe_at_home/shared/models/contracts.dart';
import 'package:safe_at_home/shared/models/evidence.dart';
import 'package:safe_at_home/shared/services/case_evidence_api_client.dart';
import 'package:safe_at_home/shared/services/draft_export_api_client.dart';
import 'package:safe_at_home/shared/services/form_answers_api_client.dart';
import 'package:safe_at_home/shared/services/io_matching_transport.dart';
import 'package:safe_at_home/shared/services/matching_api_client.dart';

Future<void> main(List<String> arguments) async {
  if (arguments.length != 2 || arguments.first != '--backend') {
    stderr.writeln(
      'Usage: dart run tool/check_case_evidence_api.dart --backend PATH',
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
                ready.completeError(StateError('Invalid readiness response.'));
              }
            }
          },
          onDone: () {
            if (!ready.isCompleted) {
              ready.completeError(StateError('Demo exited early.'));
            }
          },
        );
    errors = process.stderr.listen((_) {});
    final config = await ready.future.timeout(const Duration(seconds: 10));
    Uri endpoint(String key) => Uri.parse(config[key] as String);
    CaseEvidenceApiClient writes(
      String token, {
      MatchingTransport? transport,
    }) => CaseEvidenceApiClient(
      createCaseEndpoint: endpoint('createCaseEndpoint'),
      saveCaseEndpoint: endpoint('saveCaseEndpoint'),
      caseEndpoint: endpoint('caseEndpoint'),
      uploadEvidenceEndpoint: endpoint('uploadEvidenceEndpoint'),
      deleteEvidenceEndpoint: endpoint('deleteEvidenceEndpoint'),
      tokenProvider: () async => token,
      transport: transport ?? IoMatchingTransport(),
      allowInsecureLoopback: true,
    );
    final alice = writes(config['alice'] as String),
        bob = writes(config['bob'] as String);
    final exports = DraftExportApiClient(
      evidenceEndpoint: endpoint('evidenceEndpoint'),
      evidenceDownloadEndpoint: endpoint('evidenceDownloadEndpoint'),
      exportEndpoint: endpoint('exportEndpoint'),
      exportDownloadEndpoint: endpoint('exportDownloadEndpoint'),
      tokenProvider: () async => config['alice'] as String,
      transport: IoMatchingTransport(),
      allowInsecureLoopback: true,
    );
    final answers = FormAnswersApiClient(
      caseEndpoint: endpoint('caseEndpoint'),
      readEndpoint: endpoint('formAnswersReadEndpoint'),
      saveEndpoint: endpoint('formAnswersSaveEndpoint'),
      tokenProvider: () async => config['alice'] as String,
      transport: IoMatchingTransport(),
      allowInsecureLoopback: true,
    );
    final scenarios =
        jsonDecode(await fixtures.readAsString()) as List<dynamic>;
    final seed = CaseSnapshot.fromJson(scenarios.first['case']);
    final seedCatalog = await exports.listEvidence(
      seed,
      currentCase: () => seed,
      currentCatalog: () => null,
    );
    final image = await exports.downloadEvidence(
      seed,
      catalog: seedCatalog,
      evidence: seedCatalog.evidence.first,
      currentCase: () => seed,
      currentCatalog: () => seedCatalog,
    );
    final id = newUuidV4();
    var draft = CaseDraft.fromJson({
      ...CaseDraft.fromSnapshot(seed).toJson(),
      'caseId': id,
      'findings': [],
    });
    CaseSnapshot? selected;
    EvidenceCatalog? catalog;
    CaseSnapshot currentCase() => selected!;
    Future<void> reloadCatalog() async {
      catalog = await exports.listEvidence(
        currentCase(),
        currentCase: currentCase,
        currentCatalog: () => catalog,
      );
    }

    stage = 'lost-create recovery';
    final lostCreate = writes(
      config['alice'] as String,
      transport: _LoseSuccessfulResponse('/v1/create-case'),
    );
    await expectCode(
      () => lostCreate.createCase(draft, currentDraft: () => draft),
      'CASE_SAVE_UNCERTAIN',
    );
    selected = await alice.reloadCase(
      id,
      currentCaseId: () => id,
      currentCase: () => selected,
    );
    require(
      selected.revision == 1 && selected.findings.isEmpty,
      'Create recovery did not load the saved case.',
    );
    await expectCode(
      () => alice.createCase(draft, currentDraft: () => draft),
      'CASE_ID_UNAVAILABLE',
    );

    stage = 'finding save and owner isolation';
    final finding = {
      'id': newUuidV4(),
      'room': 'entrance',
      'observation': 'Fictional raised threshold',
      'reviewState': 'needs_review',
      'evidenceIds': [newUuidV4()],
      'measurements': [
        {
          'type': 'threshold_height',
          'value': 25.0,
          'unit': 'mm',
          'method': 'manual',
          'confirmed': false,
        },
      ],
    };
    draft = CaseDraft.fromJson({
      ...draft.toJson(),
      'findings': [finding],
    });
    await expectCode(
      () => bob.saveCase(
        currentCase(),
        replacement: draft,
        currentCase: currentCase,
        currentDraft: () => draft,
      ),
      'CASE_NOT_FOUND',
    );
    selected = await alice.saveCase(
      currentCase(),
      replacement: draft,
      currentCase: currentCase,
      currentDraft: () => draft,
    );
    require(selected.revision == 2, 'Saved finding did not advance the case.');
    await reloadCatalog();

    stage = 'lost-upload recovery';
    final evidenceId = (finding['evidenceIds'] as List<String>).single;
    final lostUpload = writes(
      config['alice'] as String,
      transport: _LoseSuccessfulResponse('/v1/upload-evidence'),
    );
    Future<Object?> upload(CaseEvidenceApiClient client) =>
        client.uploadEvidence(
          currentCase(),
          catalog: catalog!,
          evidenceId: evidenceId,
          expectedEvidenceRevision: catalog!.evidence.isEmpty
              ? 0
              : catalog!.evidence.single.evidenceRevision,
          findingId: finding['id'] as String,
          capturedAt: null,
          imageBytes: image,
          currentCase: currentCase,
          currentCatalog: () => catalog!,
        );
    await expectCode(() => upload(bob), 'CASE_NOT_FOUND');
    await expectCode(() => upload(lostUpload), 'EVIDENCE_SAVE_UNCERTAIN');
    await reloadCatalog();
    require(
      catalog!.catalogRevision == 1 &&
          catalog!.evidence.single.evidenceRevision == 1,
      'Lost upload did not recover exactly one saved asset.',
    );
    final preview = await exports.downloadEvidence(
      currentCase(),
      catalog: catalog!,
      evidence: catalog!.evidence.single,
      currentCase: currentCase,
      currentCatalog: () => catalog!,
    );
    require(
      preview.isNotEmpty && preview.first == 137,
      'Sanitized preview was unavailable.',
    );

    stage = 'reviewed finding and draft export';
    draft = CaseDraft.fromJson({
      ...draft.toJson(),
      'findings': [
        {...finding, 'reviewState': 'confirmed'},
      ],
    });
    selected = await alice.saveCase(
      currentCase(),
      replacement: draft,
      currentCase: currentCase,
      currentDraft: () => draft,
    );
    catalog = null;
    await reloadCatalog();
    const programId = 'demo-home-support';
    final form = await answers.readAnswers(
      currentCase(),
      programId: programId,
      currentCase: currentCase,
      currentProgramId: () => programId,
      currentContext: () => null,
    );
    final state = ExportSelectionState(
      snapshot: currentCase(),
      context: form.context,
      answerRevision: 0,
      catalog: catalog!,
      selectedEvidence: [
        EvidenceSelection.fromJson({
          'evidenceId': evidenceId,
          'expectedEvidenceRevision': 1,
          'reviewedForExport': true,
        }),
      ],
    );
    final artifact = await exports.createDraftExport(
      currentCase(),
      context: form.context,
      answerRevision: 0,
      catalog: catalog!,
      selectedEvidence: state.selectedEvidence,
      generationKey: 'case-photo-roundtrip',
      currentState: () => state,
    );
    final pdf = await exports.downloadDraftExport(
      artifact,
      currentState: () => state,
      currentArtifact: () => artifact,
    );
    require(
      ascii.decode(pdf.take(5).toList()) == '%PDF-' && artifact.pageCount == 2,
      'Expected form plus image appendix.',
    );

    stage = 'replacement invalidates existing export';
    await upload(alice);
    await expectCode(
      () => exports.downloadDraftExport(
        artifact,
        currentState: () => state,
        currentArtifact: () => artifact,
      ),
      'EVIDENCE_CONFLICT',
    );
    await reloadCatalog();
    require(
      catalog!.catalogRevision == 2 &&
          catalog!.evidence.single.evidenceRevision == 2,
      'Replacement revisions did not advance.',
    );

    stage = 'lost-delete recovery and finding removal';
    final lostDelete = writes(
      config['alice'] as String,
      transport: _LoseSuccessfulResponse('/v1/delete-evidence'),
    );
    await expectCode(
      () => lostDelete.deleteEvidence(
        currentCase(),
        catalog: catalog!,
        evidence: catalog!.evidence.single,
        currentCase: currentCase,
        currentCatalog: () => catalog!,
      ),
      'EVIDENCE_SAVE_UNCERTAIN',
    );
    await reloadCatalog();
    require(
      catalog!.catalogRevision == 3 && catalog!.evidence.isEmpty,
      'Deletion recovery did not remove the asset.',
    );
    draft = CaseDraft.fromJson({...draft.toJson(), 'findings': []});
    final lostSave = writes(
      config['alice'] as String,
      transport: _LoseSuccessfulResponse('/v1/save-case'),
    );
    await expectCode(
      () => lostSave.saveCase(
        currentCase(),
        replacement: draft,
        currentCase: currentCase,
        currentDraft: () => draft,
      ),
      'CASE_SAVE_UNCERTAIN',
    );
    selected = await alice.reloadCase(
      id,
      currentCaseId: () => id,
      currentCase: () => selected,
    );
    require(
      selected.revision == 4 && selected.findings.isEmpty,
      'Case save recovery failed.',
    );
    stdout.writeln(
      'PASS: Dart/HTTP create/save, private upload/preview/replacement/deletion, owner isolation, draft invalidation and four lost-write recoveries.',
    );
  } catch (error) {
    stderr.writeln(
      'Case/evidence integration failed at $stage. No private data or session values were logged.',
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
    throw StateError(
      'Unexpected safe error code: ${error.code}; expected $code.',
    );
  }
  throw StateError('Expected request rejection.');
}

void require(bool condition, String message) {
  if (!condition) throw StateError(message);
}

class _LoseSuccessfulResponse implements MatchingTransport {
  _LoseSuccessfulResponse(this.path);
  final String path;
  final _delegate = IoMatchingTransport();
  @override
  MatchingExchange post(MatchingHttpRequest request) {
    final exchange = _delegate.post(request);
    return MatchingExchange(
      response: exchange.response.then((response) {
        if (request.endpoint.path == path && response.statusCode == 200) {
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
