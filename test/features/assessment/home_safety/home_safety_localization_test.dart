import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/features/assessment/domain/home_safety/home_safety.dart';
import 'package:safe_at_home/l10n/app_localizations.dart';
import 'package:safe_at_home/l10n/catalogs/home_safety.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'every checklist prompt, guidance and new copy entry covers all supported translations',
    () async {
      final catalog = await HomeSafetyCatalog.load();
      for (final text in [
        ...homeSafetyTranslations.keys,
        ...catalog.questions.expand((q) => [q.prompt, q.guidance]),
      ]) {
        final placeholders = RegExp(
          r'\{\w+\}',
        ).allMatches(text).map((m) => m[0]).toSet();
        for (final language in ['es', 'zh-Hans', 'zh-Hant', 'vi', 'fil']) {
          final translated = AppLocalizations.translations[text]?[language];
          expect(translated, isNotNull, reason: '$language: $text');
          expect(translated, isNotEmpty);
          expect(
            RegExp(r'\{\w+\}').allMatches(translated!).map((m) => m[0]).toSet(),
            placeholders,
            reason: '$language: $text',
          );
        }
      }
    },
  );
}
