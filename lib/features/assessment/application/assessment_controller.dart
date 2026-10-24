import 'package:flutter/foundation.dart';

import '../../../shared/models/contracts.dart';
import '../../../shared/models/export_contract_values.dart';
import '../domain/capture/capture_adapter.dart';
import '../domain/ids/id_factory.dart';
import '../domain/measurement/measurement_fields.dart';
import '../domain/measurement/measurement_input.dart';
import '../domain/review/finding_review_tracker.dart';
import '../domain/review/finding_review_state.dart';
import '../domain/review/review_snapshot.dart';

final class CaptureCapacityException implements Exception {
  const CaptureCapacityException();
}

extension AssessmentAreaRoom on AssessmentArea {
  String get roomWireValue => switch (this) {
    AssessmentArea.bathroom => 'bathroom',
    AssessmentArea.entrance => 'entrance',
  };
}

enum MeasurementMethod {
  manual('manual'),
  estimated('estimated');

  const MeasurementMethod(this.wireValue);
  final String wireValue;
}

final class RecordedMeasurement {
  const RecordedMeasurement._({
    required this.type,
    required this.input,
    required this.method,
    required this.confirmed,
    this.originalInputKnown = true,
    this.recorder = 'self',
    this.recordedAt,
  });

  final String type;

  final MeasurementInput input;

  final MeasurementMethod method;

  final bool confirmed;
  final bool originalInputKnown;
  final String recorder;
  final String? recordedAt;

  bool get promptsZeroReview =>
      needsZeroReviewPrompt(type: type, millimetres: input.millimetres);

  Map<String, Object?> toV1Json() => {
    'type': type,
    'value': _wireNumber(input.millimetres),
    'unit': 'mm',
    'method': method.wireValue,
    'confirmed': confirmed,
  };

  RecordedMeasurement _withConfirmed(bool value) => RecordedMeasurement._(
    type: type,
    input: input,
    method: method,
    confirmed: value,
    originalInputKnown: originalInputKnown,
    recorder: recorder,
    recordedAt: recordedAt,
  );
}

final class FindingDraft {
  const FindingDraft._({
    required this.id,
    required this.area,
    required this.observation,
    required this.evidence,
    required this.measurements,
  });

  final String id;
  final AssessmentArea area;

  final String observation;

  final List<EvidenceVersion> evidence;

  final List<RecordedMeasurement> measurements;

  RecordedMeasurement? measurementOf(String type) {
    for (final RecordedMeasurement m in measurements) {
      if (m.type == type) return m;
    }
    return null;
  }

  ReviewSnapshot get snapshot => ReviewSnapshot(
    observation: observation,
    evidence: evidence,
    measurements: measurements.map((m) => m.toV1Json()),
  );

  FindingDraft _copyWith({
    String? observation,
    List<EvidenceVersion>? evidence,
    List<RecordedMeasurement>? measurements,
  }) => FindingDraft._(
    id: id,
    area: area,
    observation: observation ?? this.observation,
    evidence: evidence == null ? this.evidence : List.unmodifiable(evidence),
    measurements: measurements == null
        ? this.measurements
        : List.unmodifiable(measurements),
  );
}

enum MeasurementChangeKind { corrected, cleared }

final class MeasurementChange {
  const MeasurementChange({
    required this.kind,
    required this.previous,
    required this.at,
  });

  final MeasurementChangeKind kind;

  final RecordedMeasurement previous;

  final DateTime at;
}

class AssessmentController extends ChangeNotifier {
  AssessmentController({
    required IdFactory ids,
    FindingReviewTracker? tracker,
    DateTime Function()? clock,
  }) : _ids = ids,
       _clock = clock ?? (() => DateTime.now().toUtc()),
       _tracker = tracker ?? FindingReviewTracker(clock: clock);

  final IdFactory _ids;
  final DateTime Function() _clock;
  final FindingReviewTracker _tracker;
  final Map<String, List<MeasurementChange>> _measurementHistory = {};
  final Set<String> _removedFindingIds = {};

  final Map<String, FindingDraft> _drafts = {};
  final Set<String> _issuedFindingIds = {};
  final Set<String> _issuedEvidenceIds = {};
  final Set<String> _reservedFindingIds = {};
  final Set<String> _reservedEvidenceIds = {};

  String reserveFindingId() =>
      _reserve(_ids.newFindingId(), _issuedFindingIds, _reservedFindingIds);
  String reserveEvidenceId() =>
      _reserve(_ids.newEvidenceId(), _issuedEvidenceIds, _reservedEvidenceIds);
  bool isReservedFinding(String id) => _reservedFindingIds.contains(id);
  bool isReservedEvidence(String id) => _reservedEvidenceIds.contains(id);
  void abandonReservedIds({String? findingId, String? evidenceId}) {
    _reservedFindingIds.remove(findingId);
    _reservedEvidenceIds.remove(evidenceId);
  }

  List<FindingDraft> get drafts => List.unmodifiable(_drafts.values);

  FindingDraft? draftOf(String findingId) => _drafts[findingId];

  FindingReview? reviewOf(String findingId) => _tracker.reviewOf(findingId);

  List<MeasurementChange> measurementHistoryOf(String findingId, String type) =>
      List.unmodifiable(
        _measurementHistory[_historyKey(findingId, type)] ?? const [],
      );

  Set<String> get removedFindingIds => Set.unmodifiable(_removedFindingIds);

  String startFinding(AssessmentArea area, {String? reservedId}) {
    final String id = reservedId == null
        ? _issue(_ids.newFindingId(), _issuedFindingIds)
        : _consume(reservedId, _reservedFindingIds);
    _drafts[id] = FindingDraft._(
      id: id,
      area: area,
      observation: '',
      evidence: const [],
      measurements: const [],
    );
    _tracker.start(id);
    notifyListeners();
    return id;
  }

  void setObservation(String findingId, String text) {
    final FindingDraft draft = _require(findingId);
    if (draft.observation == text) return;
    _update(draft._copyWith(observation: text));
  }

  String addEvidence(
    String findingId, {
    required String version,
    String? reservedId,
  }) {
    final FindingDraft draft = _require(findingId);
    final String evidenceId = reservedId == null
        ? _issue(_ids.newEvidenceId(), _issuedEvidenceIds)
        : _consume(reservedId, _reservedEvidenceIds);
    _tracker.viewAdded(findingId);
    _update(
      draft._copyWith(
        evidence: [
          ...draft.evidence,
          EvidenceVersion(evidenceId: evidenceId, version: version),
        ],
      ),
    );
    return evidenceId;
  }

  void replaceEvidence(
    String findingId,
    String evidenceId, {
    required String version,
  }) {
    final FindingDraft draft = _require(findingId);
    final int index = draft.evidence.indexWhere(
      (e) => e.evidenceId == evidenceId,
    );
    if (index < 0) {
      throw ArgumentError.value(
        evidenceId,
        'evidenceId',
        'Not on this finding',
      );
    }
    if (draft.evidence[index].version == version) return;
    _update(
      draft._copyWith(
        evidence: [...draft.evidence]
          ..[index] = EvidenceVersion(evidenceId: evidenceId, version: version),
      ),
    );
  }

  bool removeEvidence(String findingId, String evidenceId) {
    final FindingDraft draft = _require(findingId);
    final List<EvidenceVersion> kept = draft.evidence
        .where((e) => e.evidenceId != evidenceId)
        .toList();
    if (kept.length == draft.evidence.length) return false;
    _update(draft._copyWith(evidence: kept));
    return true;
  }

  void setMeasurement(
    String findingId,
    String type,
    MeasurementInput input, {
    MeasurementMethod method = MeasurementMethod.manual,
  }) {
    final FindingDraft draft = _require(findingId);
    if (measurementFieldSpecFor(type) == null) {
      throw ArgumentError.value(type, 'type', 'Not a known measurement type');
    }
    final RecordedMeasurement? existing = draft.measurementOf(type);
    if (existing != null &&
        existing.input == input &&
        existing.method == method) {
      return;
    }
    final next = RecordedMeasurement._(
      type: type,
      input: input,
      method: method,
      confirmed: false,
      recordedAt: _clock().toUtc().toIso8601String(),
    );
    if (existing != null) {
      _recordChange(findingId, existing, MeasurementChangeKind.corrected);
    }
    _update(
      draft._copyWith(
        measurements: existing == null
            ? [...draft.measurements, next]
            : [
                for (final RecordedMeasurement m in draft.measurements)
                  m.type == type ? next : m,
              ],
      ),
    );
  }

  bool clearMeasurement(String findingId, String type) {
    final FindingDraft draft = _require(findingId);
    final RecordedMeasurement? existing = draft.measurementOf(type);
    if (existing == null) return false;
    _recordChange(findingId, existing, MeasurementChangeKind.cleared);
    _update(
      draft._copyWith(
        measurements: draft.measurements.where((m) => m.type != type).toList(),
      ),
    );
    return true;
  }

  bool confirmMeasurement(String findingId, String type) {
    final FindingDraft draft = _require(findingId);
    final RecordedMeasurement? existing = draft.measurementOf(type);
    if (existing == null) return false;
    if (existing.confirmed) return true;
    _drafts[findingId] = draft._copyWith(
      measurements: [
        for (final RecordedMeasurement m in draft.measurements)
          m.type == type ? m._withConfirmed(true) : m,
      ],
    );
    notifyListeners();
    return true;
  }

  ReviewOutcome confirm(String findingId) =>
      _notifying(_tracker.confirm(findingId, _require(findingId).snapshot));

  ReviewOutcome dismiss(String findingId) {
    _require(findingId);
    return _notifying(_tracker.dismiss(findingId));
  }

  ReviewOutcome restore(String findingId) {
    _require(findingId);
    return _notifying(_tracker.restore(findingId));
  }

  ReviewOutcome requestAnotherView(String findingId) {
    _require(findingId);
    return _notifying(_tracker.requestAnotherView(findingId));
  }

  Finding? toFinding(String findingId) {
    final FindingDraft draft = _require(findingId);
    final String observation = draft.observation.trim();
    if (observation.isEmpty) return null;
    return Finding.fromJson({
      'id': draft.id,
      'room': draft.area.roomWireValue,
      'observation': observation,
      'reviewState': _tracker.reviewOf(findingId)!.state.wireValue,
      'evidenceIds': [for (final e in draft.evidence) e.evidenceId],
      'measurements': [for (final m in draft.measurements) m.toV1Json()],
    });
  }

  List<Finding> get findings =>
      List.unmodifiable(_drafts.keys.map(toFinding).whereType<Finding>());

  List<String> get incompleteFindingIds => List.unmodifiable(
    _drafts.values.where((d) => d.observation.trim().isEmpty).map((d) => d.id),
  );

  FindingDraft? removeFinding(String findingId) {
    final FindingDraft? removed = _drafts.remove(findingId);
    if (removed == null) return null;
    _tracker.forget(findingId);
    _measurementHistory.removeWhere(
      (key, _) => key.startsWith('$findingId\u0000'),
    );
    _removedFindingIds.add(findingId);
    notifyListeners();
    return removed;
  }

  void clear() {
    _drafts.clear();
    _issuedFindingIds.clear();
    _issuedEvidenceIds.clear();
    _reservedFindingIds.clear();
    _reservedEvidenceIds.clear();
    _measurementHistory.clear();
    _removedFindingIds.clear();
    _tracker.clear();
    notifyListeners();
  }

  Map<String, Object?> metadataFor(List<Finding> replacement) => {
    'measurements': [
      for (final finding in replacement)
        for (final measurement in finding.measurements)
          _measurementMetadata(finding.id, measurement),
    ],
    'reviews': [
      for (final finding in replacement)
        {'findingId': finding.id, 'state': finding.reviewState, 'note': null},
    ],
  };

  Map<String, Object?> _measurementMetadata(
    String findingId,
    Measurement wire,
  ) {
    final local = _drafts[findingId]?.measurementOf(wire.type);
    final known =
        local != null &&
        local.originalInputKnown &&
        local.input.millimetres == wire.value;
    return {
      'findingId': findingId,
      'type': wire.type,
      'originalText': known ? local.input.originalText : null,
      'originalUnit': known ? local.input.unit.symbol : null,
      'decimalSeparator': known ? local.input.decimalSeparator.name : null,
      'source': known ? local.method.wireValue : 'legacy_unknown',
      'recorder': known ? local.recorder : 'unknown',
      'recordedAt': known ? local.recordedAt : null,
    };
  }

  void hydrate(
    CaseSnapshot saved, {
    required Map<String, String> evidenceVersions,
    Map<String, Object?>? metadata,
  }) {
    clear();
    final originals = <String, Map<String, Object?>>{};
    for (final value in (metadata?['measurements'] as List? ?? const [])) {
      final item = Map<String, Object?>.from(value as Map);
      originals[_historyKey(
            item['findingId'] as String,
            item['type'] as String,
          )] =
          item;
    }
    for (final finding in saved.findings) {
      _issuedFindingIds.add(finding.id);
      _issuedEvidenceIds.addAll(finding.evidenceIds);
      final area = AssessmentArea.values
          .where((a) => a.roomWireValue == finding.room)
          .firstOrNull;
      if (area == null) continue;
      if (finding.measurements.map((m) => m.type).toSet().length !=
          finding.measurements.length) {
        throw const FormatException('Duplicate measurement types need review');
      }
      final measurements = <RecordedMeasurement>[];
      var metadataChanged = false;
      for (final wire in finding.measurements) {
        final original = originals[_historyKey(finding.id, wire.type)];
        var input = MeasurementInput.fromSavedMillimetres(wire.value);
        var known = false;
        if (original?['originalText'] is String &&
            original?['originalUnit'] is String) {
          try {
            input = MeasurementInput.fromLocalJson({
              'originalText': original!['originalText'],
              'unit': original['originalUnit'],
              'decimalSeparator': original['decimalSeparator'],
              'millimetres': wire.value,
            });
            known = original['source'] == wire.method;
            if (!known) metadataChanged = true;
          } on FormatException {
            input = MeasurementInput.fromSavedMillimetres(wire.value);
            metadataChanged = true;
          }
        }
        measurements.add(
          RecordedMeasurement._(
            type: wire.type,
            input: input,
            method: wire.method == 'manual'
                ? MeasurementMethod.manual
                : MeasurementMethod.estimated,
            confirmed: wire.confirmed && !metadataChanged,
            originalInputKnown: known,
            recorder: original?['recorder'] as String? ?? 'unknown',
            recordedAt: original?['recordedAt'] as String?,
          ),
        );
      }
      final draft = FindingDraft._(
        id: finding.id,
        area: area,
        observation: finding.observation,
        evidence: [
          for (final id in finding.evidenceIds)
            EvidenceVersion(
              evidenceId: id,
              version: evidenceVersions[id] ?? 'missing',
            ),
        ],
        measurements: List.unmodifiable(measurements),
      );
      _drafts[finding.id] = draft;
      final missingEvidence = finding.evidenceIds.any(
        (id) => !evidenceVersions.containsKey(id),
      );
      _tracker.hydrate(
        findingId: finding.id,
        current: draft.snapshot,
        state: finding.reviewState == 'dismissed'
            ? FindingReviewState.dismissed
            : finding.reviewState == 'confirmed' &&
                  !missingEvidence &&
                  !metadataChanged
            ? FindingReviewState.confirmed
            : FindingReviewState.needsReview,
      );
    }
    notifyListeners();
  }

  Map<String, Object?> toLocalJson() => {
    'version': 1,
    'drafts': [
      for (final d in drafts)
        {
          'id': d.id,
          'area': d.area.name,
          'observation': d.observation,
          'evidence': [
            for (final e in d.evidence)
              {'id': e.evidenceId, 'version': e.version},
          ],
          'measurements': [
            for (final m in d.measurements) _localMeasurement(m),
          ],
          'review': {
            'state': reviewOf(d.id)!.state.name,
            'anotherViewRequested': reviewOf(d.id)!.anotherViewRequested,
            'history': [
              for (final e in reviewOf(d.id)!.history)
                {'kind': e.kind.name, 'at': e.at.toUtc().toIso8601String()},
            ],
          },
        },
    ],
    'measurementHistory': {
      for (final e in _measurementHistory.entries)
        e.key: [
          for (final h in e.value)
            {
              'kind': h.kind.name,
              'at': h.at.toUtc().toIso8601String(),
              'previous': _localMeasurement(h.previous),
            },
        ],
    },
    'issuedFindings': _issuedFindingIds.toList(),
    'issuedEvidence': _issuedEvidenceIds.toList(),
    'reservedFindings': _reservedFindingIds.toList(),
    'reservedEvidence': _reservedEvidenceIds.toList(),
    'removedFindings': _removedFindingIds.toList(),
  };

  Map<String, Object?> _localMeasurement(RecordedMeasurement m) => {
    'type': m.type,
    'input': m.input.toLocalJson(),
    'method': m.method.name,
    'confirmed': m.confirmed,
    'originalInputKnown': m.originalInputKnown,
    'recorder': m.recorder,
    'recordedAt': m.recordedAt,
  };

  RecordedMeasurement _restoreMeasurement(Map<String, Object?> value) {
    final known = value['originalInputKnown'] == true;
    final input = Map<String, Object?>.from(value['input'] as Map);
    return RecordedMeasurement._(
      type: value['type'] as String,
      input: known
          ? MeasurementInput.fromLocalJson(input)
          : MeasurementInput.fromSavedMillimetres(input['millimetres'] as num),
      method: MeasurementMethod.values.byName(value['method'] as String),
      confirmed: value['confirmed'] == true,
      originalInputKnown: known,
      recorder: value['recorder'] as String? ?? 'unknown',
      recordedAt: value['recordedAt'] as String?,
    );
  }

  void restoreLocal(Map<String, Object?> value) {
    if (value['version'] != 1) {
      throw const FormatException('Unsupported assessment draft');
    }
    clear();
    for (final raw in value['drafts'] as List) {
      final d = Map<String, Object?>.from(raw as Map);
      final draft = FindingDraft._(
        id: d['id'] as String,
        area: AssessmentArea.values.byName(d['area'] as String),
        observation: d['observation'] as String,
        evidence: [
          for (final raw in d['evidence'] as List)
            EvidenceVersion(
              evidenceId: (raw as Map)['id'] as String,
              version: raw['version'] as String,
            ),
        ],
        measurements: [
          for (final raw in d['measurements'] as List)
            _restoreMeasurement(Map<String, Object?>.from(raw as Map)),
        ],
      );
      _drafts[draft.id] = draft;
      final review = d['review'] as Map;
      _tracker.hydrate(
        findingId: draft.id,
        state: FindingReviewState.values.byName(review['state'] as String),
        current: draft.snapshot,
        anotherViewRequested: review['anotherViewRequested'] == true,
        history: [
          for (final raw in review['history'] as List)
            ReviewEvent(
              ReviewEventKind.values.byName((raw as Map)['kind'] as String),
              DateTime.parse(raw['at'] as String).toUtc(),
            ),
        ],
      );
    }
    for (final entry in (value['measurementHistory'] as Map).entries) {
      _measurementHistory[entry.key as String] = [
        for (final raw in entry.value as List)
          MeasurementChange(
            kind: MeasurementChangeKind.values.byName(
              (raw as Map)['kind'] as String,
            ),
            previous: _restoreMeasurement(
              Map<String, Object?>.from(raw['previous'] as Map),
            ),
            at: DateTime.parse(raw['at'] as String).toUtc(),
          ),
      ];
    }
    _issuedFindingIds.addAll((value['issuedFindings'] as List).cast<String>());
    _issuedEvidenceIds.addAll((value['issuedEvidence'] as List).cast<String>());
    _reservedFindingIds.addAll(
      (value['reservedFindings'] as List? ?? const []).cast<String>(),
    );
    _reservedEvidenceIds.addAll(
      (value['reservedEvidence'] as List? ?? const []).cast<String>(),
    );
    if (_reservedFindingIds.length > 1 ||
        _reservedEvidenceIds.length > 1 ||
        !_issuedFindingIds.containsAll(_reservedFindingIds) ||
        !_issuedEvidenceIds.containsAll(_reservedEvidenceIds) ||
        _reservedFindingIds.any(_drafts.containsKey) ||
        drafts.any(
          (d) => d.evidence.any(
            (e) => _reservedEvidenceIds.contains(e.evidenceId),
          ),
        )) {
      throw const FormatException('Invalid reserved capture identifiers');
    }
    _removedFindingIds.addAll(
      (value['removedFindings'] as List).cast<String>(),
    );
    notifyListeners();
  }

  FindingDraft _require(String findingId) =>
      _drafts[findingId] ??
      (throw ArgumentError.value(findingId, 'findingId', 'Unknown finding'));

  void _update(FindingDraft next) {
    _drafts[next.id] = next;
    _tracker.contentChanged(next.id, next.snapshot);
    notifyListeners();
  }

  ReviewOutcome _notifying(ReviewOutcome outcome) {
    if (outcome.applied) notifyListeners();
    return outcome;
  }

  void _recordChange(
    String findingId,
    RecordedMeasurement previous,
    MeasurementChangeKind kind,
  ) {
    (_measurementHistory[_historyKey(findingId, previous.type)] ??= []).add(
      MeasurementChange(kind: kind, previous: previous, at: _clock()),
    );
  }

  static String _historyKey(String findingId, String type) =>
      '$findingId\u0000$type';

  static String _issue(String id, Set<String> issued) {
    ExportContractValues.id(id);
    if (!issued.add(id)) {
      throw StateError('IdFactory returned an ID it had already issued.');
    }
    return id;
  }

  static String _reserve(String id, Set<String> issued, Set<String> reserved) {
    if (issued.length >= 4096) throw const CaptureCapacityException();
    if (reserved.isNotEmpty) throw StateError('Another capture is reserved.');
    reserved.add(_issue(id, issued));
    return id;
  }

  static String _consume(String id, Set<String> reserved) {
    if (!reserved.remove(id)) throw StateError('Capture identifier expired.');
    return id;
  }
}

num _wireNumber(double value) =>
    value == value.truncateToDouble() && value.abs() < 9007199254740992
    ? value.toInt()
    : value;
