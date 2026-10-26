import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/app/live_app.dart';
import 'package:safe_at_home/app/theme.dart';
import 'package:safe_at_home/features/programs/program_intake_screen.dart';
import 'package:safe_at_home/features/requests/application_workspace_screen.dart';
import 'package:safe_at_home/features/requests/form_review_screen.dart';
import 'package:safe_at_home/features/requests/private_export_screen.dart';
import 'package:safe_at_home/shared/models/case_draft.dart';
import 'package:safe_at_home/shared/services/matching_api_client.dart';
import 'app_design_test.dart' show narrowLargeText;
import 'case_coordinator_test.dart' show FakeTransport, FakeSession;
import 'live_workflows_test.dart' show MemoryPrivateStore, program, input;
import '../contracts/form_answers_test.dart' as fixture;
import '../services/case_evidence_api_client_test.dart' as http;

class _Server {
  bool offline = false;
  bool omitBirthDate = false;
  Map<String, Object?>? intakeOverride;
  late Map<String, Object?> currentCase;
  Map<String, Object?>? saved;
  int saves = 0;
  final pdf = utf8.encode('%PDF-1.7\nFictional draft\n%%EOF');
  final now = DateTime.now().toUtc();
  Map<String, Object?> get answers => {
    ...fixture.responseJson(),
    'schemaVersion': '2',
    'caseId': currentCase['caseId'],
    'caseRevision': currentCase['revision'],
    'context': {
      ...fixture.contextJson(),
      if (omitBirthDate) ...{
        'formVersion': 'fictional-revised-form-version',
        'formContextId': 'b' * 64,
      },
    },
    'saved': saved,
    'isCurrent': saved != null,
    'fieldDefinitions': [
      for (final field in [
        ('memberFirstName', 'Given name', 'text', 160),
        ('memberBirthDate', 'Birth date', 'date', 10),
        ('referralDate', 'Referral date', 'date', 10),
        ('referrerEmail', 'Contact email', 'email', 254),
      ])
        if (!omitBirthDate || field.$1 != 'memberBirthDate')
          {
            'key': field.$1,
            'label': field.$2,
            'kind': field.$3,
            'maxLength': field.$4,
          },
    ],
    'artifactKind': 'official_form_draft',
  };
  late final transport = FakeTransport((request) async {
    final body = http.requestJson(request);
    if (offline) {
      throw const MatchingTransportException(MatchingTransportFailure.network);
    }
    switch (request.endpoint.path) {
      case '/v1/create-case':
        currentCase = {...body, 'revision': 1};
        return http.jsonResponse(currentCase);
      case '/v1/read-case':
        return http.jsonResponse(currentCase);
      case '/v2/read-form-answers':
        return http.jsonResponse(answers);
      case '/v2/save-form-answers':
        saves++;
        currentCase['revision'] = (currentCase['revision'] as int) + 1;
        saved = {
          ...fixture.savedJson(),
          'caseId': currentCase['caseId'],
          'caseRevision': currentCase['revision'],
          'answerRevision': saves,
          'answers': [
            for (final answer in body['answers'] as List)
              {
                ...Map<String, Object?>.from(answer as Map),
                'reviewedAt': answer['reviewState'] == 'reviewed'
                    ? fixture.stamp
                    : null,
                'reviewedBy': answer['reviewState'] == 'reviewed'
                    ? 'fictional-user'
                    : null,
              },
          ],
        };
        return http.jsonResponse(answers);
      case '/v2/read-program-intake':
        return http.jsonResponse(
          intakeOverride ??
              {
                'schemaVersion': '2',
                'caseId': currentCase['caseId'],
                'caseRevision': currentCase['revision'],
                'definition': {
                  'programId': 'scfhp-eaa',
                  'questionnaireVersion': fixture.digest,
                  'questions': [
                    {
                      'key': 'cost',
                      'label': 'Estimated cost',
                      'kind': 'money',
                      'maxLength': null,
                      'description': 'Unknown is different from zero.',
                    },
                    {
                      'key': 'permission',
                      'label': 'Permission reported?',
                      'kind': 'boolean',
                      'maxLength': null,
                      'description': 'Reported permission only.',
                    },
                  ],
                },
                'saved': null,
                'isCurrent': false,
              },
        );
      case '/v1/list-evidence':
        return http.jsonResponse({
          'schemaVersion': '1',
          'caseId': currentCase['caseId'],
          'caseRevision': currentCase['revision'],
          'catalogRevision': 0,
          'evidence': <Object>[],
        });
      case '/v2/create-draft-export':
        return http.jsonResponse({
          'schemaVersion': '2',
          'artifactId': 'fictional-artifact',
          'caseId': currentCase['caseId'],
          'caseRevision': currentCase['revision'],
          ...fixture.contextJson(),
          'ruleVersion': 'fictional-rule',
          'answerRevision': 0,
          'evidenceCatalogRevision': 0,
          'exportContextId': fixture.digest,
          'generatedAt': now.toIso8601String(),
          'expiresAt': now.add(const Duration(minutes: 10)).toIso8601String(),
          'recheckAfter': null,
          'status': 'draft',
          'isDemo': false,
          'mediaType': 'application/pdf',
          'byteLength': pdf.length,
          'sha256': sha256.convert(pdf).toString(),
          'pageCount': 1,
          'renderingVersion': 'draft-export-annotations-v2',
          'selectedEvidence': <Object>[],
          'missingItems': <Object>[],
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
      default:
        throw StateError(
          'Unexpected fictional request ${request.endpoint.path}',
        );
    }
  });
}

Future<AppServices> _app(_Server server, MemoryPrivateStore store) async {
  final app = AppServices(
    config: LiveAppConfig(
      apiOrigin: Uri.parse('https://example.org'),
      supabaseUrl: Uri.parse('https://example.supabase.co'),
      publishableKey: 'fictional',
    ),
    session: FakeSession(),
    store: store,
    transport: server.transport,
    pdfPreviewBuilder: (_) =>
        const SizedBox(key: ValueKey('fictional-pdf'), height: 200),
  );
  addTearDown(() {
    app.dispose();
    app.session.dispose();
  });
  await app.coordinator.createDraft();
  await app.coordinator.save();
  return app;
}

Widget _screen(AppServices app, {bool intake = false, bool export = false}) =>
    MaterialApp(
      theme: SafeAtHomeTheme.light(),
      home: export
          ? PrivateExportScreen(
              services: app,
              program: program(programId: 'scfhp-eaa'),
            )
          : intake
          ? ProgramIntakeScreen(
              services: app,
              program: program(programId: 'scfhp-eaa'),
            )
          : FormReviewScreen(
              services: app,
              program: program(programId: 'scfhp-eaa'),
            ),
    );
Future<void> _tap(WidgetTester tester, Finder target) async {
  FocusManager.instance.primaryFocus?.unfocus();
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
  await tester.tap(target);
  await tester.pumpAndSettle();
}

Future<void> _enter(WidgetTester tester, String label, String value) async {
  await tester.ensureVisible(input(label));
  await tester.pumpAndSettle();
  await tester.enterText(input(label), value);
  await tester.pumpAndSettle();
}

Finder _formField(String key) => find.byKey(ValueKey('form-field-$key'));

Future<void> _seedForm(
  MemoryPrivateStore store,
  AppServices app,
  Map<String, String> values,
) => store.writeJson('form.${app.coordinator.snapshot!.caseId}.scfhp-eaa', {
  'values': values,
  'reviewed': <String, bool>{},
  'uncertain': false,
  'caseRevision': app.coordinator.snapshot!.revision,
  'formContextId': null,
  'response': null,
});

Future<void> _reopen(
  WidgetTester tester,
  AppServices app, {
  bool intake = false,
}) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
  await tester.pumpWidget(_screen(app, intake: intake));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'check answers is a read-only summary with Change links and program answers',
    (tester) async {
      final server = _Server(), store = MemoryPrivateStore();
      final app = await _app(server, store);
      await tester.pumpWidget(_screen(app));
      await tester.pumpAndSettle();
      await _enter(tester, 'Given name', 'Fictional summary name');
      await _tap(tester, find.byKey(const ValueKey('form-save')));
      expect(server.saves, 1);
      final caseId = app.coordinator.snapshot!.caseId;
      server.intakeOverride = {
        'schemaVersion': '2',
        'caseId': caseId,
        'caseRevision': server.currentCase['revision'],
        'definition': {
          'programId': 'scfhp-eaa',
          'questionnaireVersion': fixture.digest,
          'questions': [
            for (final key in ['permission', 'order', 'evaluation'])
              {
                'key': key,
                'label': 'Fictional $key?',
                'kind': 'boolean',
                'maxLength': null,
                'description': 'Reported only.',
              },
          ],
        },
        'saved': {
          'schemaVersion': '2',
          'caseId': caseId,
          'caseRevision': 1,
          'programId': 'scfhp-eaa',
          'questionnaireVersion': fixture.digest,
          'intakeRevision': 1,
          'updatedAt': fixture.stamp,
          'updatedBy': 'fictional-user',
          'answers': [
            {'key': 'permission', 'value': true, 'reviewState': 'reported'},
            {'key': 'order', 'value': null, 'reviewState': 'unknown'},
            {'key': 'evaluation', 'value': null, 'reviewState': 'unknown'},
          ],
        },
        'isCurrent': false,
      };
      await store.writeJson('intake.$caseId.scfhp-eaa', {
        'notSure': ['order'],
      });
      await _reopen(tester, app);
      expect(_formField('memberFirstName'), findsNothing);
      String row(String key) => tester
          .widgetList<Text>(
            find.descendant(
              of: find.byKey(ValueKey('form-summary-$key')),
              matching: find.byType(Text),
            ),
          )
          .map((t) => t.data)
          .join('|');
      expect(row('memberFirstName'), contains('Fictional summary name'));
      expect(row('memberBirthDate'), contains('Not provided'));
      expect(row('intake-permission'), contains('Yes'));
      expect(row('intake-order'), contains('Not sure'));
      expect(row('intake-evaluation'), contains('Not answered'));
      expect(find.text('Left blank on purpose'), findsOneWidget);
      await _tap(
        tester,
        find.byKey(const ValueKey('form-change-memberFirstName')),
      );
      expect(_formField('memberFirstName'), findsOneWidget);
      await _tap(tester, find.byKey(const ValueKey('form-show-summary')));
      expect(_formField('memberFirstName'), findsNothing);
      await _tap(
        tester,
        find.byKey(const ValueKey('form-change-intake-permission')),
      );
      expect(find.byType(ProgramIntakeScreen), findsOneWidget);
      await _tap(tester, find.byType(BackButton));
      expect(find.byType(ProgramIntakeScreen), findsNothing);
      expect(
        find.byKey(const ValueKey('form-summary-resident')),
        findsOneWidget,
      );
      await _tap(tester, find.byKey(const ValueKey('form-save')));
      expect(server.saves, 2);
      final saved = {
        for (final answer in (server.saved!['answers'] as List).cast<Map>())
          answer['key']: answer,
      };
      expect(saved['memberFirstName']!['reviewState'], 'reviewed');
      expect(saved['memberBirthDate']!['reviewState'], 'needs_review');
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'changed intake questions retain new server answers and archive incompatible draft values',
    (tester) async {
      final server = _Server(), store = MemoryPrivateStore();
      final app = await _app(server, store);
      await tester.pumpWidget(_screen(app, intake: true));
      await tester.pumpAndSettle();
      await _enter(tester, 'Estimated cost', '0');
      await _tap(tester, find.byKey(const ValueKey('permission-false')));
      final nextVersion = 'c' * 64;
      server.intakeOverride = {
        'schemaVersion': '2',
        'caseId': server.currentCase['caseId'],
        'caseRevision': server.currentCase['revision'],
        'definition': {
          'programId': 'scfhp-eaa',
          'questionnaireVersion': nextVersion,
          'questions': [
            {
              'key': 'cost',
              'label': 'Cost confirmed?',
              'kind': 'boolean',
              'maxLength': null,
              'description': 'Changed fictional question.',
            },
            {
              'key': 'permission',
              'label': 'Permission details',
              'kind': 'text',
              'maxLength': 160,
              'description': 'Changed fictional question.',
            },
            {
              'key': 'added',
              'label': 'Added details',
              'kind': 'text',
              'maxLength': 160,
              'description': 'New fictional question.',
            },
          ],
        },
        'saved': {
          'schemaVersion': '2',
          'caseId': server.currentCase['caseId'],
          'caseRevision': server.currentCase['revision'],
          'programId': 'scfhp-eaa',
          'questionnaireVersion': nextVersion,
          'intakeRevision': 1,
          'updatedAt': fixture.stamp,
          'updatedBy': 'fictional-user',
          'answers': [
            {'key': 'cost', 'value': false, 'reviewState': 'reported'},
            {
              'key': 'permission',
              'value': 'Fresh permission details',
              'reviewState': 'reported',
            },
            {
              'key': 'added',
              'value': 'Fresh added details',
              'reviewState': 'reported',
            },
          ],
        },
        'isCurrent': true,
      };
      await _reopen(tester, app, intake: true);
      expect(tester.takeException(), isNull);
      expect(
        tester
            .widget<RadioGroup<String>>(
              find.byKey(const ValueKey('intake-choices-cost')),
            )
            .groupValue,
        'false',
      );
      expect(
        tester.widget<TextField>(input('Permission details')).controller!.text,
        'Fresh permission details',
      );
      expect(
        tester.widget<TextField>(input('Added details')).controller!.text,
        'Fresh added details',
      );
      final retained =
          store.records['intake.${app.coordinator.snapshot!.caseId}.scfhp-eaa']!['unmappedAnswers']
              as Map;
      expect((retained['${fixture.digest}:cost'] as Map)['value'], '0');
      expect((retained['${fixture.digest}:permission'] as Map)['value'], false);
      expect(server.saves, 0);
      server.offline = true;
      await _reopen(tester, app, intake: true);
      expect(
        tester.widget<TextField>(input('Added details')).controller!.text,
        'Fresh added details',
      );
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'form refresh drops obsolete validation fields while preserving unfinished values',
    (tester) async {
      final server = _Server(), store = MemoryPrivateStore();
      final app = await _app(server, store);
      await _seedForm(store, app, {'memberBirthDate': '2026-99-99'});
      await tester.pumpWidget(_screen(app));
      await tester.pumpAndSettle();
      await _enter(tester, 'Given name', 'Fictional retained value');
      await _tap(tester, find.byKey(const ValueKey('form-save')));
      expect(
        find.byKey(const ValueKey('form-validation-feedback')),
        findsOneWidget,
      );
      expect(server.saves, 0);
      expect(find.byKey(const ValueKey('form-reconcile')), findsNothing);
      server.omitBirthDate = true;
      await _reopen(tester, app);
      expect(tester.takeException(), isNull);
      expect(_formField('memberBirthDate'), findsNothing);
      expect(
        find.byKey(const ValueKey('form-validation-feedback')),
        findsNothing,
      );
      expect(
        tester.widget<TextField>(input('Given name')).controller!.text,
        'Fictional retained value',
      );
      final values =
          store.records['form.${app.coordinator.snapshot!.caseId}.scfhp-eaa']!['values']
              as Map;
      expect(values['memberBirthDate'], '2026-99-99');
      expect(values['memberFirstName'], 'Fictional retained value');
      expect(server.saves, 0);
    },
  );
  for (final intake in [false, true]) {
    testWidgets(
      'initial ${intake ? 'intake' : 'form'} context resumes offline without typing',
      (tester) async {
        final server = _Server(), store = MemoryPrivateStore();
        final app = await _app(server, store);
        if (!intake) {
          server.saved = {
            ...fixture.savedJson(),
            'caseId': server.currentCase['caseId'],
            'caseRevision': server.currentCase['revision'],
          };
        }
        await tester.pumpWidget(_screen(app, intake: intake));
        await tester.pumpAndSettle();
        server.offline = true;
        await _reopen(tester, app, intake: intake);
        expect(
          find.byKey(
            ValueKey(
              intake ? 'intake-offline-context' : 'form-offline-context',
            ),
          ),
          findsOneWidget,
        );
        expect(input(intake ? 'Estimated cost' : 'Given name'), findsOneWidget);
        if (!intake) {
          expect(
            tester.widget<TextField>(input('Given name')).controller!.text,
            'Fictional',
          );
        }
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets(
    'empty form starts with honest guidance, without a stale saved-answer warning',
    (tester) async {
      final app = await _app(_Server(), MemoryPrivateStore());
      await tester.pumpWidget(_screen(app));
      await tester.pumpAndSettle();
      expect(
        find.text('Saved answers need review for the current case and form.'),
        findsNothing,
      );
      expect(find.text('0 of 0 checked'), findsNothing);
      expect(
        find.text('Enter what you know. Leave unknown answers blank.'),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('form-reconcile')), findsNothing);
      expect(find.byKey(const ValueKey('form-confirmed')), findsNothing);
    },
  );
  for (final invalid in [
    (
      'memberBirthDate',
      '2026-99-99',
      'Enter a valid date as YYYY-MM-DD, or leave blank.',
    ),
    (
      'referrerEmail',
      'invalid email',
      'Enter a valid email address, or leave blank.',
    ),
    ('memberBirthDate', '2999-01-01', 'Enter a date on or before today.'),
    (
      'memberBirthDate',
      '2001-01-01',
      'Birth date must be on or before the referral date.',
    ),
  ]) {
    testWidgets(
      'form identifies ${invalid.$2}, focuses the field, and never starts an uncertain save',
      (tester) async {
        narrowLargeText(tester, scale: 3.2);
        final server = _Server(), store = MemoryPrivateStore();
        final app = await _app(server, store);
        final date = invalid.$1 != 'referrerEmail';
        if (date) {
          await _seedForm(store, app, {
            invalid.$1: invalid.$2,
            if (invalid.$2 == '2001-01-01') 'referralDate': '2000-01-01',
          });
        }
        await tester.pumpWidget(_screen(app));
        await tester.pumpAndSettle();
        if (!date) await _enter(tester, 'Contact email', invalid.$2);
        await _tap(tester, find.byKey(const ValueKey('form-save')));
        if (date) {
          final field = tester.widget<IsoDateField>(
            find.descendant(
              of: _formField(invalid.$1),
              matching: find.byType(IsoDateField),
            ),
          );
          expect(field.focusNode!.hasFocus, true);
          expect(field.errorText, invalid.$3);
          expect(
            find.descendant(
              of: _formField(invalid.$1),
              matching: find.text(invalid.$3),
            ),
            findsOneWidget,
          );
        } else {
          final field = tester.widget<TextField>(input('Contact email'));
          expect(field.focusNode!.hasFocus, true);
          expect((field.decoration!.error as Text).data, invalid.$3);
        }
        expect(
          tester.getTopLeft(_formField(invalid.$1)).dy,
          inInclusiveRange(0, 650),
        );
        expect(server.saves, 0);
        expect(find.text('Check the last save'), findsNothing);
        expect(
          store
              .records['form.${app.coordinator.snapshot!.caseId}.scfhp-eaa']!['uncertain'],
          false,
        );
        if (date) {
          await _tap(
            tester,
            find.descendant(
              of: _formField(invalid.$1),
              matching: find.byTooltip('Clear date'),
            ),
          );
        } else {
          await _enter(tester, 'Contact email', '');
        }
        await _tap(tester, find.byKey(const ValueKey('form-save')));
        expect(server.saves, 1);
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets(
    'form journal reopens offline, keeps local edits, and requires reload before online save',
    (tester) async {
      final server = _Server(), store = MemoryPrivateStore();
      final app = await _app(server, store);
      await tester.pumpWidget(_screen(app));
      await tester.pumpAndSettle();
      await _enter(tester, 'Given name', 'Fictional offline name');
      server.offline = true;
      await _reopen(tester, app);
      expect(
        find.byKey(const ValueKey('form-offline-context')),
        findsOneWidget,
      );
      expect(
        tester.widget<TextField>(input('Given name')).controller!.text,
        'Fictional offline name',
      );
      expect(
        tester
            .widget<FilledButton>(find.byKey(const ValueKey('form-save')))
            .onPressed,
        isNull,
      );
      await _enter(tester, 'Given name', 'Fictional updated offline');
      await _tap(tester, find.byKey(const ValueKey('form-reconcile')));
      expect(
        tester.widget<TextField>(input('Given name')).controller!.text,
        'Fictional updated offline',
      );
      await _reopen(tester, app);
      expect(
        tester.widget<TextField>(input('Given name')).controller!.text,
        'Fictional updated offline',
      );
      server.offline = false;
      await _tap(tester, find.byKey(const ValueKey('form-reconcile')));
      expect(find.byKey(const ValueKey('form-offline-context')), findsNothing);
      expect(
        tester.widget<TextField>(input('Given name')).controller!.text,
        'Fictional updated offline',
      );
      await _tap(tester, find.byKey(const ValueKey('form-save')));
      expect(server.saves, 1);
      final saved = {
        for (final answer in (server.saved!['answers'] as List).cast<Map>())
          answer['key']: answer,
      };
      expect(saved['memberFirstName']!['reviewState'], 'reviewed');
      expect(saved['memberFirstName']!['reviewedBy'], 'fictional-user');
      for (final key in ['memberBirthDate', 'referralDate', 'referrerEmail']) {
        expect(saved[key]!['value'], isNull);
        expect(saved[key]!['reviewState'], 'needs_review');
      }
      expect(find.byKey(const ValueKey('form-confirmed')), findsOneWidget);
      await _enter(tester, 'Given name', 'Fictional changed again');
      expect(
        find.byKey(const ValueKey('form-unconfirmed-memberFirstName')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('form-confirmed')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('date answers use the system picker and keep the ISO wire format', (
    tester,
  ) async {
    final server = _Server(), store = MemoryPrivateStore();
    final app = await _app(server, store);
    await tester.pumpWidget(_screen(app));
    await tester.pumpAndSettle();
    await _tap(
      tester,
      find.descendant(
        of: _formField('referralDate'),
        matching: find.byType(InkWell),
      ),
    );
    expect(find.byType(DatePickerDialog), findsOneWidget);
    await _tap(tester, find.byIcon(Icons.edit_outlined));
    await tester.enterText(
      find.descendant(
        of: find.byType(DatePickerDialog),
        matching: find.byType(TextField),
      ),
      '03/04/2020',
    );
    await _tap(tester, find.text('OK'));
    expect(
      store.records['form.${app.coordinator.snapshot!.caseId}.scfhp-eaa']!['values']
          as Map,
      containsPair('referralDate', '2020-03-04'),
    );
    expect(find.text('Wednesday, March 4, 2020'), findsOneWidget);
    await _tap(tester, find.byKey(const ValueKey('form-save')));
    expect(server.saves, 1);
    final saved = (server.saved!['answers'] as List).cast<Map>().firstWhere(
      (answer) => answer['key'] == 'referralDate',
    );
    expect(saved['value'], '2020-03-04');
    expect(saved['reviewState'], 'reviewed');
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'intake journal keeps zero and explicit no through offline reopen and reconnect',
    (tester) async {
      final server = _Server(), store = MemoryPrivateStore();
      final app = await _app(server, store);
      await tester.pumpWidget(_screen(app, intake: true));
      await tester.pumpAndSettle();
      await _enter(tester, 'Estimated cost', '0');
      final choices = find.byKey(const ValueKey('intake-choices-permission'));
      String? chosen() => tester.widget<RadioGroup<String>>(choices).groupValue;
      expect(chosen(), isNull, reason: 'Unanswered starts unselected (N-01).');
      await _tap(tester, find.byKey(const ValueKey('permission-false')));
      server.offline = true;
      await _reopen(tester, app, intake: true);
      expect(
        find.byKey(const ValueKey('intake-offline-context')),
        findsOneWidget,
      );
      expect(
        tester.widget<TextField>(input('Estimated cost')).controller!.text,
        '0',
      );
      expect(chosen(), 'false');
      expect(
        tester
            .widget<FilledButton>(find.byKey(const ValueKey('intake-save')))
            .onPressed,
        isNull,
      );
      await _enter(tester, 'Estimated cost', '12.34');
      await _tap(tester, find.byKey(const ValueKey('intake-reconcile')));
      expect(
        tester.widget<TextField>(input('Estimated cost')).controller!.text,
        '12.34',
      );
      await _reopen(tester, app, intake: true);
      expect(
        tester.widget<TextField>(input('Estimated cost')).controller!.text,
        '12.34',
      );
      server.offline = false;
      await _tap(tester, find.byKey(const ValueKey('intake-reconcile')));
      expect(
        find.byKey(const ValueKey('intake-offline-context')),
        findsNothing,
      );
      expect(
        tester.widget<TextField>(input('Estimated cost')).controller!.text,
        '12.34',
      );
      expect(chosen(), 'false');
      expect(
        tester
            .widget<FilledButton>(find.byKey(const ValueKey('intake-save')))
            .onPressed,
        isNotNull,
      );
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'unsaved local changes invalidate an already prepared PDF and its share action',
    (tester) async {
      final server = _Server();
      final app = await _app(server, MemoryPrivateStore());
      await tester.pumpWidget(_screen(app, export: true));
      await tester.pumpAndSettle();
      await _tap(tester, find.text('Create draft PDF'));
      expect(
        server.transport.requests.where(
          (request) => request.endpoint.path == '/v2/download-draft-export',
        ),
        hasLength(1),
      );
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('fictional-pdf')),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('fictional-pdf')), findsOneWidget);
      expect(find.text('Share draft file'), findsOneWidget);
      final draft = app.coordinator.currentDraft();
      await app.coordinator.updateDraft(
        CaseDraft.fromJson({
          ...draft.toJson(),
          'profile': {
            ...draft.profile.toJson(),
            'city': 'Fictional local change',
          },
        }),
      );
      await tester.pumpAndSettle();
      expect(app.coordinator.hasUnsavedChanges, true);
      expect(find.byKey(const ValueKey('fictional-pdf')), findsNothing);
      expect(find.text('Share draft file'), findsNothing);
      final prepare = find.widgetWithText(FilledButton, 'Create draft PDF');
      expect(tester.widget<FilledButton>(prepare).onPressed, isNull);
      expect(tester.takeException(), isNull);
    },
  );
}
