import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/features/assessment/application/home_safety/home_safety_session.dart';
import 'package:safe_at_home/features/assessment/domain/assessment_location.dart';
import 'package:safe_at_home/features/assessment/presentation/home_safety/home_safety_screen.dart';
import 'package:safe_at_home/shared/presentation/sah_components.dart';
import 'home_safety_support.dart';

void main() {
  testWidgets(
    'embedded rooms keep one scaffold, every capture path and internal back',
    (tester) async {
      tester.view.physicalSize = const Size(320, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      final h = (await tester.runAsync(() async {
        final h = await safetyHarness(homeSafety: true);
        final session = HomeSafetySession(
          services: h.services,
          catalog: h.server.catalog,
        );
        await session.initialize();
        for (final type in AssessmentLocation.values) {
          await session.edit(
            addRoom(type.name, type: type.name, name: 'Fictional ${type.name}'),
          );
        }
        await session.edit(
          addRoom('second-bathroom', type: 'bathroom', name: 'Second bathroom'),
        );
        await session.save();
        session.dispose();
        return h;
      }))!;
      addTearDown(() {
        h.services.dispose();
        h.auth.dispose();
      });
      final key = GlobalKey<HomeSafetyScreenState>();
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(3.2)),
            child: child!,
          ),
          home: Scaffold(
            body: HomeSafetyScreen(
              key: key,
              services: h.services,
              catalog: h.server.catalog,
              workspaceMode: true,
              embedded: true,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(Scaffold), findsOneWidget);
      expect(find.byType(AppBar), findsNothing);
      expect(find.text('Home assessment'), findsNothing);
      expect(key.currentState!.handleBack(), false);
      expect(find.textContaining('0 of'), findsNothing);
      expect(find.text('Not started'), findsWidgets);
      for (final id in [
        ...AssessmentLocation.values.map((type) => type.name),
        'second-bathroom',
      ]) {
        final room = find.byKey(ValueKey('room-$id'));
        await tester.scrollUntilVisible(
          room,
          500,
          scrollable: find.byType(Scrollable).first,
        );
        final title = find.descendant(
          of: room,
          matching: find.text(
            id == 'second-bathroom' ? 'Second bathroom' : 'Fictional $id',
          ),
        );
        await Scrollable.ensureVisible(tester.element(title), alignment: .5);
        await tester.pumpAndSettle();
        await tester.tap(title);
        await tester.pumpAndSettle();
        expect(key.currentState!.selectedRoom, id);
        final scan = find.byKey(const ValueKey('room-start-assessment'));
        if (id != 'outdoorPaths') {
          await tester.scrollUntilVisible(
            scan,
            500,
            scrollable: find.byType(Scrollable).first,
          );
          expect(tester.widget<FilledButton>(scan).onPressed, isNotNull);
          await tester.scrollUntilVisible(
            find.byKey(ValueKey('open-room-scan-$id')),
            300,
            scrollable: find.byType(Scrollable).first,
          );
        } else {
          expect(scan, findsNothing);
          expect(find.byKey(ValueKey('open-room-scan-$id')), findsNothing);
          expect(
            find.byKey(const ValueKey('room-next-questions')),
            findsOneWidget,
          );
        }
        for (final action in [
          'room-continue-questions',
          'room-add-photo',
          'room-enter-measurement',
        ]) {
          await tester.scrollUntilVisible(
            find.byKey(ValueKey(action)),
            300,
            scrollable: find.byType(Scrollable).first,
          );
          expect(
            tester.widget<SahActionTile>(find.byKey(ValueKey(action))).onTap,
            isNotNull,
          );
        }
        expect(tester.takeException(), isNull);
        expect(key.currentState!.handleBack(), true);
        await tester.pumpAndSettle();
        expect(key.currentState!.selectedRoom, isNull);
      }
      expect(h.server.document.rooms, hasLength(8));
      await tester.pumpWidget(const SizedBox());
    },
  );
}
