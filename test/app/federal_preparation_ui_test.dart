import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/features/programs/live_programs_screen.dart';
import 'package:safe_at_home/features/programs/program_intake_screen.dart';
import 'package:safe_at_home/features/requests/draft_packet_screen.dart';
import 'package:safe_at_home/features/requests/form_review_screen.dart';
import 'package:safe_at_home/features/requests/private_export_screen.dart';
import 'package:safe_at_home/l10n/app_localizations.dart';

import '../services/case_evidence_api_client_test.dart' as http;
import 'case_coordinator_test.dart' show FakeTransport;
import 'live_workflows_test.dart' show MemoryPrivateStore, services;

void main() {
  for (final programId in [
    'usda-section-504',
    'va-hisa',
    'fictional-unmapped-production-route',
  ]) {
    testWidgets('$programId offers only supported checklist preparation', (
      tester,
    ) async {
      final now = DateTime.now().toUtc().toIso8601String();
      final transport = FakeTransport((request) async {
        final body = http.requestJson(request);
        if (request.endpoint.path == '/v1/create-case') {
          return http.jsonResponse({...body, 'revision': 1});
        }
        if (request.endpoint.path == '/v1/match-case') {
          return http.jsonResponse({
            'schemaVersion': '1',
            'caseId': body['caseId'],
            'caseRevision': body['expectedCaseRevision'],
            'evaluatedAt': now,
            'evaluationDate': now.substring(0, 10),
            'matches': [
              {
                'programId': programId,
                'programName': 'Fictional preparation checklist fixture',
                'ruleVersion': 'fictional-preparation-v1',
                'isDemo': false,
                'availability': 'unverified',
                'recheckAfter': null,
                'status': 'needs_confirmation',
                'checks': [
                  {
                    'id': 'permission-review',
                    'status': 'unknown',
                    'reasonCode': 'rules_unverified',
                    'explanation': 'Fictional resident evidence needs review.',
                    'missingFields': <String>[],
                    'resolvedBy': 'resident',
                    'sourceIds': <String>[],
                  },
                ],
                'sources': <Object?>[],
                'requiredDocuments': <String>[],
                'intake': 'Contact the program for the accepted application.',
              },
            ],
          });
        }
        if (request.endpoint.path == '/v1/prepare-packet') {
          return http.jsonResponse({
            'schemaVersion': '1',
            'packetId': 'fictional-checklist',
            'caseId': body['caseId'],
            'caseRevision': body['expectedCaseRevision'],
            'programId': programId,
            'ruleVersion': 'fictional-preparation-v1',
            'formVersion': null,
            'mappingVersion': null,
            'status': 'draft',
            'isDemo': false,
            'generatedAt': now,
            'recheckAfter': null,
            'storageReference': null,
            'attachments': <Object?>[],
            'missingItems': [
              {
                'id': 'official-form',
                'description':
                    'Confirm the accepted application with the program.',
                'resolvedBy': 'program',
              },
            ],
          });
        }
        throw StateError(
          'No unsupported form or questionnaire request expected.',
        );
      });
      final app = services(MemoryPrivateStore(), transport);
      addTearDown(() {
        app.dispose();
        app.session.dispose();
      });
      await app.coordinator.createDraft();
      await app.coordinator.save();
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('en'),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          home: LiveProgramsScreen(services: app),
        ),
      );
      await tester.pumpAndSettle();
      final details = find.descendant(
        of: find.byKey(ValueKey('program-$programId-details')),
        matching: find.text('Details'),
      );
      await Scrollable.ensureVisible(tester.element(details));
      await tester.tap(details);
      await tester.pumpAndSettle();
      expect(
        find.text(
          'This app-generated checklist is not an official application form. Review requirements with the program.',
        ),
        findsOneWidget,
      );
      for (final unsupported in [
        'intake',
        'answers',
        'export',
        'missing-answers',
      ]) {
        expect(
          find.byKey(ValueKey('program-$programId-$unsupported')),
          findsNothing,
        );
      }
      expect(
        find.byKey(ValueKey('program-$programId-history')),
        findsOneWidget,
      );
      expect(find.text('Prepare a draft'), findsNothing);
      final start = find.byKey(ValueKey('program-$programId-start'));
      expect(
        find.descendant(of: start, matching: find.text('See checklist')),
        findsOneWidget,
      );
      expect(find.text('Checklist'), findsOneWidget);
      expect(find.text('Start application'), findsNothing);
      await Scrollable.ensureVisible(tester.element(start), alignment: .5);
      await tester.pumpAndSettle();
      await tester.tap(start);
      await tester.pumpAndSettle();
      expect(find.byType(DraftPacketScreen), findsOneWidget);
      expect(find.byType(ProgramIntakeScreen), findsNothing);
      expect(find.byType(FormReviewScreen), findsNothing);
      expect(find.byType(PrivateExportScreen), findsNothing);
      expect(
        find.text('Confirm the accepted application with the program.'),
        findsOneWidget,
      );
      expect(find.text('Checklist — no form in this app'), findsOneWidget);
      expect(
        find.text('Official form not prepared. Its fields are unverified.'),
        findsNothing,
      );
      final item = find.byKey(const ValueKey('checklist-item-official-form'));
      await tester.ensureVisible(item);
      await tester.pumpAndSettle();
      await tester.tap(item);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(
        find.text('Contact the program for the accepted application.'),
        findsOneWidget,
      );
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('checklist-updates')), findsOneWidget);
      expect(
        transport.requests.where(
          (r) => r.endpoint.path == '/v1/prepare-packet',
        ),
        hasLength(1),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
