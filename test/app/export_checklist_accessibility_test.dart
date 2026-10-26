import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/app/live_app.dart';
import 'package:safe_at_home/app/theme.dart';
import 'package:safe_at_home/l10n/app_localizations.dart';
import 'program_localization_support.dart';
import 'package:safe_at_home/features/requests/private_export_screen.dart';
import 'package:safe_at_home/shared/services/matching_api_client.dart';
import 'case_coordinator_test.dart' show FakeSession, FakeTransport;
import 'live_workflows_test.dart' show MemoryPrivateStore, program;
import '../contracts/form_answers_test.dart' as forms;
import '../services/case_evidence_api_client_test.dart' as http;

void main() {
  for (final config in [
    (const Locale('en'), const Size(320, 812)),
    (const Locale('en'), const Size(932, 430)),
    for (final locale in programLocales) (locale, const Size(320, 812)),
  ]) {
    final (locale, size) = config;
    String tr(String text, [Map<String, Object?> args = const {}]) =>
        programText(locale, text, args);
    testWidgets(
      'long backend checklist preserves reachable PDF and share review at 3.2x in $locale $size',
      (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final missing =
            (jsonDecode(
                      File(
                        'test/fixtures/scfhp-unresolved-layout.json',
                      ).readAsStringSync(),
                    )
                    as Map)['missingItems']
                as List;
        expect(missing, hasLength(20));
        expect(
          missing.fold<int>(
            0,
            (n, m) => n + (m['description'] as String).length,
          ),
          greaterThan(5000),
        );
        final pdf = utf8.encode('%PDF-1.7\nFictional layout draft\n%%EOF');
        final now = DateTime.now().toUtc();
        final transport = FakeTransport((request) async {
          final body = http.requestJson(request);
          switch (request.endpoint.path) {
            case '/v1/create-case':
              return http.jsonResponse({...body, 'revision': 1});
            case '/v1/list-evidence':
              return http.jsonResponse({
                'schemaVersion': '1',
                'caseId': body['caseId'],
                'caseRevision': 1,
                'catalogRevision': 0,
                'evidence': <Object>[],
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
            case '/v2/create-draft-export':
              return http.jsonResponse({
                'schemaVersion': '2',
                'artifactId': 'fictional-layout-artifact',
                'caseId': body['caseId'],
                'caseRevision': 1,
                ...forms.contextJson(),
                'ruleVersion': 'fictional-layout',
                'answerRevision': 1,
                'evidenceCatalogRevision': 0,
                'exportContextId': forms.digest,
                'generatedAt': now.toIso8601String(),
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
                'selectedEvidence': <Object>[],
                'missingItems': missing,
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
                'No submission or history mutation is expected.',
              );
          }
        });
        final app = AppServices(
          config: LiveAppConfig(
            apiOrigin: Uri.parse('https://example.org'),
            supabaseUrl: Uri.parse('https://example.supabase.co'),
            publishableKey: 'fictional',
          ),
          session: FakeSession(),
          store: MemoryPrivateStore(),
          transport: transport,
          pdfPreviewBuilder: (bytes) {
            expect(bytes, pdf);
            return const SizedBox(
              key: ValueKey('validated-pdf-surface'),
              height: 240,
              child: Text('Validated PDF preview surface'),
            );
          },
        );
        addTearDown(() {
          app.dispose();
          app.session.dispose();
        });
        await app.coordinator.createDraft();
        await app.coordinator.save();
        await tester.pumpWidget(
          MaterialApp(
            locale: locale,
            supportedLocales: AppLocalizations.supportedLocales,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            theme: SafeAtHomeTheme.light(),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(3.2)),
              child: child!,
            ),
            home: PrivateExportScreen(
              services: app,
              program: program(programId: 'scfhp-eaa'),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final scroll = find.byType(Scrollable).first;
        Future<void> reveal(Finder finder, {double delta = 300}) async {
          await tester.scrollUntilVisible(
            finder,
            delta,
            scrollable: scroll,
            maxScrolls: 60,
          );
          await Scrollable.ensureVisible(
            tester.element(finder.first),
            alignment: .5,
          );
          await tester.pumpAndSettle();
        }

        final prepare = find.text(tr('Create draft PDF'));
        await reveal(prepare);
        await tester.tap(prepare);
        await tester.pumpAndSettle();
        final stillNeeded = find.text(
          tr('{count} items still needed. Nothing has been submitted.', {
            'count': 20,
          }),
        );
        await reveal(stillNeeded);
        expect(stillNeeded.hitTestable(), findsOneWidget);
        for (final warning in [
          'Program availability or requirements still need confirmation.',
        ]) {
          await reveal(find.text(tr(warning)));
          expect(find.text(tr(warning)).hitTestable(), findsOneWidget);
        }
        final share = find.text(tr('Share draft file'));
        await reveal(share, delta: -300);
        expect(share.hitTestable(), findsOneWidget);
        expect(
          tester.takeException(),
          isNull,
          reason:
              'The draft review must fit before opening share confirmation.',
        );
        await tester.tap(share);
        await tester.pumpAndSettle();
        expect(
          tester.takeException(),
          isNull,
          reason: 'The share confirmation must fit at large text.',
        );
        expect(find.text(tr('Share the draft file?')), findsOneWidget);
        final cancel = find.text(tr('Cancel'));
        await tester.ensureVisible(cancel);
        await tester.pumpAndSettle();
        await tester.tap(cancel);
        await tester.pumpAndSettle();
        final preview = find.byKey(const ValueKey('validated-pdf-surface'));
        await reveal(preview, delta: -300);
        expect(preview.hitTestable(), findsOneWidget);
        for (final item in missing) {
          expect(find.text(item['description'] as String), findsNothing);
        }
        final expand = find.text(tr('Unresolved draft items'));
        await reveal(expand);
        await tester.tap(expand);
        await tester.pumpAndSettle();
        for (final item in missing) {
          final detail = find.byKey(ValueKey('draft-unresolved-${item['id']}'));
          expect(detail, findsOneWidget);
          expect(
            (tester.widget<Padding>(detail).child as Text).data,
            item['description'],
          );
        }
        final last = find.text(missing.last['description'] as String);
        await Scrollable.ensureVisible(tester.element(last), alignment: .5);
        await tester.pumpAndSettle();
        expect(last.hitTestable(), findsOneWidget);
        await Scrollable.ensureVisible(tester.element(expand), alignment: .5);
        await tester.pumpAndSettle();
        await tester.tap(expand);
        await tester.pumpAndSettle();
        expect(find.text(missing.last['description'] as String), findsNothing);
        await reveal(share, delta: -300);
        expect(share.hitTestable(), findsOneWidget);
        expect(
          transport.requests.where(
            (r) => r.endpoint.path == '/v2/create-draft-export',
          ),
          hasLength(1),
        );
        expect(
          transport.requests.where(
            (r) => r.endpoint.path == '/v2/download-draft-export',
          ),
          hasLength(1),
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
}
