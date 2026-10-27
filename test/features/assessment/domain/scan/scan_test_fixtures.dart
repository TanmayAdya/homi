import 'dart:math' as math;

import 'package:safe_at_home/features/assessment/domain/scan/bathroom_scan_scene.dart';

Map<String, Object?> scanSceneJson({
  String source = 'roomplan',
  List<Map<String, Object?>>? elements,
  List<List<num>>? points,
}) => {
  'schemaVersion': source == 'arkit' ? 2 : 1,
  'scanId': 'd6a4a6b3-74cb-4fa9-9cc0-13710e793d32',
  'source': source,
  'sourceVersion': source == 'roomplan'
      ? 'RoomPlan test fixture'
      : source == 'arkit'
      ? 'ARKit camera test fixture'
      : 'ARCore test fixture',
  'capturedAt': '2026-10-23T12:00:00.000Z',
  'units': 'm',
  'coordinateSystem': 'right_handed_y_up',
  'coverage': 'partial',
  'truncated': false,
  'warnings': <String>[if (source == 'arkit') 'depth_unavailable'],
  'elements':
      elements ??
      [
        source == 'arkit'
            ? scanElementJson(
                id: 'plane-1',
                kind: 'unknown',
                nativeCategory: 'horizontal',
                dimensions: [2, 0, 3],
                confidence: 'unknown',
              )
            : scanElementJson(),
      ],
  'points': points ?? <List<num>>[],
  if (source == 'arkit') 'measurements': <Map<String, Object?>>[],
};

Map<String, Object?> scanElementJson({
  String id = 'door-1',
  String kind = 'door',
  String? nativeCategory,
  List<num> dimensions = const [1, 2, 0],
  List<num>? transform,
  String confidence = 'high',
}) => {
  'id': id,
  'kind': kind,
  'nativeCategory': nativeCategory ?? kind,
  'dimensions': List<num>.of(dimensions),
  'transform': transform ?? scanTransform(y: 1),
  'classificationConfidence': confidence,
};

List<double> scanTransform({
  double x = 0,
  double y = 0,
  double z = 0,
  double yaw = 0,
}) => [
  math.cos(yaw),
  0,
  -math.sin(yaw),
  0,
  0,
  1,
  0,
  0,
  math.sin(yaw),
  0,
  math.cos(yaw),
  0,
  x,
  y,
  z,
  1,
];

BathroomScanScene fictionalScanScene({
  String source = 'roomplan',
  List<Map<String, Object?>>? elements,
  List<List<num>>? points,
}) => BathroomScanScene.fromJson(
  scanSceneJson(source: source, elements: elements, points: points),
);
