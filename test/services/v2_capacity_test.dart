import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/shared/models/annotated_export.dart';
import 'package:safe_at_home/shared/models/contracts.dart';
import 'package:safe_at_home/shared/models/program_intake.dart';
import 'package:safe_at_home/shared/services/annotated_export_api_client.dart';
import 'package:safe_at_home/shared/services/assessment_api_client.dart';
import 'package:safe_at_home/shared/services/evidence_annotations_api_client.dart';
import 'package:safe_at_home/shared/services/matching_api_client.dart';
import 'package:safe_at_home/shared/services/program_intake_api_client.dart';

import '../contracts/draft_export_test.dart' as pdf;
import 'assessment_v2_api_client_test.dart' as v2;
import 'team_program_clients_test.dart' as programs;

void main() {
  final origin = Uri.parse('https://fictional.example');
  Future<String?> token() async => 'fictional-token';
  bool current() => true;
  AssessmentApiClient assessment(MatchingTransport t) =>
      AssessmentApiClient(baseUri: origin, tokenProvider: token, transport: t);
  EvidenceAnnotationsApiClient annotations(MatchingTransport t) =>
      EvidenceAnnotationsApiClient(
        baseUri: origin,
        tokenProvider: token,
        transport: t,
      );
  AnnotatedExportApiClient exports(MatchingTransport t) =>
      AnnotatedExportApiClient(
        baseUri: origin,
        tokenProvider: token,
        transport: t,
        now: () => DateTime.parse(pdf.stamp),
      );
  ProgramIntakeApiClient intake(MatchingTransport t) => ProgramIntakeApiClient(
    baseUri: origin,
    tokenProvider: token,
    transport: t,
  );
  final fixture = programs.fixtures().first;
  final snapshot = CaseSnapshot.fromJson(fixture['case']);
  final definition = ProgramIntakeResponse.fromJson(
    fixture['intake'],
  ).definition;
  final annotationRequest = <String, Object?>{
    'schemaVersion': '2',
    'caseId': 'fictional-case',
    'expectedCaseRevision': 2,
    'expectedCatalogRevision': 1,
    'evidenceId': 'fictional-evidence',
    'expectedEvidenceRevision': 1,
    'expectedAnnotationRevision': 0,
    'marks': <Object>[],
    'reviewedForExport': false,
  };
  final operations = <String, Future<Object?> Function(MatchingTransport)>{
    'read assessment': (t) =>
        assessment(t).readAssessment('fictional-case', isCurrent: current),
    'save assessment': (t) => assessment(t).saveAssessment({
      'schemaVersion': '2',
      'caseId': 'fictional-case',
      'expectedCaseRevision': 2,
      'mutationId': 'fictional-mutation',
    }, isCurrent: current),
    'read annotations': (t) =>
        annotations(t).readAnnotations(annotationRequest, isCurrent: current),
    'save annotations': (t) =>
        annotations(t).saveAnnotations(annotationRequest, isCurrent: current),
    'create annotated export': (t) =>
        exports(t).createDraftExport(v2.createRequest(), isCurrent: current),
    'download annotated export': (t) => exports(t).downloadDraftExport(
      AnnotatedExportArtifact.fromJson(v2.artifact()),
      isCurrent: current,
    ),
    'read intake': (t) => intake(
      t,
    ).readIntake(snapshot, programId: definition.programId, isCurrent: current),
    'save intake': (t) => intake(t).saveIntake(
      snapshot,
      definition: definition,
      expectedIntakeRevision: 0,
      answers: const [],
      isCurrent: current,
    ),
  };
  for (final operation in operations.entries) {
    for (final status in [429, 507]) {
      final code = status == 429 ? 'RATE_LIMITED' : 'STORAGE_LIMIT_REACHED';
      test(
        '${operation.key} keeps definite $status rejection with no automatic retry',
        () async {
          final transport = v2.Transport(
            (_) async => MatchingHttpResponse(
              statusCode: status,
              contentType: 'application/json',
              retryAfter: '5',
              body: utf8.encode(
                jsonEncode({
                  'schemaVersion': '2',
                  'error': {
                    'code': code,
                    'message': 'Private provider detail secret-token',
                  },
                }),
              ),
            ),
          );
          await expectLater(
            operation.value(transport),
            throwsA(
              isA<MatchingApiException>()
                  .having((e) => e.code, 'definite rejection', code)
                  .having((e) => e.statusCode, 'status', status)
                  .having(
                    (e) => e.retryAfter,
                    'bounded delay',
                    status == 429 ? const Duration(seconds: 5) : null,
                  )
                  .having(
                    (e) => e.toString(),
                    'safe message',
                    isNot(contains('secret-token')),
                  ),
            ),
          );
          expect(transport.requests, hasLength(1));
          expect(transport.requests.single.endpoint.path, startsWith('/v2/'));
        },
      );
    }
  }
  test(
    'assessment history ceiling remains a definite rejection preserving mutation',
    () async {
      final request = <String, Object?>{
        'schemaVersion': '2',
        'caseId': 'fictional-case',
        'expectedCaseRevision': 2,
        'mutationId': 'fictional-retained-mutation',
      };
      final transport = v2.Transport(
        (_) async => MatchingHttpResponse(
          statusCode: 507,
          contentType: 'application/json',
          body: utf8.encode(
            jsonEncode({
              'schemaVersion': '2',
              'error': {
                'code': 'ASSESSMENT_HISTORY_LIMIT',
                'message': 'Private detail',
              },
            }),
          ),
        ),
      );
      final before = jsonEncode(request);
      await expectLater(
        assessment(transport).saveAssessment(request, isCurrent: current),
        throwsA(v2.failure('ASSESSMENT_HISTORY_LIMIT')),
      );
      expect(transport.requests, hasLength(1));
      expect(utf8.decode(transport.requests.single.body), before);
      expect(jsonEncode(request), before);
    },
  );
}
