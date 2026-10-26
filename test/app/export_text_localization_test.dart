import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/features/requests/form_review_screen.dart';
import 'package:safe_at_home/features/requests/private_export_screen.dart';
import 'package:safe_at_home/shared/models/case_draft.dart';
import 'package:safe_at_home/shared/services/matching_api_client.dart';

import '../contracts/draft_export_test.dart' as evidence;
import '../contracts/form_answers_test.dart' as forms;
import '../services/case_evidence_api_client_test.dart' as http;
import 'case_coordinator_test.dart' show FakeTransport;
import 'live_workflows_test.dart' show MemoryPrivateStore, services, program;
import 'program_localization_support.dart';

void main() {
  for (final locale in programLocales) {
    String tr(String text, [Map<String, Object?> args = const {}]) =>
        programText(locale, text, args);
    testWidgets(
      '$locale unsupported PDF text preserves Chinese answers, observations, photo labels and exact retry journal',
      (tester) async {
        largeProgramViewport(tester);
        const originalName = '李明 María {count}';
        const originalObservation = '浴室门槛較高，请保留原文 {number}';
        const originalMark = '扶手位置 — 李家 {count}';
        final store = MemoryPrivateStore();
        final attempts = <List<int>>[];
        final returnedAnnotations = <String>[];
        final transport = FakeTransport((request) async {
          final body = http.requestJson(request);
          switch (request.endpoint.path) {
            case '/v1/create-case':
              return http.jsonResponse({...body, 'revision': 1});
            case '/v1/list-evidence':
              return http.jsonResponse({
                ...evidence.catalogJson(),
                'caseId': body['caseId'],
                'caseRevision': 1,
                'evidence': [
                  {...evidence.descriptorJson(), 'caseId': body['caseId']},
                ],
              });
            case '/v2/read-form-answers':
              return http.jsonResponse({
                ...forms.responseJson(),
                'schemaVersion': '2',
                'caseId': body['caseId'],
                'caseRevision': 1,
                'saved': {
                  ...forms.savedJson(),
                  'caseId': body['caseId'],
                  'caseRevision': 1,
                  'answers': [forms.savedAnswerJson(value: originalName)],
                },
                'fieldDefinitions': [
                  {
                    'key': 'memberFirstName',
                    'label': 'Given name',
                    'kind': 'text',
                    'maxLength': 160,
                  },
                ],
                'artifactKind': 'official_form_draft',
              });
            case '/v2/read-evidence-annotations':
              returnedAnnotations.add(originalMark);
              return http.jsonResponse({
                'schemaVersion': '2',
                'caseId': body['caseId'],
                'caseRevision': 1,
                'catalogRevision': 1,
                'annotation': {
                  'schemaVersion': '2',
                  'caseId': body['caseId'],
                  'evidenceId': 'fictional-evidence',
                  'evidenceRevision': 1,
                  'annotationRevision': 1,
                  'imageSha256': evidence.descriptorJson()['sha256'],
                  'imageWidth': 1,
                  'imageHeight': 1,
                  'coordinateSpace': 'normalized-top-left-1e6',
                  'marks': [
                    {
                      'id': 'original-mark',
                      'rect': [100000, 100000, 500000, 500000],
                      'label': originalMark,
                    },
                  ],
                  'reviewState': 'reviewed',
                  'reviewedCaseRevision': 1,
                  'reviewedAt': evidence.stamp,
                  'reviewedBy': 'fictional-owner',
                },
              });
            case '/v2/create-draft-export':
              attempts.add(List<int>.of(request.body));
              return MatchingHttpResponse(
                statusCode: 422,
                contentType: 'application/json',
                body: utf8.encode(
                  jsonEncode({
                    'schemaVersion': '1',
                    'error': {
                      'code': 'EXPORT_REVIEW_REQUIRED',
                      'message':
                          'Private font internals: WinAnsi cannot encode 李',
                    },
                  }),
                ),
              );
            default:
              throw StateError(
                'Text rendering rejection must not download, rewrite answers, upload or submit.',
              );
          }
        });
        final app = services(store, transport);
        addTearDown(() {
          app.dispose();
          app.session.dispose();
        });
        await app.coordinator.createDraft();
        await app.coordinator.updateDraft(
          CaseDraft.fromJson({
            ...app.coordinator.currentDraft().toJson(),
            'findings': [
              for (final finding
                  in evidence.snapshot().toJson()['findings'] as List)
                {...finding as Map, 'observation': originalObservation},
            ],
          }),
        );
        await app.coordinator.save();
        final id = app.coordinator.snapshot!.caseId;
        final request = <String, Object?>{
          'schemaVersion': '2',
          'caseId': id,
          'expectedCaseRevision': 1,
          'programId': 'scfhp-eaa',
          'expectedFormContextId': forms.digest,
          'expectedAnswerRevision': 1,
          'expectedEvidenceCatalogRevision': 1,
          'generationKey': 'fictional-retained-generation',
          'selectedEvidence': [
            {
              'evidenceId': 'fictional-evidence',
              'expectedEvidenceRevision': 1,
              'expectedAnnotationRevision': 1,
              'reviewedForExport': true,
            },
          ],
        };
        final key = 'export.$id.scfhp-eaa';
        await store.writeJson(key, {
          'fingerprint': sha256
              .convert(
                utf8.encode(
                  jsonEncode({...request, 'generationKey': 'fingerprint'}),
                ),
              )
              .toString(),
          'generation': request['generationKey'],
          'request': request,
        });
        final retained = jsonEncode(store.records[key]);
        final formKey = 'form.$id.scfhp-eaa';
        await store.writeJson(formKey, {
          'values': {'memberFirstName': originalName},
          'reviewed': {'memberFirstName': true},
          'uncertain': false,
          'caseRevision': 1,
          'formContextId': forms.digest,
        });
        final originalForm = jsonEncode(store.records[formKey]);
        final originalCase = jsonEncode(app.coordinator.currentCase().toJson());
        Widget screen() => programTestApp(
          locale,
          PrivateExportScreen(
            services: app,
            program: program(programId: 'scfhp-eaa'),
          ),
        );
        Future<void> reveal(Finder finder, {double delta = 260}) async {
          await tester.scrollUntilVisible(
            finder,
            delta,
            scrollable: find.byType(Scrollable).first,
            maxScrolls: 50,
          );
          await tester.ensureVisible(finder);
          await tester.pumpAndSettle();
        }

        final selection = find.text(tr('Included · {number}', {'number': 1}));
        final prepare = find.text(tr('Finish draft'));
        for (var attempt = 1; attempt <= 2; attempt++) {
          await tester.pumpWidget(screen());
          await tester.pumpAndSettle();
          await reveal(selection);
          expect(selection, findsOneWidget);
          await reveal(prepare);
          await tester.tap(prepare);
          await tester.pumpAndSettle();
          expect(attempts, hasLength(attempt));
          expect(jsonDecode(utf8.decode(attempts.last)), request);
          expect(jsonEncode(store.records[key]), retained);
          expect(jsonEncode(store.records[formKey]), originalForm);
          expect(
            jsonEncode(app.coordinator.currentCase().toJson()),
            originalCase,
          );
          expect(
            transport.requests.where(
              (r) => r.endpoint.path == '/v2/read-evidence-annotations',
            ),
            hasLength(attempt),
          );
          final notice = find.text(
            tr(
              'The draft could not be prepared accurately. Review the text, measurements and images. The current PDF does not support all characters or layouts. Your saved information is kept; preserve the original spelling.',
            ),
          );
          await reveal(notice, delta: -260);
          expect(notice, findsOneWidget);
          expect(find.textContaining('Private font internals'), findsNothing);
          await reveal(selection);
          expect(selection, findsOneWidget);
          await reveal(prepare);
          final button = find.ancestor(
            of: prepare,
            matching: find.byType(FilledButton),
          );
          expect(tester.widget<FilledButton>(button).onPressed, isNotNull);
          expect(find.text(tr('Share draft file')), findsNothing);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pumpAndSettle();
        }
        expect(attempts[1], attempts[0]);
        expect(returnedAnnotations, [originalMark, originalMark]);
        expect(app.coordinator.snapshot!.revision, 1);
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
        final givenNameLabel = tr('Given name');
        expect(find.text(givenNameLabel), findsOneWidget);
        final change = find.byKey(
          const ValueKey('form-change-memberFirstName'),
        );
        await tester.ensureVisible(change);
        await tester.tap(change);
        await tester.pumpAndSettle();
        expect(find.text(givenNameLabel), findsOneWidget);
        final field = find.descendant(
          of: find.byKey(const ValueKey('form-field-memberFirstName')),
          matching: find.byType(TextField),
        );
        expect(tester.widget<TextField>(field).controller!.text, originalName);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
