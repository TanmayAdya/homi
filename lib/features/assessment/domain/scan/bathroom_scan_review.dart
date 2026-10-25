import 'bathroom_scan_scene.dart';
import 'scan_suggestions.dart';
import '../home_safety/home_safety.dart';
import '../../../../shared/models/case_draft.dart';

class BathroomScanReview {
  BathroomScanReview({
    this.scene,
    this.pendingScanId,
    Set<String> reviewed = const {},
    Map<String, ScanElementKind> labels = const {},
    Set<ScanDifficulty> difficulties = const {},
    Set<String> dismissed = const {},
  }) : reviewed = Set.unmodifiable(reviewed),
       labels = Map.unmodifiable(labels),
       difficulties = Set.unmodifiable(difficulties),
       dismissed = Set.unmodifiable(dismissed);

  final BathroomScanScene? scene;
  final String? pendingScanId;
  final Set<String> reviewed, dismissed;
  final Map<String, ScanElementKind> labels;
  final Set<ScanDifficulty> difficulties;

  BathroomScanReview copyWith({
    String? pendingScanId,
    bool clearPending = false,
    Set<String>? reviewed,
    Map<String, ScanElementKind>? labels,
    Set<ScanDifficulty>? difficulties,
    Set<String>? dismissed,
  }) => BathroomScanReview(
    scene: scene,
    pendingScanId: clearPending ? null : pendingScanId ?? this.pendingScanId,
    reviewed: reviewed ?? this.reviewed,
    labels: labels ?? this.labels,
    difficulties: difficulties ?? this.difficulties,
    dismissed: dismissed ?? this.dismissed,
  );

  Map<String, Object?> toJson(String caseId, {RoomInstance? room}) => {
    'version': room == null ? 1 : 2,
    'caseId': caseId,
    if (room != null) 'roomId': room.id,
    if (room != null) 'roomType': room.type.name,
    'scene': scene?.toJson(),
    'pendingScanId': pendingScanId,
    'reviewed': reviewed.toList()..sort(),
    'labels': {for (final e in labels.entries) e.key: e.value.name},
    'difficulties': difficulties.map((e) => e.name).toList()..sort(),
    'dismissed': dismissed.toList()..sort(),
  };

  factory BathroomScanReview.fromJson(
    Object? raw,
    String caseId, {
    RoomInstance? room,
  }) {
    if (raw is! Map ||
        raw['version'] is! int ||
        raw['version'] != (room == null ? 1 : 2) ||
        raw['caseId'] != caseId ||
        (room != null &&
            (raw['roomId'] != room.id || raw['roomType'] != room.type.name)) ||
        raw.keys.length != (room == null ? 8 : 10) ||
        raw.keys.any(
          (key) => !{
            'version',
            'caseId',
            'scene',
            'pendingScanId',
            'reviewed',
            'labels',
            'difficulties',
            'dismissed',
            if (room != null) 'roomId',
            if (room != null) 'roomType',
          }.contains(key),
        )) {
      throw const FormatException('Invalid private scan review.');
    }
    final scene = raw['scene'] == null
        ? null
        : BathroomScanScene.fromJson(raw['scene']);
    final pending = raw['pendingScanId'];
    if (pending != null && (pending is! String || !isCaseUuidV4(pending))) {
      throw const FormatException('Invalid pending scan.');
    }
    Set<String> strings(Object? value, int maximum) {
      if (value is! List ||
          value.length > maximum ||
          value.any((e) => e is! String) ||
          value.toSet().length != value.length) {
        throw const FormatException('Invalid private scan selection.');
      }
      return value.cast<String>().toSet();
    }

    final ids = scene?.elements.map((e) => e.id).toSet() ?? <String>{};
    final reviewed = strings(raw['reviewed'], 256);
    final labels = raw['labels'];
    final dismissed = strings(raw['dismissed'], 256);
    if (!ids.containsAll(reviewed) ||
        labels is! Map ||
        labels.length > 256 ||
        !ids.containsAll(labels.keys) ||
        dismissed.any(
          (id) => !RegExp(r'^[a-zA-Z0-9_.:-]{1,128}$').hasMatch(id),
        )) {
      throw const FormatException('Scan review has invalid bindings.');
    }
    try {
      return BathroomScanReview(
        scene: scene,
        pendingScanId: pending as String?,
        reviewed: reviewed,
        labels: {
          for (final e in labels.entries)
            e.key as String: ScanElementKind.values.byName(e.value as String),
        },
        difficulties: strings(
          raw['difficulties'],
          ScanDifficulty.values.length,
        ).map(ScanDifficulty.values.byName).toSet(),
        dismissed: dismissed,
      );
    } catch (_) {
      throw const FormatException('Invalid private scan review values.');
    }
  }
}
