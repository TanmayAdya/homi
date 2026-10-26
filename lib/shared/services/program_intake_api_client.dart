import '../models/contracts.dart';
import '../models/program_intake.dart';
import '../models/export_contract_values.dart';
import 'assessment_api_client.dart';
import 'matching_api_client.dart';

class ProgramIntakeApiClient {
  ProgramIntakeApiClient({
    required Uri baseUri,
    required MatchingTokenProvider tokenProvider,
    required MatchingTransport transport,
    bool allowInsecureLoopback = false,
    bool allowAndroidEmulatorLoopback = false,
  }) : _client = PrivateV2JsonClient(
         baseUri: baseUri,
         tokenProvider: tokenProvider,
         transport: transport,
         allowedRoutes: const {'read-program-intake', 'save-program-intake'},
         allowInsecureLoopback: allowInsecureLoopback,
         allowAndroidEmulatorLoopback: allowAndroidEmulatorLoopback,
       );
  final PrivateV2JsonClient _client;
  Future<ProgramIntakeResponse> readIntake(
    CaseSnapshot snapshot, {
    required String programId,
    required bool Function() isCurrent,
  }) async {
    final result = await _client.post(
      'read-program-intake',
      _base(snapshot, programId),
      isCurrent: isCurrent,
    );
    return _parse(result, snapshot, programId, save: false);
  }

  Future<ProgramIntakeResponse> saveIntake(
    CaseSnapshot snapshot, {
    required IntakeDefinition definition,
    required int expectedIntakeRevision,
    required List<IntakeAnswer> answers,
    required bool Function() isCurrent,
  }) async {
    ExportContractValues.integer(expectedIntakeRevision, min: 0);
    final captured = answers
        .map((a) => IntakeAnswer.fromJson(a.toJson(), definition))
        .toList();
    ExportContractValues.unique(captured.map((a) => a.key));
    final result = await _client.post(
      'save-program-intake',
      {
        ..._base(snapshot, definition.programId),
        'expectedIntakeRevision': expectedIntakeRevision,
        'expectedQuestionnaireVersion': definition.questionnaireVersion,
        'answers': captured.map((a) => a.toJson()).toList(),
      },
      isCurrent: isCurrent,
      uncertainCode: 'INTAKE_SAVE_UNCERTAIN',
    );
    final response = _parse(result, snapshot, definition.programId, save: true);
    if (response.saved!.intakeRevision != expectedIntakeRevision + 1 ||
        response.definition.questionnaireVersion !=
            definition.questionnaireVersion) {
      throw MatchingApiException.forCode('INTAKE_SAVE_UNCERTAIN');
    }
    return response;
  }

  Map<String, Object?> _base(CaseSnapshot snapshot, String programId) => {
    'schemaVersion': '2',
    'caseId': ExportContractValues.id(snapshot.caseId),
    'expectedCaseRevision': ExportContractValues.integer(snapshot.revision),
    'programId': ExportContractValues.id(programId),
  };
  ProgramIntakeResponse _parse(
    Object? value,
    CaseSnapshot snapshot,
    String programId, {
    required bool save,
  }) {
    try {
      final result = ProgramIntakeResponse.fromJson(value);
      if (result.caseId != snapshot.caseId ||
          result.caseRevision != snapshot.revision + (save ? 1 : 0) ||
          result.definition.programId != programId ||
          save && (!result.isCurrent || result.saved == null)) {
        ExportContractValues.invalid();
      }
      return result;
    } catch (_) {
      throw MatchingApiException.forCode(
        save ? 'INTAKE_SAVE_UNCERTAIN' : 'UNEXPECTED_RESPONSE',
      );
    }
  }
}
