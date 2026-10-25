import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/app/theme.dart';
import 'package:safe_at_home/features/cases/profile_editor_screen.dart';
import 'package:safe_at_home/features/programs/program_intake_screen.dart';
import 'package:safe_at_home/features/requests/form_review_screen.dart';
import 'package:safe_at_home/features/requests/request_history_screen.dart';
import 'package:safe_at_home/shared/presentation/sah_components.dart';
import 'package:safe_at_home/shared/services/matching_api_client.dart';
import 'app_design_test.dart' show narrowLargeText;
import 'case_coordinator_test.dart' show FakeTransport;
import 'live_workflows_test.dart'
    show MemoryPrivateStore, services, program, input;
import '../contracts/form_answers_test.dart' as form;
import '../services/case_evidence_api_client_test.dart' as http;

const _intakeSuccess =
    'Reported program answers saved. Refresh the program checks to use the new case revision.';
const _formSuccess =
    'Administrative answers saved. Clinical review, consent and signatures remain separate.';
const _historySuccess =
    'Manual update saved. This is not verified agency status.';

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.pumpAndSettle();
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

void _visibleResult(WidgetTester tester, String key, String message) {
  final feedback = find.byKey(ValueKey(key));
  expect(feedback, findsOneWidget);
  expect(find.text(message), findsOneWidget);
  final rect = tester.getRect(find.text(message));
  expect(rect.top, greaterThanOrEqualTo(0));
  expect(rect.top, lessThan(700));
  expect(
    find.descendant(
      of: feedback,
      matching: find.byWidgetPredicate(
        (w) => w is Semantics && w.properties.liveRegion == true,
      ),
    ),
    findsOneWidget,
  );
  expect(tester.takeException(), isNull);
}

class _Server {
  _Server({this.failSave = false});
  final bool failSave;
  late Map<String, Object?> savedCase;
  Map<String, Object?>? savedIntake, savedForm;
  final events = <Map<String, Object?>>[];
  final savedBodies = <Map<String, Object?>>[];
  int get revision => savedCase['revision'] as int;
  String get id => savedCase['caseId'] as String;
  final definition = {
    'programId': 'fictional-program',
    'questionnaireVersion': form.digest,
    'questions': [
      {
        'key': 'monthlyIncome',
        'label': 'Monthly income',
        'kind': 'money',
        'maxLength': null,
        'description': 'Enter the reported monthly household amount.',
      },
      {
        'key': 'localNotes',
        'label': 'Reported household notes',
        'kind': 'text',
        'maxLength': 200,
        'description':
            'Record only reported facts; unknown details can stay blank.',
      },
      {
        'key': 'permission',
        'label': 'Has the resident reported owner permission?',
        'kind': 'boolean',
        'maxLength': null,
        'description': 'This reported answer is not signed authorization.',
      },
    ],
  };
  Map<String, Object?> intake() => {
    'schemaVersion': '2',
    'caseId': id,
    'caseRevision': revision,
    'definition': definition,
    'saved': savedIntake,
    'isCurrent': savedIntake != null,
  };
  Map<String, Object?> answers() => {
    ...form.responseJson(),
    'schemaVersion': '2',
    'caseId': id,
    'caseRevision': revision,
    'saved': savedForm,
    'isCurrent': savedForm != null,
    'fieldDefinitions': [
      for (final entry in {
        'memberFirstName': 'Given name',
        'memberLastName': 'Family name',
        'representativeName': 'Representative name',
      }.entries)
        {
          'key': entry.key,
          'label': entry.value,
          'kind': 'text',
          'maxLength': 160,
        },
    ],
    'artifactKind': 'official_form_draft',
  };
  Map<String, Object?> history() => {
    'schemaVersion': '1',
    'caseId': id,
    'caseRevision': revision,
    'programId': 'fictional-program',
    'requestRevision': events.length,
    'provenance': 'user_reported',
    'events': events,
  };
  late final transport = FakeTransport((request) async {
    final body = http.requestJson(request);
    final path = request.endpoint.path;
    if (path == '/v1/create-case') {
      savedCase = {...body, 'revision': 1};
      return http.jsonResponse(savedCase);
    }
    if (path.contains('/save-') || path == '/v1/append-request-update') {
      savedBodies.add(body);
      if (failSave) {
        throw const MatchingTransportException(
          MatchingTransportFailure.network,
        );
      }
    }
    switch (path) {
      case '/v2/read-program-intake':
        return http.jsonResponse(intake());
      case '/v2/save-program-intake':
        savedCase['revision'] = revision + 1;
        savedIntake = {
          'schemaVersion': '2',
          'caseId': id,
          'caseRevision': revision,
          'programId': 'fictional-program',
          'questionnaireVersion': form.digest,
          'intakeRevision': 1,
          'updatedAt': form.stamp,
          'updatedBy': 'fictional-owner',
          'answers': body['answers'],
        };
        return http.jsonResponse(intake());
      case '/v2/read-form-answers':
        return http.jsonResponse(answers());
      case '/v2/save-form-answers':
        savedCase['revision'] = revision + 1;
        savedForm = {
          ...form.savedJson(),
          'caseId': id,
          'caseRevision': revision,
          'answers': [
            for (final value in body['answers'] as List)
              {
                ...Map<String, Object?>.from(value as Map),
                'reviewedAt': value['reviewState'] == 'reviewed'
                    ? form.stamp
                    : null,
                'reviewedBy': value['reviewState'] == 'reviewed'
                    ? 'fictional-owner'
                    : null,
              },
          ],
        };
        return http.jsonResponse(answers());
      case '/v1/read-request-history':
        return http.jsonResponse(history());
      case '/v1/append-request-update':
        events.add({
          ...Map<String, Object?>.from(body['update'] as Map),
          'revision': events.length + 1,
          'caseRevision': revision,
          'recordedAt': DateTime.fromMillisecondsSinceEpoch(
            DateTime.now().millisecondsSinceEpoch,
            isUtc: true,
          ).toIso8601String(),
        });
        return http.jsonResponse(history());
      default:
        throw StateError('Unexpected fictional request $path');
    }
  });
}

void main() {
  testWidgets(
    'offscreen profile validation names and focuses the invalid answer at 3.2x',
    (tester) async {
      narrowLargeText(tester, scale: 3.2);
      final transport = FakeTransport(
        (_) async => throw StateError('No network expected'),
      );
      final app = services(MemoryPrivateStore(), transport);
      addTearDown(app.dispose);
      await app.coordinator.createDraft();
      await tester.pumpWidget(
        MaterialApp(
          theme: SafeAtHomeTheme.light(),
          home: ProfileEditorScreen(services: app),
        ),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(input('City'));
      await tester.enterText(input('City'), List.filled(201, 'x').join());
      await tester.ensureVisible(input('Age in years'));
      await tester.enterText(input('Age in years'), '44');
      FocusManager.instance.primaryFocus?.unfocus();
      await _tap(tester, find.byKey(const ValueKey('profile-keep-edits')));
      _visibleResult(
        tester,
        'profile-validation-feedback',
        'City: Use at most 200 characters.',
      );
      expect(app.coordinator.draft!.profile.toJson()['city'], isNull);
      expect(transport.requests, isEmpty);
      await _tap(tester, find.text('Review this answer'));
      expect(tester.widget<TextField>(input('City')).focusNode!.hasFocus, true);
      expect(tester.getRect(input('City')).top, inInclusiveRange(0, 650));
      await tester.enterText(input('City'), 'Fictional city');
      expect(tester.takeException(), isNull);
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(input('City')).focusNode!.hasFocus, true);
      expect(tester.getRect(input('City')).top, inInclusiveRange(0, 650));
    },
  );

  testWidgets(
    'offscreen intake amount is validated, then zero saves with visible feedback',
    (tester) async {
      narrowLargeText(tester, scale: 3.2);
      final server = _Server();
      final app = services(MemoryPrivateStore(), server.transport);
      addTearDown(app.dispose);
      await app.coordinator.createDraft();
      await app.coordinator.save();
      await tester.pumpWidget(
        MaterialApp(
          theme: SafeAtHomeTheme.light(),
          home: ProgramIntakeScreen(services: app, program: program()),
        ),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(input('Monthly income'));
      await tester.enterText(input('Monthly income'), '-1');
      await tester.ensureVisible(input('Reported household notes'));
      await tester.enterText(
        input('Reported household notes'),
        'Fictional note',
      );
      FocusManager.instance.primaryFocus?.unfocus();
      await _tap(tester, find.byKey(const ValueKey('intake-save')));
      _visibleResult(
        tester,
        'intake-validation-feedback',
        'Monthly income: Enter a nonnegative amount with at most two decimal places, or leave blank.',
      );
      expect(server.savedBodies, isEmpty);
      await _tap(tester, find.text('Review this answer'));
      expect(
        tester.widget<TextField>(input('Monthly income')).focusNode!.hasFocus,
        true,
      );
      expect(
        tester.getRect(input('Monthly income')).top,
        inInclusiveRange(0, 650),
      );
      await tester.enterText(input('Monthly income'), '0');
      FocusManager.instance.primaryFocus?.unfocus();
      await _tap(tester, find.byKey(const ValueKey('intake-save')));
      _visibleResult(tester, 'intake-save-feedback', _intakeSuccess);
      expect(server.savedBodies, hasLength(1));
      final sent = server.savedBodies.single['answers'] as List;
      expect(sent.first['value'], 0);
      expect(sent.last['value'], isNull);
      expect(sent.last['reviewState'], 'unknown');
      await tester.ensureVisible(input('Monthly income'));
      await tester.enterText(input('Monthly income'), '1');
      await tester.pumpAndSettle();
      expect(find.text(_intakeSuccess), findsNothing);
    },
  );

  for (final failure in [false, true]) {
    testWidgets(
      'administrative save ${failure ? 'failure' : 'success'} is visible once beside action at 3.2x',
      (tester) async {
        narrowLargeText(tester, scale: 3.2);
        final server = _Server(failSave: failure);
        final app = services(MemoryPrivateStore(), server.transport);
        addTearDown(app.dispose);
        await app.coordinator.createDraft();
        await app.coordinator.save();
        await tester.pumpWidget(
          MaterialApp(
            theme: SafeAtHomeTheme.light(),
            home: FormReviewScreen(
              services: app,
              program: program(programId: 'scfhp-eaa'),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await _tap(tester, find.byKey(const ValueKey('form-save')));
        final message = tester
            .widget<SahActionFeedback>(
              find.byKey(const ValueKey('form-save-feedback')),
            )
            .message;
        _visibleResult(tester, 'form-save-feedback', message);
        expect(server.savedBodies, hasLength(1));
        expect(message == _formSuccess, !failure);
        if (failure) {
          expect(
            tester
                .widget<FilledButton>(find.byKey(const ValueKey('form-save')))
                .onPressed,
            isNull,
          );
        } else {
          await tester.ensureVisible(input('Given name'));
          await tester.enterText(input('Given name'), 'New fictional edit');
          await tester.pumpAndSettle();
          expect(find.text(_formSuccess), findsNothing);
        }
      },
    );

    testWidgets(
      'history save ${failure ? 'failure' : 'success'} is visible once beside action at 3.2x',
      (tester) async {
        narrowLargeText(tester, scale: 3.2);
        final server = _Server(failSave: failure);
        final app = services(MemoryPrivateStore(), server.transport);
        addTearDown(app.dispose);
        await app.coordinator.createDraft();
        await app.coordinator.save();
        await tester.pumpWidget(
          MaterialApp(
            theme: SafeAtHomeTheme.light(),
            home: RequestHistoryScreen(services: app, program: program()),
          ),
        );
        await tester.pumpAndSettle();
        final field = tester.widget<TextField>(
          input('Date it happened (YYYY-MM-DD)'),
        );
        expect(field.decoration!.helperText, contains('Use YYYY-MM-DD'));
        final follow = tester.widget<TextField>(
          input('Optional follow-up date (YYYY-MM-DD)'),
        );
        expect(follow.decoration!.helperText, contains('Add a next action'));
        await _tap(tester, find.byKey(const ValueKey('history-save')));
        final message = tester
            .widget<SahActionFeedback>(
              find.byKey(const ValueKey('history-save-feedback')),
            )
            .message;
        _visibleResult(tester, 'history-save-feedback', message);
        expect(server.savedBodies, hasLength(1));
        expect(message == _historySuccess, !failure);
        expect(server.events, hasLength(failure ? 0 : 1));
        if (failure) {
          expect(find.text('Retry exact pending update'), findsOneWidget);
        } else {
          await tester.ensureVisible(input('Optional note'));
          await tester.enterText(input('Optional note'), 'A new unsaved note');
          await tester.pumpAndSettle();
          expect(find.text(_historySuccess), findsNothing);
        }
      },
    );
  }
}
