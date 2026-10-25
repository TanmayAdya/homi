import 'dart:convert';
import 'package:crypto/crypto.dart';
import '../models/annotated_export.dart';
import '../models/draft_export.dart';
import '../models/evidence.dart';
import '../models/export_contract_values.dart';
import 'assessment_api_client.dart';
import 'matching_api_client.dart';

class AnnotatedExportApiClient {
  AnnotatedExportApiClient({
    required Uri baseUri,
    required MatchingTokenProvider tokenProvider,
    required MatchingTransport transport,
    DateTime Function()? now,
    bool allowInsecureLoopback = false,
    bool allowAndroidEmulatorLoopback = false,
  }) : _now = now ?? DateTime.now,
       _client = PrivateV2JsonClient(
         baseUri: baseUri,
         tokenProvider: tokenProvider,
         transport: transport,
         allowedRoutes: const {'create-draft-export', 'download-draft-export'},
         allowInsecureLoopback: allowInsecureLoopback,
         allowAndroidEmulatorLoopback: allowAndroidEmulatorLoopback,
       );
  final PrivateV2JsonClient _client;
  final DateTime Function() _now;

  Future<AnnotatedExportArtifact> createDraftExport(
    Map<String, Object?> retainedRequest, {
    required bool Function() isCurrent,
  }) async {
    final request =
        ExportContractValues.object(jsonDecode(jsonEncode(retainedRequest)), {
          'schemaVersion',
          'caseId',
          'expectedCaseRevision',
          'programId',
          'expectedFormContextId',
          'expectedAnswerRevision',
          'expectedEvidenceCatalogRevision',
          'generationKey',
          'selectedEvidence',
        });
    if (request['schemaVersion'] != '2') ExportContractValues.invalid();
    for (final key in ['caseId', 'programId']) {
      ExportContractValues.id(request[key]);
    }
    ExportContractValues.integer(request['expectedCaseRevision']);
    ExportContractValues.digest(request['expectedFormContextId']);
    for (final key in [
      'expectedAnswerRevision',
      'expectedEvidenceCatalogRevision',
    ]) {
      ExportContractValues.integer(request[key], min: 0);
    }
    final generation = request['generationKey'];
    if (generation is! String ||
        generation.length < 8 ||
        generation.length > 128 ||
        RegExp(r'[^A-Za-z0-9_-]').hasMatch(generation)) {
      ExportContractValues.invalid();
    }
    final selections = ExportContractValues.list(request['selectedEvidence'], (
      raw,
    ) {
      final value = ExportContractValues.object(raw, {
        'evidenceId',
        'expectedEvidenceRevision',
        'expectedAnnotationRevision',
        'reviewedForExport',
      });
      ExportContractValues.integer(value['expectedAnnotationRevision'], min: 0);
      EvidenceSelection.fromJson(
        {...value}..remove('expectedAnnotationRevision'),
      );
      return value;
    }, 6);
    ExportContractValues.unique(
      selections.map((value) => value['evidenceId'] as String),
    );
    final artifact = AnnotatedExportArtifact.fromJson(
      await _client.post('create-draft-export', request, isCurrent: isCurrent),
    );
    final base = artifact.base;
    final actual = artifact.toJson()['selectedEvidence'] as List;
    if (base.caseId != request['caseId'] ||
        base.caseRevision != request['expectedCaseRevision'] ||
        base.programId != request['programId'] ||
        base.formContextId != request['expectedFormContextId'] ||
        base.answerRevision != request['expectedAnswerRevision'] ||
        base.evidenceCatalogRevision !=
            request['expectedEvidenceCatalogRevision'] ||
        actual.length != selections.length ||
        actual.any(
          (item) => !selections.any(
            (selection) =>
                item['evidenceId'] == selection['evidenceId'] &&
                item['evidenceRevision'] ==
                    selection['expectedEvidenceRevision'] &&
                item['annotationRevision'] ==
                    selection['expectedAnnotationRevision'],
          ),
        )) {
      throw MatchingApiException.forCode('UNEXPECTED_RESPONSE');
    }
    _timeGuard(artifact);
    return artifact;
  }

  Future<List<int>> downloadDraftExport(
    AnnotatedExportArtifact artifact, {
    required bool Function() isCurrent,
  }) async {
    final captured = AnnotatedExportArtifact.fromJson(artifact.toJson());
    bool guard() {
      _timeGuard(captured);
      return isCurrent();
    }

    final base = captured.base;
    final result = await _client.post(
      'download-draft-export',
      {
        'schemaVersion': '2',
        'caseId': base.caseId,
        'expectedCaseRevision': base.caseRevision,
        'artifactId': base.artifactId,
      },
      isCurrent: guard,
      accept: 'application/pdf',
      maxResponseBytes: maxDraftExportBytes,
    );
    if (result is! List<int> ||
        result.length != base.byteLength ||
        result.length < 5 ||
        utf8.decode(result.take(5).toList(), allowMalformed: true) != '%PDF-' ||
        sha256.convert(result).toString() != base.sha256) {
      throw MatchingApiException.forCode('UNEXPECTED_RESPONSE');
    }
    _timeGuard(captured);
    return result;
  }

  void _timeGuard(AnnotatedExportArtifact artifact) {
    if (!artifact.base.isAvailableAt(_now().toUtc())) {
      throw MatchingApiException.forCode('EXPORT_EXPIRED');
    }
  }
}
