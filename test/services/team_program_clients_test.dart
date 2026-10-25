import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/shared/models/contracts.dart';
import 'package:safe_at_home/shared/models/form_answers.dart';
import 'package:safe_at_home/shared/models/program_intake.dart';
import 'package:safe_at_home/shared/services/form_answers_api_client.dart';
import 'package:safe_at_home/shared/services/program_intake_api_client.dart';
import 'package:safe_at_home/shared/services/matching_api_client.dart';
import '../case_discovery_api_client_test.dart'
    show FakeTransport, jsonResponse, apiError, failure;

List<Map<String, Object?>> fixtures() =>
    (jsonDecode(
              File(
                'contracts/v2/fixtures/team-programs.json',
              ).readAsStringSync(),
            )
            as List)
        .map((v) => Map<String, Object?>.from(v as Map))
        .toList();
void main() {
  for (final fixture in fixtures()) {
    final program = fixture['programId'] as String;
    test(
      '$program shared intake and independent form definitions round-trip strictly',
      () {
        final intake = ProgramIntakeResponse.fromJson(fixture['intake']);
        expect(intake.toJson(), fixture['intake']);
        expect(intake.saved!.answers.first.value, false);
        final form = FormAnswersResponse.fromV2Json(fixture['form']);
        expect(form.toJson(), fixture['form']);
        expect(
          form.fieldDefinitions.length,
          program == 'scfhp-eaa'
              ? 18
              : program == 'hpsm-eaa'
              ? 10
              : 4,
        );
        expect(
          form.artifactKind,
          program == 'rtp-home-repair'
              ? 'preparation_worksheet'
              : 'official_form_draft',
        );
        expect(
          () => FormAnswersResponse.fromJson(fixture['form']),
          throwsFormatException,
        );
        expect(
          () => ProgramIntakeResponse.fromJson({
            ...fixture['intake'] as Map,
            'isCurrent': false,
          }),
          throwsFormatException,
        );
      },
    );
  }
  test(
    'v2 form transport uses fixed routes and rejects an old protocol response',
    () async {
      final fixture = fixtures()[1];
      final snapshot = CaseSnapshot.fromJson({
        ...fixture['case'] as Map,
        'revision': 2,
      });
      final transport = FakeTransport(
        (_) async => jsonResponse(fixture['form']),
      );
      final client = FormAnswersApiClient(
        protocolVersion: '2',
        readEndpoint: Uri.parse(
          'https://fictional.example/v2/read-form-answers',
        ),
        saveEndpoint: Uri.parse(
          'https://fictional.example/v2/save-form-answers',
        ),
        caseEndpoint: Uri.parse('https://fictional.example/v1/read-case'),
        tokenProvider: () async => 'fictional-token',
        transport: transport,
      );
      final response = await client.readAnswers(
        snapshot,
        programId: 'hpsm-eaa',
        currentCase: () => snapshot,
        currentProgramId: () => 'hpsm-eaa',
        currentContext: () => null,
      );
      expect(
        response.fieldDefinitions.map((f) => f.key),
        isNot(contains('representativeName')),
      );
      expect(
        jsonDecode(
          utf8.decode(transport.requests.single.body),
        )['schemaVersion'],
        '2',
      );
      expect(transport.requests.single.endpoint.path, '/v2/read-form-answers');
    },
  );
  test(
    'intake save confirms exact program, questionnaire and successor revisions',
    () async {
      final fixture = fixtures()[1];
      final parsed = ProgramIntakeResponse.fromJson(fixture['intake']);
      final snapshot = CaseSnapshot.fromJson(fixture['case']);
      final transport = FakeTransport(
        (_) async => jsonResponse(fixture['intake']),
      );
      final client = ProgramIntakeApiClient(
        baseUri: Uri.parse('https://fictional.example'),
        tokenProvider: () async => 'fictional-token',
        transport: transport,
      );
      final saved = await client.saveIntake(
        snapshot,
        definition: parsed.definition,
        expectedIntakeRevision: 0,
        answers: parsed.saved!.answers,
        isCurrent: () => true,
      );
      expect(saved.caseRevision, 2);
      expect(
        jsonDecode(utf8.decode(transport.requests.single.body)),
        fixture['intakeRequest'],
      );
    },
  );
  test(
    'lost intake save response remains uncertain and never retries automatically',
    () async {
      final fixture = fixtures()[1];
      final parsed = ProgramIntakeResponse.fromJson(fixture['intake']);
      final transport = FakeTransport(
        (_) async => throw const MatchingTransportException(
          MatchingTransportFailure.network,
        ),
      );
      final client = ProgramIntakeApiClient(
        baseUri: Uri.parse('https://fictional.example'),
        tokenProvider: () async => 'fictional-token',
        transport: transport,
      );
      await expectLater(
        client.saveIntake(
          CaseSnapshot.fromJson(fixture['case']),
          definition: parsed.definition,
          expectedIntakeRevision: 0,
          answers: parsed.saved!.answers,
          isCurrent: () => true,
        ),
        throwsA(failure('INTAKE_SAVE_UNCERTAIN')),
      );
      expect(transport.requests, hasLength(1));
    },
  );
  test(
    'account changes reject late intake answers and conflicts stay actionable',
    () async {
      final fixture = fixtures()[1];
      var current = true;
      final pending = Completer<MatchingHttpResponse>();
      final transport = FakeTransport((_) => pending.future);
      final client = ProgramIntakeApiClient(
        baseUri: Uri.parse('https://fictional.example'),
        tokenProvider: () async => 'fictional-token',
        transport: transport,
      );
      final read = client.readIntake(
        CaseSnapshot.fromJson({...fixture['case'] as Map, 'revision': 2}),
        programId: 'hpsm-eaa',
        isCurrent: () => current,
      );
      final assertion = expectLater(read, throwsA(failure('STALE_RESPONSE')));
      await Future<void>.delayed(Duration.zero);
      current = false;
      pending.complete(jsonResponse(fixture['intake']));
      await assertion;
      final conflict = ProgramIntakeApiClient(
        baseUri: Uri.parse('https://fictional.example'),
        tokenProvider: () async => 'fictional-token',
        transport: FakeTransport((_) async => apiError('INTAKE_CONFLICT', 409)),
      );
      await expectLater(
        conflict.readIntake(
          CaseSnapshot.fromJson(fixture['case']),
          programId: 'hpsm-eaa',
          isCurrent: () => true,
        ),
        throwsA(failure('INTAKE_CONFLICT')),
      );
    },
  );
  test(
    'questionnaire answers reject inferred yes, unknown zero, extra fields and unbounded text',
    () {
      final definition = ProgramIntakeResponse.fromJson(
        fixtures()[1]['intake'],
      ).definition;
      for (final value in [
        {
          'key': 'activeMembershipReported',
          'value': 'yes',
          'reviewState': 'reported',
        },
        {'key': 'estimatedCostUsd', 'value': 0, 'reviewState': 'unknown'},
        {'key': 'estimatedCostUsd', 'value': 1.001, 'reviewState': 'reported'},
        {
          'key': 'professionalOrderReported',
          'value': true,
          'reviewState': 'reported',
          'verifiedBy': 'invented',
        },
      ]) {
        expect(
          () => IntakeAnswer.fromJson(value, definition),
          throwsFormatException,
        );
      }
    },
  );
}
