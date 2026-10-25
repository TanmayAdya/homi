import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

enum AppLanguage {
  system('system', 'Use phone language', null),
  english('en', 'English', Locale('en')),
  spanish('es', 'Español', Locale('es')),
  chineseSimplified(
    'zh-Hans',
    '简体中文',
    Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hans'),
  ),
  chineseTraditional(
    'zh-Hant',
    '繁體中文',
    Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant'),
  ),
  vietnamese('vi', 'Tiếng Việt', Locale('vi')),
  filipino('fil', 'Filipino (Tagalog)', Locale('fil'));

  const AppLanguage(this.code, this.nativeName, this.locale);
  final String code, nativeName;
  final Locale? locale;

  static AppLanguage fromCode(String? code) => values.firstWhere(
    (language) => language.code == code,
    orElse: () => system,
  );

  static AppLanguage forLocale(Locale locale) {
    if (locale.languageCode == 'zh') {
      final traditional =
          locale.scriptCode == 'Hant' ||
          (locale.scriptCode == null &&
              const ['TW', 'HK', 'MO'].contains(locale.countryCode));
      return traditional ? chineseTraditional : chineseSimplified;
    }
    if (locale.languageCode == 'tl') return filipino;
    return values.firstWhere(
      (language) => language.code == locale.languageCode,
      orElse: () => english,
    );
  }

  static AppLanguage forPreferredLocales(List<Locale> preferred) {
    for (final locale in preferred) {
      if (const [
        'en',
        'es',
        'zh',
        'vi',
        'fil',
        'tl',
      ].contains(locale.languageCode)) {
        return forLocale(locale);
      }
    }
    return english;
  }
}

class AppLanguageController extends ValueNotifier<AppLanguage> {
  AppLanguageController({Future<File> Function()? file})
    : _file = file ?? _defaultFile,
      super(AppLanguage.system);

  static final instance = AppLanguageController();
  final Future<File> Function() _file;
  Future<void> _writes = Future.value();
  int _generation = 0;
  bool _saveFailed = false;
  bool get saveFailed => _saveFailed;
  AppLanguage get effectiveLanguage => value == AppLanguage.system
      ? AppLanguage.forPreferredLocales(
          WidgetsBinding.instance.platformDispatcher.locales,
        )
      : value;

  static Future<File> _defaultFile() async =>
      File('${(await getApplicationSupportDirectory()).path}/app-language');

  Future<void> load() async {
    final generation = _generation;
    try {
      final file = await _file();
      if (!await file.exists()) return;
      if (await file.length() > 32) return;
      final saved = await file.readAsString();
      if (generation == _generation) value = AppLanguage.fromCode(saved.trim());
    } catch (_) {
      // ignore: empty_catches
    }
  }

  Future<void> choose(AppLanguage language) {
    final generation = ++_generation;
    value = language;
    _saveFailed = false;
    notifyListeners();
    final next = _writes.then((_) async {
      try {
        final file = await _file();
        await file.parent.create(recursive: true);
        final temporary = File('${file.path}.next');
        await temporary.writeAsString(language.code, flush: true);
        await temporary.rename(file.path);
      } catch (_) {
        if (generation == _generation) {
          _saveFailed = true;
          notifyListeners();
        }
      }
    });
    _writes = next;
    return next;
  }
}
