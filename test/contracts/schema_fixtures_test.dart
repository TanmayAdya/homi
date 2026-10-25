import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final caseSchema = readSchema('case');
  final matchSchema = readSchema('match');
  final packetSchema = readSchema('packet');

  test('every shared case and match fixture satisfies its JSON schema', () {
    final scenarios =
        jsonDecode(
              File('contracts/v1/fixtures/scenarios.json').readAsStringSync(),
            )
            as List;
    for (final scenario in scenarios) {
      validate(scenario['case'], caseSchema);
      validate(scenario['match'], matchSchema);
    }
  });

  test('every shared draft fixture satisfies its JSON schema', () {
    final packets =
        jsonDecode(
              File('contracts/v1/fixtures/packets.json').readAsStringSync(),
            )
            as List;
    for (final entry in packets) {
      validate(entry['packet'], packetSchema);
      expect(entry['packet']['status'], 'draft');
      expect(entry['packet']['formVersion'], isNull);
      expect(entry['packet']['storageReference'], isNull);
      expect(entry['packet']['attachments'], isEmpty);
    }
  });

  test('schemas reject missing fields, unexpected fields and type drift', () {
    final scenarios =
        jsonDecode(
              File('contracts/v1/fixtures/scenarios.json').readAsStringSync(),
            )
            as List;
    final input = scenarios.first['case'] as Map<String, dynamic>;
    input['profile']['annualIncomeUsd'] = '0';
    expect(() => validate(input, caseSchema), throwsStateError);
    input['profile']['annualIncomeUsd'] = 0;
    input['profile']['isEligible'] = true;
    expect(() => validate(input, caseSchema), throwsStateError);
    input['profile'].remove('isEligible');
    input['profile'].remove('ownerConsentReported');
    expect(() => validate(input, caseSchema), throwsStateError);
  });

  test('packet shape remains a draft and supports unresolved form details', () {
    final packet = <String, dynamic>{
      'schemaVersion': '1',
      'packetId': 'fictional-packet',
      'caseId': 'fictional-case',
      'caseRevision': 1,
      'programId': 'demo-home-support',
      'ruleVersion': 'demo-v1',
      'formVersion': null,
      'mappingVersion': null,
      'status': 'draft',
      'isDemo': true,
      'generatedAt': '2026-10-13T19:00:00Z',
      'recheckAfter': null,
      'storageReference': null,
      'attachments': [],
      'missingItems': [
        {
          'id': 'official-form',
          'description': 'Verify the current official form.',
          'resolvedBy': 'program',
        },
      ],
    };
    validate(packet, packetSchema);
    packet['status'] = 'submitted';
    expect(() => validate(packet, packetSchema), throwsStateError);
    packet['status'] = 'draft';
    packet['generatedAt'] = '2026-02-30T19:00:00Z';
    expect(() => validate(packet, packetSchema), throwsStateError);
  });
}

Map<String, dynamic> readSchema(String name) =>
    jsonDecode(File('contracts/v1/$name.schema.json').readAsStringSync())
        as Map<String, dynamic>;

void validate(
  Object? value,
  Map<String, dynamic> root, {
  Map<String, dynamic>? schema,
  String path = r'$',
}) {
  final s = schema ?? root;
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
    'uniqueItems',
    'minItems',
    'minLength',
    'maxLength',
    'minimum',
    'maximum',
    'enum',
    'const',
    'pattern',
    'format',
  };
  if (s.keys.any((key) => !supported.contains(key))) {
    throw StateError(
      'Extend the test validator for new schema keywords at $path',
    );
  }
  void require(bool condition, String message) {
    if (!condition) throw StateError('$path: $message');
  }

  if (s.containsKey(r'$ref')) {
    final ref = s[r'$ref'] as String;
    require(
      ref.startsWith('#/'),
      'test validator supports local references only',
    );
    dynamic target = root;
    for (final segment in ref.substring(2).split('/')) {
      target = target[segment];
    }
    validate(value, root, schema: target as Map<String, dynamic>, path: path);
    return;
  }
  if (s.containsKey('const')) require(value == s['const'], 'constant mismatch');
  if (s.containsKey('enum')) {
    require((s['enum'] as List).contains(value), 'enum mismatch');
  }
  if (s.containsKey('type')) {
    final types = s['type'] is List ? s['type'] as List : [s['type']];
    require(
      types.any(
        (type) => switch (type) {
          'null' => value == null,
          'object' => value is Map<String, dynamic>,
          'array' => value is List,
          'string' => value is String,
          'boolean' => value is bool,
          'integer' =>
            value is num && value.isFinite && value == value.truncateToDouble(),
          'number' => value is num && value.isFinite,
          _ => throw StateError('Unsupported type $type'),
        },
      ),
      'type mismatch',
    );
  }
  if (value is Map<String, dynamic>) {
    final properties = (s['properties'] as Map<String, dynamic>?) ?? {};
    for (final key in (s['required'] as List?) ?? []) {
      require(value.containsKey(key), 'missing $key');
    }
    if (s['additionalProperties'] == false) {
      require(value.keys.every(properties.containsKey), 'unexpected property');
    }
    for (final key in value.keys.where(properties.containsKey)) {
      validate(
        value[key],
        root,
        schema: properties[key] as Map<String, dynamic>,
        path: '$path.$key',
      );
    }
  }
  if (value is List) {
    if (s.containsKey('minItems')) {
      require(value.length >= (s['minItems'] as int), 'too few items');
    }
    if (s['uniqueItems'] == true) {
      require(
        value.map(jsonEncode).toSet().length == value.length,
        'duplicate items',
      );
    }
    if (s.containsKey('items')) {
      for (var i = 0; i < value.length; i++) {
        validate(
          value[i],
          root,
          schema: s['items'] as Map<String, dynamic>,
          path: '$path[$i]',
        );
      }
    }
  }
  if (value is num && s.containsKey('minimum')) {
    require(value >= (s['minimum'] as num), 'below minimum');
  }
  if (value is num && s.containsKey('maximum')) {
    require(value <= (s['maximum'] as num), 'above maximum');
  }
  if (value is String) {
    if (s.containsKey('minLength')) {
      require(value.runes.length >= (s['minLength'] as int), 'too short');
    }
    if (s.containsKey('maxLength')) {
      require(value.runes.length <= (s['maxLength'] as int), 'too long');
    }
    if (s.containsKey('pattern')) {
      require(
        RegExp(s['pattern'] as String).hasMatch(value),
        'pattern mismatch',
      );
    }
    if (s['format'] == 'date' || s['format'] == 'date-time') {
      final parsed = DateTime.tryParse(value);
      require(parsed != null, 'invalid date');
      require(
        parsed!.toIso8601String().substring(0, 10) == value.substring(0, 10),
        'invalid calendar date',
      );
      if (s['format'] == 'date-time') {
        require(
          parsed.toIso8601String().substring(11, 19) == value.substring(11, 19),
          'invalid time',
        );
      }
    }
    if (s['format'] == 'uri') {
      final uri = Uri.tryParse(value);
      require(
        uri != null && uri.hasScheme && uri.host.isNotEmpty,
        'invalid absolute URI',
      );
    }
  }
}
