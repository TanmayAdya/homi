import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/features/settings/language_section.dart';
import 'package:safe_at_home/l10n/app_language.dart';
import 'package:safe_at_home/l10n/app_localizations.dart';

class _MemoryLanguageController extends AppLanguageController {
  @override
  Future<void> choose(AppLanguage language) async => value = language;
}

Future<void> selectLanguage(WidgetTester tester, String label) async {
  final field = find.byKey(const ValueKey('language-selection'));
  await tester.ensureVisible(field);
  await tester.tap(field);
  await tester.pumpAndSettle();
  final option = find.text(label).last;
  await tester.ensureVisible(option);
  await tester.pumpAndSettle();
  await tester.tap(option);
  await tester.pumpAndSettle();
}

void main() {
  late Directory directory;
  late AppLanguageController controller;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('sah-language-');
    controller = AppLanguageController(
      file: () async => File('${directory.path}/language'),
    );
  });
  tearDown(() async {
    controller.dispose();
    await directory.delete(recursive: true);
  });

  test(
    'language persists across a fresh controller without account storage',
    () async {
      await controller.choose(AppLanguage.chineseTraditional);
      final restored = AppLanguageController(
        file: () async => File('${directory.path}/language'),
      );
      addTearDown(restored.dispose);
      await restored.load();
      expect(restored.value, AppLanguage.chineseTraditional);
      expect(
        await File('${directory.path}/language').readAsString(),
        'zh-Hant',
      );
      expect(await File('${directory.path}/language.next').exists(), false);
    },
  );

  test(
    'rapid choices serialize disk writes and retain the last language',
    () async {
      await Future.wait([
        controller.choose(AppLanguage.spanish),
        controller.choose(AppLanguage.vietnamese),
        controller.choose(AppLanguage.filipino),
      ]);
      expect(controller.value, AppLanguage.filipino);
      expect(await File('${directory.path}/language').readAsString(), 'fil');
    },
  );

  test('delayed startup cannot overwrite a newer explicit choice', () async {
    final file = File('${directory.path}/language');
    await file.writeAsString('vi');
    final gate = Completer<File>();
    var reads = 0;
    final delayed = AppLanguageController(
      file: () => reads++ == 0 ? gate.future : Future.value(file),
    );
    addTearDown(delayed.dispose);
    final loading = delayed.load();
    await delayed.choose(AppLanguage.spanish);
    gate.complete(file);
    await loading;
    expect(delayed.value, AppLanguage.spanish);
  });

  test(
    'bad preferences fall back and failed writes stay visibly temporary',
    () async {
      await File(
        '${directory.path}/language',
      ).writeAsString('not-a-supported-locale');
      await controller.load();
      expect(controller.value, AppLanguage.system);
      final broken = AppLanguageController(
        file: () async => throw const FileSystemException('Fictional'),
      );
      addTearDown(broken.dispose);
      await broken.choose(AppLanguage.vietnamese);
      expect(broken.value, AppLanguage.vietnamese);
      expect(broken.saveFailed, true);
    },
  );

  test(
    'phone resolution respects Chinese scripts, region and preference order',
    () {
      Locale resolve(List<Locale> locales) => AppLocalizations.resolveLocales(
        locales,
        AppLocalizations.supportedLocales,
      );
      expect(resolve([const Locale('zh', 'HK')]).scriptCode, 'Hant');
      expect(resolve([const Locale('zh', 'TW')]).scriptCode, 'Hant');
      expect(
        resolve([
          const Locale.fromSubtags(
            languageCode: 'zh',
            scriptCode: 'Hans',
            countryCode: 'HK',
          ),
        ]).scriptCode,
        'Hans',
      );
      expect(resolve([const Locale('zh')]).scriptCode, 'Hans');
      expect(resolve([const Locale('tl')]).languageCode, 'fil');
      expect(
        resolve([const Locale('fr'), const Locale('es')]).languageCode,
        'es',
      );
      expect(resolve([const Locale('fr')]).languageCode, 'en');
    },
  );

  test(
    'all shipped catalog messages have every locale and preserve placeholders',
    () {
      final codes = AppLanguage.values
          .where((v) => v.locale != null && v != AppLanguage.english)
          .map((v) => v.code)
          .toSet();
      Set<String> placeholders(String text) => RegExp(
        r'\{([A-Za-z][A-Za-z0-9_]*)\}',
      ).allMatches(text).map((m) => m[1]!).toSet();
      for (final catalog in AppLocalizations.catalogs) {
        for (final entry in catalog.entries) {
          expect(entry.value.keys.toSet(), codes, reason: entry.key);
          for (final translation in entry.value.entries) {
            expect(
              translation.value.trim(),
              isNotEmpty,
              reason: '${translation.key}: ${entry.key}',
            );
            expect(
              placeholders(translation.value),
              placeholders(entry.key),
              reason: '${translation.key}: ${entry.key}',
            );
          }
        }
      }
    },
  );

  test(
    'formatting preserves resident text, even text that looks like a key',
    () {
      const l10n = AppLocalizations(Locale('es'));
      expect(
        l10n.text('{city} home plan', {'city': 'Home {reference}'}),
        'Plan del hogar en Home {reference}',
      );
      expect(
        l10n.text('Unknown original source wording'),
        'Unknown original source wording',
      );
    },
  );

  testWidgets(
    'language changes keep an open form and preserve its entered text',
    (tester) async {
      final controller = _MemoryLanguageController();
      addTearDown(controller.dispose);
      final text = TextEditingController(text: 'Home {city}');
      addTearDown(text.dispose);
      await tester.pumpWidget(
        ListenableBuilder(
          listenable: controller,
          builder: (context, _) => MaterialApp(
            locale: controller.value.locale,
            supportedLocales: AppLocalizations.supportedLocales,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            localeListResolutionCallback: AppLocalizations.resolveLocales,
            home: Builder(
              builder: (context) => Scaffold(
                body: ListView(
                  children: [
                    TextField(
                      key: const ValueKey('retained-name'),
                      controller: text,
                    ),
                    LanguageSection(controller: controller),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.enterText(
        find.byKey(const ValueKey('retained-name')),
        'Grandma’s Home',
      );
      await selectLanguage(tester, 'Español');
      expect(find.text('Idioma'), findsOneWidget);
      expect(text.text, 'Grandma’s Home');
      expect(controller.value, AppLanguage.spanish);
      await controller.choose(AppLanguage.system);
      await tester.pumpAndSettle();
      expect(text.text, 'Grandma’s Home');
    },
  );

  testWidgets('all language choices remain reachable at large text', (
    tester,
  ) async {
    final controller = _MemoryLanguageController();
    addTearDown(controller.dispose);
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('es'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(3.2)),
          child: Scaffold(
            body: SingleChildScrollView(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: LanguageSection(controller: controller),
              ),
            ),
          ),
        ),
      ),
    );
    await selectLanguage(tester, 'Filipino (Tagalog)');
    expect(controller.value, AppLanguage.filipino);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'the open language sheet updates and closes without replacing its route',
    (tester) async {
      final controller = _MemoryLanguageController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        ListenableBuilder(
          listenable: controller,
          builder: (context, _) => MaterialApp(
            locale: controller.value.locale,
            supportedLocales: AppLocalizations.supportedLocales,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            localeListResolutionCallback: AppLocalizations.resolveLocales,
            home: Scaffold(
              appBar: AppBar(actions: [LanguageButton(controller: controller)]),
              body: const Text('Resident text stays here'),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('choose-language')));
      await tester.pumpAndSettle();
      await selectLanguage(tester, 'Español');
      expect(find.text('Idioma'), findsOneWidget);
      final done = AppLocalizations(const Locale('es')).text('Done');
      await tester.tap(find.text(done));
      await tester.pumpAndSettle();
      expect(find.byType(LanguageSection), findsNothing);
      expect(find.text('Resident text stays here'), findsOneWidget);
      expect(controller.value, AppLanguage.spanish);
      expect(tester.takeException(), isNull);
    },
  );
}
