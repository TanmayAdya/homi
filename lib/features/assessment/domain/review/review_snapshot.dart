import 'dart:collection';
import 'dart:convert';

import '../../../../shared/models/contracts.dart';

final class EvidenceVersion {
  const EvidenceVersion({required this.evidenceId, required this.version});
  final String evidenceId;
  final String version;
}

final class ReviewSnapshot {
  factory ReviewSnapshot({
    required String observation,
    required Iterable<EvidenceVersion> evidence,
    required Iterable<Map<String, Object?>> measurements,
    Set<String> ignoredMeasurementKeys = const {'confirmed'},
  }) {
    final String trimmedObservation = observation.trim();

    final List<List<String>> evidenceEntries =
        evidence.map((e) => [e.evidenceId, e.version]).toList()..sort((a, b) {
          final int byId = a[0].compareTo(b[0]);
          return byId != 0 ? byId : a[1].compareTo(b[1]);
        });

    final List<String> measurementEntries =
        measurements
            .map(
              (m) => jsonEncode(
                _canonicalise({
                  for (final entry in m.entries)
                    if (!ignoredMeasurementKeys.contains(entry.key))
                      entry.key: entry.value,
                }),
              ),
            )
            .toList()
          ..sort();

    final String canonical = jsonEncode({
      'evidence': evidenceEntries,
      'measurements': measurementEntries,
      'observation': trimmedObservation,
    });
    return ReviewSnapshot._(canonical, trimmedObservation);
  }

  factory ReviewSnapshot.fromFinding(
    Finding finding, {
    required Map<String, String> evidenceVersions,
  }) {
    return ReviewSnapshot(
      observation: finding.observation,
      evidence: [
        for (final String id in finding.evidenceIds)
          EvidenceVersion(
            evidenceId: id,
            version:
                evidenceVersions[id] ??
                (throw ArgumentError.value(
                  id,
                  'evidenceVersions',
                  'No version for this evidence ID',
                )),
          ),
      ],
      measurements: finding.measurements.map((m) => m.toJson()),
    );
  }

  factory ReviewSnapshot.fromCanonical(String canonical) {
    final decoded = jsonDecode(canonical);
    if (decoded is! Map<String, Object?> || decoded['observation'] is! String) {
      throw const FormatException('Malformed review snapshot.');
    }
    return ReviewSnapshot._(canonical, decoded['observation']! as String);
  }
  ReviewSnapshot._(this.canonical, this.observation);

  final String canonical;

  final String observation;

  bool get hasObservation => observation.isNotEmpty;

  @override
  bool operator ==(Object other) =>
      other is ReviewSnapshot && other.canonical == canonical;

  @override
  int get hashCode => canonical.hashCode;
}

Object? _canonicalise(Object? value) {
  if (value is Map) {
    final sorted = SplayTreeMap<String, Object?>();
    value.forEach((key, v) => sorted[key.toString()] = _canonicalise(v));
    return sorted;
  }
  if (value is List) return value.map(_canonicalise).toList();
  if (value is double &&
      value.isFinite &&
      value == value.truncateToDouble() &&
      value.abs() < 9007199254740992) {
    return value.toInt();
  }
  return value;
}
