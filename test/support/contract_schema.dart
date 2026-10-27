import 'dart:convert';

bool acceptsContract(
  Object? value,
  dynamic rule,
  Map<String, Map<String, dynamic>> schemas,
  Map<String, dynamic> root,
) {
  if (rule is bool) return rule;
  if (rule is! Map<String, dynamic>) throw StateError('Invalid schema rule');
  const supported = {
    r'$schema',
    r'$id',
    r'$defs',
    r'$ref',
    'title',
    'description',
    'type',
    'additionalProperties',
    'required',
    'properties',
    'items',
    'prefixItems',
    'minItems',
    'maxItems',
    'uniqueItems',
    'minLength',
    'maxLength',
    'minimum',
    'maximum',
    'enum',
    'const',
    'pattern',
    'format',
    'allOf',
    'anyOf',
    'if',
    'then',
    'else',
    'contains',
    'minContains',
    'maxContains',
  };
  if (rule.keys.any((key) => !supported.contains(key))) {
    throw StateError('Unsupported form-answer test schema keyword.');
  }
  bool check(Object? item, dynamic next) =>
      acceptsContract(item, next, schemas, root);
  if (rule.containsKey(r'$ref')) {
    final parts = (rule[r'$ref'] as String).split('#');
    final document = parts.first.isEmpty ? root : schemas[parts.first];
    if (document == null || parts.length != 2) {
      throw StateError('Unknown schema ref');
    }
    dynamic target = document;
    for (final part in parts[1].split('/').skip(1)) {
      target = target[part];
    }
    return acceptsContract(
      value,
      target as Map<String, dynamic>,
      schemas,
      document,
    );
  }
  if (rule.containsKey('const') && value != rule['const']) return false;
  if (rule.containsKey('enum') && !(rule['enum'] as List).contains(value)) {
    return false;
  }
  if (rule.containsKey('allOf') &&
      !(rule['allOf'] as List).every((next) => check(value, next))) {
    return false;
  }
  if (rule.containsKey('anyOf') &&
      !(rule['anyOf'] as List).any((next) => check(value, next))) {
    return false;
  }
  if (rule.containsKey('if')) {
    final selected = check(value, rule['if']) ? rule['then'] : rule['else'];
    if (selected != null && !check(value, selected)) return false;
  }
  if (rule.containsKey('type')) {
    final types = rule['type'] is List ? rule['type'] as List : [rule['type']];
    if (!types.any(
      (type) => switch (type) {
        'null' => value == null,
        'object' => value is Map,
        'array' => value is List,
        'string' => value is String,
        'boolean' => value is bool,
        'number' => value is num && value.isFinite,
        'integer' =>
          value is num && value.isFinite && value == value.truncateToDouble(),
        _ => throw StateError('Unsupported schema type'),
      },
    )) {
      return false;
    }
  }
  if (value is Map) {
    final required = rule['required'] as List? ?? [];
    if (!required.every(value.containsKey)) return false;
    final properties = rule['properties'] as Map? ?? {};
    if (rule['additionalProperties'] == false &&
        value.keys.any((key) => !properties.containsKey(key))) {
      return false;
    }
    for (final key in properties.keys) {
      if (value.containsKey(key) && !check(value[key], properties[key])) {
        return false;
      }
    }
  }
  if (value is List) {
    if (rule['uniqueItems'] == true &&
        value.map(jsonEncode).toSet().length != value.length) {
      return false;
    }
    if (rule['minItems'] != null && value.length < (rule['minItems'] as int)) {
      return false;
    }
    if (rule['maxItems'] != null && value.length > (rule['maxItems'] as int)) {
      return false;
    }
    final prefix = rule['prefixItems'] as List? ?? [];
    for (var i = 0; i < prefix.length && i < value.length; i++) {
      if (!check(value[i], prefix[i])) return false;
    }
    if (rule['items'] != null &&
        !value
            .skip(prefix.length)
            .every((item) => check(item, rule['items']))) {
      return false;
    }
    if (rule['contains'] != null) {
      final count = value.where((item) => check(item, rule['contains'])).length;
      if (count < (rule['minContains'] as int? ?? 1) ||
          (rule['maxContains'] != null &&
              count > (rule['maxContains'] as int))) {
        return false;
      }
    }
  }
  if (value is num) {
    if (rule['minimum'] != null && value < (rule['minimum'] as num)) {
      return false;
    }
    if (rule['maximum'] != null && value > (rule['maximum'] as num)) {
      return false;
    }
  }
  if (value is String) {
    if (rule['minLength'] != null &&
        value.runes.length < (rule['minLength'] as int)) {
      return false;
    }
    if (rule['maxLength'] != null &&
        value.runes.length > (rule['maxLength'] as int)) {
      return false;
    }
    if (rule['pattern'] != null &&
        !RegExp(rule['pattern'] as String, unicode: true).hasMatch(value)) {
      return false;
    }
    if (rule['format'] != null) {
      final parsed = DateTime.tryParse(value);
      if (parsed == null ||
          value.length < 10 ||
          parsed.year < 1 ||
          parsed.year != int.tryParse(value.substring(0, 4)) ||
          parsed.month != int.tryParse(value.substring(5, 7)) ||
          parsed.day != int.tryParse(value.substring(8, 10))) {
        return false;
      }
      if (rule['format'] == 'date-time' &&
          (value.length < 20 ||
              parsed.hour != int.tryParse(value.substring(11, 13)) ||
              parsed.minute != int.tryParse(value.substring(14, 16)) ||
              parsed.second != int.tryParse(value.substring(17, 19)))) {
        return false;
      }
    }
  }
  return true;
}
