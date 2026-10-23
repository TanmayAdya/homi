import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/features/assessment/application/assessment_sync.dart';
import 'package:safe_at_home/features/assessment/application/export_review.dart';
import 'package:safe_at_home/features/assessment/domain/capture/capture_adapter.dart';
import 'package:safe_at_home/features/assessment/presentation/export_review_screen.dart';
import 'package:safe_at_home/features/assessment/presentation/save_status_card.dart';
import 'package:safe_at_home/shared/models/evidence.dart';

import '../application/export_review_test.dart' show Fixture;
import '../fakes/fake_case_server.dart';

void main() {
  Future<void> tap(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  testWidgets('show, check, include and hand over the selection', (
    tester,
  ) async {
    late Fixture fx;
    late List<String> photos;
    await tester.runAsync(() async {
      fx = await Fixture.create();
      photos = (await fx.seed()).photos;
    });
    final review = ExportReview(
      gateway: fx.server,
      currentCase: () => fx.sync.savedCase,
    );
    List<EvidenceSelection>? handed;

    await tester.pumpWidget(
      MaterialApp(
        home: ExportReviewScreen(
          review: review,
          savedCase: () => fx.sync.savedCase,
          onDone: (s) => handed = s,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('0 of 6 photos chosen'), findsOneWidget);
    final Finder first = find.byKey(ValueKey('candidate-${photos[0]}'));
    final Finder include = find.byKey(ValueKey('include-${photos[0]}'));
    expect(tester.widget<CheckboxListTile>(include).onChanged, isNull);

    await tap(
      tester,
      find.descendant(of: first, matching: find.text('Show photo')),
    );
    await tap(tester, find.text('I checked this photo'));
    expect(find.text('Checked by you'), findsOneWidget);
    await tap(tester, include);
    expect(find.text('1 of 6 photos chosen'), findsOneWidget);

    final Finder unconfirmedInclude = find.byKey(
      ValueKey('include-${photos[2]}'),
    );
    expect(
      tester.widget<CheckboxListTile>(unconfirmedInclude).onChanged,
      isNull,
    );

    await tap(tester, find.text('Use these photos'));
    expect(handed!.single.evidenceId, photos[0]);
    expect(handed!.single.reviewedForExport, isTrue);
  });

  group('save status card', () {
    testWidgets('moves from unsaved to saved', (tester) async {
      late Fixture fx;
      await tester.runAsync(() async {
        fx = await Fixture.create();
      });
      final String id = fx.controller.startFinding(AssessmentArea.entrance);
      fx.controller.setObservation(id, 'I notice a step.');

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: SaveStatusCard(sync: fx.sync)),
        ),
      );
      expect(find.textContaining('Not saved yet'), findsOneWidget);

      await tester.runAsync(() => fx.sync.save());
      await tester.pumpAndSettle();
      expect(find.text('Saved to your case.'), findsOneWidget);

      fx.controller.setObservation(id, 'I notice a high step.');
      await tester.pump();
      expect(find.textContaining('Not saved yet'), findsOneWidget);
    });

    testWidgets('an uncertain save offers only a check', (tester) async {
      late Fixture fx;
      await tester.runAsync(() async {
        fx = await Fixture.create();
      });
      final String id = fx.controller.startFinding(AssessmentArea.entrance);
      fx.controller.setObservation(id, 'I notice a step.');
      fx.server.failNext['saveCase'] = (
        'CASE_SAVE_UNCERTAIN',
        FailMode.afterApplying,
      );
      await tester.runAsync(() => fx.sync.save());

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: SaveStatusCard(sync: fx.sync)),
        ),
      );
      expect(fx.sync.phase, SyncPhase.uncertain);
      expect(find.text('Check what is saved'), findsOneWidget);
      expect(find.text('Save to my case'), findsNothing);

      await tester.runAsync(() async {
        await tester.tap(find.text('Check what is saved'));
        await Future<void>.delayed(const Duration(milliseconds: 10));
      });
      await tester.pumpAndSettle();
      expect(find.text('Saved to your case.'), findsOneWidget);
    });
  });
}
