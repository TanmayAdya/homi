import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/app/live_app.dart';
import 'package:safe_at_home/features/cases/case_home_screen.dart';
import 'package:safe_at_home/shared/services/matching_api_client.dart';
import '../services/case_evidence_api_client_test.dart' as http;
import 'case_coordinator_test.dart' show FakeSession, FakeTransport;
import 'live_workflows_test.dart' show MemoryPrivateStore, input;

Map<String, Object?> copy(Object value) =>
    Map<String, Object?>.from(jsonDecode(jsonEncode(value)) as Map);

void main() {
  testWidgets(
    'SCFHP case connects profile, program intake, reviewed form, private draft and manual history',
    (tester) async {
      final fixtures =
          jsonDecode(
                File(
                  'contracts/v2/fixtures/team-programs.json',
                ).readAsStringSync(),
              )
              as List;
      final fixture = copy(
        fixtures.firstWhere((item) => item['programId'] == 'scfhp-eaa'),
      );
      Map<String, Object?>? serverCase,
          savedIntake,
          savedAnswers,
          exportRequest;
      final events = <Map<String, Object?>>[];
      final pdf = utf8.encode(
        '%PDF-1.7\nFictional workflow transport fixture\n%%EOF',
      );
      final current = DateTime.now().toUtc();
      final now = DateTime.utc(
        current.year,
        current.month,
        current.day,
        current.hour,
        current.minute,
        current.second,
      );
      final stamp = now.toIso8601String();
      int revision() => serverCase!['revision'] as int;
      String id() => serverCase!['caseId'] as String;
      Map<String, Object?> intake() => {
        ...copy(fixture['intake']!),
        'caseId': id(),
        'caseRevision': revision(),
        'saved': savedIntake,
        'isCurrent': savedIntake?['caseRevision'] == revision(),
      };
      Map<String, Object?> form() => {
        ...copy(fixture['form']!),
        'caseId': id(),
        'caseRevision': revision(),
        'saved': savedAnswers,
        'isCurrent': savedAnswers?['caseRevision'] == revision(),
      };
      Map<String, Object?> history() => {
        'schemaVersion': '1',
        'caseId': id(),
        'caseRevision': revision(),
        'programId': 'scfhp-eaa',
        'requestRevision': events.length,
        'provenance': 'user_reported',
        'events': events,
      };
      final transport = FakeTransport((request) async {
        final body = http.requestJson(request);
        switch (request.endpoint.path) {
          case '/v2/list-cases':
            return http.jsonResponse({
              'schemaVersion': '2',
              'cases': serverCase == null
                  ? []
                  : [
                      {
                        'caseId': id(),
                        'caseRevision': revision(),
                        'name': null,
                        'nameRevision': 0,
                        'lastMutationId': null,
                      },
                    ],
              'nextAfterCaseId': null,
            });
          case '/v1/create-case':
            serverCase = {...body, 'revision': 1};
            return http.jsonResponse(serverCase);
          case '/v1/save-case':
            serverCase = {
              ...body..remove('expectedCaseRevision'),
              'revision': revision() + 1,
            };
            return http.jsonResponse(serverCase);
          case '/v1/read-case':
            return http.jsonResponse(serverCase);
          case '/v1/match-case':
            return http.jsonResponse({
              'schemaVersion': '1',
              'caseId': id(),
              'caseRevision': revision(),
              'evaluatedAt': stamp,
              'evaluationDate': stamp.substring(0, 10),
              'matches': [
                {
                  'programId': 'scfhp-eaa',
                  'programName': 'SCFHP EAA — fictional test case',
                  'ruleVersion': 'test-review-required',
                  'isDemo': false,
                  'status': 'needs_confirmation',
                  'availability': 'unverified',
                  'recheckAfter': null,
                  'checks': [
                    {
                      'id': 'professional',
                      'status': 'unknown',
                      'reasonCode': 'PROFESSIONAL_REVIEW',
                      'explanation':
                          'A professional must review medical necessity.',
                      'missingFields': [],
                      'resolvedBy': 'professional',
                      'sourceIds': [],
                    },
                  ],
                  'sources': [],
                  'requiredDocuments': [],
                  'intake': null,
                },
              ],
            });
          case '/v2/read-program-intake':
            return http.jsonResponse(intake());
          case '/v2/save-program-intake':
            serverCase!['revision'] = revision() + 1;
            savedIntake = {
              'schemaVersion': '2',
              'caseId': id(),
              'caseRevision': revision(),
              'programId': 'scfhp-eaa',
              'questionnaireVersion':
                  (intake()['definition'] as Map)['questionnaireVersion'],
              'intakeRevision': 1,
              'updatedAt': stamp,
              'updatedBy': 'fictional-owner',
              'answers': body['answers'],
            };
            return http.jsonResponse(intake());
          case '/v2/read-form-answers':
            return http.jsonResponse(form());
          case '/v2/save-form-answers':
            serverCase!['revision'] = revision() + 1;
            savedAnswers = {
              'schemaVersion': '1',
              'caseId': id(),
              'caseRevision': revision(),
              ...copy(form()['context']!),
              'answerRevision': 1,
              'updatedAt': stamp,
              'updatedBy': 'fictional-owner',
              'answers': [
                for (final answer in body['answers'] as List)
                  {
                    ...copy(answer),
                    'reviewedAt': answer['reviewState'] == 'reviewed'
                        ? stamp
                        : null,
                    'reviewedBy': answer['reviewState'] == 'reviewed'
                        ? 'fictional-owner'
                        : null,
                  },
              ],
            };
            return http.jsonResponse(form());
          case '/v1/list-evidence':
            return http.jsonResponse({
              'schemaVersion': '1',
              'caseId': id(),
              'caseRevision': revision(),
              'catalogRevision': 0,
              'evidence': [],
            });
          case '/v2/create-draft-export':
            exportRequest = body;
            return http.jsonResponse({
              'schemaVersion': '2',
              'artifactId': 'fictional-artifact',
              'caseId': id(),
              'caseRevision': revision(),
              ...copy(form()['context']!),
              'ruleVersion': 'test-review-required',
              'answerRevision': 1,
              'evidenceCatalogRevision': 0,
              'exportContextId': List.filled(64, 'a').join(),
              'generatedAt': stamp,
              'expiresAt': now
                  .add(const Duration(minutes: 10))
                  .toIso8601String(),
              'recheckAfter': null,
              'status': 'draft',
              'isDemo': false,
              'mediaType': 'application/pdf',
              'byteLength': pdf.length,
              'sha256': sha256.convert(pdf).toString(),
              'pageCount': 1,
              'renderingVersion': 'draft-export-annotations-v2',
              'selectedEvidence': [],
              'missingItems': [
                {
                  'id': 'review',
                  'description': 'Professional review remains required.',
                  'resolvedBy': 'professional',
                },
              ],
              'warnings': [
                'INCOMPLETE_DRAFT',
                'NOT_SUBMITTED',
                'POLICY_CURRENTNESS_UNKNOWN',
              ],
            });
          case '/v2/download-draft-export':
            return MatchingHttpResponse(
              statusCode: 200,
              contentType: 'application/pdf',
              body: pdf,
            );
          case '/v1/read-request-history':
            return http.jsonResponse(history());
          case '/v1/append-request-update':
            events.add({
              ...copy(body['update']!),
              'revision': events.length + 1,
              'caseRevision': revision(),
              'recordedAt': stamp,
            });
            return http.jsonResponse(history());
          default:
            throw StateError(
              'Unexpected fictional route: ${request.endpoint.path}',
            );
        }
      });
      final store = MemoryPrivateStore();
      final app = AppServices(
        config: LiveAppConfig(
          apiOrigin: Uri.parse('https://example.org'),
          supabaseUrl: Uri.parse('https://example.supabase.co'),
          publishableKey: 'fictional',
        ),
        session: FakeSession(),
        store: store,
        transport: transport,
        pdfPreviewBuilder: (bytes) {
          expect(bytes, pdf);
          return const Text('Validated fictional PDF preview');
        },
      );
      addTearDown(app.dispose);
      Future<void> tap(String label, {double direction = 250}) async {
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(
          find.text(label),
          direction,
          scrollable: find.byType(Scrollable).first,
          maxScrolls: 60,
        );
        await Scrollable.ensureVisible(
          tester.element(find.text(label).first),
          alignment: 0.5,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text(label).first);
        await tester.pumpAndSettle();
      }

      Future<void> back() async {
        await tester.pageBack();
        await tester.pumpAndSettle();
      }

      await tester.pumpWidget(MaterialApp(home: CaseHomeScreen(services: app)));
      await tester.pumpAndSettle();
      await tap('Start a home plan');
      await tester.ensureVisible(find.byKey(const ValueKey('plan-name-save')));
      await tester.tap(find.byKey(const ValueKey('plan-name-save')));
      await tester.pumpAndSettle();
      await tap('Resident details');
      await tester.enterText(input('City'), 'Fictional San Jose');
      await tester.scrollUntilVisible(
        input('Annual household income (USD)'),
        250,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.enterText(input('Annual household income (USD)'), '0');
      await tap('Done');
      expect(revision(), 2);
      expect((serverCase!['profile'] as Map)['annualIncomeUsd'], 0);
      expect((serverCase!['profile'] as Map)['ageYears'], isNull);
      await tester.tap(find.byKey(const ValueKey('plan-tab-help')));
      await tester.pumpAndSettle();
      await tap('Details');
      await tester.scrollUntilVisible(
        find.text('A professional must review medical necessity.'),
        250,
        scrollable: find.byType(Scrollable).first,
      );
      expect(
        find.text('A professional must review medical necessity.'),
        findsOneWidget,
      );
      await tap('Start application');
      expect(find.text('Draft · not sent'), findsOneWidget);
      expect(find.text('Official form draft'), findsOneWidget);
      Future<void> nowStep() async {
        final action = find.byKey(const ValueKey('workspace-now'));
        await tester.scrollUntilVisible(
          action,
          -250,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.tap(action);
        await tester.pumpAndSettle();
      }

      await nowStep();
      expect(find.text('Program questions'), findsOneWidget);
      await tap('Save');
      expect(revision(), 3);
      await nowStep();
      await tester.scrollUntilVisible(
        input('Given name'),
        250,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.enterText(input('Given name'), 'Fictional Resident');
      await tester.pumpAndSettle();
      await tap('Confirm these answers');
      expect(revision(), 4);
      final supplied = (savedAnswers!['answers'] as List).first;
      expect(supplied['value'], 'Fictional Resident');
      expect(supplied['reviewState'], 'reviewed');
      await nowStep();
      await tap('Create draft PDF');
      expect(exportRequest!['schemaVersion'], '2');
      expect(exportRequest!['expectedCaseRevision'], 4);
      expect(exportRequest!['expectedAnswerRevision'], 1);
      expect(exportRequest!['selectedEvidence'], isEmpty);
      expect(
        transport.requests.any(
          (r) => r.endpoint.path == '/v2/download-draft-export',
        ),
        true,
        reason: tester
            .widgetList<Text>(find.byType(Text))
            .map((w) => w.data)
            .join(' | '),
      );
      await tester.scrollUntilVisible(
        find.text('Validated fictional PDF preview'),
        250,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('Validated fictional PDF preview'), findsOneWidget);
      await tap('Unresolved draft items');
      expect(
        find.text('Professional review remains required.'),
        findsOneWidget,
      );
      await back();
      expect(find.textContaining('The case changed.'), findsNothing);
      expect(find.text('You send it — the app can’t'), findsOneWidget);
      await tap('Updates');
      await tap('Add update');
      await tester.scrollUntilVisible(
        input('Optional note'),
        250,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.enterText(
        input('Optional note'),
        'Fictional resident will ask the program about missing documents.',
      );
      await tap('Save update');
      expect(events, hasLength(1));
      expect(events.single['status'], 'preparing');
      await tester.scrollUntilVisible(
        find.text('Manual update saved. This is not verified agency status.'),
        -300,
        scrollable: find.byType(Scrollable).first,
        maxScrolls: 60,
      );
      expect(
        find.text('Manual update saved. This is not verified agency status.'),
        findsOneWidget,
      );
      expect(
        transport.requests.every(
          (request) => request.bearerToken == 'fictional-token',
        ),
        true,
      );
      expect(store.records.keys.any((key) => key.startsWith('export.')), true);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );
}
