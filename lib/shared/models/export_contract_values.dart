abstract final class ExportContractValues {
  static const maxInteger = 9007199254740991;

  static Map<String, Object?> object(Object? value, Set<String> keys) {
    if (value is! Map ||
        value.length != keys.length ||
        value.keys.any((key) => key is! String || !keys.contains(key))) {
      invalid();
    }
    return Map<String, Object?>.from(value);
  }

  static String id(Object? value) {
    if (value is! String ||
        value.isEmpty ||
        value.trim() != value ||
        value.runes.length > 200 ||
        RegExp(r'[\x00-\x1f\x7f-\x9f\u2028\u2029]').hasMatch(value) ||
        value.runes.any((rune) => rune >= 0xd800 && rune <= 0xdfff)) {
      invalid();
    }
    return value;
  }

  static int integer(Object? value, {int min = 1, int max = maxInteger}) {
    if (value is! num ||
        !value.isFinite ||
        value < min ||
        value > max ||
        value != value.truncateToDouble()) {
      invalid();
    }
    return value.toInt();
  }

  static String digest(Object? value) {
    if (value is! String ||
        value.length != 64 ||
        RegExp(r'[^a-f0-9]').hasMatch(value)) {
      invalid();
    }
    return value;
  }

  static String instant(Object? value) {
    if (value is! String ||
        RegExp(
              r'^(?!0000)[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]{1,6})?Z$',
            ).stringMatch(value) !=
            value) {
      invalid();
    }
    final parsed = DateTime.tryParse(value);
    if (parsed == null ||
        parsed.year != int.parse(value.substring(0, 4)) ||
        parsed.month != int.parse(value.substring(5, 7)) ||
        parsed.day != int.parse(value.substring(8, 10)) ||
        parsed.hour != int.parse(value.substring(11, 13)) ||
        parsed.minute != int.parse(value.substring(14, 16)) ||
        parsed.second != int.parse(value.substring(17, 19))) {
      invalid();
    }
    return value;
  }

  static List<T> list<T>(Object? value, T Function(Object?) parse, int max) {
    if (value is! List || value.length > max) invalid();
    return List.unmodifiable(value.map(parse));
  }

  static void unique(Iterable<String> values) {
    final seen = <String>{};
    if (values.any((value) => !seen.add(value))) invalid();
  }

  static Never invalid() =>
      throw const FormatException('Invalid private artifact contract.');
}
