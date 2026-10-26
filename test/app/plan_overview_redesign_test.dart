import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/app/theme.dart';
import 'package:safe_at_home/features/cases/case_home_screen.dart';
import 'package:safe_at_home/features/cases/profile_editor_screen.dart';
import 'package:safe_at_home/l10n/app_localizations.dart';
import 'package:safe_at_home/shared/presentation/sah_components.dart';
import 'package:safe_at_home/shared/presentation/sah_floating_nav.dart';

import '../features/assessment/home_safety/home_safety_support.dart'
    show SafetyStore;
import '../services/case_evidence_api_client_test.dart' as http;
import 'case_coordinator_test.dart' show FakeTransport;
import 'live_workflows_test.dart' show services;

void viewSize(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
}

const stages = [
  'case-profile',
  'case-rooms',
  'case-programs',
  'case-documents',
  'case-tasks',
];

void main() {
  testWidgets(
    'a new plan recommends resident details and opens them inside the Plan tab',
    (tester) async {
      viewSize(tester, const Size(390, 2000));
      final app = services(
        SafetyStore(),
        FakeTransport(
          (request) async => request.endpoint.path == '/v2/list-cases'
              ? http.jsonResponse({
                  'schemaVersion': '2',
                  'cases': [],
                  'nextAfterCaseId': null,
                })
              : http.apiError('SERVICE_UNAVAILABLE', 503),
        ),
      );
      addTearDown(app.dispose);
      await app.coordinator.createDraft(name: 'Fictional house');
      app.coordinator.snapshot = app.coordinator.draft!.atRevision(1);
      await tester.pumpWidget(
        MaterialApp(
          theme: SafeAtHomeTheme.light().copyWith(platform: TargetPlatform.iOS),
          home: CaseHomeScreen(services: app),
        ),
      );
      await tester.pumpAndSettle();

      for (final key in [
        'case-plan-title',
        'case-save-badge',
        'case-rename-plan',
      ]) {
        expect(find.byKey(ValueKey(key)), findsOneWidget, reason: key);
      }
      final card = find.byKey(const ValueKey('plan-next-step'));
      expect(
        find.descendant(of: card, matching: find.text('Add resident details')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: card, matching: find.text('Start')),
        findsOneWidget,
      );
      expect(find.text('Your progress'), findsOneWidget);

      var previous = tester.getRect(card).bottom;
      for (final key in stages) {
        final row = find.byKey(ValueKey(key));
        final top = tester.getRect(row).top;
        expect(top, greaterThanOrEqualTo(previous - 0.5), reason: key);
        previous = tester.getRect(row).bottom;
      }

      final action = find.byKey(const ValueKey('plan-next-step-action'));
      await tester.tap(action);
      await tester.pumpAndSettle();
      expect(find.byType(ProfileEditorScreen), findsOneWidget);
      expect(find.byType(SahFloatingNavBar), findsOneWidget);
      expect(find.byKey(const ValueKey('plan-next-step')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  for (final locale in const [
    Locale('en'),
    Locale('es'),
    Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hans'),
  ]) {
    testWidgets(
      'plan components fit 320px at 3.2x text in ${locale.toLanguageTag()}',
      (tester) async {
        viewSize(tester, const Size(320, 640));
        await tester.pumpWidget(
          MaterialApp(
            theme: SafeAtHomeTheme.light(),
            locale: locale,
            supportedLocales: AppLocalizations.supportedLocales,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: const TextScaler.linear(3.2)),
              child: child!,
            ),
            home: Builder(
              builder: (context) => Scaffold(
                body: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SahNextStepCard(
                        title: context.tr('Review {count} suggested concerns', {
                          'count': 12,
                        }),
                        message: context.tr(
                          'Keep the ones that are real and remove the rest. You can change this later.',
                        ),
                        actionLabel: context.tr('Review concerns'),
                        onAction: () {},
                      ),
                      SahListGroup(
                        title: context.tr('Your progress'),
                        children: [
                          SahStepTile(
                            number: 2,
                            title: context.tr('Rooms and concerns'),
                            subtitle: context.tr(
                              'Not started — you can start here',
                            ),
                            state: SahStepState.attention,
                            current: true,
                            onTap: () {},
                          ),
                          SahStepTile(
                            number: 5,
                            title: context.tr('Follow-up'),
                            subtitle: context.tr('Tasks appear as you go'),
                            state: SahStepState.done,
                            tag: context.tr('Needs attention'),
                          ),
                        ],
                      ),
                      for (final kind in SahOutputKind.values)
                        SahOutputLabel(kind: kind),
                      SahStatusLine(
                        label: context.tr('Changes not saved online'),
                        state: SahSaveState.waiting,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.byType(SahStepTile), findsNWidgets(2));
      },
    );
  }

  testWidgets('a step tile is one semantics node whose label includes state', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      MaterialApp(
        theme: SafeAtHomeTheme.light(),
        home: Scaffold(
          body: SahListGroup(
            children: [
              SahStepTile(
                key: const ValueKey('tile'),
                number: 2,
                title: 'Rooms and concerns',
                subtitle: '1 to review',
                state: SahStepState.attention,
                current: true,
                onTap: () {},
              ),
            ],
          ),
        ),
      ),
    );
    const label =
        'Step 2. Rooms and concerns. 1 to review. Needs attention. Current step';
    expect(find.bySemanticsLabel(label), findsOneWidget);
    final node = tester.getSemantics(find.byKey(const ValueKey('tile')));
    expect(node.label, label);
    expect(node.childrenCount, 0);
    expect(find.bySemanticsLabel('Rooms and concerns'), findsNothing);
    expect(find.bySemanticsLabel('Now'), findsNothing);
    semantics.dispose();
  });
}
