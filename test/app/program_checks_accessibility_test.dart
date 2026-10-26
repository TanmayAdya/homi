import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/app/theme.dart';
import 'package:safe_at_home/l10n/app_localizations.dart';
import 'program_localization_support.dart';
import 'package:safe_at_home/features/programs/live_programs_screen.dart';
import 'case_coordinator_test.dart' show FakeTransport;
import 'live_workflows_test.dart' show MemoryPrivateStore, services;
import '../services/case_evidence_api_client_test.dart' as http;

void main() {
  for (final config in [
    (const Locale('en'), const Size(320, 812)),
    (const Locale('en'), const Size(932, 430)),
    for (final locale in AppLocalizations.supportedLocales.where(
      (locale) => locale.languageCode != 'en',
    ))
      (locale, const Size(320, 812)),
  ]) {
    final (locale, size) = config;
    String tr(String text, [Map<String, Object?> args = const {}]) =>
        programText(locale, text, args);
    testWidgets(
      'program actions and all expanded reasons remain accessible at 3.2x in $locale $size',
      (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final reasons = [
          for (var i = 0; i < 10; i++)
            'Fictional check $i: ${'A qualified reviewer must confirm these reported facts and the current program rules. ' * 5}',
        ];
        final match = {
          'programId': 'fictional-program',
          'programName': 'Fictional program',
          'ruleVersion': 'test-v1',
          'isDemo': true,
          'availability': 'unverified',
          'recheckAfter': null,
          'sources': <Object>[],
          'requiredDocuments': <String>[],
          'intake': null,
          'status': 'does_not_meet_criterion',
          'checks': [
            for (var i = 0; i < 10; i++)
              {
                'id': 'check-$i',
                'status': i < 3
                    ? 'pass'
                    : i < 6
                    ? 'fail'
                    : 'unknown',
                'reasonCode': 'FIXTURE',
                'explanation': reasons[i],
                'missingFields': <String>[],
                'resolvedBy': 'program',
                'sourceIds': <String>[],
              },
          ],
        };
        final transport = FakeTransport((request) async {
          final body = http.requestJson(request);
          if (request.endpoint.path == '/v1/create-case') {
            return http.jsonResponse({...body, 'revision': 1});
          }
          expect(request.endpoint.path, '/v1/match-case');
          final now = DateTime.now().toUtc().toIso8601String();
          return http.jsonResponse({
            'schemaVersion': '1',
            'caseId': body['caseId'],
            'caseRevision': 1,
            'evaluatedAt': now,
            'evaluationDate': now.substring(0, 10),
            'matches': [match],
          });
        });
        final app = services(MemoryPrivateStore(), transport);
        addTearDown(app.dispose);
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
            home: LiveProgramsScreen(services: app),
          ),
        );
        await tester.pumpAndSettle();
        final scroll = find.byType(Scrollable).first;
        final action = find.descendant(
          of: find.byKey(const ValueKey('program-fictional-program-details')),
          matching: find.text(tr('Details')),
        );
        await tester.scrollUntilVisible(
          action,
          300,
          scrollable: scroll,
          maxScrolls: 30,
        );
        await Scrollable.ensureVisible(tester.element(action), alignment: .5);
        await tester.pumpAndSettle();
        expect(action.hitTestable(), findsOneWidget);
        expect(find.text(tr('Review requirements')), findsNothing);
        final summary = tr(
          '{notMet} not met · {met} looks met · {answer} for you to answer · {others} others must confirm',
          {'notMet': 3, 'met': 3, 'answer': 0, 'others': 4},
        );
        expect(find.text(summary), findsOneWidget);
        expect(find.text(tr('A known criterion is not met')), findsOneWidget);
        for (final reason in reasons) {
          expect(find.text(reason), findsNothing);
        }
        await tester.tap(action);
        await tester.pumpAndSettle();
        for (final (group, count) in [
          ('Looks met', 3),
          ('Not met', 3),
          ('The program must confirm', 4),
        ]) {
          expect(
            find.text(
              tr('{group} ({count})', {'group': tr(group), 'count': count}),
            ),
            findsOneWidget,
          );
        }
        String firstSentence(String reason) =>
            RegExp(r'^(.+?[.!?])\s').firstMatch(reason)!.group(1)!;
        for (var i = 0; i < 10; i++) {
          final tile = find.byKey(
            ValueKey('program-fictional-program-check-check-$i'),
          );
          expect(tile, findsOneWidget);
          expect(
            find.descendant(
              of: tile,
              matching: find.text(firstSentence(reasons[i])),
            ),
            findsOneWidget,
          );
          expect(find.text(reasons[i]), findsNothing);
        }
        final last = find.byKey(
          const ValueKey('program-fictional-program-check-check-9'),
        );
        final why = find.descendant(of: last, matching: find.text(tr('Why')));
        await Scrollable.ensureVisible(tester.element(why), alignment: .5);
        await tester.pumpAndSettle();
        expect(why.hitTestable(), findsOneWidget);
        await tester.tap(why);
        await tester.pumpAndSettle();
        final full = find.text(reasons.last);
        await Scrollable.ensureVisible(tester.element(full), alignment: .5);
        await tester.pumpAndSettle();
        expect(full.hitTestable(), findsOneWidget);
        await Scrollable.ensureVisible(tester.element(action), alignment: .5);
        await tester.pumpAndSettle();
        await tester.tap(action);
        await tester.pumpAndSettle();
        expect(find.text(reasons.last), findsNothing);
        await Scrollable.ensureVisible(tester.element(action), alignment: .5);
        await tester.pumpAndSettle();
        expect(action.hitTestable(), findsOneWidget);
        expect(
          transport.requests.where((r) => r.endpoint.path == '/v1/match-case'),
          hasLength(1),
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
}
