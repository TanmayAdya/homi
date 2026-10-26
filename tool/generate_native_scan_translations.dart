import 'dart:convert';
import 'dart:io';

import 'package:safe_at_home/l10n/catalogs/native_scan.dart';

void main(List<String> arguments) {
  final check = arguments.contains('--check');
  final swiftFile = File('ios/Runner/BathroomScanPlatform.swift');
  final kotlinFile = File(
    'android/app/src/main/kotlin/com/example/safe_at_home/AppScanTranslations.kt',
  );
  const marker = '// BEGIN GENERATED APP SCAN TRANSLATIONS';
  final original = swiftFile.readAsStringSync();
  final markerIndex = original.indexOf(marker);
  final swiftPrefix = markerIndex < 0
      ? original.trimRight()
      : original.substring(0, markerIndex).trimRight();
  String quote(String value) => jsonEncode(value);
  final swift = StringBuffer('$swiftPrefix\n\n$marker\n')
    ..writeln(
      '// Source: lib/l10n/catalogs/native_scan.dart. Do not edit this table.',
    )
    ..writeln('enum BathroomScanText {')
    ..writeln(
      '  static func text(_ english: String, language: String) -> String {',
    )
    ..writeln('    messages[english]?[language] ?? english')
    ..writeln('  }')
    ..writeln('  private static let messages: [String: [String: String]] = [');
  final kotlin = StringBuffer('package com.example.safe_at_home\n\n')
    ..writeln(
      '// Generated from lib/l10n/catalogs/native_scan.dart. Do not edit.',
    )
    ..writeln('internal object AppScanTranslations {')
    ..writeln(
      '    fun text(english: String, language: String): String = messages[english]?.get(language) ?: english',
    )
    ..writeln('    private val messages = mapOf(');
  for (final entry in nativeScanTranslations.entries) {
    swift.writeln('    ${quote(entry.key)}: [');
    kotlin.writeln('        ${quote(entry.key)} to mapOf(');
    for (final translation in entry.value.entries) {
      if (translation.value.contains(r'$')) {
        throw StateError(
          'Escape Kotlin interpolation before adding a dollar sign.',
        );
      }
      swift.writeln(
        '      ${quote(translation.key)}: ${quote(translation.value)},',
      );
      kotlin.writeln(
        '            ${quote(translation.key)} to ${quote(translation.value)},',
      );
    }
    swift.writeln('    ],');
    kotlin.writeln('        ),');
  }
  swift
    ..writeln('  ]')
    ..writeln('}')
    ..writeln('// END GENERATED APP SCAN TRANSLATIONS');
  kotlin
    ..writeln('    )')
    ..writeln('}');
  for (final entry in {
    swiftFile: swift.toString(),
    kotlinFile: kotlin.toString(),
  }.entries) {
    if (check) {
      if (!entry.key.existsSync() ||
          entry.key.readAsStringSync() != entry.value) {
        stderr.writeln('Outdated native translations: ${entry.key.path}');
        exitCode = 1;
      }
    } else {
      entry.key.writeAsStringSync(entry.value);
    }
  }
}
