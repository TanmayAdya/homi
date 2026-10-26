import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/app/theme.dart';
import 'package:safe_at_home/l10n/app_localizations.dart';

const programLocales = [
  Locale('es'),
  Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hans'),
  Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant'),
];

String programText(
  Locale locale,
  String english, [
  Map<String, Object?> args = const {},
]) {
  if (locale.languageCode != 'en') {
    final code = locale.scriptCode == null
        ? locale.languageCode
        : '${locale.languageCode}-${locale.scriptCode}';
    expect(
      AppLocalizations.translations[english]?[code],
      isNotNull,
      reason: '$locale must translate app-owned text: $english',
    );
  }
  return AppLocalizations(locale).text(english, args);
}

Widget programTestApp(Locale locale, Widget home) => MaterialApp(
  locale: locale,
  supportedLocales: AppLocalizations.supportedLocales,
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  localeListResolutionCallback: AppLocalizations.resolveLocales,
  theme: SafeAtHomeTheme.light(),
  home: home,
);

void largeProgramViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(320, 812);
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = 3.2;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
    tester.platformDispatcher.clearTextScaleFactorTestValue();
  });
}

Future<void> revealProgramControl(WidgetTester tester, Finder finder) async {
  await tester.pumpAndSettle();
  await tester.scrollUntilVisible(
    finder,
    300,
    scrollable: find.byType(Scrollable).first,
    maxScrolls: 100,
  );
  await Scrollable.ensureVisible(tester.element(finder.first), alignment: .5);
  await tester.pumpAndSettle();
}
