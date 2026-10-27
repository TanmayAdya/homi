import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/app/theme.dart';
import 'package:safe_at_home/features/requests/private_export_screen.dart';
import 'package:safe_at_home/shared/models/case_draft.dart';
import 'package:safe_at_home/shared/services/matching_api_client.dart';

import '../contracts/draft_export_test.dart' as evidence;
import '../contracts/form_answers_test.dart' as forms;
import '../services/case_evidence_api_client_test.dart' as http;
import 'case_coordinator_test.dart' show FakeTransport;
import 'live_workflows_test.dart' show MemoryPrivateStore, services, program;

void main() {
  testWidgets(
    'v2 capacity rejection retains reviewed photo and exact journal across reopen and retry',
    (tester) async {
      final store = MemoryPrivateStore();
      final attempts = <List<int>>[];
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
                'marks': <Object>[],
                'reviewState': 'reviewed',
                'reviewedCaseRevision': 1,
                'reviewedAt': evidence.stamp,
                'reviewedBy': 'fictional-owner',
              },
            });
          case '/v2/create-draft-export':
            attempts.add(List<int>.of(request.body));
            return MatchingHttpResponse(
              statusCode: 507,
              contentType: 'application/json',
              body: utf8.encode(
                jsonEncode({
                  'schemaVersion': '2',
                  'error': {
                    'code': 'STORAGE_LIMIT_REACHED',
                    'message': 'Private capacity internals',
                  },
                }),
              ),
            );
          default:
            throw StateError(
              'Capacity rejection must not download, upload or submit.',
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
          'findings': evidence.snapshot().toJson()['findings'],
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
      Widget screen() => MaterialApp(
        theme: SafeAtHomeTheme.light(),
        home: PrivateExportScreen(
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

      final selection = find.text('Included · 1');
      final prepare = find.text('Finish draft');
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
        final notice = find.text(
          'Private storage has reached its limit. Contact the app operator before retrying.',
        );
        await reveal(notice, delta: -260);
        expect(notice, findsOneWidget);
        expect(find.textContaining('Private capacity internals'), findsNothing);
        await reveal(selection);
        expect(selection, findsOneWidget);
        await reveal(prepare);
        final button = find.ancestor(
          of: prepare,
          matching: find.byType(FilledButton),
        );
        expect(tester.widget<FilledButton>(button).onPressed, isNotNull);
        expect(find.text('Share draft file'), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      }
      expect(attempts[1], attempts[0]);
      expect(app.coordinator.snapshot!.revision, 1);
    },
  );
}
