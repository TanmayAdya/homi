import 'dart:convert';
import 'dart:io';

import 'package:safe_at_home/features/assessment/domain/scan/scan_suggestions.dart';

import 'scan_test_fixtures.dart';

void main() {
  final scene = fictionalScanScene(
    elements: [
      for (var i = 0; i < 128; i++) scanElementJson(id: 'door-$i'),
      for (var i = 0; i < 128; i++)
        scanElementJson(
          id: 'item-$i',
          kind: 'furniture',
          dimensions: [.6, .8, .6],
          transform: scanTransform(x: 3, y: .4, z: 3),
        ),
    ],
  );
  final reviewed = scene.elements.map((e) => e.id).toSet();
  void exercise() {
    final suggestions = suggestBathroomImprovements(
      scene: scene,
      reviewedElementIds: reviewed,
      difficulties: {},
    );
    if (suggestions.isNotEmpty) throw StateError('Negative geometry changed');
  }

  for (var i = 0; i < 5; i++) {
    exercise();
  }
  const iterations = 25;
  final timer = Stopwatch()..start();
  for (var i = 0; i < iterations; i++) {
    exercise();
  }
  timer.stop();
  stdout.writeln(
    jsonEncode({
      'scenario': 'dense_negative_bathroom_scan',
      'elementCount': scene.elements.length,
      'maximumCandidatePairsPerCall': 128 * 128,
      'iterations': iterations,
      'elapsedMicroseconds': timer.elapsedMicroseconds,
      'suggestionsPerCall': 0,
      'interpretation':
          'Local Dart process timing; not physical-device latency acceptance',
    }),
  );
}
