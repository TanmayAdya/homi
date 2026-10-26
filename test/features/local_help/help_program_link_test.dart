import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/features/local_help/help_finder.dart';
import 'package:safe_at_home/features/local_help/referral_catalog.dart';
import 'package:safe_at_home/features/local_help/referral_directory.dart';

import '../../app/core_localization_test.dart' show localized;
import 'local_help_screen_test.dart' show reveal, tap;

const _checklistNote = 'This app has a checklist for this program';

Future<void> _pump(
  WidgetTester tester,
  VoidCallback? Function(String)? checklist,
) => tester.pumpWidget(
  localized(
    const Locale('en'),
    Scaffold(
      body: SingleChildScrollView(
        child: HelpFinder(
          directory: const OfficialReferralDirectory(),
          now: DateTime(2026, 10, 26),
          location: null,
          onLocation: (_) {},
          actions: HelpActions(
            open: (_) async => true,
            save: (_) async {},
            followUp: (_) async {},
            isSaved: (_) => false,
            checklist: checklist,
          ),
        ),
      ),
    ),
  ),
);

void main() {
  test('federal referrals carry their backend program IDs', () {
    final directory = ReferralCatalog.bundled();
    expect(
      directory.provider('referral-usda-section-504')?.programId,
      'usda-section-504',
    );
    expect(directory.provider('referral-va-hisa')?.programId, 'va-hisa');
    expect(directory.providers.map((p) => p.programId).nonNulls.toList(), [
      'usda-section-504',
      'va-hisa',
    ]);
  });

  testWidgets(
    'matched program shows one card with the checklist; unmatched stays a referral',
    (tester) async {
      final opened = <String>[];
      await _pump(
        tester,
        (id) => id == 'usda-section-504' ? () => opened.add(id) : null,
      );
      final usda = find.byKey(const ValueKey('referral-usda-section-504'));
      await reveal(tester, usda);
      expect(usda, findsOneWidget);
      expect(
        find.descendant(of: usda, matching: find.text(_checklistNote)),
        findsOneWidget,
      );
      expect(find.text(_checklistNote), findsOneWidget);
      expect(
        find.byKey(const ValueKey('help-checklist-referral-va-hisa')),
        findsNothing,
      );
      await tap(
        tester,
        find.byKey(const ValueKey('help-checklist-referral-usda-section-504')),
      );
      expect(opened, ['usda-section-504']);
    },
  );

  testWidgets('without plan results the cards behave as before', (
    tester,
  ) async {
    await _pump(tester, null);
    await reveal(
      tester,
      find.byKey(const ValueKey('referral-usda-section-504')),
    );
    expect(find.text(_checklistNote), findsNothing);
    expect(find.text('Open checklist'), findsNothing);
  });
}
