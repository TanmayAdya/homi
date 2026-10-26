import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/app/theme.dart';
import 'package:safe_at_home/features/cases/case_home_screen.dart';
import 'package:safe_at_home/features/cases/profile_editor_screen.dart';
import 'package:safe_at_home/shared/presentation/sah_floating_nav.dart';

import '../services/case_evidence_api_client_test.dart' as http;
import 'case_coordinator_test.dart' show FakeTransport;
import 'live_workflows_test.dart' show services;
import '../features/assessment/home_safety/home_safety_support.dart'
    show SafetyStore;

void phoneSize(WidgetTester tester) {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
}

Future<void> capture(WidgetTester tester, String name) async {
  if (!const bool.fromEnvironment('SAVE_UI_PREVIEWS')) return;
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(const ValueKey('preview')),
  );
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 2);
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    await File(
      '/tmp/homi-approved-$name.png',
    ).writeAsBytes(png!.buffer.asUint8List());
    image.dispose();
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    const fontPath = String.fromEnvironment('UI_PREVIEW_FONT');
    if (fontPath.isEmpty) return;
    final font = FontLoader('Roboto')
      ..addFont(File(fontPath).readAsBytes().then(ByteData.sublistView));
    await font.load();
    final icons = FontLoader('MaterialIcons')
      ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await icons.load();
  });

  testWidgets('tab bar keeps every label and never covers content', (
    tester,
  ) async {
    phoneSize(tester);
    var tapped = false;
    for (final scale in [1.0, 3.2]) {
      await tester.pumpWidget(
        MaterialApp(
          theme: SafeAtHomeTheme.light().copyWith(platform: TargetPlatform.iOS),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: SahFloatingScaffold(
            selectedIndex: 0,
            onDestinationSelected: (_) {},
            body: Builder(
              builder: (context) => ListView(
                padding: sahFloatingContentPadding(context),
                children: [
                  for (var i = 0; i < 20; i++)
                    SizedBox(height: 80, child: Text('Room $i')),
                  FilledButton(
                    key: const ValueKey('last-action'),
                    onPressed: () => tapped = true,
                    child: const Text('Last action'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      for (final label in ['Plan', 'Rooms', 'Help', 'Tasks', 'Assistant']) {
        expect(find.text(label), findsOneWidget, reason: '$label at $scale');
      }
      expect(find.byKey(const ValueKey('ask-homi')), findsNothing);
      final viewport = tester.getRect(find.byType(Scrollable));
      final navigation = tester.getRect(find.byType(SahFloatingNavBar));
      expect(viewport.bottom, lessThanOrEqualTo(navigation.top));
      final position = tester
          .state<ScrollableState>(find.byType(Scrollable))
          .position;
      position.jumpTo(position.maxScrollExtent);
      await tester.pumpAndSettle();
      final action = find.byKey(const ValueKey('last-action'));
      expect(tester.getRect(action).bottom, lessThanOrEqualTo(navigation.top));
      await tester.tap(action);
      expect(tapped, isTrue);
      tapped = false;
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('plan header names the plan and keeps rename one tap away', (
    tester,
  ) async {
    phoneSize(tester);
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
    await app.coordinator.createDraft(name: 'David’s house');
    app.coordinator.snapshot = app.coordinator.draft!.atRevision(1);
    await tester.pumpWidget(
      MaterialApp(
        theme: SafeAtHomeTheme.light().copyWith(platform: TargetPlatform.iOS),
        builder: (context, child) =>
            RepaintBoundary(key: const ValueKey('preview'), child: child!),
        home: CaseHomeScreen(services: app),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Plans'), findsOneWidget);
    expect(find.byKey(const ValueKey('plan-next-step')), findsOneWidget);
    expect(find.byKey(const ValueKey('case-rename-plan')), findsOneWidget);
    expect(find.byKey(const ValueKey('open-account')), findsOneWidget);
    final title = tester.getRect(find.byKey(const ValueKey('case-plan-title')));
    final selector = tester.getRect(
      find.byKey(const ValueKey('active-plan-selector')),
    );
    expect(selector.left, closeTo(12, 1));
    expect(selector.bottom, lessThan(title.top + 1));
    await capture(tester, 'plan');
    await tester.tap(find.byKey(const ValueKey('plan-tab-rooms')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('active-plan-selector')).hitTestable(),
      findsOneWidget,
    );
    expect(
      tester.getRect(find.byKey(const ValueKey('active-plan-selector'))).top,
      greaterThanOrEqualTo(0),
    );
    expect(find.text('David’s house'), findsWidgets);
    await capture(tester, 'rooms');
    await tester.tap(find.byKey(const ValueKey('plan-tab-plan')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('case-profile')));
    await tester.pumpAndSettle();
    expect(find.byType(SahFloatingNavBar), findsOneWidget);
    expect(find.byKey(const ValueKey('active-plan-selector')), findsNothing);
    await capture(tester, 'resident');
    expect(find.text('Scan or view your bathroom'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('pushed screens stay in their tab and back pops them first', (
    tester,
  ) async {
    phoneSize(tester);
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
    await app.coordinator.createDraft(name: 'David’s house');
    app.coordinator.snapshot = app.coordinator.draft!.atRevision(1);
    final caseId = app.coordinator.draft!.caseId;
    await tester.pumpWidget(
      MaterialApp(
        theme: SafeAtHomeTheme.light(),
        home: CaseHomeScreen(services: app),
      ),
    );
    await tester.pumpAndSettle();
    NavigationBar bar() => tester.widget(find.byType(NavigationBar));
    final resident = find.byType(ProfileEditorScreen);

    await tester.tap(find.byKey(const ValueKey('case-profile')));
    await tester.pumpAndSettle();
    expect(resident, findsOneWidget);
    expect(find.byType(NavigationBar).hitTestable(), findsOneWidget);
    expect(find.byKey(const ValueKey('active-plan-selector')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('plan-tab-rooms')));
    await tester.pumpAndSettle();
    expect(bar().selectedIndex, HomiTab.rooms.index);
    expect(resident, findsNothing);
    expect(find.byKey(const ValueKey('active-plan-selector')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('plan-tab-plan')));
    await tester.pumpAndSettle();
    expect(bar().selectedIndex, HomiTab.plan.index);
    expect(resident, findsOneWidget);
    expect(find.byKey(const ValueKey('case-plan-title')), findsNothing);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(resident, findsNothing);
    expect(find.byType(CaseHomeScreen), findsOneWidget);
    expect(find.byKey(const ValueKey('case-plan-title')), findsOneWidget);
    expect(find.byKey(const ValueKey('active-plan-selector')), findsOneWidget);
    expect(bar().selectedIndex, HomiTab.plan.index);
    expect(app.coordinator.draft!.caseId, caseId);
    expect(tester.takeException(), isNull);
  });
}
