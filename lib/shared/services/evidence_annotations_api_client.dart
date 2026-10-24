import 'dart:convert';
import '../models/evidence_annotations.dart';
import 'assessment_api_client.dart';
import 'matching_api_client.dart';

class EvidenceAnnotationsApiClient {
  EvidenceAnnotationsApiClient({
    required Uri baseUri,
    required MatchingTokenProvider tokenProvider,
    required MatchingTransport transport,
    bool allowInsecureLoopback = false,
    bool allowAndroidEmulatorLoopback = false,
  }) : _client = PrivateV2JsonClient(
         baseUri: baseUri,
         tokenProvider: tokenProvider,
         transport: transport,
         allowedRoutes: const {
           'read-evidence-annotations',
           'save-evidence-annotations',
         },
         allowInsecureLoopback: allowInsecureLoopback,
         allowAndroidEmulatorLoopback: allowAndroidEmulatorLoopback,
       );
  final PrivateV2JsonClient _client;
  Future<AnnotationState> readAnnotations(
    Map<String, Object?> retainedRequest, {
    required bool Function() isCurrent,
  }) => _run(retainedRequest, isCurrent, false);
  Future<AnnotationState> saveAnnotations(
    Map<String, Object?> retainedRequest, {
    required bool Function() isCurrent,
  }) => _run(retainedRequest, isCurrent, true);
  Future<AnnotationState> _run(
    Map<String, Object?> request,
    bool Function() isCurrent,
    bool save,
  ) async {
    request = Map<String, Object?>.from(jsonDecode(jsonEncode(request)) as Map);
    final result = AnnotationState.fromJson(
      await _client.post(
        save ? 'save-evidence-annotations' : 'read-evidence-annotations',
        request,
        isCurrent: isCurrent,
        uncertainCode: save ? 'EVIDENCE_SAVE_UNCERTAIN' : null,
      ),
    );
    if (result.caseId != request['caseId'] ||
        result.caseRevision != request['expectedCaseRevision'] ||
        result.annotation['evidenceId'] != request['evidenceId'] ||
        result.annotation['evidenceRevision'] !=
            request['expectedEvidenceRevision'] ||
        result.catalogRevision !=
            (request['expectedCatalogRevision'] as int) + (save ? 1 : 0) ||
        save &&
            result.annotationRevision !=
                (request['expectedAnnotationRevision'] as int) + 1) {
      throw MatchingApiException.forCode(
        save ? 'EVIDENCE_SAVE_UNCERTAIN' : 'UNEXPECTED_RESPONSE',
      );
    }
    return result;
  }
}
