import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/shared/models/annotated_export.dart';
import 'package:safe_at_home/shared/models/assessment.dart';
import 'package:safe_at_home/shared/models/draft_export.dart';
import 'package:safe_at_home/shared/models/evidence_annotations.dart';
import 'package:safe_at_home/shared/services/assessment_api_client.dart';
import 'package:safe_at_home/shared/services/annotated_export_api_client.dart';
import 'package:safe_at_home/shared/services/evidence_annotations_api_client.dart';
import 'package:safe_at_home/shared/services/matching_api_client.dart';
import '../contracts/draft_export_test.dart' as f;

MatchingHttpResponse response(Object? value) => MatchingHttpResponse(
  statusCode: 200,
  contentType: 'application/json',
  body: utf8.encode(jsonEncode(value)),
);
Map<String, Object?> state() => {
  'schemaVersion': '2',
  'case': f.snapshot().toJson(),
  'caseFingerprint': f.digest,
  'catalogRevision': 1,
  'assessment': {
    'schemaVersion': '2',
    'caseId': 'fictional-case',
    'caseRevision': 2,
    'assessmentRevision': 0,
    'metadata': {'measurements': [], 'reviews': []},
    'history': [],
  },
  'acknowledgedMutationId': null,
};
Map<String, Object?> annotation() => {
  'schemaVersion': '2',
  'caseId': 'fictional-case',
  'caseRevision': 2,
  'catalogRevision': 1,
  'annotation': {
    'schemaVersion': '2',
    'caseId': 'fictional-case',
    'evidenceId': 'fictional-evidence',
    'evidenceRevision': 1,
    'annotationRevision': 0,
    'imageSha256': f.digest,
    'imageWidth': 100,
    'imageHeight': 200,
    'coordinateSpace': 'normalized-top-left-1e6',
    'marks': [],
    'reviewState': 'needs_review',
    'reviewedCaseRevision': null,
    'reviewedAt': null,
    'reviewedBy': null,
  },
};
Map<String, Object?> artifact() => {
  ...f.artifactJson(),
  'schemaVersion': '2',
  'renderingVersion': 'draft-export-annotations-v2',
  'selectedEvidence': (f.artifactJson()['selectedEvidence'] as List)
      .map(
        (e) => {
          ...e as Map,
          'annotationRevision': 1,
          'annotationSha256': f.digest,
        },
      )
      .toList(),
};
Map<String, Object?> createRequest() => {
  'schemaVersion': '2',
  'caseId': 'fictional-case',
  'expectedCaseRevision': 2,
  'programId': 'fictional-program',
  'expectedFormContextId': f.digest,
  'expectedAnswerRevision': 0,
  'expectedEvidenceCatalogRevision': 1,
  'generationKey': 'fictional-export-key',
  'selectedEvidence': [
    {...f.selectionJson(), 'expectedAnnotationRevision': 1},
  ],
};
TypeMatcher<MatchingApiException> failure(String code) =>
    isA<MatchingApiException>().having((e) => e.code, 'code', code);

void main() {
  test(
    'v2 models keep v1 strict, detach payloads and preserve original measurement text',
    () {
      final metadata = {
        'measurements': [
          {
            'findingId': 'f',
            'type': 'width',
            'originalText': ' 000.5 ',
            'originalUnit': 'in',
            'decimalSeparator': 'point',
            'source': 'manual',
            'recorder': 'self',
            'recordedAt': null,
          },
        ],
        'reviews': [],
      };
      expect(
        (validateAssessmentMetadata(metadata)['measurements'] as List)
            .first['originalText'],
        ' 000.5 ',
      );
      for (final original in ['.12345', '1000000000', '1,2']) {
        (metadata['measurements'] as List).first['originalText'] = original;
        expect(
          () => validateAssessmentMetadata(metadata),
          throwsFormatException,
        );
      }
      final raw = state(), model = AssessmentState.fromJson(raw);
      raw['catalogRevision'] = 99;
      expect(model.catalogRevision, 1);
      final exported = AnnotatedExportArtifact.fromJson(artifact());
      expect(exported.toJson()['schemaVersion'], '2');
      expect(
        () => ExportArtifactMetadata.fromJson(exported.toJson()),
        throwsFormatException,
      );
      expect(
        () => AnnotatedExportArtifact.fromJson(f.artifactJson()),
        throwsFormatException,
      );
    },
  );
  test(
    'annotation rectangles cannot leave canonical image and reviews require server provenance',
    () {
      expect(
        () => validateAnnotationMarks([
          {
            'id': 'mark',
            'rect': [900000, 0, 200000, 100000],
            'label': 'Area',
          },
        ]),
        throwsFormatException,
      );
      final raw = annotation();
      (raw['annotation'] as Map)['reviewState'] = 'reviewed';
      expect(() => AnnotationState.fromJson(raw), throwsFormatException);
    },
  );
  test(
    'assessment client rejects stale account after delayed token without issuing request',
    () async {
      final token = Completer<String?>(),
          transport = Transport((_) async => response(state()));
      var current = true;
      final client = AssessmentApiClient(
        baseUri: Uri.parse('https://example.org'),
        tokenProvider: () => token.future,
        transport: transport,
      );
      final future = client.readAssessment(
        'fictional-case',
        isCurrent: () => current,
      );
      current = false;
      token.complete('fictional-token');
      await expectLater(future, throwsA(failure('STALE_RESPONSE')));
      expect(transport.requests, isEmpty);
    },
  );
  test(
    'annotation request is captured before token waits and response checks current revisions',
    () async {
      final token = Completer<String?>(),
          transport = Transport((_) async => response(annotation()));
      final client = EvidenceAnnotationsApiClient(
        baseUri: Uri.parse('https://example.org'),
        tokenProvider: () => token.future,
        transport: transport,
      );
      final request = {
        'schemaVersion': '2',
        'caseId': 'fictional-case',
        'expectedCaseRevision': 2,
        'expectedCatalogRevision': 1,
        'evidenceId': 'fictional-evidence',
        'expectedEvidenceRevision': 1,
      };
      final future = client.readAnnotations(request, isCurrent: () => true);
      request['caseId'] = 'different';
      token.complete('fictional-token');
      expect((await future).caseId, 'fictional-case');
      expect(
        transport.requests.single.endpoint.path,
        '/v2/read-evidence-annotations',
      );
      expect(
        (jsonDecode(utf8.decode(transport.requests.single.body))
            as Map)['caseId'],
        'fictional-case',
      );
    },
  );
  test(
    'v2 PDF creation checks selected annotation revision and bounded download verifies actual bytes',
    () async {
      final transport = Transport(
        (request) async => request.accept == 'application/pdf'
            ? MatchingHttpResponse(
                statusCode: 200,
                contentType: 'application/pdf',
                body: f.pdf,
              )
            : response(artifact()),
      );
      final client = AnnotatedExportApiClient(
        baseUri: Uri.parse('https://example.org'),
        tokenProvider: () async => 'fictional-token',
        transport: transport,
        now: () => DateTime.parse(f.stamp),
      );
      final exported = await client.createDraftExport(
        createRequest(),
        isCurrent: () => true,
      );
      expect(
        await client.downloadDraftExport(exported, isCurrent: () => true),
        f.pdf,
      );
      expect(transport.requests.last.maxResponseBytes, maxDraftExportBytes);
      final bad = createRequest();
      (bad['selectedEvidence'] as List).first['expectedAnnotationRevision'] = 9;
      await expectLater(
        client.createDraftExport(bad, isCurrent: () => true),
        throwsA(failure('UNEXPECTED_RESPONSE')),
      );
    },
  );
  test(
    'PDF byte tampering, redirects and stale responses never become a shareable artifact',
    () async {
      final exported = AnnotatedExportArtifact.fromJson(artifact());
      for (final reply in [
        MatchingHttpResponse(
          statusCode: 200,
          contentType: 'application/pdf',
          body: [...f.pdf]..[10] = 0,
        ),
        MatchingHttpResponse(
          statusCode: 302,
          contentType: 'application/pdf',
          body: f.pdf,
        ),
      ]) {
        final client = AnnotatedExportApiClient(
          baseUri: Uri.parse('https://example.org'),
          tokenProvider: () async => 'fictional-token',
          transport: Transport((_) async => reply),
          now: () => DateTime.parse(f.stamp),
        );
        await expectLater(
          client.downloadDraftExport(exported, isCurrent: () => true),
          throwsA(failure('UNEXPECTED_RESPONSE')),
        );
      }
    },
  );
}

class Transport implements MatchingTransport {
  Transport(this.handler);
  final Future<MatchingHttpResponse> Function(MatchingHttpRequest) handler;
  final requests = <MatchingHttpRequest>[];
  @override
  MatchingExchange post(MatchingHttpRequest request) {
    requests.add(request);
    return MatchingExchange(response: handler(request), cancel: () {});
  }
}
