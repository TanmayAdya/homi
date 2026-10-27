import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:safe_at_home/shared/models/case_draft.dart';
import 'package:safe_at_home/shared/models/evidence.dart';
import 'package:safe_at_home/shared/models/form_answers.dart';
import 'package:safe_at_home/shared/models/program_intake.dart';
import 'package:safe_at_home/shared/services/annotated_export_api_client.dart';
import 'package:safe_at_home/shared/services/assessment_api_client.dart';
import 'package:safe_at_home/shared/services/case_evidence_api_client.dart';
import 'package:safe_at_home/shared/services/draft_export_api_client.dart';
import 'package:safe_at_home/shared/services/evidence_annotations_api_client.dart';
import 'package:safe_at_home/shared/services/form_answers_api_client.dart';
import 'package:safe_at_home/shared/services/io_matching_transport.dart';
import 'package:safe_at_home/shared/services/matching_api_client.dart';
import 'package:safe_at_home/shared/services/program_intake_api_client.dart';

Future<void> main(List<String> arguments) async {
  if (arguments.length != 2 || arguments.first != '--backend') {
    stderr.writeln('Usage: dart tool/check_team_beta_api.dart --backend PATH');
    exitCode = 1;
    return;
  }
  Process? process;
  StreamSubscription<String>? output;
  StreamSubscription<List<int>>? errors;
  var step = 'startup';
  try {
    final backend = Directory(arguments[1]).absolute;
    process = await Process.start(
      'node',
      ['${backend.path}/tool/team-beta-http-fixture.ts'],
      workingDirectory: backend.path,
      includeParentEnvironment: false,
      environment: {
        'PATH': Platform.environment['PATH'] ?? '',
        'NODE_ENV': 'test',
      },
    );
    final ready = Completer<Map<String, dynamic>>();
    var startupBytes = 0;
    output = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          (line) {
            if (ready.isCompleted) return;
            startupBytes += line.length;
            try {
              if (startupBytes > 64 * 1024) throw const FormatException();
              final message = jsonDecode(line);
              if (message is! Map<String, dynamic> ||
                  message['type'] != 'team-beta-ready') {
                throw const FormatException();
              }
              ready.complete(message);
            } catch (_) {
              ready.completeError(StateError('Invalid fictional startup.'));
            }
          },
          onDone: () {
            if (!ready.isCompleted) {
              ready.completeError(
                StateError('Fixture stopped before startup.'),
              );
            }
          },
        );
    errors = process.stderr.listen((_) {});
    final config = await ready.future.timeout(const Duration(seconds: 15));
    final base = Uri.parse(config['baseUri'] as String);
    final image = base64Decode(config['imageBase64'] as String);
    final alice = _Clients(base, config['alice'] as String);
    final bob = _Clients(base, config['bob'] as String);
    for (final program in ['scfhp-eaa', 'hpsm-eaa', 'rtp-home-repair']) {
      await _exerciseProgram(
        backend.path,
        alice,
        bob,
        image,
        program,
        (value) => step = '$program/$value',
      );
      stdout.writeln(
        'PASS: $program Dart/HTTP atomic assessment, original units/history, private photo/annotations, program intake, form fields and verified draft download.',
      );
    }
    stdout.writeln(
      'PASS: v1 case compatibility, exact lost-response recovery, cross-client resume, owner isolation and stale export invalidation.',
    );
  } catch (error) {
    stderr.writeln(
      'Team beta Dart/HTTP check failed at $step. No private input or session details logged.',
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
        await process.exitCode;
      }
    }
  }
}

class _Clients {
  _Clients(this.base, this.token);
  final Uri base;
  final String token;
  MatchingTransport get transport => IoMatchingTransport();
  Future<String?> tokens() async => token;
  AssessmentApiClient assessment({MatchingTransport? via}) =>
      AssessmentApiClient(
        baseUri: base,
        tokenProvider: tokens,
        transport: via ?? transport,
        allowInsecureLoopback: true,
      );
  EvidenceAnnotationsApiClient get annotations => EvidenceAnnotationsApiClient(
    baseUri: base,
    tokenProvider: tokens,
    transport: transport,
    allowInsecureLoopback: true,
  );
  ProgramIntakeApiClient get intake => ProgramIntakeApiClient(
    baseUri: base,
    tokenProvider: tokens,
    transport: transport,
    allowInsecureLoopback: true,
  );
  AnnotatedExportApiClient get exports => AnnotatedExportApiClient(
    baseUri: base,
    tokenProvider: tokens,
    transport: transport,
    allowInsecureLoopback: true,
  );
  FormAnswersApiClient get forms => FormAnswersApiClient(
    caseEndpoint: base.resolve('/v1/read-case'),
    readEndpoint: base.resolve('/v2/read-form-answers'),
    saveEndpoint: base.resolve('/v2/save-form-answers'),
    protocolVersion: '2',
    tokenProvider: tokens,
    transport: transport,
    allowInsecureLoopback: true,
  );
  DraftExportApiClient get legacy => DraftExportApiClient(
    evidenceEndpoint: base.resolve('/v1/list-evidence'),
    evidenceDownloadEndpoint: base.resolve('/v1/download-evidence'),
    exportEndpoint: base.resolve('/v1/create-draft-export'),
    exportDownloadEndpoint: base.resolve('/v1/download-draft-export'),
    tokenProvider: tokens,
    transport: transport,
    allowInsecureLoopback: true,
  );
  CaseEvidenceApiClient get cases => CaseEvidenceApiClient(
    createCaseEndpoint: base.resolve('/v1/create-case'),
    saveCaseEndpoint: base.resolve('/v1/save-case'),
    caseEndpoint: base.resolve('/v1/read-case'),
    uploadEvidenceEndpoint: base.resolve('/v1/upload-evidence'),
    deleteEvidenceEndpoint: base.resolve('/v1/delete-evidence'),
    tokenProvider: tokens,
    transport: transport,
    allowInsecureLoopback: true,
  );
}

Future<void> _exerciseProgram(
  String backend,
  _Clients alice,
  _Clients bob,
  List<int> image,
  String program,
  void Function(String) step,
) async {
  step('create');
  final caseId = newUuidV4(), findingId = newUuidV4(), evidenceId = newUuidV4();
  final draft = CaseDraft.fromJson({
    'schemaVersion': '1',
    'caseId': caseId,
    'profile': {
      'city': null,
      'county': null,
      'healthPlan': null,
      'tenure': null,
      'ageYears': null,
      'householdSize': null,
      'annualIncomeUsd': 0,
      'ownerConsentReported': false,
    },
    'unresolvedFields': [],
    'findings': [],
  });
  var current = await alice.cases.createCase(draft, currentDraft: () => draft);
  var state = await alice.assessment().readAssessment(
    caseId,
    isCurrent: () => current.caseId == caseId,
  );
  _require(
    state.caseSnapshot.schemaVersion == '1' &&
        state.assessmentRevision == 0 &&
        state.catalogRevision == 0,
  );
  final finding = <String, Object?>{
    'id': findingId,
    'room': 'entrance',
    'observation': 'Fictional generated step for HTTP acceptance.',
    'reviewState': 'confirmed',
    'evidenceIds': [evidenceId],
    'measurements': [
      {
        'type': 'thresholdHeight',
        'value': 12.7,
        'unit': 'mm',
        'method': 'manual',
        'confirmed': true,
      },
      {
        'type': 'clearOpening',
        'value': 25,
        'unit': 'mm',
        'method': 'manual',
        'confirmed': true,
      },
    ],
  };
  var metadata = <String, Object?>{
    'measurements': [
      {
        'findingId': findingId,
        'type': 'thresholdHeight',
        'originalText': ' .5 ',
        'originalUnit': 'in',
        'decimalSeparator': 'point',
        'source': 'manual',
        'recorder': 'self',
        'recordedAt': null,
      },
      {
        'findingId': findingId,
        'type': 'clearOpening',
        'originalText': ' 0002,5 ',
        'originalUnit': 'cm',
        'decimalSeparator': 'comma',
        'source': 'manual',
        'recorder': 'helper',
        'recordedAt': null,
      },
    ],
    'reviews': [
      {
        'findingId': findingId,
        'state': 'confirmed',
        'note': 'Fictional review only.',
      },
    ],
  };
  final assessedDraft = CaseDraft.fromJson({
    ...draft.toJson(),
    'findings': [finding],
  });
  final retained = state.saveRequest(
    draft: assessedDraft,
    metadata: metadata,
    mutationId: newUuidV4(),
  );
  final capturedRevision = current.revision;
  step('atomic-save-lost-response');
  await _expectCode(
    () => alice
        .assessment(via: _LoseSaveResponse())
        .saveAssessment(
          retained,
          isCurrent: () => current.revision == capturedRevision,
        ),
    'CASE_SAVE_UNCERTAIN',
  );
  state = await alice.assessment().saveAssessment(
    retained,
    isCurrent: () => current.revision == capturedRevision,
  );
  current = state.caseSnapshot;
  _require(
    current.revision == 2 &&
        state.assessmentRevision == 1 &&
        state.history.length == 1,
  );
  _require(state.history.single['recordedBy'] == 'fictional-team-alice');
  _require(jsonEncode(state.metadata) == jsonEncode(metadata));
  final retried = await alice.assessment().saveAssessment(
    retained,
    isCurrent: () => true,
  );
  _require(
    retried.caseSnapshot.revision == 2 &&
        retried.history.length == 1 &&
        retried.acknowledgedMutationId == retained['mutationId'],
  );
  await _expectCode(
    () => alice.assessment().saveAssessment({
      ...retained,
      'expectedCatalogRevision': 1,
    }, isCurrent: () => true),
    'ASSESSMENT_MUTATION_CONFLICT',
  );
  await _expectCode(
    () => bob.assessment().readAssessment(caseId, isCurrent: () => true),
    'CASE_NOT_FOUND',
  );
  state = await _Clients(
    alice.base,
    alice.token,
  ).assessment().readAssessment(caseId, isCurrent: () => true);
  _require(
    state.caseSnapshot.revision == 2 &&
        jsonEncode(state.metadata) == jsonEncode(metadata),
  );

  step('photo-upload');
  var catalog = await alice.legacy.listEvidence(
    current,
    currentCase: () => current,
    currentCatalog: () => null,
  );
  final uploaded = await alice.cases.uploadEvidence(
    current,
    catalog: catalog,
    evidenceId: evidenceId,
    expectedEvidenceRevision: 0,
    findingId: findingId,
    capturedAt: null,
    imageBytes: image,
    currentCase: () => current,
    currentCatalog: () => catalog,
  );
  _require(
    uploaded.catalogRevision == 1 && uploaded.evidence.mediaType == 'image/png',
  );
  catalog = await alice.legacy.listEvidence(
    current,
    currentCase: () => current,
    currentCatalog: () => null,
  );
  final canonical = await alice.legacy.downloadEvidence(
    current,
    catalog: catalog,
    evidence: catalog.evidence.single,
    currentCase: () => current,
    currentCatalog: () => catalog,
  );
  _require(canonical.length == uploaded.evidence.byteLength);
  Map<String, Object?> annotationRead() => {
    'schemaVersion': '2',
    'caseId': caseId,
    'expectedCaseRevision': current.revision,
    'expectedCatalogRevision': catalog.catalogRevision,
    'evidenceId': evidenceId,
    'expectedEvidenceRevision': 1,
  };
  var annotation = await alice.annotations.readAnnotations(
    annotationRead(),
    isCurrent: () => true,
  );
  _require(
    annotation.annotationRevision == 0 &&
        annotation.annotation['imageSha256'] == uploaded.evidence.sha256,
  );
  const marks = <Map<String, Object?>>[
    {
      'id': 'fictional-box',
      'rect': [100000, 200000, 400000, 300000],
      'label': 'Fictional step marker',
    },
  ];
  annotation = await alice.annotations.saveAnnotations(
    annotation.saveRequest(marks: marks, reviewedForExport: false),
    isCurrent: () => true,
  );
  catalog = await alice.legacy.listEvidence(
    current,
    currentCase: () => current,
    currentCatalog: () => null,
  );
  _require(
    annotation.annotationRevision == 1 &&
        catalog.catalogRevision == 2 &&
        annotation.annotation['reviewState'] == 'needs_review',
  );
  await _expectCode(
    () => bob.annotations.readAnnotations(
      annotationRead(),
      isCurrent: () => true,
    ),
    'CASE_NOT_FOUND',
  );

  step('v1-cannot-drop-annotations');
  final preliminaryForm = await alice.forms.readAnswers(
    current,
    programId: program,
    currentCase: () => current,
    currentProgramId: () => program,
    currentContext: () => null,
  );
  final legacySelected = [
    EvidenceSelection.fromJson({
      'evidenceId': evidenceId,
      'expectedEvidenceRevision': 1,
      'reviewedForExport': true,
    }),
  ];
  final legacyState = ExportSelectionState(
    snapshot: current,
    context: preliminaryForm.context,
    answerRevision: 0,
    catalog: catalog,
    selectedEvidence: legacySelected,
  );
  await _expectCode(
    () => alice.legacy.createDraftExport(
      current,
      context: preliminaryForm.context,
      answerRevision: 0,
      catalog: catalog,
      selectedEvidence: legacySelected,
      generationKey: newUuidV4(),
      currentState: () => legacyState,
    ),
    'ANNOTATIONS_REQUIRE_V2',
  );

  step('program-intake');
  final initialIntake = await alice.intake.readIntake(
    current,
    programId: program,
    isCurrent: () => true,
  );
  final definition = initialIntake.definition;
  var firstBoolean = true, firstMoney = true;
  final answers = definition.questions.map((q) {
    Object? value;
    if (q.kind == 'boolean' && firstBoolean) {
      value = false;
      firstBoolean = false;
    }
    if (q.kind == 'money' && firstMoney) {
      value = 0;
      firstMoney = false;
    }
    if (q.kind == 'text') value = 'Fictional repair discussion only.';
    return IntakeAnswer.fromJson({
      'key': q.key,
      'value': value,
      'reviewState': value == null ? 'unknown' : 'reported',
    }, definition);
  }).toList();
  final savedIntake = await alice.intake.saveIntake(
    current,
    definition: definition,
    expectedIntakeRevision: 0,
    answers: answers,
    isCurrent: () => true,
  );
  _require(
    savedIntake.caseRevision == 3 &&
        savedIntake.isCurrent &&
        savedIntake.saved!.answers.any((a) => a.value == false),
  );
  _require(savedIntake.saved!.answers.any((a) => a.value == null));
  if (program != 'rtp-home-repair') {
    _require(savedIntake.saved!.answers.any((a) => a.value == 0));
  }
  current = await alice.cases.reloadCase(
    caseId,
    currentCaseId: () => caseId,
    currentCase: () => current,
  );
  await _expectCode(
    () => bob.intake.readIntake(
      current,
      programId: program,
      isCurrent: () => true,
    ),
    'CASE_NOT_FOUND',
  );

  step('independent-form-fields');
  final form = await alice.forms.readAnswers(
    current,
    programId: program,
    currentCase: () => current,
    currentProgramId: () => program,
    currentContext: () => null,
  );
  _require(form.schemaVersion == '2' && form.context.programId == program);
  _require(
    form.fieldDefinitions.length ==
        {'scfhp-eaa': 18, 'hpsm-eaa': 10, 'rtp-home-repair': 4}[program],
  );
  _require(
    form.artifactKind ==
        (program == 'rtp-home-repair'
            ? 'preparation_worksheet'
            : 'official_form_draft'),
  );
  final savedForm = await alice.forms.saveAnswers(
    current,
    context: form.context,
    expectedAnswerRevision: 0,
    answers: [
      FormAnswerInput.fromJson({
        'key': 'memberFirstName',
        'value': 'Alex',
        'reviewState': 'reviewed',
      }),
    ],
    currentCase: () => current,
    currentProgramId: () => program,
    currentContext: () => form.context,
  );
  _require(
    savedForm.caseRevision == 4 &&
        savedForm.saved!.answerRevision == 1 &&
        savedForm.isCurrent,
  );
  current = await alice.cases.reloadCase(
    caseId,
    currentCaseId: () => caseId,
    currentCase: () => current,
  );
  final earlierIntake = await alice.intake.readIntake(
    current,
    programId: program,
    isCurrent: () => true,
  );
  _require(!earlierIntake.isCurrent && earlierIntake.saved!.caseRevision == 3);
  catalog = await alice.legacy.listEvidence(
    current,
    currentCase: () => current,
    currentCatalog: () => null,
  );

  Map<String, Object?> exportRequest(int revision, String key) => {
    'schemaVersion': '2',
    'caseId': caseId,
    'expectedCaseRevision': current.revision,
    'programId': program,
    'expectedFormContextId': form.context.formContextId,
    'expectedAnswerRevision': 1,
    'expectedEvidenceCatalogRevision': catalog.catalogRevision,
    'generationKey': key,
    'selectedEvidence': [
      {
        'evidenceId': evidenceId,
        'expectedEvidenceRevision': 1,
        'expectedAnnotationRevision': revision,
        'reviewedForExport': true,
      },
    ],
  };
  step('annotation-review-and-export');
  await _expectCode(
    () => alice.exports.createDraftExport(
      exportRequest(1, newUuidV4()),
      isCurrent: () => true,
    ),
    'ANNOTATION_REVIEW_REQUIRED',
  );
  annotation = await _Clients(
    alice.base,
    alice.token,
  ).annotations.readAnnotations(annotationRead(), isCurrent: () => true);
  _require(jsonEncode(annotation.marks) == jsonEncode(marks));
  annotation = await alice.annotations.saveAnnotations(
    annotation.saveRequest(marks: annotation.marks, reviewedForExport: true),
    isCurrent: () => true,
  );
  _require(
    annotation.annotationRevision == 2 &&
        annotation.annotation['reviewedCaseRevision'] == 4,
  );
  catalog = await alice.legacy.listEvidence(
    current,
    currentCase: () => current,
    currentCatalog: () => null,
  );
  final retainedExport = exportRequest(2, newUuidV4());
  final artifact = await alice.exports.createDraftExport(
    retainedExport,
    isCurrent: () => true,
  );
  _require(artifact.base.programId == program && artifact.base.pageCount >= 3);
  final selection =
      (artifact.toJson()['selectedEvidence'] as List).single as Map;
  _require(
    selection['annotationRevision'] == 2 &&
        (selection['annotationSha256'] as String).length == 64,
  );
  final pdf = await alice.exports.downloadDraftExport(
    artifact,
    isCurrent: () => true,
  );
  _require(
    pdf.length == artifact.base.byteLength &&
        ascii.decode(pdf.take(5).toList()) == '%PDF-',
  );
  await _verifyDownloadedPdf(backend, program, pdf);
  final repeated = await alice.exports.createDraftExport(
    retainedExport,
    isCurrent: () => true,
  );
  _require(
    repeated.base.artifactId == artifact.base.artifactId &&
        repeated.base.sha256 == artifact.base.sha256,
  );
  await _expectCode(
    () => bob.exports.downloadDraftExport(artifact, isCurrent: () => true),
    'ARTIFACT_NOT_FOUND',
  );

  step('resume-edit-invalidates-draft');
  state = await alice.assessment().readAssessment(
    caseId,
    isCurrent: () => true,
  );
  _require(
    state.boundCaseRevision == 2 &&
        state.caseSnapshot.revision == 4 &&
        state.history.length == 1,
  );
  final edited = CaseDraft.fromJson({
    ...CaseDraft.fromSnapshot(current).toJson(),
    'findings': [
      {
        ...finding,
        'measurements': [
          {
            'type': 'thresholdHeight',
            'value': 12.7,
            'unit': 'mm',
            'method': 'manual',
            'confirmed': true,
          },
          {
            'type': 'clearOpening',
            'value': 35,
            'unit': 'mm',
            'method': 'manual',
            'confirmed': true,
          },
        ],
      },
    ],
  });
  final oldMeasurements = metadata['measurements'] as List;
  metadata = {
    ...metadata,
    'measurements': [
      oldMeasurements.first,
      {
        ...oldMeasurements.last as Map<String, Object?>,
        'originalText': ' 0003,5 ',
      },
    ],
  };
  state = await alice.assessment().saveAssessment(
    state.saveRequest(
      draft: edited,
      metadata: metadata,
      mutationId: newUuidV4(),
    ),
    isCurrent: () => true,
  );
  current = state.caseSnapshot;
  _require(
    current.revision == 5 &&
        state.history.length == 2 &&
        state.history.last['caseRevision'] == 5,
  );
  await _expectCode(
    () => alice.exports.downloadDraftExport(artifact, isCurrent: () => true),
    'CASE_REVISION_MISMATCH',
  );
  final staleForm = await alice.forms.readAnswers(
    current,
    programId: program,
    currentCase: () => current,
    currentProgramId: () => program,
    currentContext: () => null,
  );
  _require(!staleForm.isCurrent && staleForm.saved!.caseRevision == 4);
}

void _require(bool condition) {
  if (!condition) throw StateError('Fictional integration assertion failed.');
}

Future<void> _expectCode(Future<Object?> Function() action, String code) async {
  try {
    await action();
  } on MatchingApiException catch (error) {
    if (error.code == code) return;
    rethrow;
  }
  throw StateError('Expected safe request rejection.');
}

class _LoseSaveResponse implements MatchingTransport {
  final _delegate = IoMatchingTransport();
  @override
  MatchingExchange post(MatchingHttpRequest request) {
    final exchange = _delegate.post(request);
    return MatchingExchange(
      response: exchange.response.then((response) {
        if (request.endpoint.path == '/v2/save-assessment' &&
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

Future<void> _verifyDownloadedPdf(
  String backend,
  String program,
  List<int> bytes,
) async {
  final child = await Process.start(
    'node',
    ['$backend/tool/check-team-beta-pdf.ts', program],
    workingDirectory: backend,
    includeParentEnvironment: false,
    environment: {
      'PATH': Platform.environment['PATH'] ?? '',
      'NODE_ENV': 'test',
    },
  );
  try {
    final output = child.stdout.transform(utf8.decoder).join();
    final errors = child.stderr.drain<void>();
    child.stdin.add(bytes);
    await child.stdin.close();
    final status = await child.exitCode.timeout(const Duration(seconds: 20));
    _require(status == 0 && (await output).trim() == 'PASS');
    await errors;
  } finally {
    child.kill(ProcessSignal.sigkill);
    await child.exitCode;
  }
}
