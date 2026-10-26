import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

class AppAppearance extends ValueNotifier<ThemeMode> {
  AppAppearance({Future<File> Function()? file})
    : _file = file ?? _defaultFile,
      super(ThemeMode.system);

  static final instance = AppAppearance();

  final Future<File> Function() _file;
  Future<void> _writes = Future.value();
  int _generation = 0;
  bool _saveFailed = false;
  bool get saveFailed => _saveFailed;

  static Future<File> _defaultFile() async =>
      File('${(await getApplicationSupportDirectory()).path}/appearance');

  Future<void> load() async {
    final generation = _generation;
    try {
      final file = await _file();
      if (!await file.exists()) return;
      final name = (await file.readAsString()).trim();
      if (generation == _generation) {
        value = ThemeMode.values.firstWhere(
          (mode) => mode.name == name,
          orElse: () => ThemeMode.system,
        );
      }
    } catch (_) {
      // ignore: empty_catches
    }
  }

  Future<void> choose(ThemeMode mode) {
    final generation = ++_generation;
    value = mode;
    _saveFailed = false;
    notifyListeners();
    final next = _writes.then((_) async {
      try {
        final file = await _file();
        await file.parent.create(recursive: true);
        final temporary = File('${file.path}.next');
        await temporary.writeAsString(mode.name, flush: true);
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
