import 'homi_navigation_support.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/app/theme.dart';
import 'package:safe_at_home/features/auth/login_screen.dart';
import 'package:safe_at_home/features/cases/case_home_screen.dart';
import 'package:safe_at_home/features/cases/case_workspace_screen.dart';
import 'package:safe_at_home/shared/models/case_draft.dart';
import 'package:safe_at_home/features/cases/plan_name_dialog.dart';
import 'package:safe_at_home/l10n/app_localizations.dart';

import '../services/case_evidence_api_client_test.dart' as http;
import 'app_design_test.dart' show narrowLargeText, reveal;
import 'case_coordinator_test.dart' show FakeSession, FakeTransport;
import 'live_workflows_test.dart' show MemoryPrivateStore, services;

Widget localized(Locale locale, Widget home) => MaterialApp(
  locale: locale,
  supportedLocales: AppLocalizations.supportedLocales,
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  theme: SafeAtHomeTheme.light(),
  home: home,
);

void main() {
  testWidgets(
    'Spanish login translates controls without changing typed credentials',
    (tester) async {
      narrowLargeText(tester, scale: 3.2);
      final session = FakeSession();
      addTearDown(session.dispose);
      final home = LoginScreen(session: session, emailDeliveryEnabled: false);
      await tester.pumpWidget(localized(const Locale('es'), home));
      await tester.pumpAndSettle();
      expect(find.text('Te damos la bienvenida'), findsOneWidget);
      expect(find.byKey(const ValueKey('choose-language')), findsOneWidget);
      final email = find.widgetWithText(TextField, 'Correo electrónico');
      await reveal(tester, email);
      await tester.enterText(email, 'fictional@example.test');
      final password = find.widgetWithText(TextField, 'Contraseña');
      await reveal(tester, password);
      await tester.enterText(password, 'Fictional-password-42');
      await tester.tap(find.byTooltip('Mostrar contraseña'));
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(password).obscureText, false);
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(localized(const Locale('vi'), home));
      await tester.pumpAndSettle();
      final fields = tester
          .widgetList<TextField>(find.byType(TextField))
          .toList();
      expect(fields[0].controller!.text, 'fictional@example.test');
      expect(fields[1].controller!.text, 'Fictional-password-42');
      expect((fields[1].decoration!.label! as Text).data, 'Mật khẩu');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'conflict summary translates only field-aware enums and preserves resident text',
    (tester) async {
      final transport = FakeTransport(
        (_) async =>
            throw StateError('Viewing a conflict must not send a request'),
      );
      final app = services(MemoryPrivateStore(), transport);
      addTearDown(() {
        app.dispose();
        app.session.dispose();
      });
      await app.coordinator.createDraft();
      final json = app.coordinator.draft!.toJson();
      json['profile'] = {
        ...json['profile']! as Map<String, Object?>,
        'city': 'owner',
        'county': 'renter',
        'healthPlan': 'owner',
        'tenure': 'owner',
      };
      const observation = 'owner renter Bathroom {count}';
      json['findings'] = [
        {
          'id': 'fictional-finding',
          'room': 'bathroom',
          'observation': observation,
          'reviewState': 'confirmed',
          'evidenceIds': <String>[],
          'measurements': [
            {
              'type': 'fictional_width',
              'value': 800,
              'unit': 'mm',
              'method': 'manual',
              'confirmed': true,
            },
          ],
        },
      ];
      final draft = CaseDraft.fromJson(json);
      app.coordinator.draft = draft;
      app.coordinator.snapshot = draft.atRevision(1);
      app.coordinator.conflict = true;
      final before = app.coordinator.draft!.toJson();
      await tester.pumpWidget(
        localized(const Locale('es'), CaseWorkspaceScreen(services: app)),
      );
      await tester.pumpAndSettle();
      await reveal(tester, find.text('Comparar versiones'));
      await tester.tap(find.text('Comparar versiones'));
      await tester.pumpAndSettle();
      expect(find.text('Ciudad: owner'), findsNWidgets(2));
      expect(find.text('Condado: renter'), findsNWidgets(2));
      expect(find.text('Plan de salud: owner'), findsNWidgets(2));
      expect(find.text('Vivienda: Propietario'), findsNWidgets(2));
      final findings = tester
          .widgetList<Text>(find.textContaining(observation))
          .map((text) => text.data!)
          .toList();
      expect(findings, hasLength(2));
      for (final text in findings) {
        expect(text, contains(observation));
        expect(text, contains('Baño'));
        expect(text, contains('Confirmado por usted'));
        expect(text, contains('Medido'));
      }
      expect(app.coordinator.draft!.toJson(), before);
      expect(transport.requests, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  for (final entry in <Locale, String>{
    const Locale('es'): 'Tus planes para el hogar',
    const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hans'): '你的居家计划',
    const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant'): '你的居家計畫',
    const Locale('vi'): 'Các kế hoạch nhà ở của bạn',
    const Locale('fil'): 'Mga plano mo para sa bahay',
  }.entries) {
    testWidgets(
      '${entry.key} primary navigation fits large text and preserves a custom plan name',
      (tester) async {
        narrowLargeText(tester, scale: 3.2);
        final transport = FakeTransport((request) async {
          expect(request.endpoint.path, '/v2/list-cases');
          return http.jsonResponse({
            'schemaVersion': '2',
            'cases': [],
            'nextAfterCaseId': null,
          });
        });
        final app = services(MemoryPrivateStore(), transport);
        addTearDown(() {
          app.dispose();
          app.session.dispose();
        });
        const name = 'Welcome back {name}';
        await app.coordinator.createDraft(name: name);
        final id = app.coordinator.draft!.caseId;
        await tester.pumpWidget(
          localized(entry.key, CaseHomeScreen(services: app)),
        );
        await tester.pumpAndSettle();
        await reveal(tester, find.byKey(const ValueKey('case-plan-title')));
        expect(find.text(name), findsWidgets);
        await openManagePlans(tester);
        await tester.pumpAndSettle();
        await reveal(tester, find.byKey(const ValueKey('plan-search')));
        expect(find.byKey(const ValueKey('plan-search')), findsOneWidget);
        await reveal(tester, find.byKey(ValueKey('local-case-$id')));
        expect(find.text(name), findsWidgets);
        expect(app.coordinator.draft!.caseId, id);
        expect(tester.takeException(), isNull);
        expect(find.byType(NavigationDestination), findsNWidgets(5));
        await tester.tap(find.byKey(const ValueKey('open-account')));
        await tester.pumpAndSettle();
        final privacy = find
            .descendant(
              of: find.byKey(const ValueKey('account-privacy')),
              matching: find.byType(Text),
            )
            .first;
        await tester.ensureVisible(privacy);
        await tester.pumpAndSettle();
        expect(privacy.hitTestable(), findsOneWidget);
        await tester.tap(privacy);
        await tester.pumpAndSettle();
        await tester.ensureVisible(
          find.byKey(const ValueKey('settings-delete-account')),
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('settings-delete-account')).hitTestable(),
          findsOneWidget,
        );
        expect(app.coordinator.draft!.caseId, id);
        expect(tester.takeException(), isNull);
        expect(
          transport.requests.map((r) => r.endpoint.path),
          everyElement('/v2/list-cases'),
        );
      },
    );
  }

  testWidgets(
    'localized name dialog validates without translating resident input',
    (tester) async {
      narrowLargeText(tester, scale: 3.2);
      String? result;
      await tester.pumpWidget(
        localized(
          const Locale('es'),
          Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                key: const ValueKey('open-name'),
                onPressed: () async {
                  result = await showPlanNameDialog(
                    context: context,
                    defaultName: 'Home {name}',
                    creating: true,
                  );
                },
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('open-name')));
      await tester.pumpAndSettle();
      expect(find.text('Ponle nombre a tu plan'), findsOneWidget);
      expect(
        find.text('Déjalo en blanco para usar «Home {name}».'),
        findsOneWidget,
      );
      final input = find.byKey(const ValueKey('plan-name-input'));
      await tester.enterText(input, 'x' * 81);
      await tester.ensureVisible(find.byKey(const ValueKey('plan-name-save')));
      await tester.tap(find.byKey(const ValueKey('plan-name-save')));
      await tester.pumpAndSettle();
      expect(
        find.text('Usa hasta 80 caracteres en una sola línea.'),
        findsOneWidget,
      );
      final validationText = tester.renderObject<RenderParagraph>(
        find.text('Usa hasta 80 caracteres en una sola línea.'),
      );
      expect(validationText.maxLines, isNull);
      expect(validationText.didExceedMaxLines, false);
      await tester.ensureVisible(input);
      await tester.enterText(input, 'Welcome back {count}');
      await tester.ensureVisible(find.byKey(const ValueKey('plan-name-save')));
      await tester.tap(find.byKey(const ValueKey('plan-name-save')));
      await tester.pumpAndSettle();
      expect(result, 'Welcome back {count}');
      expect(tester.takeException(), isNull);
    },
  );
}
