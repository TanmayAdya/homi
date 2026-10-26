import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/app/theme.dart';
import 'package:safe_at_home/features/requests/application_workspace_screen.dart';
import 'package:safe_at_home/l10n/app_localizations.dart';
import 'package:safe_at_home/shared/models/contracts.dart';
import 'package:safe_at_home/shared/presentation/sah_components.dart';

import '../contracts/form_answers_test.dart' as forms;
import '../request_tracking_test.dart' as history;
import '../services/case_evidence_api_client_test.dart' as http;
import 'case_coordinator_test.dart' show FakeTransport;
import 'live_workflows_test.dart' show MemoryPrivateStore, services;

ProgramMatch _program(String id) => ProgramMatch.fromJson({
  'programId': id,
  'programName': 'Fictional official program title (referral draft)',
  'ruleVersion': 'fictional-rule-v1',
  'isDemo': false,
  'status': 'needs_confirmation',
  'availability': 'unverified',
  'recheckAfter': null,
  'checks': [
    for (final resolver in ['program', 'professional'])
      {
        'id': resolver,
        'status': 'unknown',
        'reasonCode': 'MANUAL_REVIEW',
        'explanation': 'Fictional $resolver confirmation.',
        'missingFields': <String>[],
        'resolvedBy': resolver,
        'sourceIds': <String>[],
      },
  ],
  'sources': <Object>[],
  'requiredDocuments': <String>[],
  'intake': null,
});

void main() {
  testWidgets('overview names are short and singular counts are localized', (
    tester,
  ) async {
    late BuildContext context;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (c) {
            context = c;
            return const SizedBox();
          },
        ),
      ),
    );
    expect(
      programOverviewName(context, 'scfhp-eaa', 'Long official name'),
      'SCFHP home accessibility',
    );
    expect(
      programOverviewName(context, 'unknown', 'Long official name'),
      'Long official name',
    );
    for (final key in [
      '1 item still needed. Nothing has been submitted.',
      '1 item to review',
      '1 thing the program or a professional must confirm',
      '1 evidence reference recorded. Files are not shown here.',
      'SCFHP home accessibility',
      'HPSM home modifications',
      'USDA Section 504 home repair',
      'VA HISA home changes',
    ]) {
      expect(AppLocalizations.translations[key]?.keys.toSet(), {
        'es',
        'zh-Hans',
        'zh-Hant',
        'vi',
        'fil',
      }, reason: key);
    }
  });

  for (final scenario in ['new', 'stale draft', 'sent']) {
    testWidgets('workspace shows one Now step and honest status: $scenario', (
      tester,
    ) async {
      Map<String, Object?>? server;
      final transport = FakeTransport((request) async {
        final body = http.requestJson(request);
        switch (request.endpoint.path) {
          case '/v1/create-case':
            server = {...body, 'revision': 1};
            return http.jsonResponse(server);
          case '/v2/read-program-intake':
            return http.jsonResponse({
              'schemaVersion': '2',
              'caseId': server!['caseId'],
              'caseRevision': 1,
              'definition': {
                'programId': 'scfhp-eaa',
                'questionnaireVersion': forms.digest,
                'questions': [
                  {
                    'key': 'active',
                    'label': 'Fictional active?',
                    'kind': 'boolean',
                    'maxLength': null,
                    'description': 'Fictional.',
                  },
                ],
              },
              'saved': scenario == 'new'
                  ? null
                  : {
                      'schemaVersion': '2',
                      'caseId': server!['caseId'],
                      'caseRevision': 1,
                      'programId': 'scfhp-eaa',
                      'questionnaireVersion': forms.digest,
                      'intakeRevision': 1,
                      'updatedAt': forms.stamp,
                      'updatedBy': 'fictional-user',
                      'answers': [
                        {
                          'key': 'active',
                          'value': null,
                          'reviewState': 'unknown',
                        },
                      ],
                    },
              'isCurrent': scenario != 'new',
            });
          case '/v2/read-form-answers':
            return http.jsonResponse({
              ...forms.responseJson(),
              'schemaVersion': '2',
              'fieldDefinitions': [
                {
                  'key': 'memberFirstName',
                  'label': 'Given name',
                  'kind': 'text',
                  'maxLength': 160,
                },
              ],
              'artifactKind': 'official_form_draft',
              'caseId': server!['caseId'],
              'caseRevision': 1,
              'saved': scenario == 'new'
                  ? null
                  : {
                      ...forms.savedJson(),
                      'caseId': server!['caseId'],
                      'caseRevision': 1,
                    },
              'isCurrent': scenario != 'new',
            });
          case '/v1/read-request-history':
            return http.jsonResponse({
              ...history.historyJson(caseRevision: 1),
              'caseId': server!['caseId'],
              'programId': 'scfhp-eaa',
              'requestRevision': scenario == 'sent' ? 1 : 0,
              'events': [
                if (scenario == 'sent')
                  history.eventJson(caseRevision: 1, status: 'submitted'),
              ],
            });
          default:
            throw StateError('Unexpected request ${request.endpoint.path}');
        }
      });
      final store = MemoryPrivateStore();
      final app = services(store, transport);
      addTearDown(app.dispose);
      await app.coordinator.createDraft();
      await app.coordinator.save();
      if (scenario == 'stale draft') {
        await store.writeJson(
          'export.${app.coordinator.snapshot!.caseId}.scfhp-eaa',
          {
            'fingerprint': 'fictional',
            'generation': 'fictional',
            'completed': true,
            'request': {
              'expectedCaseRevision': 0,
              'expectedFormContextId': forms.digest,
              'expectedAnswerRevision': 1,
            },
          },
        );
      }
      await tester.pumpWidget(
        MaterialApp(
          theme: SafeAtHomeTheme.light(),
          home: ApplicationWorkspaceScreen(
            services: app,
            program: _program('scfhp-eaa'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final now = find.byType(SahNextStepCard);
      expect(now, findsOneWidget);
      final title = tester.widget<SahNextStepCard>(now).title;
      final status = tester.widget<SahTag>(
        find.byKey(const ValueKey('workspace-status')),
      );
      switch (scenario) {
        case 'new':
          expect(title, 'Program questions');
          expect(status.label, 'Draft · not sent');
        case 'stale draft':
          expect(title, 'Update draft');
          expect(
            find.byKey(const ValueKey('workspace-stale-draft')),
            findsOneWidget,
          );
          expect(status.label, 'Draft · not sent');
        case 'sent':
          expect(title, 'Updates');
          expect(status.label, 'Sent (you recorded)');
      }
      expect(find.text('SCFHP'), findsWidgets);
      expect(find.text('Official form draft'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('workspace-waiting')),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('Professional review'), findsOneWidget);
      expect(find.text('You arrange'), findsOneWidget);
      expect(
        find.text('2 things the program or a professional must confirm'),
        findsOneWidget,
      );
      expect(
        find.text('Refreshing won’t change these. Ask the program.'),
        findsOneWidget,
      );
      expect(find.textContaining('Submitted'), findsNothing);
      expect(
        find.text('Fictional official program title (referral draft)'),
        findsNothing,
      );
      await tester.scrollUntilVisible(
        find.text('About this form'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('About this form'));
      await tester.pumpAndSettle();
      expect(
        find.text('Fictional official program title (referral draft)'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });
  }
}
