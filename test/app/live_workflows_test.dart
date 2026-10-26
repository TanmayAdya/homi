import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/app/live_app.dart';
import 'package:safe_at_home/features/auth/login_screen.dart';
import 'package:safe_at_home/features/cases/profile_editor_screen.dart';
import 'package:safe_at_home/features/programs/program_intake_screen.dart';
import 'package:safe_at_home/shared/models/contracts.dart';
import 'package:safe_at_home/shared/services/local_private_store.dart';
import 'package:safe_at_home/shared/services/matching_api_client.dart';
import '../services/case_evidence_api_client_test.dart' as http;
import 'case_coordinator_test.dart' show FakeSession, FakeTransport;
import 'local_private_store_test.dart' show MemorySecrets;

class MemoryPrivateStore extends LocalPrivateStore {
  MemoryPrivateStore()
    : super(
        directory: Directory('/unused-fictional'),
        accountId: 'fictional-owner',
        secrets: MemorySecrets(),
      );
  final records = <String, Map<String, Object?>>{};
  @override
  Future<Map<String, Object?>?> readJson(String key) async =>
      records[key] == null
      ? null
      : Map<String, Object?>.from(jsonDecode(jsonEncode(records[key])) as Map);
  @override
  Future<void> writeJson(String key, Map<String, Object?> value) async {
    records[key] = Map<String, Object?>.from(
      jsonDecode(jsonEncode(value)) as Map,
    );
  }

  @override
  Future<void> delete(String key) async {
    records.remove(key);
  }

  @override
  Future<List<String>> keys() async => records.keys.toList();
}

class FailingSession extends FakeSession {
  int attempts = 0;
  @override
  Future<void> signIn(String email, String password) async {
    attempts++;
    throw StateError('secret-provider-detail');
  }
}

ProgramMatch program({String programId = 'fictional-program'}) =>
    ProgramMatch.fromJson({
      'programId': programId,
      'programName': 'Fictional program',
      'ruleVersion': 'test-v1',
      'isDemo': true,
      'status': 'needs_confirmation',
      'availability': 'unverified',
      'recheckAfter': null,
      'checks': [
        {
          'id': 'review',
          'status': 'unknown',
          'reasonCode': 'REVIEW',
          'explanation': 'Review required',
          'missingFields': [],
          'resolvedBy': null,
          'sourceIds': [],
        },
      ],
      'sources': [],
      'requiredDocuments': [],
      'intake': null,
    });
AppServices services(MemoryPrivateStore store, FakeTransport transport) =>
    AppServices(
      config: LiveAppConfig(
        apiOrigin: Uri.parse('https://example.org'),
        supabaseUrl: Uri.parse('https://example.supabase.co'),
        publishableKey: 'fictional',
      ),
      session: FakeSession(),
      store: store,
      transport: transport,
    );

Finder input(String label) => find.byElementPredicate((element) {
  final w = element.widget;
  if (w is! TextField) return false;
  if (w.decoration?.labelText == label ||
      (w.decoration?.label is Text &&
          (w.decoration!.label! as Text).data == label)) {
    return true;
  }
  var labelled = false;
  element.visitAncestorElements((ancestor) {
    final widget = ancestor.widget;
    if (widget is Semantics && widget.properties.label != null) {
      labelled = widget.properties.label == label;
      return false;
    }
    return true;
  });
  return labelled;
});

void main() {
  testWidgets(
    'disabled email paths and sign-in failures remain honest at large text',
    (tester) async {
      tester.view.physicalSize = const Size(320, 700);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 1.8;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        tester.platformDispatcher.clearTextScaleFactorTestValue();
      });
      final session = FailingSession();
      await tester.pumpWidget(
        MaterialApp(
          home: LoginScreen(session: session, emailDeliveryEnabled: false),
        ),
      );
      expect(find.text('Forgot password'), findsNothing);
      await tester.scrollUntilVisible(
        input('Email'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.enterText(input('Email'), 'fictional@example.org');
      await tester.scrollUntilVisible(
        input('Password'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.enterText(input('Password'), 'fictional-password');
      await tester.scrollUntilVisible(
        find.text('Sign in'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.ensureVisible(find.text('Sign in'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();
      expect(session.attempts, 1);
      expect(
        find.textContaining('Sign-in could not be completed'),
        findsOneWidget,
      );
      expect(find.textContaining('secret-provider-detail'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'unfinished profile resumes zero income and explicit No separately from unknown',
    (tester) async {
      final store = MemoryPrivateStore();
      final app = services(
        store,
        FakeTransport((_) async => throw StateError('No network expected')),
      );
      addTearDown(app.dispose);
      await app.coordinator.createDraft();
      final id = app.coordinator.draft!.caseId;
      await store.writeJson('profile-edit.$id', {
        'values': {'annualIncomeUsd': '0', 'city': 'Fictional City'},
        'tenure': null,
        'consent': false,
      });
      await tester.pumpWidget(
        MaterialApp(home: ProfileEditorScreen(services: app)),
      );
      await tester.pumpAndSettle();
      expect(find.text('Compare unfinished edits'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('profile-review-recovered')),
        200,
        scrollable: find.byType(Scrollable).first,
        maxScrolls: 100,
      );
      await tester.ensureVisible(
        find.byKey(const ValueKey('profile-review-recovered')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('profile-review-recovered')));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('Done'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.ensureVisible(find.text('Done'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      final profile = app.coordinator.draft!.profile;
      expect(profile.annualIncomeUsd, 0);
      expect(profile.ownerConsentReported, false);
      expect(profile.ageYears, isNull);
      expect(profile.tenure, isNull);
      expect(store.records.containsKey('profile-edit.$id'), false);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'lost intake save is reconciled by reading and never automatically repeated',
    (tester) async {
      Map<String, Object?>? server;
      Map<String, Object?>? intake;
      var writes = 0;
      final definition = {
        'programId': 'fictional-program',
        'questionnaireVersion': List.filled(64, 'a').join(),
        'questions': [
          {
            'key': 'hasCoverage',
            'label': 'Coverage reported?',
            'kind': 'boolean',
            'maxLength': null,
            'description': 'Use the reported answer.',
          },
          {
            'key': 'cost',
            'label': 'Reported cost',
            'kind': 'money',
            'maxLength': null,
            'description': 'Unknown is blank.',
          },
        ],
      };
      Map<String, Object?> response() => {
        'schemaVersion': '2',
        'caseId': server!['caseId'],
        'caseRevision': server!['revision'],
        'definition': definition,
        'saved': intake,
        'isCurrent': intake != null,
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
            intake = {
              'schemaVersion': '2',
              'caseId': server!['caseId'],
              'caseRevision': 2,
              'programId': 'fictional-program',
              'questionnaireVersion': definition['questionnaireVersion'],
              'intakeRevision': 1,
              'updatedAt': '2026-10-22T12:00:00.000Z',
              'updatedBy': 'fictional-owner',
              'answers': body['answers'],
            };
            throw const MatchingTransportException(
              MatchingTransportFailure.network,
            );
          default:
            throw StateError('Unexpected test request');
        }
      });
      final store = MemoryPrivateStore();
      final app = services(store, transport);
      addTearDown(app.dispose);
      await app.coordinator.createDraft();
      await app.coordinator.save();
      await tester.pumpWidget(
        MaterialApp(
          home: ProgramIntakeScreen(services: app, program: program()),
        ),
      );
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        input('Reported cost'),
        250,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.enterText(input('Reported cost'), '0');
      await tester.ensureVisible(find.text('Save'));
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(writes, 1);
      await tester.scrollUntilVisible(
        find.textContaining('A save may already have succeeded'),
        -250,
        scrollable: find.byType(Scrollable).first,
      );
      expect(
        find.textContaining('A save may already have succeeded'),
        findsOneWidget,
      );
      await tester.scrollUntilVisible(
        find.text('Save'),
        250,
        scrollable: find.byType(Scrollable).first,
      );
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, 'Save'))
            .onPressed,
        isNull,
      );
      await tester.scrollUntilVisible(
        find.text('Check saved answers and reconcile'),
        -250,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('Check saved answers and reconcile'));
      await tester.pumpAndSettle();
      expect(writes, 1);
      expect(app.coordinator.snapshot!.revision, 2);
      await tester.scrollUntilVisible(
        find.text('The submitted answers are confirmed saved.'),
        -250,
        scrollable: find.byType(Scrollable).first,
      );
      expect(
        find.text('The submitted answers are confirmed saved.'),
        findsOneWidget,
      );
      final answers = intake!['answers'] as List;
      expect(answers.first['value'], isNull);
      expect(answers.first['reviewState'], 'unknown');
      expect(answers.last['value'], 0);
      expect(answers.last['reviewState'], 'reported');
      expect(tester.takeException(), isNull);
    },
  );
}
