import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/l10n/app_localizations.dart';
import 'package:safe_at_home/shared/presentation/sah_components.dart';

Widget _form({double keyboard = 0}) => MaterialApp(
  supportedLocales: AppLocalizations.supportedLocales,
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  home: Builder(
    builder: (context) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(viewInsets: EdgeInsets.only(bottom: keyboard)),
      child: const SahKeyboardDismissal(
        child: Scaffold(
          body: Column(
            children: [
              TextField(key: ValueKey('a')),
              TextField(key: ValueKey('b')),
              SizedBox(key: ValueKey('outside'), height: 100),
            ],
          ),
        ),
      ),
    ),
  ),
);

bool _focused(WidgetTester tester, String key) => tester
    .widget<EditableText>(
      find.descendant(
        of: find.byKey(ValueKey(key)),
        matching: find.byType(EditableText),
      ),
    )
    .focusNode
    .hasFocus;

void main() {
  testWidgets('touching outside a field closes it; another field keeps it', (
    tester,
  ) async {
    await tester.pumpWidget(_form());
    await tester.tap(find.byKey(const ValueKey('a')));
    await tester.pump();
    expect(_focused(tester, 'a'), true);
    await tester.tap(find.byKey(const ValueKey('b')));
    await tester.pump();
    expect(_focused(tester, 'b'), true);
    await tester.tapAt(tester.getCenter(find.byKey(const ValueKey('outside'))));
    await tester.pump();
    expect(_focused(tester, 'b'), false);
  });

  testWidgets('iPhone shows Done above an open keyboard, Android does not', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    await tester.pumpWidget(_form(keyboard: 300));
    await tester.tap(find.byKey(const ValueKey('a')));
    await tester.pump();
    expect(find.byKey(const ValueKey('keyboard-done')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('keyboard-done')));
    await tester.pump();
    expect(_focused(tester, 'a'), false);
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    await tester.pumpWidget(_form(keyboard: 300));
    expect(find.byKey(const ValueKey('keyboard-done')), findsNothing);
    debugDefaultTargetPlatformOverride = null;
  });
}
