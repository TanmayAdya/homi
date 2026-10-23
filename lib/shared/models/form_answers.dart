import 'contracts.dart';

const formAnswerValueLimits = <String, int>{
  'memberFirstName': 160,
  'memberLastName': 160,
  'memberBirthDate': 10,
  'memberId': 80,
  'memberPhone': 40,
  'memberPreferredSpokenLanguage': 80,
  'representativeName': 160,
  'representativeEmail': 254,
  'representativePhone': 40,
  'referralDate': 10,
  'referralSource': 200,
  'referringOrganizationName': 200,
  'referringOrganizationPhone': 40,
  'referrerName': 160,
  'referrerTitle': 100,
  'referrerOrganizationName': 200,
  'referrerEmail': 254,
  'referrerPhone': 40,
};

class FormAnswerInput {
  FormAnswerInput._(this.key, this.value, this.reviewState);

  factory FormAnswerInput.fromJson(Object? json) {
    final object = _object(json, {'key', 'value', 'reviewState'});
    return _answer(object);
  }

  final String key;
  final String? value;
  final String reviewState;

  Map<String, Object?> toJson() => {
    'key': key,
    'value': value,
    'reviewState': reviewState,
  };
}

class SavedFormAnswer extends FormAnswerInput {
  SavedFormAnswer._(
    super.key,
    super.value,
    super.reviewState,
    this.reviewedAt,
    this.reviewedBy,
  ) : super._();

  factory SavedFormAnswer.fromJson(Object? json) {
    final object = _object(json, {
      'key',
      'value',
      'reviewState',
      'reviewedAt',
      'reviewedBy',
    });
    final answer = _answer(object);
    String? reviewedAt;
    String? reviewedBy;
    if (answer.reviewState == 'reviewed') {
      reviewedAt = _instant(object['reviewedAt']);
      reviewedBy = _text(object['reviewedBy'], 200);
    } else if (object['reviewedAt'] != null || object['reviewedBy'] != null) {
      _invalid('Unreviewed answers must have null review provenance.');
    }
    return SavedFormAnswer._(
      answer.key,
      answer.value,
      answer.reviewState,
      reviewedAt,
      reviewedBy,
    );
  }

  final String? reviewedAt;
  final String? reviewedBy;

  @override
  Map<String, Object?> toJson() => {
    ...super.toJson(),
    'reviewedAt': reviewedAt,
    'reviewedBy': reviewedBy,
  };
}

class FormAnswerContext {
  FormAnswerContext._(
    this.programId,
    this.formVersion,
    this.mappingVersion,
    this.formContextId,
  );

  factory FormAnswerContext.fromJson(Object? json) {
    final object = _object(json, {
      'programId',
      'formVersion',
      'mappingVersion',
      'formContextId',
    });
    return FormAnswerContext._(
      _text(object['programId'], 200),
      _text(object['formVersion'], 200),
      _text(object['mappingVersion'], 200),
      _digest(object['formContextId']),
    );
  }

  final String programId;
  final String formVersion;
  final String mappingVersion;
  final String formContextId;

  Map<String, Object?> toJson() => {
    'programId': programId,
    'formVersion': formVersion,
    'mappingVersion': mappingVersion,
    'formContextId': formContextId,
  };
}

class SavedFormAnswerSet {
  SavedFormAnswerSet._({
    required this.caseId,
    required this.caseRevision,
    required this.context,
    required this.answerRevision,
    required this.updatedAt,
    required this.updatedBy,
    required this.answers,
  });

  factory SavedFormAnswerSet.fromJson(Object? json) {
    final object = _object(json, {
      'schemaVersion',
      'caseId',
      'caseRevision',
      'programId',
      'formVersion',
      'mappingVersion',
      'formContextId',
      'answerRevision',
      'updatedAt',
      'updatedBy',
      'answers',
    });
    _version(object);
    final updatedAt = _instant(object['updatedAt']);
    final answers = _answers(object['answers'], SavedFormAnswer.fromJson);
    _validateDates(answers, latestDate: updatedAt.substring(0, 10));
    for (final answer in answers) {
      if (answer.reviewedAt != null &&
          DateTime.parse(
            answer.reviewedAt!,
          ).isAfter(DateTime.parse(updatedAt))) {
        _invalid('Answer review cannot be later than the saved update.');
      }
    }
    return SavedFormAnswerSet._(
      caseId: _text(object['caseId'], 200),
      caseRevision: _integer(object['caseRevision'], 1),
      context: FormAnswerContext.fromJson({
        for (final key in [
          'programId',
          'formVersion',
          'mappingVersion',
          'formContextId',
        ])
          key: object[key],
      }),
      answerRevision: _integer(object['answerRevision'], 1),
      updatedAt: updatedAt,
      updatedBy: _text(object['updatedBy'], 200),
      answers: answers,
    );
  }

  String get schemaVersion => '1';
  final String caseId;
  final int caseRevision;
  final FormAnswerContext context;
  String get programId => context.programId;
  String get formVersion => context.formVersion;
  String get mappingVersion => context.mappingVersion;
  String get formContextId => context.formContextId;
  final int answerRevision;
  final String updatedAt;
  final String updatedBy;
  final List<SavedFormAnswer> answers;

  bool isCurrentFor(CaseSnapshot snapshot, FormAnswerContext currentContext) =>
      _matches(snapshot.caseId, snapshot.revision, currentContext);

  bool _matches(String id, int revision, FormAnswerContext current) =>
      caseId == id &&
      caseRevision == revision &&
      programId == current.programId &&
      formVersion == current.formVersion &&
      mappingVersion == current.mappingVersion &&
      formContextId == current.formContextId;

  Map<String, Object?> toJson() => {
    'schemaVersion': schemaVersion,
    'caseId': caseId,
    'caseRevision': caseRevision,
    ...context.toJson(),
    'answerRevision': answerRevision,
    'updatedAt': updatedAt,
    'updatedBy': updatedBy,
    'answers': answers.map((answer) => answer.toJson()).toList(),
  };
}

class FormAnswersResponse {
  FormAnswersResponse._(
    this.caseId,
    this.caseRevision,
    this.context,
    this.saved,
    this.isCurrent,
  );

  factory FormAnswersResponse.fromJson(Object? json) {
    final object = _object(json, {
      'schemaVersion',
      'caseId',
      'caseRevision',
      'context',
      'saved',
      'isCurrent',
    });
    _version(object);
    final caseId = _text(object['caseId'], 200);
    final caseRevision = _integer(object['caseRevision'], 1);
    final context = FormAnswerContext.fromJson(object['context']);
    final saved = object['saved'] == null
        ? null
        : SavedFormAnswerSet.fromJson(object['saved']);
    final isCurrent = object['isCurrent'];
    if (isCurrent is! bool) _invalid('Answer currency must be a boolean.');
    if (saved != null &&
        (saved.caseId != caseId ||
            saved.programId != context.programId ||
            saved.caseRevision > caseRevision)) {
      _invalid('Saved answers have another case/program or a future revision.');
    }
    if (isCurrent !=
        (saved?._matches(caseId, caseRevision, context) ?? false)) {
      _invalid('Answer currency does not match the supplied revisions.');
    }
    return FormAnswersResponse._(
      caseId,
      caseRevision,
      context,
      saved,
      isCurrent,
    );
  }

  String get schemaVersion => '1';
  final String caseId;
  final int caseRevision;
  final FormAnswerContext context;
  final SavedFormAnswerSet? saved;
  final bool isCurrent;

  bool isCurrentFor(CaseSnapshot snapshot, FormAnswerContext currentContext) =>
      isCurrent && (saved?.isCurrentFor(snapshot, currentContext) ?? false);

  Map<String, Object?> toJson() => {
    'schemaVersion': schemaVersion,
    'caseId': caseId,
    'caseRevision': caseRevision,
    'context': context.toJson(),
    'saved': saved?.toJson(),
    'isCurrent': isCurrent,
  };
}

class FormAnswersReadRequest {
  FormAnswersReadRequest._(
    this.caseId,
    this.expectedCaseRevision,
    this.programId,
  );

  factory FormAnswersReadRequest.fromJson(Object? json) {
    final object = _object(json, {
      'schemaVersion',
      'caseId',
      'expectedCaseRevision',
      'programId',
    });
    _version(object);
    return FormAnswersReadRequest._(
      _text(object['caseId'], 200),
      _integer(object['expectedCaseRevision'], 1),
      _text(object['programId'], 200),
    );
  }

  String get schemaVersion => '1';
  final String caseId;
  final int expectedCaseRevision;
  final String programId;

  Map<String, Object?> toJson() => {
    'schemaVersion': schemaVersion,
    'caseId': caseId,
    'expectedCaseRevision': expectedCaseRevision,
    'programId': programId,
  };
}

class FormAnswersSaveRequest extends FormAnswersReadRequest {
  FormAnswersSaveRequest._(
    super.caseId,
    super.expectedCaseRevision,
    super.programId,
    this.expectedFormContextId,
    this.expectedAnswerRevision,
    this.answers,
  ) : super._();

  factory FormAnswersSaveRequest.fromJson(Object? json) {
    final object = _object(json, {
      'schemaVersion',
      'caseId',
      'expectedCaseRevision',
      'programId',
      'expectedFormContextId',
      'expectedAnswerRevision',
      'answers',
    });
    _version(object);
    final answers = _answers(object['answers'], FormAnswerInput.fromJson);
    _validateDates(answers);
    return FormAnswersSaveRequest._(
      _text(object['caseId'], 200),
      _integer(object['expectedCaseRevision'], 1),
      _text(object['programId'], 200),
      _digest(object['expectedFormContextId']),
      _integer(object['expectedAnswerRevision'], 0),
      answers,
    );
  }

  final String expectedFormContextId;
  final int expectedAnswerRevision;
  final List<FormAnswerInput> answers;

  @override
  Map<String, Object?> toJson() => {
    ...super.toJson(),
    'expectedFormContextId': expectedFormContextId,
    'expectedAnswerRevision': expectedAnswerRevision,
    'answers': answers.map((answer) => answer.toJson()).toList(),
  };
}

FormAnswerInput _answer(Map<String, Object?> object) {
  final key = object['key'];
  if (key is! String || !formAnswerValueLimits.containsKey(key)) {
    _invalid('Unknown or protected form-answer key.');
  }
  final reviewState = object['reviewState'];
  if (reviewState != 'needs_review' && reviewState != 'reviewed') {
    _invalid('Unsupported answer review state.');
  }
  final raw = object['value'];
  final value = raw == null ? null : _text(raw, formAnswerValueLimits[key]!);
  if (value == null && reviewState != 'needs_review') {
    _invalid('A null answer cannot be reviewed.');
  }
  if (value != null) {
    if (_dateKeys.contains(key)) _date(value);
    if (_emailKeys.contains(key) &&
        !RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(value)) {
      _invalid('Invalid administrative email value.');
    }
  }
  return FormAnswerInput._(key, value, reviewState as String);
}

const _dateKeys = {'memberBirthDate', 'referralDate'};
const _emailKeys = {'representativeEmail', 'referrerEmail'};

void _validateDates(Iterable<FormAnswerInput> answers, {String? latestDate}) {
  final dates = {
    for (final answer in answers)
      if (_dateKeys.contains(answer.key) && answer.value != null)
        answer.key: answer.value!,
  };
  if (latestDate != null &&
      dates.values.any((date) => date.compareTo(latestDate) > 0)) {
    _invalid('Answer date cannot be later than the saved update date.');
  }
  if (dates.containsKey('memberBirthDate') &&
      dates.containsKey('referralDate') &&
      dates['memberBirthDate']!.compareTo(dates['referralDate']!) > 0) {
    _invalid('Birth date cannot be later than referral date.');
  }
}

List<T> _answers<T extends FormAnswerInput>(
  Object? json,
  T Function(Object?) parse,
) {
  if (json is! List || json.length > formAnswerValueLimits.length) {
    _invalid('Answers must be a bounded array.');
  }
  final answers = json.map(parse).toList();
  final keys = <String>{};
  if (answers.any((answer) => !keys.add(answer.key))) {
    _invalid('Duplicate form-answer key.');
  }
  return List.unmodifiable(answers);
}

Map<String, Object?> _object(Object? json, Set<String> keys) {
  if (json is! Map ||
      json.length != keys.length ||
      json.keys.any((key) => key is! String || !keys.contains(key))) {
    _invalid('Form-answer object has missing or unexpected properties.');
  }
  return Map<String, Object?>.from(json);
}

void _version(Map<String, Object?> object) {
  if (object['schemaVersion'] != '1') _invalid('Unsupported answer schema.');
}

String _text(Object? value, int maximum) {
  if (value is! String ||
      value.isEmpty ||
      value.trim() != value ||
      value.runes.length > maximum ||
      RegExp(r'[\x00-\x1f\x7f-\x9f\u2028\u2029]').hasMatch(value) ||
      value.runes.any((rune) => rune >= 0xd800 && rune <= 0xdfff)) {
    _invalid('Form-answer text must be bounded, nonblank and unmodified.');
  }
  return value;
}

int _integer(Object? value, int minimum) {
  if (value is! num ||
      !value.isFinite ||
      value < minimum ||
      value > 9007199254740991 ||
      value != value.truncateToDouble()) {
    _invalid('Form-answer revision must be a safe integer.');
  }
  return value.toInt();
}

String _digest(Object? value) {
  if (value is! String ||
      value.length != 64 ||
      RegExp(r'[^a-f0-9]').hasMatch(value)) {
    _invalid('Form context must be a lowercase SHA-256 identifier.');
  }
  return value;
}

String _date(Object? value) {
  final text = _text(value, 10);
  if (text.length != 10 || !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(text)) {
    _invalid('Answer date must use YYYY-MM-DD.');
  }
  final parsed = DateTime.tryParse(text);
  if (parsed == null ||
      parsed.year < 1 ||
      parsed.year != int.parse(text.substring(0, 4)) ||
      parsed.month != int.parse(text.substring(5, 7)) ||
      parsed.day != int.parse(text.substring(8, 10))) {
    _invalid('Answer date must be a valid calendar date.');
  }
  return text;
}

String _instant(Object? value) {
  final text = _text(value, 27);
  if (!RegExp(
    r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,6})?Z$',
  ).hasMatch(text)) {
    _invalid(
      'Answer timestamp must use UTC with at most six fractional digits.',
    );
  }
  _date(text.substring(0, 10));
  final parsed = DateTime.tryParse(text);
  if (parsed == null ||
      parsed.hour != int.parse(text.substring(11, 13)) ||
      parsed.minute != int.parse(text.substring(14, 16)) ||
      parsed.second != int.parse(text.substring(17, 19))) {
    _invalid('Answer timestamp contains an invalid time.');
  }
  return text;
}

Never _invalid(String message) => throw FormatException(message);
