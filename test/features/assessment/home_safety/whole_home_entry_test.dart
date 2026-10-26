import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/features/assessment/application/home_safety/home_safety_session.dart';
import 'package:safe_at_home/features/assessment/presentation/home_safety/home_safety_screen.dart';
import 'package:safe_at_home/features/assessment/presentation/whole_home_screen.dart';
import 'home_safety_support.dart';

void main() {
  for (final scansFirst in [false, true]) {
    testWidgets(
      'connected model opens from ${scansFirst ? "room scans" : "checklist"} and returns to the same rooms',
      (tester) async {
        final h = (await tester.runAsync(() async {
          final h = await safetyHarness(homeSafety: true);
          final s = HomeSafetySession(
            services: h.services,
            catalog: h.server.catalog,
          );
          await s.initialize();
          await s.edit(
            addRoom('first', type: 'bathroom', name: 'First bathroom'),
          );
          await s.edit(
            addRoom('second', type: 'bathroom', name: 'Second bathroom'),
          );
          await s.save();
          s.dispose();
          return h;
        }))!;
        addTearDown(() {
          h.services.dispose();
          h.auth.dispose();
        });
        await tester.pumpWidget(
          MaterialApp(
            home: HomeSafetyScreen(
              services: h.services,
              catalog: h.server.catalog,
              scansFirst: scansFirst,
            ),
          ),
        );
        await tester.pumpAndSettle();
        final entry = find.byKey(const ValueKey('open-whole-home-model'));
        await tester.scrollUntilVisible(
          entry,
          200,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.tap(entry);
        await tester.pumpAndSettle();
        expect(find.byType(WholeHomeScreen), findsOneWidget);
        expect(find.text('First bathroom'), findsOneWidget);
        await tester.scrollUntilVisible(
          find.text('Second bathroom'),
          180,
          scrollable: find.byType(Scrollable).last,
        );
        expect(find.text('Second bathroom'), findsOneWidget);
        await tester.tap(find.byTooltip('Back'));
        await tester.pumpAndSettle();
        expect(find.byType(WholeHomeScreen), findsNothing);
        expect(h.server.document.rooms.map((r) => r.id), ['first', 'second']);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}
