import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/app/live_app.dart';
import 'package:safe_at_home/app/theme.dart';
import 'package:safe_at_home/features/programs/live_programs_screen.dart';
import 'package:safe_at_home/features/programs/program_intake_screen.dart';
import 'package:safe_at_home/l10n/app_localizations.dart';
import 'package:safe_at_home/shared/models/case_draft.dart';
import 'package:safe_at_home/shared/services/matching_api_client.dart';

import '../services/case_evidence_api_client_test.dart' as http;
import 'case_coordinator_test.dart' show FakeTransport;
import 'live_workflows_test.dart' show MemoryPrivateStore, services;

Map<String, Object?> _manualProgram({bool sources = true}) => {
  'programId': 'fictional-program',
  'programName': 'Fictional manual-review program',
  'ruleVersion': 'fictional-rule-v2',
  'isDemo': true,
  'availability': 'unverified',
  'recheckAfter': null,
  'status': 'needs_confirmation',
  'checks': [
    for (var i = 0; i < 10; i++)
      {
        'id': 'check-$i',
        'status': 'unknown',
        'reasonCode': i == 5 ? 'EXCEPTION_UNRESOLVED' : 'MANUAL_REVIEW',
        'explanation': i == 5
            ? 'Fictional exception still needs program review; this is not a rejection.'
            : 'Fictional requirement $i remains unknown.',
        'missingFields': <String>[],
        'resolvedBy': i < 2
            ? 'resident'
            : i < 4
            ? 'professional'
            : i < 9
            ? 'program'
            : null,
        'sourceIds': [if (sources) 'fictional-source'],
      },
  ],
  'sources': [
    if (sources)
      {
        'id': 'fictional-source',
        'url': 'https://example.org/fictional-program',
        'title': 'Fictional official source',
        'reviewedOn': '2026-10-20',
        'effectiveFrom': null,
        'effectiveUntil': null,
      },
  ],
  'requiredDocuments': <String>[],
  'intake': sources
      ? 'Fictional contact instructions. Confirm intake with the program.'
      : null,
};

Map<String, Object?> _response(
  Map<String, Object?> request, {
  bool sources = true,
  List<Map<String, Object?>>? programs,
}) {
  final now = DateTime.now().toUtc().toIso8601String();
  return {
    'schemaVersion': '1',
    'caseId': request['caseId'],
    'caseRevision': request['expectedCaseRevision'],
    'evaluatedAt': now,
    'evaluationDate': now.substring(0, 10),
    'matches': programs ?? [_manualProgram(sources: sources)],
  };
}

Future<AppServices> _app(FakeTransport transport) async {
  final app = services(MemoryPrivateStore(), transport);
  addTearDown(() {
    app.dispose();
    app.session.dispose();
  });
  await app.coordinator.createDraft();
  await app.coordinator.save();
  return app;
}

Widget _screen(AppServices app, {bool embedded = false, bool dark = false}) =>
    MaterialApp(
      locale: const Locale('en'),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      theme: dark ? SafeAtHomeTheme.dark() : SafeAtHomeTheme.light(),
      home: embedded
          ? Scaffold(
              body: LiveProgramsScreen(
                services: app,
                workspaceMode: true,
                embedded: true,
              ),
            )
          : LiveProgramsScreen(services: app),
    );

Future<void> _tap(WidgetTester tester, Finder target) async {
  await Scrollable.ensureVisible(tester.element(target), alignment: .5);
  await tester.pumpAndSettle();
  await tester.tap(target);
  await tester.pumpAndSettle();
}

Finder _details(String id) => find.descendant(
  of: find.byKey(ValueKey('program-$id-details')),
  matching: find.text('Details'),
);

void main() {
  for (final dark in [false, true]) {
    testWidgets(
      'manual-review Help explains responsibility and preserves draft routes (${dark ? 'dark' : 'light'})',
      (tester) async {
        final transport = FakeTransport((request) async {
          final body = http.requestJson(request);
          if (request.endpoint.path == '/v1/create-case') {
            return http.jsonResponse({...body, 'revision': 1});
          }
          if (request.endpoint.path == '/v1/match-case') {
            return http.jsonResponse(_response(body));
          }
          throw StateError('Only fictional matching is configured');
        });
        final app = await _app(transport);
        await tester.pumpWidget(_screen(app, embedded: true, dark: dark));
        await tester.pumpAndSettle();
        expect(find.byType(Scaffold), findsOneWidget);
        expect(find.byType(AppBar), findsNothing);
        expect(
          find.text('Possible help: review the program’s service scope.'),
          findsOneWidget,
        );
        expect(
          find.text('Eligibility and availability need confirmation.'),
          findsOneWidget,
        );
        for (final label in [
          'Current availability is unverified. Confirm it with the program.',
          'More information is needed',
          'Ask the program',
          'Review requirements',
          'Some policy details are unconfirmed',
          'Preparation only. Nothing has been submitted by this app.',
        ]) {
          expect(find.text(label), findsNothing);
        }
        expect(find.textContaining('Review needed:'), findsNothing);
        expect(
          find.text(
            '0 looks met · 2 for you to answer · 8 others must confirm',
          ),
          findsOneWidget,
        );
        expect(
          find.text('Where: Confirm your address with the program'),
          findsOneWidget,
        );
        expect(find.text('Official form draft'), findsOneWidget);
        expect(find.text('Prepare a draft'), findsNothing);
        await _tap(tester, _details('fictional-program'));
        for (final label in [
          'Current availability is unverified. Confirm it with the program.',
          'More information is needed',
          'Preparation only. Nothing has been submitted by this app.',
        ]) {
          expect(find.text(label), findsOneWidget);
        }
        for (final label in [
          'You can answer (2)',
          'The program must confirm (5)',
          'A professional must confirm (2)',
          'Reviewer not specified (1)',
        ]) {
          expect(find.text(label), findsOneWidget);
        }
        expect(find.textContaining('Looks met ('), findsNothing);
        expect(find.textContaining('Not met ('), findsNothing);
        expect(
          find.text(
            'Fictional exception still needs program review; this is not a rejection.',
          ),
          findsOneWidget,
        );
        expect(
          find.byWidgetPredicate(
            (w) =>
                (w is ListTile || w is ExpansionTile) &&
                w.key.toString().contains('-check-check-'),
          ),
          findsNWidgets(10),
        );
        expect(find.text('Why'), findsNWidgets(10));
        expect(find.text('Rule version: fictional-rule-v2'), findsOneWidget);
        expect(find.text('Fictional official source'), findsOneWidget);
        for (final action in ['intake', 'answers', 'export', 'history']) {
          expect(
            find.byKey(ValueKey('program-fictional-program-$action')),
            findsNothing,
          );
        }
        expect(
          tester
              .widget<FilledButton>(
                find.byKey(const ValueKey('program-fictional-program-start')),
              )
              .onPressed,
          isNotNull,
        );
        await _tap(
          tester,
          find.byKey(const ValueKey('program-fictional-program-contact')),
        );
        expect(find.byType(AlertDialog), findsOneWidget);
        expect(
          find.text(
            'Fictional contact instructions. Confirm intake with the program.',
          ),
          findsWidgets,
        );
        await tester.tap(find.text('Close'));
        await tester.pumpAndSettle();
        await _tap(
          tester,
          find.byKey(
            const ValueKey('program-fictional-program-missing-answers'),
          ),
        );
        expect(find.byType(ProgramIntakeScreen), findsOneWidget);
        expect(
          transport.requests.where(
            (r) => r.endpoint.path.contains('save-program-intake'),
          ),
          isEmpty,
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets('three program overviews stay compact and retain full names in details', (
    tester,
  ) async {
    const routes = [
      (
        'scfhp-eaa',
        'SCFHP',
        'SCFHP Environmental Accessibility Adaptations (referral draft)',
        'May help SCFHP Medi-Cal members with home changes needed for safety and independence.',
        'Needs a professional order and a physical or occupational therapy evaluation.',
        'Santa Clara County · SCFHP Medi-Cal or DualConnect members only',
      ),
      (
        'hpsm-eaa',
        'HPSM',
        'HPSM Home Modifications (referral draft)',
        'May help HPSM members with home changes needed for safety and independence.',
        'Needs a professional order and a physical or occupational therapy evaluation.',
        'San Mateo County · HPSM Medi-Cal or CareAdvantage members only',
      ),
      (
        'rtp-home-repair',
        'Rebuilding Together Peninsula',
        'Rebuilding Together Peninsula (preparation worksheet)',
        'May help homeowners with no-cost safety repairs, if RTP accepts the project.',
        'RTP typically can’t do emergency repairs.',
        'San Mateo County, Palo Alto, Mountain View, Los Altos · RTP confirms the address',
      ),
    ];
    final transport = FakeTransport((request) async {
      final body = http.requestJson(request);
      if (request.endpoint.path == '/v1/create-case') {
        return http.jsonResponse({...body, 'revision': 1});
      }
      return http.jsonResponse(
        _response(
          body,
          programs: [
            for (final (id, _, fullName, _, _, _) in routes)
              {..._manualProgram(), 'programId': id, 'programName': fullName},
          ],
        ),
      );
    });
    final app = await _app(transport);
    await tester.pumpWidget(_screen(app, embedded: true));
    await tester.pumpAndSettle();
    expect(
      find.text('Eligibility and availability need confirmation.'),
      findsOneWidget,
    );
    expect(find.text('3 programs'), findsOneWidget);
    expect(find.text('Details'), findsWidgets);
    expect(find.textContaining('Review needed:'), findsNothing);
    for (final (id, title, fullName, purpose, limit, where) in routes) {
      final start = find.byKey(ValueKey('program-$id-start'));
      await tester.scrollUntilVisible(
        start,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      expect(tester.widget(start), isA<FilledButton>());
      final worksheet = id == 'rtp-home-repair';
      expect(
        find.descendant(
          of: start,
          matching: find.text(
            worksheet ? 'Prepare worksheet' : 'Start application',
          ),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(ValueKey('program-$id')),
          matching: find.text(
            worksheet ? 'Preparation worksheet' : 'Official form draft',
          ),
        ),
        findsOneWidget,
      );
      expect(
        tester.getTopLeft(start).dy,
        lessThan(tester.getTopLeft(_details(id)).dy),
      );
      expect(find.text(title), findsOneWidget);
      expect(find.text(purpose), findsOneWidget);
      expect(
        tester.widget<Text>(find.byKey(ValueKey('program-limit-$id'))).data,
        limit,
      );
      expect(find.text('Where: $where'), findsOneWidget);
      expect(find.text(fullName), findsNothing);
      await _tap(tester, _details(id));
      expect(find.text(fullName), findsOneWidget);
      expect(
        find.text('Preparation only. Nothing has been submitted by this app.'),
        findsOneWidget,
      );
      await _tap(tester, _details(id));
      expect(find.text(fullName), findsNothing);
    }
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'closed intake and a failed criterion remain visible before details',
    (tester) async {
      final route = _manualProgram();
      final checks = (route['checks'] as List).cast<Map<String, Object?>>();
      route['availability'] = 'not_accepting';
      route['status'] = 'does_not_meet_criterion';
      route['checks'] = [
        {
          ...checks.first,
          'status': 'fail',
          'explanation': 'A fictional documented criterion is not met.',
        },
        ...checks.skip(1),
      ];
      final transport = FakeTransport((request) async {
        final body = http.requestJson(request);
        return http.jsonResponse(
          request.endpoint.path == '/v1/create-case'
              ? {...body, 'revision': 1}
              : _response(body, programs: [route]),
        );
      });
      final app = await _app(transport);
      await tester.pumpWidget(_screen(app));
      await tester.pumpAndSettle();
      expect(
        find.text(
          'Intake is listed as closed. Ask the program about next steps.',
        ),
        findsOneWidget,
      );
      expect(find.text('A known criterion is not met'), findsOneWidget);
      expect(
        find.text('A fictional documented criterion is not met.'),
        findsNothing,
      );
      await _tap(tester, _details('fictional-program'));
      expect(
        find.text('A fictional documented criterion is not met.'),
        findsOneWidget,
      );
      expect(
        find.text(
          '1 not met · 0 looks met · 1 for you to answer · 8 others must confirm',
        ),
        findsOneWidget,
      );
      expect(find.text('Not met (1)'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'expired dated checks retain a warning and a working refresh action',
    (tester) async {
      var reads = 0;
      final transport = FakeTransport((request) async {
        final body = http.requestJson(request);
        if (request.endpoint.path == '/v1/create-case') {
          return http.jsonResponse({...body, 'revision': 1});
        }
        reads++;
        final deadline = DateTime.now().toUtc().add(
          Duration(days: reads == 1 ? -1 : 1),
        );
        return http.jsonResponse(
          _response(
            body,
            programs: [
              {..._manualProgram(), 'recheckAfter': deadline.toIso8601String()},
            ],
          ),
        );
      });
      final app = await _app(transport);
      await tester.pumpWidget(_screen(app));
      await tester.pumpAndSettle();
      expect(find.text('Some policy details are unconfirmed'), findsOneWidget);
      await _tap(tester, find.byKey(const ValueKey('program-refresh')));
      expect(reads, 2);
      expect(find.text('Some policy details are unconfirmed'), findsNothing);
      expect(find.byKey(const ValueKey('program-refresh')), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'stale answers disable draft writes and clearing the plan removes prior results',
    (tester) async {
      final transport = FakeTransport((request) async {
        final body = http.requestJson(request);
        if (request.endpoint.path == '/v1/create-case') {
          return http.jsonResponse({...body, 'revision': 1});
        }
        return http.jsonResponse(_response(body, sources: false));
      });
      final app = await _app(transport);
      await tester.pumpWidget(_screen(app));
      await tester.pumpAndSettle();
      await _tap(tester, _details('fictional-program'));
      expect(
        find.text('No verified source references are supplied for this route.'),
        findsOneWidget,
      );
      final before = app.coordinator.draft!.toJson();
      await app.coordinator.updateDraft(
        CaseDraft.fromJson({
          ...before,
          'profile': {
            ...before['profile'] as Map,
            'city': 'Fictional changed city',
          },
        }),
      );
      await tester.pumpAndSettle();
      tester
          .state<ScrollableState>(find.byType(Scrollable).first)
          .position
          .jumpTo(0);
      await tester.pumpAndSettle();
      expect(
        find.text('These results update once the case changes are saved.'),
        findsOneWidget,
      );
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('program-fictional-program-start')),
            )
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<TextButton>(
              find.byKey(
                const ValueKey('program-fictional-program-missing-answers'),
              ),
            )
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<TextButton>(
              find.byKey(const ValueKey('program-fictional-program-contact')),
            )
            .onPressed,
        isNotNull,
      );
      await app.coordinator.clearSelected();
      await tester.pumpAndSettle();
      expect(find.text('Fictional manual-review program'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('late matching response cannot restore a closed plan', (
    tester,
  ) async {
    final pending = Completer<MatchingHttpResponse>();
    Map<String, Object?>? matched;
    final transport = FakeTransport((request) async {
      final body = http.requestJson(request);
      if (request.endpoint.path == '/v1/create-case') {
        return http.jsonResponse({...body, 'revision': 1});
      }
      matched = body;
      return pending.future;
    });
    final app = await _app(transport);
    await tester.pumpWidget(_screen(app));
    await tester.pump();
    await app.coordinator.clearSelected();
    pending.complete(http.jsonResponse(_response(matched!)));
    await tester.pumpAndSettle();
    expect(find.text('Fictional manual-review program'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
