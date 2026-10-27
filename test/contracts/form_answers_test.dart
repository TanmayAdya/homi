import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/shared/models/contracts.dart';
import 'package:safe_at_home/shared/models/form_answers.dart';

const digest =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const stamp = '2026-10-17T19:00:00.123456Z';

Map<String, Object?> contextJson() => {
  'programId': 'scfhp-eaa',
  'formVersion': 'fictional-form-version',
  'mappingVersion': 'fictional-mapping-version',
  'formContextId': digest,
};

Map<String, Object?> answerJson({
  String key = 'memberFirstName',
  Object? value = 'Fictional',
  String reviewState = 'reviewed',
}) => {'key': key, 'value': value, 'reviewState': reviewState};

Map<String, Object?> savedAnswerJson({
  String key = 'memberFirstName',
  Object? value = 'Fictional',
  String reviewState = 'reviewed',
}) => {
  ...answerJson(key: key, value: value, reviewState: reviewState),
  'reviewedAt': reviewState == 'reviewed' ? stamp : null,
  'reviewedBy': reviewState == 'reviewed' ? 'fictional-user' : null,
};

Map<String, Object?> savedJson() => {
  'schemaVersion': '1',
  'caseId': 'fictional-case',
  'caseRevision': 2,
  ...contextJson(),
  'answerRevision': 1,
  'updatedAt': stamp,
  'updatedBy': 'fictional-user',
  'answers': [savedAnswerJson()],
};

Map<String, Object?> responseJson() => {
  'schemaVersion': '1',
  'caseId': 'fictional-case',
  'caseRevision': 2,
  'context': contextJson(),
  'saved': savedJson(),
  'isCurrent': true,
};

Map<String, Object?> readJson() => {
  'schemaVersion': '1',
  'caseId': 'fictional-case',
  'expectedCaseRevision': 2,
  'programId': 'scfhp-eaa',
};

Map<String, Object?> saveJson() => {
  ...readJson(),
  'expectedFormContextId': digest,
  'expectedAnswerRevision': 0,
  'answers': [answerJson()],
};

CaseSnapshot snapshot({String caseId = 'fictional-case', int revision = 2}) =>
    CaseSnapshot.fromJson({
      'schemaVersion': '1',
      'caseId': caseId,
      'revision': revision,
      'profile': {
        'city': null,
        'county': null,
        'healthPlan': null,
        'tenure': null,
        'ageYears': null,
        'householdSize': null,
        'annualIncomeUsd': null,
        'ownerConsentReported': null,
      },
      'unresolvedFields': <String>[],
      'findings': <Object>[],
    });

void main() {
  final schemas = <String, Map<String, dynamic>>{
    for (final name in [
      'form-answers',
      'form-answers-read-request',
      'form-answers-save-request',
    ])
      '$name.schema.json':
          jsonDecode(File('contracts/v1/$name.schema.json').readAsStringSync())
              as Map<String, dynamic>,
  };
  bool accepts(Object? json, String name) => _accepts(
    json,
    schemas['$name.schema.json']!,
    schemas,
    schemas['$name.schema.json']!,
  );
  bool acceptsInput(Object? answer) =>
      accepts(saveJson()..['answers'] = [answer], 'form-answers-save-request');

  test('fictional responses and requests satisfy schemas and round-trip', () {
    expect(accepts(responseJson(), 'form-answers'), isTrue);
    expect(accepts(readJson(), 'form-answers-read-request'), isTrue);
    expect(accepts(saveJson(), 'form-answers-save-request'), isTrue);
    expect(
      FormAnswersResponse.fromJson(responseJson()).toJson(),
      responseJson(),
    );
    expect(FormAnswersReadRequest.fromJson(readJson()).toJson(), readJson());
    expect(FormAnswersSaveRequest.fromJson(saveJson()).toJson(), saveJson());
    expect(SavedFormAnswerSet.fromJson(savedJson()).toJson(), savedJson());
  });

  test(
    'all eighteen keys preserve independent member and referrer answers',
    () {
      expect(formAnswerValueLimits, hasLength(18));
      for (final key in formAnswerValueLimits.keys) {
        final value = key.endsWith('Email')
            ? 'fictional@example.org'
            : key.endsWith('Date')
            ? '2000-02-29'
            : 'Fictional $key';
        final answer = answerJson(key: key, value: value);
        expect(FormAnswerInput.fromJson(answer).value, value);
        expect(acceptsInput(answer), isTrue, reason: key);
      }
    },
  );

  test('unknown answers and empty replacement remain explicit', () {
    final unknown = answerJson(value: null, reviewState: 'needs_review');
    expect(FormAnswerInput.fromJson(unknown).value, isNull);
    expect(acceptsInput(unknown), isTrue);
    final request = saveJson()..['answers'] = <Object>[];
    expect(FormAnswersSaveRequest.fromJson(request).answers, isEmpty);
    expect(accepts(request, 'form-answers-save-request'), isTrue);
    final empty = responseJson()
      ..['saved'] = null
      ..['isCurrent'] = false;
    expect(FormAnswersResponse.fromJson(empty).saved, isNull);
    expect(accepts(empty, 'form-answers'), isTrue);
    expect(
      () => FormAnswersResponse.fromJson(empty..['isCurrent'] = true),
      throwsFormatException,
    );
    expect(accepts(empty, 'form-answers'), isFalse);
  });

  test('clinical consent signature and raw PDF keys are rejected', () {
    for (final key in [
      'diagnosis',
      'consent',
      'signature',
      'signatureDate',
      'ecmEnrolled',
      'comments',
      'First Name',
      'Signature4',
      'ha',
    ]) {
      final answer = answerJson(key: key);
      expect(() => FormAnswerInput.fromJson(answer), throwsFormatException);
      expect(acceptsInput(answer), isFalse);
    }
  });

  test('strict objects reject extra missing and client-owned provenance', () {
    for (final key in ['key', 'value', 'reviewState']) {
      final answer = answerJson()..remove(key);
      expect(() => FormAnswerInput.fromJson(answer), throwsFormatException);
      expect(acceptsInput(answer), isFalse);
    }
    for (final key in ['reviewedAt', 'reviewedBy', 'ownerId', 'fieldName']) {
      final answer = answerJson()..[key] = 'forged';
      expect(() => FormAnswerInput.fromJson(answer), throwsFormatException);
      expect(acceptsInput(answer), isFalse);
    }
    for (final key in ['ownerId', 'updatedAt', 'caseRevision', 'profile']) {
      final request = saveJson()..[key] = 'forged';
      expect(
        () => FormAnswersSaveRequest.fromJson(request),
        throwsFormatException,
      );
      expect(accepts(request, 'form-answers-save-request'), isFalse);
    }
    final response = responseJson()..['approved'] = true;
    expect(() => FormAnswersResponse.fromJson(response), throwsFormatException);
    expect(accepts(response, 'form-answers'), isFalse);
    expect(
      () => FormAnswerContext.fromJson(contextJson()..remove('formVersion')),
      throwsFormatException,
    );
  });

  test('null and review state combinations cannot invent review', () {
    for (final answer in [
      answerJson(value: null),
      answerJson(value: ''),
      answerJson(reviewState: 'approved'),
      answerJson()..['reviewState'] = true,
      answerJson(value: 0),
    ]) {
      expect(() => FormAnswerInput.fromJson(answer), throwsFormatException);
      expect(acceptsInput(answer), isFalse);
    }
    final unreviewed = answerJson(reviewState: 'needs_review');
    expect(FormAnswerInput.fromJson(unreviewed).value, 'Fictional');
    expect(acceptsInput(unreviewed), isTrue);
  });

  test(
    'duplicate keys with identical or different values fail both boundaries',
    () {
      for (final second in [answerJson(), answerJson(value: 'Different')]) {
        final request = saveJson()..['answers'] = [answerJson(), second];
        expect(
          () => FormAnswersSaveRequest.fromJson(request),
          throwsFormatException,
        );
        expect(accepts(request, 'form-answers-save-request'), isFalse);
      }
      final response = responseJson();
      (response['saved'] as Map)['answers'] = [
        savedAnswerJson(),
        savedAnswerJson(),
      ];
      expect(
        () => FormAnswersResponse.fromJson(response),
        throwsFormatException,
      );
      expect(accepts(response, 'form-answers'), isFalse);
    },
  );

  test('per-key length limits count Unicode scalars without normalization', () {
    for (final entry in formAnswerValueLimits.entries) {
      if (entry.key.endsWith('Date') || entry.key.endsWith('Email')) continue;
      final value = List.filled(entry.value, '😀').join();
      final answer = answerJson(key: entry.key, value: value);
      expect(FormAnswerInput.fromJson(answer).value, value);
      expect(acceptsInput(answer), isTrue);
      answer['value'] = '$value😀';
      expect(() => FormAnswerInput.fromJson(answer), throwsFormatException);
      expect(acceptsInput(answer), isFalse);
    }
    const combined = 'Jose\u0301 李';
    expect(
      FormAnswerInput.fromJson(answerJson(value: combined)).value,
      combined,
    );
  });

  test('whitespace controls line breaks and lone surrogates are rejected', () {
    for (final text in [
      ' ',
      ' leading',
      'trailing ',
      '\u00a0name',
      'name\uFEFF',
      'a\nb',
      'a\rb',
      'a\tb',
      'a\u0000b',
      'a\u007fb',
      'a\u0085b',
      'a\u2028b',
      'a\u2029b',
      String.fromCharCode(0xd800),
      String.fromCharCode(0xdc00),
    ]) {
      final answer = answerJson(value: text);
      expect(() => FormAnswerInput.fromJson(answer), throwsFormatException);
      expect(acceptsInput(answer), isFalse);
    }
  });

  test('basic email syntax and 254-character bound agree', () {
    for (final key in ['representativeEmail', 'referrerEmail']) {
      final valid = '${List.filled(242, 'a').join()}@example.org';
      expect(valid.length, 254);
      expect(acceptsInput(answerJson(key: key, value: valid)), isTrue);
      expect(
        FormAnswerInput.fromJson(answerJson(key: key, value: valid)).value,
        valid,
      );
      for (final value in [
        'missing.example.org',
        'a@@example.org',
        '@example.org',
        'a@example',
        'a@.org',
        'a@example.',
        'a b@example.org',
        '${valid}a',
      ]) {
        final answer = answerJson(key: key, value: value);
        expect(() => FormAnswerInput.fromJson(answer), throwsFormatException);
        expect(acceptsInput(answer), isFalse);
      }
    }
  });

  test('date values use real ISO calendars and preserve source spelling', () {
    for (final key in ['memberBirthDate', 'referralDate']) {
      for (final value in ['2024-02-29', '0001-01-01']) {
        expect(
          FormAnswerInput.fromJson(answerJson(key: key, value: value)).value,
          value,
        );
        expect(acceptsInput(answerJson(key: key, value: value)), isTrue);
      }
      for (final value in [
        '0000-01-01',
        '2023-02-29',
        '2026-02-30',
        '2026-13-01',
        '2026-01-00',
        '10/17/2026',
        '2026-1-01',
        '2026-10-17T00:00:00Z',
      ]) {
        final answer = answerJson(key: key, value: value);
        expect(() => FormAnswerInput.fromJson(answer), throwsFormatException);
        expect(acceptsInput(answer), isFalse);
      }
    }
  });

  test(
    'birth date cannot follow referral; saved dates cannot be in the future',
    () {
      final request = saveJson()
        ..['answers'] = [
          answerJson(key: 'memberBirthDate', value: '2026-10-18'),
          answerJson(key: 'referralDate', value: '2026-10-17'),
        ];
      expect(
        () => FormAnswersSaveRequest.fromJson(request),
        throwsFormatException,
      );
      for (final key in ['memberBirthDate', 'referralDate']) {
        for (final state in ['needs_review', 'reviewed']) {
          final saved = savedJson()
            ..['answers'] = [
              savedAnswerJson(
                key: key,
                value: '2026-10-18',
                reviewState: state,
              ),
            ];
          expect(
            () => SavedFormAnswerSet.fromJson(saved),
            throwsFormatException,
          );
        }
      }
      final today = savedJson()
        ..['answers'] = [
          savedAnswerJson(key: 'referralDate', value: '2026-10-17'),
        ];
      expect(
        SavedFormAnswerSet.fromJson(today).answers.single.value,
        '2026-10-17',
      );
    },
  );

  test('review provenance is mandatory only for reviewed non-null answers', () {
    for (final key in ['reviewedAt', 'reviewedBy']) {
      final answer = savedAnswerJson()..[key] = null;
      expect(() => SavedFormAnswer.fromJson(answer), throwsFormatException);
      final response = responseJson();
      (response['saved'] as Map)['answers'] = [answer];
      expect(accepts(response, 'form-answers'), isFalse);
      final unknown = savedAnswerJson(reviewState: 'needs_review')
        ..[key] = key == 'reviewedAt' ? stamp : 'fictional-user';
      expect(() => SavedFormAnswer.fromJson(unknown), throwsFormatException);
    }
    final unknown = savedAnswerJson(value: null, reviewState: 'needs_review');
    expect(SavedFormAnswer.fromJson(unknown).reviewedAt, isNull);
  });

  test(
    'review timestamps cannot follow saved time at microsecond precision',
    () {
      final saved = savedJson()
        ..['answers'] = [
          savedAnswerJson()..['reviewedAt'] = '2026-10-17T19:00:00.123457Z',
        ];
      expect(() => SavedFormAnswerSet.fromJson(saved), throwsFormatException);
      (saved['answers'] as List).single['reviewedAt'] =
          '2026-10-17T19:00:00.123455Z';
      expect(
        SavedFormAnswerSet.fromJson(saved).answers.single.reviewedAt,
        '2026-10-17T19:00:00.123455Z',
      );
    },
  );

  test('timestamps reject rollover offset time and overprecise fractions', () {
    for (final value in [
      '0000-01-01T00:00:00Z',
      '2026-02-30T00:00:00Z',
      '2026-10-17T24:00:00Z',
      '2026-10-17T19:60:00Z',
      '2026-10-17T19:00:60Z',
      '2026-10-17T19:00:00+00:00',
      '2026-10-17T19:00:00.1234567Z',
      '2026-10-17T19:00:00Z\n',
    ]) {
      final saved = savedJson()..['updatedAt'] = value;
      expect(() => SavedFormAnswerSet.fromJson(saved), throwsFormatException);
      expect(
        accepts(responseJson()..['saved'] = saved, 'form-answers'),
        isFalse,
      );
    }
    for (final fraction in [
      '',
      '.1',
      '.12',
      '.123',
      '.1234',
      '.12345',
      '.123456',
    ]) {
      final saved = savedJson()
        ..['answers'] = <Object>[]
        ..['updatedAt'] = '2026-10-17T19:00:00${fraction}Z';
      expect(
        SavedFormAnswerSet.fromJson(saved).updatedAt,
        '2026-10-17T19:00:00${fraction}Z',
      );
    }
  });

  test('IDs use 200 Unicode scalars and revisions use safe JS integers', () {
    final id = List.filled(200, '😀').join();
    expect(
      FormAnswersReadRequest.fromJson(readJson()..['caseId'] = id).caseId,
      id,
    );
    expect(
      accepts(readJson()..['caseId'] = id, 'form-answers-read-request'),
      isTrue,
    );
    expect(
      () => FormAnswersReadRequest.fromJson(readJson()..['caseId'] = '${id}a'),
      throwsFormatException,
    );
    for (final value in [
      0,
      -1,
      1.5,
      '2',
      double.nan,
      double.infinity,
      9007199254740992,
    ]) {
      expect(
        () => FormAnswersReadRequest.fromJson(
          readJson()..['expectedCaseRevision'] = value,
        ),
        throwsFormatException,
      );
    }
    expect(
      FormAnswersReadRequest.fromJson(
        readJson()..['expectedCaseRevision'] = 9007199254740991,
      ).expectedCaseRevision,
      9007199254740991,
    );
    expect(
      FormAnswersSaveRequest.fromJson(saveJson()).expectedAnswerRevision,
      0,
    );
    expect(
      () => FormAnswersSaveRequest.fromJson(
        saveJson()..['expectedAnswerRevision'] = -1,
      ),
      throwsFormatException,
    );
    expect(
      () => SavedFormAnswerSet.fromJson(savedJson()..['answerRevision'] = 0),
      throwsFormatException,
    );
  });

  test('form-context digests and strict schema markers fail closed', () {
    for (final value in [digest.toUpperCase(), '${digest}a', 'a', null, 7]) {
      expect(
        () => FormAnswerContext.fromJson(
          contextJson()..['formContextId'] = value,
        ),
        throwsFormatException,
      );
      expect(
        accepts(
          saveJson()..['expectedFormContextId'] = value,
          'form-answers-save-request',
        ),
        isFalse,
      );
    }
    expect(
      () => FormAnswersResponse.fromJson(responseJson()..['schemaVersion'] = 1),
      throwsFormatException,
    );
    expect(
      () => FormAnswersResponse.fromJson(responseJson()..['isCurrent'] = 1),
      throwsFormatException,
    );
  });

  test('saved revisions and contexts determine currency exactly', () {
    final current = FormAnswersResponse.fromJson(responseJson());
    expect(
      current.isCurrentFor(
        snapshot(),
        FormAnswerContext.fromJson(contextJson()),
      ),
      isTrue,
    );
    expect(
      current.isCurrentFor(snapshot(revision: 3), current.context),
      isFalse,
    );
    expect(
      current.isCurrentFor(snapshot(caseId: 'other'), current.context),
      isFalse,
    );
    for (final key in ['formVersion', 'mappingVersion', 'formContextId']) {
      final json = responseJson()..['isCurrent'] = false;
      (json['saved'] as Map)[key] = key == 'formContextId'
          ? digest.replaceAll('a', 'b')
          : 'older';
      expect(FormAnswersResponse.fromJson(json).isCurrent, isFalse);
      expect(
        () => FormAnswersResponse.fromJson(json..['isCurrent'] = true),
        throwsFormatException,
      );
    }
    final old = responseJson()..['isCurrent'] = false;
    (old['saved'] as Map)['caseRevision'] = 1;
    expect(FormAnswersResponse.fromJson(old).isCurrent, isFalse);
    expect(
      () => FormAnswersResponse.fromJson(responseJson()..['isCurrent'] = false),
      throwsFormatException,
    );
  });

  test(
    'cross-case cross-program and future saved revision responses are invalid',
    () {
      for (final entry in {
        'caseId': 'other-case',
        'programId': 'other-program',
        'caseRevision': 3,
      }.entries) {
        final json = responseJson()..['isCurrent'] = false;
        (json['saved'] as Map)[entry.key] = entry.value;
        expect(() => FormAnswersResponse.fromJson(json), throwsFormatException);
      }
    },
  );

  test('parsed lists and values are immutable detached snapshots', () {
    final json = responseJson();
    final parsed = FormAnswersResponse.fromJson(json);
    ((json['saved'] as Map)['answers'] as List).single['value'] = 'Changed';
    expect(parsed.saved!.answers.single.value, 'Fictional');
    expect(() => parsed.saved!.answers.clear(), throwsUnsupportedError);
    final request = FormAnswersSaveRequest.fromJson(saveJson());
    expect(() => request.answers.clear(), throwsUnsupportedError);
    final serialized = parsed.toJson();
    ((serialized['saved'] as Map)['answers'] as List).clear();
    expect(parsed.saved!.answers, hasLength(1));
    expect(() => formAnswerValueLimits.clear(), throwsUnsupportedError);
  });
}

bool _accepts(
  Object? value,
  Map<String, dynamic> rule,
  Map<String, Map<String, dynamic>> schemas,
  Map<String, dynamic> root,
) {
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
    'minItems',
    'maxItems',
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
      _accepts(item, next as Map<String, dynamic>, schemas, root);
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
    return _accepts(value, target as Map<String, dynamic>, schemas, document);
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
    if (rule['minItems'] != null && value.length < (rule['minItems'] as int)) {
      return false;
    }
    if (rule['maxItems'] != null && value.length > (rule['maxItems'] as int)) {
      return false;
    }
    if (rule['items'] != null &&
        !value.every((item) => check(item, rule['items']))) {
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
