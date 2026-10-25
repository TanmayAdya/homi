import 'dart:math' as math;

import 'bathroom_scan_scene.dart';
import 'whole_home_model.dart';

final class ProjectedScanPoint {
  const ProjectedScanPoint({
    required this.x,
    required this.y,
    required this.depth,
    this.confidence,
  });
  final double x;
  final double y;
  final double depth;
  final double? confidence;
}

final class ProjectedScanFace {
  const ProjectedScanFace._({
    required this.elementId,
    required this.kind,
    required this.vertices,
    required this.depth,
  });
  final String elementId;
  final ScanElementKind kind;
  final List<ProjectedScanPoint> vertices;
  final double depth;
}

final class ScanProjection {
  const ScanProjection._({
    required this.faces,
    required this.points,
    required this.distances,
  });
  final List<(ProjectedScanPoint, ProjectedScanPoint)> distances;
  final List<ProjectedScanFace> faces;
  final List<ProjectedScanPoint> points;

  static ScanProjection project(
    BathroomScanScene scene, {
    required double width,
    required double height,
    double yaw = -.65,
    double pitch = .55,
    double padding = 24,
    List<PlacedRoomScene>? placedRooms,
  }) {
    if (![width, height, yaw, pitch, padding].every((v) => v.isFinite) ||
        width <= 0 ||
        height <= 0 ||
        width > 100000 ||
        height > 100000 ||
        padding < 0) {
      throw ArgumentError('Invalid scan review viewport');
    }
    if (placedRooms != null &&
        (placedRooms.isEmpty ||
            placedRooms.length > 32 ||
            placedRooms.map((r) => r.roomId).toSet().length !=
                placedRooms.length ||
            placedRooms.fold<int>(0, (n, r) => n + r.scene.elements.length) >
                2048 ||
            placedRooms.fold<int>(0, (n, r) => n + r.scene.points.length) >
                8192)) {
      throw ArgumentError('Invalid connected model viewport');
    }
    final sources = placedRooms ?? [PlacedRoomScene('', scene, RoomPose())];
    String idFor(PlacedRoomScene r, String id) =>
        placedRooms == null ? id : r.featureId(id);
    final cosYaw = math.cos(yaw), sinYaw = math.sin(yaw);
    final cosPitch = math.cos(pitch), sinPitch = math.sin(pitch);
    ScanVector3 rotate(ScanVector3 p) {
      final horizontal = cosYaw * p.x - sinYaw * p.z;
      final receding = sinYaw * p.x + cosYaw * p.z;
      return ScanVector3(
        horizontal,
        cosPitch * p.y - sinPitch * receding,
        sinPitch * p.y + cosPitch * receding,
      );
    }

    final elements = [
      for (final r in sources)
        for (final e in r.scene.elements) (idFor(r, e.id), e, r.pose),
    ];
    final corners = {
      for (final (id, e, pose) in elements)
        id: e.worldCorners.map(pose.apply).map(rotate).toList(),
    };
    final samples = [
      for (final r in sources)
        for (final p in r.scene.points)
          (rotate(r.pose.apply(p.position)), p.confidence),
    ];
    final rawPoints = samples.map((p) => p.$1).toList();
    final distances = [
      for (final r in sources)
        for (final m in r.scene.measurements)
          (rotate(r.pose.apply(m.start)), rotate(r.pose.apply(m.end))),
    ];
    final all = <ScanVector3>[
      for (final values in corners.values) ...values,
      ...rawPoints,
      for (final m in distances) ...[m.$1, m.$2],
    ];
    var minX = all.first.x, maxX = all.first.x;
    var minY = all.first.y, maxY = all.first.y;
    for (final p in all) {
      minX = math.min(minX, p.x);
      maxX = math.max(maxX, p.x);
      minY = math.min(minY, p.y);
      maxY = math.max(maxY, p.y);
    }
    final inset = math.min(padding, math.min(width, height) / 4);
    final spanX = maxX - minX, spanY = maxY - minY;
    final horizontalScale = spanX > 1e-9
        ? (width - 2 * inset) / spanX
        : double.infinity;
    final verticalScale = spanY > 1e-9
        ? (height - 2 * inset) / spanY
        : double.infinity;
    final fitScale = math.min(horizontalScale, verticalScale);
    final scale = fitScale.isFinite ? fitScale : 1.0;
    final centreX = (minX + maxX) / 2, centreY = (minY + maxY) / 2;
    ProjectedScanPoint toScreen(ScanVector3 p, [double? confidence]) =>
        ProjectedScanPoint(
          x: width / 2 + (p.x - centreX) * scale,
          y: height / 2 - (p.y - centreY) * scale,
          depth: p.z,
          confidence: confidence,
        );
    const faceIndices = [
      [0, 1, 3, 2],
      [4, 6, 7, 5],
      [0, 4, 5, 1],
      [2, 3, 7, 6],
      [0, 2, 6, 4],
      [1, 5, 7, 3],
    ];
    final faces = <ProjectedScanFace>[];
    for (final (id, element, _) in elements) {
      final indices = element.dimensions.x == 0
          ? [faceIndices[0]]
          : element.dimensions.y == 0
          ? [faceIndices[2]]
          : element.dimensions.z == 0
          ? [faceIndices[4]]
          : faceIndices;
      for (final index in indices) {
        final vertices = index.map((i) => toScreen(corners[id]![i])).toList();
        faces.add(
          ProjectedScanFace._(
            elementId: id,
            kind: element.kind,
            vertices: List.unmodifiable(vertices),
            depth:
                vertices.fold<double>(0, (sum, p) => sum + p.depth) /
                vertices.length,
          ),
        );
      }
    }
    faces.sort((a, b) => a.depth.compareTo(b.depth));
    return ScanProjection._(
      faces: List.unmodifiable(faces),
      distances: List.unmodifiable([
        for (final m in distances) (toScreen(m.$1), toScreen(m.$2)),
      ]),
      points: List.unmodifiable([
        for (var i = 0; i < rawPoints.length; i++)
          toScreen(rawPoints[i], samples[i].$2),
      ]),
    );
  }
}
