import 'export_contract_values.dart';

class IntakeQuestion {
  IntakeQuestion._(
    this.key,
    this.label,
    this.kind,
    this.maxLength,
    this.description,
  );
  factory IntakeQuestion.fromJson(Object? json) {
    final v = ExportContractValues.object(json, {
      'key',
      'label',
      'kind',
      'maxLength',
      'description',
    });
    final kind = v['kind'];
    if (!{'boolean', 'money', 'text'}.contains(kind)) {
      ExportContractValues.invalid();
    }
    final limit = kind == 'text'
        ? ExportContractValues.integer(v['maxLength'], max: 600)
        : null;
    if (kind != 'text' && v['maxLength'] != null) {
      ExportContractValues.invalid();
    }
    return IntakeQuestion._(
      ExportContractValues.id(v['key']),
      _text(v['label'], 200),
      kind as String,
      limit,
      _text(v['description'], 1000),
    );
  }
  final String key;
  final String label;
  final String kind;
  final int? maxLength;
  final String description;
  Map<String, Object?> toJson() => {
    'key': key,
    'label': label,
    'kind': kind,
    'maxLength': maxLength,
    'description': description,
  };
}

class IntakeDefinition {
  IntakeDefinition._(this.programId, this.questionnaireVersion, this.questions);
  factory IntakeDefinition.fromJson(Object? json) {
    final v = ExportContractValues.object(json, {
      'programId',
      'questionnaireVersion',
      'questions',
    });
    final questions = ExportContractValues.list(
      v['questions'],
      IntakeQuestion.fromJson,
      20,
    );
    if (questions.isEmpty) ExportContractValues.invalid();
    ExportContractValues.unique(questions.map((q) => q.key));
    return IntakeDefinition._(
      ExportContractValues.id(v['programId']),
      ExportContractValues.digest(v['questionnaireVersion']),
      questions,
    );
  }
  final String programId;
  final String questionnaireVersion;
  final List<IntakeQuestion> questions;
  Map<String, Object?> toJson() => {
    'programId': programId,
    'questionnaireVersion': questionnaireVersion,
    'questions': questions.map((q) => q.toJson()).toList(),
  };
}

class IntakeAnswer {
  IntakeAnswer._(this.key, this.value, this.reviewState);
  factory IntakeAnswer.fromJson(Object? json, IntakeDefinition definition) {
    final v = ExportContractValues.object(json, {
      'key',
      'value',
      'reviewState',
    });
    final matches = definition.questions.where((q) => q.key == v['key']);
    if (matches.length != 1) ExportContractValues.invalid();
    final question = matches.single;
    final value = v['value'];
    if (value == null) {
      if (v['reviewState'] != 'unknown') ExportContractValues.invalid();
    } else {
      if (v['reviewState'] != 'reported') ExportContractValues.invalid();
      switch (question.kind) {
        case 'boolean':
          if (value is! bool) ExportContractValues.invalid();
        case 'money':
          if (value is! num ||
              !value.isFinite ||
              value < 0 ||
              value > 100000000 ||
              ((value * 100) - (value * 100).round()).abs() >= 0.00001) {
            ExportContractValues.invalid();
          }
        case 'text':
          _text(value, question.maxLength!);
      }
    }
    return IntakeAnswer._(question.key, value, v['reviewState'] as String);
  }
  final String key;
  final Object? value;
  final String reviewState;
  Map<String, Object?> toJson() => {
    'key': key,
    'value': value,
    'reviewState': reviewState,
  };
}

class SavedProgramIntake {
  SavedProgramIntake._(
    this.caseId,
    this.caseRevision,
    this.programId,
    this.questionnaireVersion,
    this.intakeRevision,
    this.updatedAt,
    this.updatedBy,
    this.answers,
  );
  factory SavedProgramIntake.fromJson(
    Object? json,
    IntakeDefinition definition,
  ) {
    final v = ExportContractValues.object(json, {
      'schemaVersion',
      'caseId',
      'caseRevision',
      'programId',
      'questionnaireVersion',
      'intakeRevision',
      'updatedAt',
      'updatedBy',
      'answers',
    });
    if (v['schemaVersion'] != '2' ||
        v['programId'] != definition.programId ||
        v['questionnaireVersion'] != definition.questionnaireVersion) {
      ExportContractValues.invalid();
    }
    final answers = ExportContractValues.list(
      v['answers'],
      (value) => IntakeAnswer.fromJson(value, definition),
      definition.questions.length,
    );
    ExportContractValues.unique(answers.map((a) => a.key));
    return SavedProgramIntake._(
      ExportContractValues.id(v['caseId']),
      ExportContractValues.integer(v['caseRevision']),
      definition.programId,
      definition.questionnaireVersion,
      ExportContractValues.integer(v['intakeRevision']),
      ExportContractValues.instant(v['updatedAt']),
      ExportContractValues.id(v['updatedBy']),
      answers,
    );
  }
  final String caseId;
  final int caseRevision;
  final String programId;
  final String questionnaireVersion;
  final int intakeRevision;
  final String updatedAt;
  final String updatedBy;
  final List<IntakeAnswer> answers;
  Map<String, Object?> toJson() => {
    'schemaVersion': '2',
    'caseId': caseId,
    'caseRevision': caseRevision,
    'programId': programId,
    'questionnaireVersion': questionnaireVersion,
    'intakeRevision': intakeRevision,
    'updatedAt': updatedAt,
    'updatedBy': updatedBy,
    'answers': answers.map((a) => a.toJson()).toList(),
  };
}

class ProgramIntakeResponse {
  ProgramIntakeResponse._(
    this.caseId,
    this.caseRevision,
    this.definition,
    this.saved,
    this.isCurrent,
  );
  factory ProgramIntakeResponse.fromJson(Object? json) {
    final v = ExportContractValues.object(json, {
      'schemaVersion',
      'caseId',
      'caseRevision',
      'definition',
      'saved',
      'isCurrent',
    });
    if (v['schemaVersion'] != '2' || v['isCurrent'] is! bool) {
      ExportContractValues.invalid();
    }
    final definition = IntakeDefinition.fromJson(v['definition']);
    final saved = v['saved'] == null
        ? null
        : SavedProgramIntake.fromJson(v['saved'], definition);
    final caseId = ExportContractValues.id(v['caseId']);
    final revision = ExportContractValues.integer(v['caseRevision']);
    if (saved != null &&
        (saved.caseId != caseId || saved.caseRevision > revision)) {
      ExportContractValues.invalid();
    }
    if (v['isCurrent'] != (saved != null && saved.caseRevision == revision)) {
      ExportContractValues.invalid();
    }
    return ProgramIntakeResponse._(
      caseId,
      revision,
      definition,
      saved,
      v['isCurrent'] as bool,
    );
  }
  final String caseId;
  final int caseRevision;
  final IntakeDefinition definition;
  final SavedProgramIntake? saved;
  final bool isCurrent;
  Map<String, Object?> toJson() => {
    'schemaVersion': '2',
    'caseId': caseId,
    'caseRevision': caseRevision,
    'definition': definition.toJson(),
    'saved': saved?.toJson(),
    'isCurrent': isCurrent,
  };
}

String _text(Object? value, int max) {
  if (value is! String ||
      value.isEmpty ||
      value.trim() != value ||
      value.runes.length > max ||
      RegExp(r'[\x00-\x1f\x7f-\x9f\u2028\u2029]').hasMatch(value) ||
      value.runes.any((r) => r >= 0xd800 && r <= 0xdfff)) {
    ExportContractValues.invalid();
  }
  return value;
}
