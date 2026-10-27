import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/app/appearance.dart';
import 'package:safe_at_home/app/theme.dart';
import 'package:safe_at_home/features/settings/account_settings_screen.dart';
import 'package:safe_at_home/features/settings/appearance_section.dart';
import 'package:safe_at_home/features/settings/language_section.dart';
import 'package:safe_at_home/l10n/app_language.dart';
import 'package:safe_at_home/l10n/app_localizations.dart';

import 'case_coordinator_test.dart' show FakeTransport;
import 'live_workflows_test.dart' show MemoryPrivateStore, services;

class _MemoryAppearance extends AppAppearance {
  @override
  Future<void> choose(ThemeMode mode) async => value = mode;
}

class _MemoryLanguage extends AppLanguageController {
  @override
  Future<void> choose(AppLanguage language) async => value = language;
}

Future<void> _select(WidgetTester tester, String key, String label) async {
  final field = find.byKey(ValueKey(key));
  await tester.ensureVisible(field);
  await tester.pumpAndSettle();
  await tester.tap(field);
  await tester.pumpAndSettle();
  if (find.text(label).evaluate().isEmpty) {
    await tester.scrollUntilVisible(
      find.text(label),
      160,
      scrollable: find.byType(Scrollable).last,
    );
  }
  final choice = find.text(label).last;
  await tester.ensureVisible(choice);
  await tester.pumpAndSettle();
  await tester.tap(choice);
  await tester.pumpAndSettle();
}

void main() {
  for (final locale in AppLocalizations.supportedLocales) {
    for (final dark in [false, true]) {
      testWidgets('dropdowns wrap at 320px and 3.2x in $locale, dark=$dark', (
        tester,
      ) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(320, 640);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final appearance = _MemoryAppearance();
        final language = _MemoryLanguage();
        addTearDown(appearance.dispose);
        addTearDown(language.dispose);
        await tester.pumpWidget(
          MaterialApp(
            locale: locale,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            theme: dark ? SafeAtHomeTheme.dark() : SafeAtHomeTheme.light(),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                textScaler: TextScaler.linear(3.2),
                disableAnimations: true,
              ),
              child: child!,
            ),
            home: Scaffold(
              body: SingleChildScrollView(
                padding: const EdgeInsets.all(20),
                child: Column(
                  children: [
                    AppearanceSection(appearance: appearance),
                    const SizedBox(height: 20),
                    LanguageSection(controller: language),
                  ],
                ),
              ),
            ),
          ),
        );
        final l10n = AppLocalizations(locale);
        await _select(tester, 'appearance-selection', l10n.text('Dark'));
        expect(appearance.value, ThemeMode.dark);
        await _select(
          tester,
          'appearance-selection',
          l10n.text('Match phone setting'),
        );
        expect(appearance.value, ThemeMode.system);
        await _select(tester, 'language-selection', 'Filipino (Tagalog)');
        expect(language.value, AppLanguage.filipino);
        await _select(
          tester,
          'language-selection',
          l10n.text('Use phone language'),
        );
        expect(language.value, AppLanguage.system);
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('closing a dropdown returns keyboard focus to its field', (
    tester,
  ) async {
    final appearance = _MemoryAppearance();
    addTearDown(appearance.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: SafeAtHomeTheme.light(),
        home: Scaffold(body: AppearanceSection(appearance: appearance)),
      ),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    final fieldFocus = FocusManager.instance.primaryFocus;
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.text('Dark').hitTestable(), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus, same(fieldFocus));
    expect(appearance.value, ThemeMode.system);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'embedded account hub keeps one scaffold and separates routine settings',
    (tester) async {
      final transport = FakeTransport(
        (_) async => throw StateError('No request'),
      );
      final app = services(MemoryPrivateStore(), transport);
      addTearDown(() {
        app.dispose();
        app.session.dispose();
      });
      await tester.pumpWidget(
        MaterialApp(
          theme: SafeAtHomeTheme.light(),
          home: Scaffold(
            body: AccountSettingsScreen(services: app, embedded: true),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(Scaffold), findsOneWidget);
      expect(find.byType(AppBar), findsNothing);
      for (final key in [
        'account-display',
        'account-privacy',
        'account-technical',
      ]) {
        expect(find.byKey(ValueKey(key)), findsOneWidget);
      }
      expect(find.byKey(const ValueKey('appearance-selection')), findsNothing);
      expect(
        find.byKey(const ValueKey('settings-delete-account')),
        findsNothing,
      );
      expect(find.text('Feature availability'), findsNothing);
      expect(transport.requests, isEmpty);
      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
      expect(tester.takeException(), isNull);
    },
  );
}
