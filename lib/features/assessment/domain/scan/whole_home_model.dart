import 'dart:math' as math;

import 'bathroom_scan_scene.dart';
import '../../../../shared/models/export_contract_values.dart';

class RoomPose {
  RoomPose({this.x = 0, this.y = 0, this.z = 0, this.yaw = 0}) {
    if (![x, y, z, yaw].every((v) => v.isFinite) ||
        [x, y, z].any((v) => v.abs() > 100) ||
        yaw.abs() > 180) {
      throw const FormatException('Invalid room placement.');
    }
  }
  final double x, y, z, yaw;
  ScanVector3 apply(ScanVector3 p) {
    final angle = yaw * math.pi / 180;
    return ScanVector3(
      x + math.cos(angle) * p.x + math.sin(angle) * p.z,
      y + p.y,
      z - math.sin(angle) * p.x + math.cos(angle) * p.z,
    );
  }

  RoomPose compose(RoomPose child) {
    final p = apply(ScanVector3(child.x, child.y, child.z));
    final angle = ((yaw + child.yaw + 180) % 360) - 180;
    return RoomPose(x: p.x, y: p.y, z: p.z, yaw: angle);
  }

  bool get isIdentity => x == 0 && y == 0 && z == 0 && yaw == 0;
  Map<String, Object?> toJson() => {'x': x, 'y': y, 'z': z, 'yaw': yaw};
  factory RoomPose.fromJson(Object? raw) {
    final v = _object(raw, {'x', 'y', 'z', 'yaw'});
    double n(String k) =>
        v[k] is num ? (v[k] as num).toDouble() : throw const FormatException();
    return RoomPose(x: n('x'), y: n('y'), z: n('z'), yaw: n('yaw'));
  }
}

class PlacedRoomScene {
  const PlacedRoomScene(this.roomId, this.scene, this.pose);
  final String roomId;
  final BathroomScanScene scene;
  final RoomPose pose;
  String featureId(String id) =>
      '${Uri.encodeComponent(roomId)}/${Uri.encodeComponent(id)}';

  List<double>? get bounds {
    final all = [
      for (final e in scene.elements) ...e.worldCorners.map(pose.apply),
      for (final p in scene.points) pose.apply(p.position),
      for (final m in scene.measurements) ...[
        pose.apply(m.start),
        pose.apply(m.end),
      ],
    ];
    if (all.isEmpty) return null;
    final v = [
      all.first.x,
      all.first.x,
      all.first.y,
      all.first.y,
      all.first.z,
      all.first.z,
    ];
    for (final p in all) {
      v[0] = math.min(v[0], p.x);
      v[1] = math.max(v[1], p.x);
      v[2] = math.min(v[2], p.y);
      v[3] = math.max(v[3], p.y);
      v[4] = math.min(v[4], p.z);
      v[5] = math.max(v[5], p.z);
    }
    return List.unmodifiable(v);
  }
}

class HomeRoomPlacement {
  HomeRoomPlacement({
    required this.roomId,
    required this.fingerprint,
    required this.pose,
    required this.reviewed,
    this.parentId,
    this.parentFingerprint,
    this.baselineFingerprint,
  }) {
    _id(roomId);
    _fingerprint(fingerprint);
    if (parentId != null) {
      _id(parentId!);
      _fingerprint(parentFingerprint);
    }
    if (parentId == null && parentFingerprint != null) {
      throw const FormatException();
    }
    if (baselineFingerprint != null) _fingerprint(baselineFingerprint);
  }
  final String roomId, fingerprint;
  final String? parentId, parentFingerprint, baselineFingerprint;
  final RoomPose pose;
  final bool reviewed;
  Map<String, Object?> toJson() => {
    'roomId': roomId,
    'fingerprint': fingerprint,
    'parentId': parentId,
    'parentFingerprint': parentFingerprint,
    'baselineFingerprint': baselineFingerprint,
    'pose': pose.toJson(),
    'reviewed': reviewed,
  };
  factory HomeRoomPlacement.fromJson(Object? raw) {
    final v = _object(raw, {
      'roomId',
      'fingerprint',
      'parentId',
      'parentFingerprint',
      'baselineFingerprint',
      'pose',
      'reviewed',
    });
    if (v['reviewed'] is! bool) throw const FormatException();
    return HomeRoomPlacement(
      roomId: v['roomId'] as String,
      fingerprint: v['fingerprint'] as String,
      parentId: v['parentId'] as String?,
      parentFingerprint: v['parentFingerprint'] as String?,
      baselineFingerprint: v['baselineFingerprint'] as String?,
      pose: RoomPose.fromJson(v['pose']),
      reviewed: v['reviewed'] as bool,
    );
  }
}

class WholeHomeModel {
  WholeHomeModel({
    required this.referenceRoomId,
    required this.method,
    required List<HomeRoomPlacement> rooms,
    Map<String, BathroomScanScene> captures = const {},
    this.mergedScene,
  }) : rooms = List.unmodifiable(rooms),
       captures = Map.unmodifiable(captures) {
    if (!{
          'reviewed_alignment',
          'roomplan_shared_frame',
          'arcore_shared_frame',
        }.contains(method) ||
        rooms.isEmpty ||
        rooms.length > 32 ||
        rooms.map((r) => r.roomId).toSet().length != rooms.length) {
      throw const FormatException('Invalid home model.');
    }
    final root = rooms.where((r) => r.roomId == referenceRoomId).singleOrNull;
    if (root == null || root.parentId != null || !root.pose.isIdentity) {
      throw const FormatException('Invalid reference room.');
    }
    for (final r in rooms) {
      if (r.roomId != referenceRoomId && r.parentId == null) {
        throw const FormatException();
      }
      globalPose(r.roomId);
    }
    if (method == 'reviewed_alignment') {
      if (captures.isNotEmpty ||
          mergedScene != null ||
          rooms.any((r) => r.baselineFingerprint != null)) {
        throw const FormatException();
      }
    } else {
      if (rooms.length < 2 ||
          rooms.length > 8 ||
          captures.length != rooms.length ||
          mergedScene == null ||
          mergedScene!.source !=
              (method == 'arcore_shared_frame'
                  ? ScanSource.arcore
                  : ScanSource.roomplan) ||
          rooms.any(
            (r) =>
                !r.pose.isIdentity ||
                captures[r.roomId]?.fingerprint != r.fingerprint ||
                captures[r.roomId]?.source != mergedScene!.source,
          )) {
        throw const FormatException('Invalid shared-frame model.');
      }
    }
  }
  final String referenceRoomId, method;
  final List<HomeRoomPlacement> rooms;
  final Map<String, BathroomScanScene> captures;
  final BathroomScanScene? mergedScene;
  HomeRoomPlacement room(String id) => rooms.firstWhere((r) => r.roomId == id);
  RoomPose globalPose(String id, [Set<String>? seen]) {
    final visited = {...?seen};
    if (!visited.add(id)) throw const FormatException('Room connection cycle.');
    final found = rooms.where((r) => r.roomId == id).singleOrNull;
    if (found == null) throw const FormatException('Missing connected room.');
    return found.parentId == null
        ? found.pose
        : globalPose(found.parentId!, visited).compose(found.pose);
  }

  List<PlacedRoomScene> resolve(
    Map<String, BathroomScanScene> saved,
    Set<String> activeRoomIds,
  ) {
    final accepted = <String, bool>{};
    bool usable(String id) => accepted.putIfAbsent(id, () {
      final r = room(id),
          scene = method == 'reviewed_alignment' ? saved[id] : captures[id];
      return activeRoomIds.contains(id) &&
          r.reviewed &&
          scene?.fingerprint == r.fingerprint &&
          (method == 'reviewed_alignment' ||
              saved[id]?.fingerprint == r.baselineFingerprint) &&
          (r.parentId == null ||
              room(r.parentId!).fingerprint == r.parentFingerprint &&
                  usable(r.parentId!));
    });
    final result = <PlacedRoomScene>[
      for (final r in rooms)
        if (usable(r.roomId))
          PlacedRoomScene(
            r.roomId,
            method == 'reviewed_alignment'
                ? saved[r.roomId]!
                : captures[r.roomId]!,
            globalPose(r.roomId),
          ),
    ];
    if (result.fold<int>(0, (n, r) => n + r.scene.elements.length) > 2048 ||
        result.fold<int>(0, (n, r) => n + r.scene.points.length) > 8192) {
      throw const FormatException(
        'Use fewer rooms or smaller scans in this model.',
      );
    }
    return List.unmodifiable(result);
  }

  Map<String, Object?> toJson(String caseId) => {
    'version': 1,
    'caseId': caseId,
    'method': method,
    'referenceRoomId': referenceRoomId,
    'rooms': rooms.map((r) => r.toJson()).toList(),
    'captures': {for (final e in captures.entries) e.key: e.value.toJson()},
    'mergedScene': mergedScene?.toJson(),
  };
  factory WholeHomeModel.fromJson(Object? raw, String caseId) {
    final v = _object(raw, {
      'version',
      'caseId',
      'method',
      'referenceRoomId',
      'rooms',
      'captures',
      'mergedScene',
    });
    if (v['version'] != 1 ||
        v['caseId'] != caseId ||
        v['rooms'] is! List ||
        (v['rooms'] as List).length > 32 ||
        v['captures'] is! Map ||
        (v['captures'] as Map).length > 8) {
      throw const FormatException('Invalid private home model.');
    }
    return WholeHomeModel(
      referenceRoomId: v['referenceRoomId'] as String,
      method: v['method'] as String,
      rooms: (v['rooms'] as List).map(HomeRoomPlacement.fromJson).toList(),
      captures: {
        for (final e in (v['captures'] as Map).entries)
          e.key as String: BathroomScanScene.fromJson(e.value),
      },
      mergedScene: v['mergedScene'] == null
          ? null
          : BathroomScanScene.fromJson(v['mergedScene']),
    );
  }
}

Map<String, Object?> _object(Object? raw, Set<String> keys) {
  if (raw is! Map || raw.length != keys.length || !keys.containsAll(raw.keys)) {
    throw const FormatException('Invalid home model record.');
  }
  return Map<String, Object?>.from(raw);
}

void _id(String id) {
  ExportContractValues.id(id);
}

void _fingerprint(Object? value) {
  if (value is! String || !RegExp(r'^[a-f0-9]{64}$').hasMatch(value)) {
    throw const FormatException();
  }
}
