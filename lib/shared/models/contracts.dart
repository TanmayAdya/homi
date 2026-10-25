library;

class CaseSnapshot {
  CaseSnapshot._(
    this.schemaVersion,
    this.caseId,
    this.revision,
    this.profile,
    this.unresolvedFields,
    this.findings,
  );

  factory CaseSnapshot.fromJson(Object? json) {
    final r = _ObjectReader(json, 'case', [
      'schemaVersion',
      'caseId',
      'revision',
      'profile',
      'unresolvedFields',
      'findings',
    ]);
    final findings = r.objects('findings', Finding.fromJson);
    _unique(findings.map((f) => f.id), 'case.findings.id');
    return CaseSnapshot._(
      r.choice('schemaVersion', ['1']),
      r.text('caseId'),
      r.integer('revision', minimum: 1),
      CaseProfile.fromJson(r.value('profile')),
      r.strings('unresolvedFields'),
      findings,
    );
  }

  final String schemaVersion;
  final String caseId;
  final int revision;
  final CaseProfile profile;
  final List<String> unresolvedFields;
  final List<Finding> findings;

  Map<String, Object?> toJson() => {
    'schemaVersion': schemaVersion,
    'caseId': caseId,
    'revision': revision,
    'profile': profile.toJson(),
    'unresolvedFields': List.of(unresolvedFields),
    'findings': findings.map((finding) => finding.toJson()).toList(),
  };
}

class CaseProfile {
  CaseProfile._(
    this.city,
    this.county,
    this.healthPlan,
    this.tenure,
    this.ageYears,
    this.householdSize,
    this.annualIncomeUsd,
    this.ownerConsentReported,
  );

  factory CaseProfile.fromJson(Object? json) {
    final r = _ObjectReader(json, 'profile', [
      'city',
      'county',
      'healthPlan',
      'tenure',
      'ageYears',
      'householdSize',
      'annualIncomeUsd',
      'ownerConsentReported',
    ]);
    return CaseProfile._(
      r.optionalText('city'),
      r.optionalText('county'),
      r.optionalText('healthPlan'),
      r.optionalChoice('tenure', ['owner', 'renter']),
      r.optionalInteger('ageYears', minimum: 0),
      r.optionalInteger('householdSize', minimum: 1),
      r.optionalNumber('annualIncomeUsd'),
      r.optionalBoolean('ownerConsentReported'),
    );
  }

  final String? city;
  final String? county;
  final String? healthPlan;
  final String? tenure;
  final int? ageYears;
  final int? householdSize;
  final num? annualIncomeUsd;
  final bool? ownerConsentReported;

  Map<String, Object?> toJson() => {
    'city': city,
    'county': county,
    'healthPlan': healthPlan,
    'tenure': tenure,
    'ageYears': ageYears,
    'householdSize': householdSize,
    'annualIncomeUsd': annualIncomeUsd,
    'ownerConsentReported': ownerConsentReported,
  };
}

class Finding {
  Finding._(
    this.id,
    this.room,
    this.observation,
    this.reviewState,
    this.evidenceIds,
    this.measurements,
  );

  factory Finding.fromJson(Object? json) {
    final r = _ObjectReader(json, 'finding', [
      'id',
      'room',
      'observation',
      'reviewState',
      'evidenceIds',
      'measurements',
    ]);
    return Finding._(
      r.text('id'),
      r.choice('room', ['bathroom', 'entrance', 'other']),
      r.text('observation'),
      r.choice('reviewState', ['confirmed', 'needs_review', 'dismissed']),
      r.strings('evidenceIds'),
      r.objects('measurements', Measurement.fromJson),
    );
  }

  final String id;
  final String room;
  final String observation;
  final String reviewState;
  final List<String> evidenceIds;
  final List<Measurement> measurements;

  Map<String, Object?> toJson() => {
    'id': id,
    'room': room,
    'observation': observation,
    'reviewState': reviewState,
    'evidenceIds': List.of(evidenceIds),
    'measurements': measurements
        .map((measurement) => measurement.toJson())
        .toList(),
  };
}

class Measurement {
  Measurement._(this.type, this.value, this.unit, this.method, this.confirmed);

  factory Measurement.fromJson(Object? json) {
    final r = _ObjectReader(json, 'measurement', [
      'type',
      'value',
      'unit',
      'method',
      'confirmed',
    ]);
    return Measurement._(
      r.text('type'),
      r.number('value', minimum: 0),
      r.choice('unit', ['mm']),
      r.choice('method', ['manual', 'estimated']),
      r.boolean('confirmed'),
    );
  }

  final String type;
  final num value;
  final String unit;
  final String method;
  final bool confirmed;

  Map<String, Object?> toJson() => {
    'type': type,
    'value': value,
    'unit': unit,
    'method': method,
    'confirmed': confirmed,
  };
}

class MatchResponse {
  MatchResponse._(
    this.schemaVersion,
    this.caseId,
    this.caseRevision,
    this.evaluatedAt,
    this.evaluationDate,
    this.matches,
  );

  factory MatchResponse.fromJson(Object? json) {
    final r = _ObjectReader(json, 'match', [
      'schemaVersion',
      'caseId',
      'caseRevision',
      'evaluatedAt',
      'evaluationDate',
      'matches',
    ]);
    final matches = r.objects('matches', ProgramMatch.fromJson);
    _unique(matches.map((m) => m.programId), 'match.matches.programId');
    return MatchResponse._(
      r.choice('schemaVersion', ['1']),
      r.text('caseId'),
      r.integer('caseRevision', minimum: 1),
      r.instant('evaluatedAt'),
      r.date('evaluationDate'),
      matches,
    );
  }

  final String schemaVersion;
  final String caseId;
  final int caseRevision;
  final String evaluatedAt;
  final String evaluationDate;
  final List<ProgramMatch> matches;

  bool isFreshFor(CaseSnapshot caseSnapshot, {required DateTime now}) {
    if (caseId != caseSnapshot.caseId ||
        caseRevision != caseSnapshot.revision ||
        matches.isEmpty ||
        now.isBefore(DateTime.parse(evaluatedAt))) {
      return false;
    }
    return matches.every((match) {
      final deadline = match.recheckAfter;
      return deadline != null && now.isBefore(DateTime.parse(deadline));
    });
  }
}

class ProgramMatch {
  ProgramMatch._(
    this.programId,
    this.programName,
    this.ruleVersion,
    this.isDemo,
    this.status,
    this.availability,
    this.recheckAfter,
    this.checks,
    this.sources,
    this.requiredDocuments,
    this.intake,
  );

  factory ProgramMatch.fromJson(Object? json) {
    final r = _ObjectReader(json, 'programMatch', [
      'programId',
      'programName',
      'ruleVersion',
      'isDemo',
      'status',
      'availability',
      'recheckAfter',
      'checks',
      'sources',
      'requiredDocuments',
      'intake',
    ]);
    final checks = r.objects('checks', RequirementCheck.fromJson);
    if (checks.isEmpty) _invalid('programMatch.checks', 'must contain a check');
    final sources = r.objects('sources', ProgramSource.fromJson);
    _unique(checks.map((c) => c.id), 'programMatch.checks.id');
    _unique(sources.map((s) => s.id), 'programMatch.sources.id');
    final sourceIds = sources.map((s) => s.id).toSet();
    for (final check in checks) {
      if (!sourceIds.containsAll(check.sourceIds)) {
        _invalid(
          'programMatch.checks.sourceIds',
          'references an absent source',
        );
      }
    }
    return ProgramMatch._(
      r.text('programId'),
      r.text('programName'),
      r.text('ruleVersion'),
      r.boolean('isDemo'),
      r.choice('status', [
        'meets_known_criteria',
        'does_not_meet_criterion',
        'needs_confirmation',
      ]),
      r.choice('availability', ['unverified', 'accepting', 'not_accepting']),
      r.optionalInstant('recheckAfter'),
      checks,
      sources,
      r.strings('requiredDocuments'),
      r.optionalText('intake'),
    );
  }

  final String programId;
  final String programName;
  final String ruleVersion;
  final bool isDemo;
  final String status;
  final String availability;
  final String? recheckAfter;
  final List<RequirementCheck> checks;
  final List<ProgramSource> sources;
  final List<String> requiredDocuments;
  final String? intake;
}

class RequirementCheck {
  RequirementCheck._(
    this.id,
    this.status,
    this.reasonCode,
    this.explanation,
    this.missingFields,
    this.resolvedBy,
    this.sourceIds,
  );

  factory RequirementCheck.fromJson(Object? json) {
    final r = _ObjectReader(json, 'check', [
      'id',
      'status',
      'reasonCode',
      'explanation',
      'missingFields',
      'resolvedBy',
      'sourceIds',
    ]);
    return RequirementCheck._(
      r.text('id'),
      r.choice('status', ['pass', 'fail', 'unknown']),
      r.text('reasonCode'),
      r.text('explanation'),
      r.strings('missingFields'),
      r.optionalChoice('resolvedBy', ['resident', 'program', 'professional']),
      r.strings('sourceIds'),
    );
  }

  final String id;
  final String status;
  final String reasonCode;
  final String explanation;
  final List<String> missingFields;
  final String? resolvedBy;
  final List<String> sourceIds;
}

class ProgramSource {
  ProgramSource._(
    this.id,
    this.url,
    this.title,
    this.reviewedOn,
    this.effectiveFrom,
    this.effectiveUntil,
  );

  factory ProgramSource.fromJson(Object? json) {
    final r = _ObjectReader(json, 'source', [
      'id',
      'url',
      'title',
      'reviewedOn',
      'effectiveFrom',
      'effectiveUntil',
    ]);
    final url = r.text('url');
    final uri = Uri.tryParse(url);
    if (uri == null ||
        !['http', 'https'].contains(uri.scheme) ||
        uri.host.isEmpty ||
        RegExp(r'\s').hasMatch(url)) {
      _invalid('source.url', 'must be an absolute HTTP(S) URL');
    }
    final from = r.optionalDate('effectiveFrom');
    final until = r.optionalDate('effectiveUntil');
    if (from != null && until != null && from.compareTo(until) > 0) {
      _invalid('source.effectiveUntil', 'must not precede effectiveFrom');
    }
    return ProgramSource._(
      r.text('id'),
      url,
      r.text('title'),
      r.date('reviewedOn'),
      from,
      until,
    );
  }

  final String id;
  final String url;
  final String title;
  final String reviewedOn;
  final String? effectiveFrom;
  final String? effectiveUntil;
}

class DemoScenario {
  DemoScenario._(
    this.id,
    this.title,
    this.description,
    this.caseSnapshot,
    this.matchResponse,
  );

  factory DemoScenario.fromJson(Object? json) {
    final r = _ObjectReader(json, 'scenario', [
      'id',
      'title',
      'description',
      'case',
      'match',
    ]);
    final snapshot = CaseSnapshot.fromJson(r.value('case'));
    final response = MatchResponse.fromJson(r.value('match'));
    if (snapshot.caseId != response.caseId ||
        snapshot.revision != response.caseRevision) {
      _invalid(
        'scenario.match',
        'must describe the scenario case and revision',
      );
    }
    if (response.matches.any((match) => !match.isDemo)) {
      _invalid(
        'scenario.match',
        'demo scenarios must contain only demo routes',
      );
    }
    return DemoScenario._(
      r.choice('id', ['matched', 'not-matched', 'unknown']),
      r.text('title'),
      r.text('description'),
      snapshot,
      response,
    );
  }

  final String id;
  final String title;
  final String description;
  final CaseSnapshot caseSnapshot;
  final MatchResponse matchResponse;
}

List<DemoScenario> parseDemoScenarios(Object? json) {
  if (json is! List || json.isEmpty) {
    _invalid('scenarios', 'must be a nonempty array');
  }
  final scenarios = json.map(DemoScenario.fromJson).toList();
  _unique(scenarios.map((s) => s.id), 'scenarios.id');
  return List.unmodifiable(scenarios);
}

Never _invalid(String path, String message) =>
    throw FormatException('$path $message');

void _unique(Iterable<String> values, String path) {
  final seen = <String>{};
  for (final value in values) {
    if (!seen.add(value)) _invalid(path, 'must be unique');
  }
}

class _ObjectReader {
  _ObjectReader(Object? input, this.path, List<String> requiredKeys) {
    if (input is! Map || input.keys.any((key) => key is! String)) {
      _invalid(path, 'must be an object with string keys');
    }
    _data = Map<String, Object?>.from(input);
    final expected = requiredKeys.toSet();
    final missing = expected.difference(_data.keys.toSet());
    final extra = _data.keys.toSet().difference(expected);
    if (missing.isNotEmpty) _invalid(path, 'is missing ${missing.join(', ')}');
    if (extra.isNotEmpty) {
      _invalid(path, 'has unexpected fields ${extra.join(', ')}');
    }
  }

  final String path;
  late final Map<String, Object?> _data;

  Object? value(String key) => _data[key];

  String text(String key) {
    final v = value(key);
    if (v is! String || v.isEmpty) {
      _invalid('$path.$key', 'must be nonempty text');
    }
    return v;
  }

  String? optionalText(String key) => value(key) == null ? null : text(key);

  String choice(String key, List<String> allowed) {
    final v = text(key);
    if (!allowed.contains(v)) {
      _invalid('$path.$key', 'has an unsupported value');
    }
    return v;
  }

  String? optionalChoice(String key, List<String> allowed) =>
      value(key) == null ? null : choice(key, allowed);

  num number(String key, {num? minimum}) {
    final v = value(key);
    if (v is! num || !v.isFinite || (minimum != null && v < minimum)) {
      _invalid(
        '$path.$key',
        'must be a finite number${minimum == null ? '' : ' >= $minimum'}',
      );
    }
    return v;
  }

  num? optionalNumber(String key) => value(key) == null ? null : number(key);

  int integer(String key, {required int minimum}) {
    final v = number(key, minimum: minimum);
    if (v != v.truncateToDouble()) _invalid('$path.$key', 'must be an integer');
    return v.toInt();
  }

  int? optionalInteger(String key, {required int minimum}) =>
      value(key) == null ? null : integer(key, minimum: minimum);

  bool boolean(String key) {
    final v = value(key);
    if (v is! bool) _invalid('$path.$key', 'must be a boolean');
    return v;
  }

  bool? optionalBoolean(String key) => value(key) == null ? null : boolean(key);

  List<String> strings(String key) {
    final v = value(key);
    if (v is! List || v.any((item) => item is! String || item.isEmpty)) {
      _invalid('$path.$key', 'must be an array of nonempty strings');
    }
    final result = List<String>.from(v);
    _unique(result, '$path.$key');
    return List.unmodifiable(result);
  }

  List<T> objects<T>(String key, T Function(Object?) parse) {
    final v = value(key);
    if (v is! List) _invalid('$path.$key', 'must be an array');
    return List.unmodifiable(v.map(parse));
  }

  String date(String key) {
    final v = text(key);
    if (!_validDate(v)) {
      _invalid('$path.$key', 'must be a valid YYYY-MM-DD date');
    }
    return v;
  }

  String? optionalDate(String key) => value(key) == null ? null : date(key);

  String instant(String key) {
    final v = text(key);
    final pattern = RegExp(
      r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,6})?Z$',
    );
    if (!pattern.hasMatch(v) ||
        !_validDate(v.substring(0, 10)) ||
        int.parse(v.substring(11, 13)) > 23 ||
        int.parse(v.substring(14, 16)) > 59 ||
        int.parse(v.substring(17, 19)) > 59 ||
        DateTime.tryParse(v) == null) {
      _invalid('$path.$key', 'must be a valid UTC timestamp ending in Z');
    }
    return v;
  }

  String? optionalInstant(String key) =>
      value(key) == null ? null : instant(key);
}

bool _validDate(String text) {
  if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(text)) return false;
  final year = int.parse(text.substring(0, 4));
  final month = int.parse(text.substring(5, 7));
  final day = int.parse(text.substring(8, 10));
  final parsed = DateTime.utc(year, month, day);
  return parsed.year == year && parsed.month == month && parsed.day == day;
}
