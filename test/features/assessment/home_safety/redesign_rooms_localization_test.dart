import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/l10n/app_localizations.dart';
import 'package:safe_at_home/l10n/catalogs/redesign_rooms.dart';

void main() {
  test('redesigned Rooms copy covers every app language and placeholder', () {
    final placeholder = RegExp(r'\{\w+\}');
    for (final entry in redesignRoomsTranslations.entries) {
      final expected = placeholder
          .allMatches(entry.key)
          .map((m) => m[0])
          .toSet();
      expect(entry.value.keys.toSet(), {
        'es',
        'zh-Hans',
        'zh-Hant',
        'vi',
        'fil',
      });
      for (final language in entry.value.keys) {
        final text = AppLocalizations.translations[entry.key]![language]!;
        expect(text, isNotEmpty, reason: '$language: ${entry.key}');
        expect(
          placeholder.allMatches(text).map((m) => m[0]).toSet(),
          expected,
          reason: '$language: ${entry.key}',
        );
      }
    }
  });
}
