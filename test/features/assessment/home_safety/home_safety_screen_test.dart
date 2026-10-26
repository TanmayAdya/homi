import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/features/assessment/presentation/home_safety/home_safety_screen.dart';
import 'package:safe_at_home/l10n/app_localizations.dart';
import 'home_safety_support.dart';

void main() {
  testWidgets(
    'two named bedrooms remain separate at large text; answers save on device without a camera',
    (tester) async {
      final h = (await tester.runAsync(safetyHarness))!;
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(1.8)),
            child: child!,
          ),
          home: HomeSafetyScreen(
            services: h.services,
            catalog: h.server.catalog,
          ),
        ),
      );
      await tester.pumpAndSettle();
      for (final name in ['Fictional upstairs', 'Fictional downstairs']) {
        await tester.scrollUntilVisible(
          find.byKey(const ValueKey('rooms-add')),
          250,
          scrollable: find.byType(Scrollable).first,
        );
        await Scrollable.ensureVisible(
          tester.element(find.byKey(const ValueKey('rooms-add'))),
          alignment: .5,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('rooms-add')));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField), name);
        await tester.tap(find.text('Save on device'));
        await tester.pumpAndSettle();
      }
      expect(find.text('Fictional upstairs'), findsOneWidget);
      expect(find.text('Fictional downstairs'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('Fictional upstairs'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await Scrollable.ensureVisible(
        tester.element(find.text('Fictional upstairs')),
        alignment: .5,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Fictional upstairs'));
      await tester.pumpAndSettle();
      final notSure = find.byKey(
        const ValueKey('answer-bedroom.path-not_sure'),
      );
      await tester.scrollUntilVisible(
        notSure,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      final state = find.byKey(const ValueKey('answer-state-bedroom.path'));
      expect(tester.widget<Text>(state).data, 'Not answered');
      expect(
        tester
            .widget<RadioGroup<String>>(
              find.byKey(const ValueKey('answer-bedroom.path')),
            )
            .groupValue,
        isNull,
        reason: 'No answer is preselected.',
      );
      await tester.tap(notSure);
      await tester.pumpAndSettle();
      expect(tester.widget<Text>(state).data, 'Answered');
      expect(
        tester
            .widget<RadioGroup<String>>(
              find.byKey(const ValueKey('answer-bedroom.path')),
            )
            .groupValue,
        'not_sure',
      );
      expect(h.server.saves, 0);
      expect(tester.takeException(), isNull);
      final record = h.store.records.values.firstWhere(
        (r) => r.containsKey('baseline'),
      );
      expect((record['pending'] as List).length, 3);
    },
  );
  testWidgets(
    'a storage failure keeps the room-name dialog and typed input available for retry',
    (tester) async {
      final h = (await tester.runAsync(safetyHarness))!;
      await tester.pumpWidget(
        MaterialApp(
          home: HomeSafetyScreen(
            services: h.services,
            catalog: h.server.catalog,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('Add a room'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('Add a room'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Fictional retained room');
      h.store.fail = true;
      await tester.tap(find.text('Save on device'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.text('Fictional retained room'), findsOneWidget);
      expect(
        find.text(
          'The device save failed. Your input is still here; try again before closing.',
        ),
        findsOneWidget,
      );
      h.store.fail = false;
      await tester.tap(find.text('Save on device'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text('Fictional retained room'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('Spanish UI labels do not translate resident room names', (
    tester,
  ) async {
    final h = (await tester.runAsync(safetyHarness))!;
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('es'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: HomeSafetyScreen(services: h.services, catalog: h.server.catalog),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Habitaciones y lista de seguridad'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Añadir habitación'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Añadir habitación'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'My fictional bedroom');
    await tester.tap(find.text('Guardar en el dispositivo'));
    await tester.pumpAndSettle();
    expect(find.text('My fictional bedroom'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
