import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/features/programs/program_intake_screen.dart';
import 'package:safe_at_home/features/requests/form_review_screen.dart';
import 'package:safe_at_home/features/requests/request_history_screen.dart';
import 'package:safe_at_home/shared/services/matching_api_client.dart';

import '../contracts/form_answers_test.dart' as forms;
import '../request_tracking_test.dart' as history;
import '../services/case_evidence_api_client_test.dart' as http;
import 'case_coordinator_test.dart' show FakeTransport;
import 'live_workflows_test.dart'
    show MemoryPrivateStore, services, program, input;
import 'program_localization_support.dart';

const _boundary =
    'Program information and official forms may remain in English. Your saved answers are not translated.';
const _original = 'Next action — Casa de María 李家 {status}';

void main() {
  for (final locale in programLocales) {
    String tr(String text, [Map<String, Object?> args = const {}]) =>
        programText(locale, text, args);

    testWidgets(
      '$locale intake validates, saves unknown/No/zero, and resumes original answers at 3.2x',
      (tester) async {
        largeProgramViewport(tester);
        Map<String, Object?>? server, saved;
        var writes = 0;
        final definition = {
          'programId': 'fictional-program',
          'questionnaireVersion': forms.digest,
          'questions': [
            for (final (key, label, kind) in [
              ('coverage', 'Official coverage question', 'boolean'),
              ('unknown', 'Official unresolved question', 'boolean'),
              ('cost', 'Official reported cost', 'money'),
              ('note', 'Official resident note', 'text'),
            ])
              {
                'key': key,
                'label': label,
                'kind': kind,
                'maxLength': kind == 'text' ? 200 : null,
                'description':
                    'Original official explanation — do not translate {count}.',
              },
          ],
        };
        Map<String, Object?> response() => {
          'schemaVersion': '2',
          'caseId': server!['caseId'],
          'caseRevision': server!['revision'],
          'definition': definition,
          'saved': saved,
          'isCurrent': saved != null,
        };
        final transport = FakeTransport((request) async {
          final body = http.requestJson(request);
          switch (request.endpoint.path) {
            case '/v1/create-case':
              server = {...body, 'revision': 1};
              return http.jsonResponse(server);
            case '/v1/read-case':
              return http.jsonResponse(server);
            case '/v2/read-program-intake':
              return http.jsonResponse(response());
            case '/v2/save-program-intake':
              writes++;
              server!['revision'] = 2;
              saved = {
                'schemaVersion': '2',
                'caseId': server!['caseId'],
                'caseRevision': 2,
                'programId': 'fictional-program',
                'questionnaireVersion': forms.digest,
                'intakeRevision': 1,
                'updatedAt': forms.stamp,
                'updatedBy': 'fictional-owner',
                'answers': body['answers'],
              };
              return http.jsonResponse(response());
            default:
              throw StateError('Unexpected request: ${request.endpoint.path}');
          }
        });
        final app = services(MemoryPrivateStore(), transport);
        addTearDown(() {
          app.dispose();
          app.session.dispose();
        });
        await app.coordinator.createDraft();
        await app.coordinator.save();
        Widget screen() => programTestApp(
          locale,
          ProgramIntakeScreen(services: app, program: program()),
        );
        await tester.pumpWidget(screen());
        await tester.pumpAndSettle();
        expect(find.text(tr(_boundary)), findsOneWidget);
        final coverage = find.byKey(const ValueKey('coverage-false'));
        await revealProgramControl(tester, coverage);
        await tester.tap(coverage);
        await tester.pumpAndSettle();
        expect(find.text(tr('Not sure')), findsNWidgets(2));
        expect(find.text(tr('Unknown')), findsNothing);
        final cost = input('Official reported cost');
        await revealProgramControl(tester, cost);
        await tester.enterText(cost, '-1');
        final note = input('Official resident note');
        await revealProgramControl(tester, note);
        await tester.enterText(note, _original);
        final save = find.byKey(const ValueKey('intake-save'));
        await revealProgramControl(tester, save);
        await tester.tap(save);
        await tester.pumpAndSettle();
        expect(writes, 0);
        const invalid =
            'Enter a nonnegative amount with at most two decimal places, or leave blank.';
        expect(
          find.text(
            tr('{field}: {message}', {
              'field': 'Official reported cost',
              'message': tr(invalid),
            }),
          ),
          findsOneWidget,
        );
        final review = find.widgetWithText(
          OutlinedButton,
          tr('Review this answer'),
        );
        await revealProgramControl(tester, review);
        await tester.tap(review);
        await tester.pumpAndSettle();
        await tester.enterText(cost, '0');
        await revealProgramControl(tester, save);
        await tester.tap(save);
        await tester.pumpAndSettle();
        expect(writes, 1);
        expect(app.coordinator.snapshot!.revision, 2);
        final answers = {
          for (final a in saved!['answers'] as List) a['key']: a,
        };
        expect(answers['coverage']['value'], false);
        expect(answers['unknown']['value'], isNull);
        expect(answers['unknown']['reviewState'], 'unknown');
        expect(answers['cost']['value'], 0);
        expect(answers['note']['value'], _original);
        expect(
          find.text(tr('Answers saved. Program checks update on their own.')),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpWidget(screen());
        await tester.pumpAndSettle();
        expect(tester.widget<TextField>(note).controller!.text, _original);
        expect(tester.widget<TextField>(cost).controller!.text, '0');
        final compare = find.text(tr('Compare saved answers'));
        await revealProgramControl(tester, compare);
        await tester.tap(compare);
        await tester.pumpAndSettle();
        expect(find.text(_original), findsWidgets);
        expect(find.text(tr('No')), findsWidgets);
        expect(find.text(tr('Unknown')), findsWidgets);
        expect(writes, 1);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      '$locale administrative review saves original Unicode value and withdraws review on edit at 3.2x',
      (tester) async {
        largeProgramViewport(tester);
        Map<String, Object?>? server, saved;
        Map<String, Object?> response() => {
          ...forms.responseJson(),
          'schemaVersion': '2',
          'caseId': server!['caseId'],
          'caseRevision': server!['revision'],
          'saved': saved,
          'isCurrent': saved != null,
          'fieldDefinitions': [
            {
              'key': 'memberFirstName',
              'label': 'Given name',
              'kind': 'text',
              'maxLength': 160,
            },
          ],
          'artifactKind': 'official_form_draft',
        };
        final transport = FakeTransport((request) async {
          final body = http.requestJson(request);
          switch (request.endpoint.path) {
            case '/v1/create-case':
              server = {...body, 'revision': 1};
              return http.jsonResponse(server);
            case '/v2/read-form-answers':
              return http.jsonResponse(response());
            case '/v2/save-form-answers':
              server!['revision'] = 2;
              saved = {
                ...forms.savedJson(),
                'caseId': server!['caseId'],
                'caseRevision': 2,
                'answers': [
                  for (final answer in body['answers'] as List)
                    {
                      ...answer as Map,
                      'reviewedAt': answer['reviewState'] == 'reviewed'
                          ? forms.stamp
                          : null,
                      'reviewedBy': answer['reviewState'] == 'reviewed'
                          ? 'fictional-user'
                          : null,
                    },
                ],
              };
              return http.jsonResponse(response());
            default:
              throw StateError('Unexpected request: ${request.endpoint.path}');
          }
        });
        final store = MemoryPrivateStore();
        final app = services(store, transport);
        addTearDown(() {
          app.dispose();
          app.session.dispose();
        });
        await app.coordinator.createDraft();
        await app.coordinator.save();
        await tester.pumpWidget(
          programTestApp(
            locale,
            FormReviewScreen(
              services: app,
              program: program(programId: 'scfhp-eaa'),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text(tr(_boundary)), findsOneWidget);
        final field = input(tr('Given name'));
        await revealProgramControl(tester, field);
        await tester.enterText(field, _original);
        await tester.pumpAndSettle();
        final unconfirmed = find.byKey(
          const ValueKey('form-unconfirmed-memberFirstName'),
        );
        expect(unconfirmed, findsOneWidget);
        expect(find.text(tr('Not confirmed yet')), findsOneWidget);
        final save = find.byKey(const ValueKey('form-save'));
        expect(
          find.descendant(
            of: save,
            matching: find.text(tr('Confirm these answers')),
          ),
          findsOneWidget,
        );
        await revealProgramControl(tester, save);
        await tester.tap(save);
        await tester.pumpAndSettle();
        expect(saved, isNotNull);
        final answer = (saved!['answers'] as List).single;
        expect(answer['value'], _original);
        expect(answer['reviewState'], 'reviewed');
        expect(find.text(tr('Answers saved.')), findsOneWidget);
        expect(unconfirmed, findsNothing);
        await revealProgramControl(tester, field);
        await tester.enterText(field, '$_original 2');
        await tester.pumpAndSettle();
        expect(unconfirmed, findsOneWidget);
        expect(
          transport.requests.where(
            (r) => r.endpoint.path == '/v2/save-form-answers',
          ),
          hasLength(1),
        );
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      '$locale manual history menus and uncertain update reconcile without retranslating or resending at 3.2x',
      (tester) async {
        largeProgramViewport(tester);
        Map<String, Object?>? server, event;
        var writes = 0;
        Map<String, Object?> response() => {
          ...history.historyJson(caseRevision: 1),
          'caseId': server!['caseId'],
          'programId': 'fictional-program',
          'requestRevision': event == null ? 0 : 1,
          'events': [?event],
        };
        final transport = FakeTransport((request) async {
          final body = http.requestJson(request);
          switch (request.endpoint.path) {
            case '/v1/create-case':
              server = {...body, 'revision': 1};
              return http.jsonResponse(server);
            case '/v1/read-request-history':
              return http.jsonResponse(response());
            case '/v1/append-request-update':
              writes++;
              event = {
                ...body['update'] as Map,
                'revision': 1,
                'caseRevision': 1,
                'recordedAt': DateTime.fromMillisecondsSinceEpoch(
                  DateTime.now().millisecondsSinceEpoch,
                  isUtc: true,
                ).toIso8601String(),
              };
              throw const MatchingTransportException(
                MatchingTransportFailure.network,
              );
            default:
              throw StateError('Unexpected request: ${request.endpoint.path}');
          }
        });
        final app = services(MemoryPrivateStore(), transport);
        addTearDown(() {
          app.dispose();
          app.session.dispose();
        });
        await app.coordinator.createDraft();
        await app.coordinator.save();
        await tester.pumpWidget(
          programTestApp(
            locale,
            RequestHistoryScreen(services: app, program: program()),
          ),
        );
        await tester.pumpAndSettle();
        final add = find.byKey(const ValueKey('history-add'));
        await revealProgramControl(tester, add);
        await tester.tap(add);
        await tester.pumpAndSettle();
        for (final (value, label) in [
          ('preparing', 'Preparing'),
          ('submitted', 'Submitted'),
          ('received', 'Received'),
          ('needs_information', 'Needs info'),
          ('approved', 'Approved'),
          ('denied', 'Denied'),
          ('withdrawn', 'Withdrawn'),
        ]) {
          expect(
            find.descendant(
              of: find.byKey(ValueKey('history-status-$value')),
              matching: find.text(tr(label)),
            ),
            findsOneWidget,
          );
        }
        final needsInfo = find.byKey(
          const ValueKey('history-status-needs_information'),
        );
        await revealProgramControl(tester, needsInfo);
        await tester.tap(needsInfo);
        await tester.pumpAndSettle();
        final more = find.text(tr('Follow-up and source'));
        await revealProgramControl(tester, more);
        await tester.tap(more);
        await tester.pumpAndSettle();
        for (final (key, selected, labels) in [
          (
            'source-false',
            'Program contact',
            ['Self report', 'Program contact', 'Document'],
          ),
          (
            'party-false',
            'Clinician',
            [
              'Resident',
              'Caregiver',
              'Program',
              'Clinician',
              'Contractor',
              'Other',
            ],
          ),
        ]) {
          final menu = find.byKey(ValueKey(key));
          await revealProgramControl(tester, menu);
          final dropdown = tester.widget<DropdownButtonFormField<String>>(menu);
          final button = tester.widget<DropdownButton<String>>(
            find.descendant(
              of: menu,
              matching: find.byType(DropdownButton<String>),
            ),
          );
          expect(
            button.items!.map((item) => (item.child as Text).data).toList(),
            labels.map(tr).toList(),
          );
          expect(dropdown.enabled, isTrue);
          await tester.tap(menu);
          await tester.pumpAndSettle();
          final choice = find.text(tr(selected));
          await tester.scrollUntilVisible(
            choice,
            150,
            scrollable: find.byType(Scrollable).last,
            maxScrolls: 30,
          );
          await tester.ensureVisible(choice);
          await tester.pumpAndSettle();
          await tester.tap(choice);
          await tester.pumpAndSettle();
        }
        final note = input(tr('Optional note'));
        await revealProgramControl(tester, note);
        await tester.enterText(note, _original);
        final action = input(tr('Optional next action'));
        await revealProgramControl(tester, action);
        await tester.enterText(action, 'Call {status} 李家');
        final save = find.byKey(const ValueKey('history-save'));
        await revealProgramControl(tester, save);
        await tester.tap(save);
        await tester.pumpAndSettle();
        expect(writes, 1);
        expect(event!['status'], 'needs_information');
        expect(event!['source'], 'program_contact');
        expect(event!['responsibleParty'], 'clinician');
        expect(event!['note'], _original);
        expect(find.text(tr('Pending update')), findsOneWidget);
        expect(find.text(_original), findsOneWidget);
        expect(
          find.text(
            tr(
              MatchingApiException.forCode('REQUEST_UPDATE_UNCERTAIN').message,
            ),
          ),
          findsOneWidget,
        );
        final reload = find.byKey(const ValueKey('history-reconcile'));
        await revealProgramControl(tester, reload);
        await tester.tap(reload);
        await tester.pumpAndSettle();
        expect(writes, 1);
        expect(find.text(tr('Pending update')), findsNothing);
        expect(
          find.text(tr('The pending update was already saved.')),
          findsOneWidget,
        );
        expect(find.textContaining(_original), findsOneWidget);
        expect(find.textContaining('Call {status} 李家'), findsOneWidget);
        expect(
          find.textContaining(
            tr('Responsible: {party}', {'party': tr('Clinician')}),
          ),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }
}
