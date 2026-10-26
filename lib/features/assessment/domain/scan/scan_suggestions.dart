import 'dart:convert';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';

import 'bathroom_scan_scene.dart';
import '../home_safety/home_safety.dart';
import '../assessment_location.dart';

const maxScanSuggestions = 20;

enum ScanDifficulty {
  enteringBathroom,
  bathing,
  toiletTransfer,
  sinkUse,
  movingAround;

  String labelFor(AssessmentLocation room) =>
      room == AssessmentLocation.bathroom
      ? label
      : switch (this) {
          enteringBathroom => 'Getting through the doorway',
          movingAround => 'Moving around this room',
          _ => label,
        };

  String get label => switch (this) {
    enteringBathroom => 'Getting through the bathroom doorway',
    bathing => 'Getting into or using the bath',
    toiletTransfer => 'Sitting down on or getting up from the toilet',
    sinkUse => 'Reaching or using the sink',
    movingAround => 'Moving around the bathroom',
  };
}

final class ScanSuggestion {
  ScanSuggestion._({
    required BathroomScanScene scene,
    this.room,
    required this.ruleId,
    required this.elementId,
    required List<String> relatedElementIds,
    required this.title,
    required this.detail,
    required this.nextAction,
    required this.basis,
  }) : relatedElementIds = List.unmodifiable(relatedElementIds),
       sceneFingerprint = scene.fingerprint,
       observation =
           '$detail Source: ${scene.sourceLabel} partial scan '
           '${scene.scanId}; resident-reviewed identification. '
           '${room == null ? '' : 'Room ID: ${room.id}; area: ${room.type.name}. '}'
           'Model elements: ${jsonEncode(relatedElementIds)}. '
           'Scene SHA-256: ${scene.fingerprint}. '
           'Rule $ruleId v$currentRuleVersion. Scan geometry is approximate; '
           'this is not a verified measurement or a professional determination.' {
    if (observation.length > 1200) {
      throw const FormatException(
        'Scan observation exceeds the draft text limit',
      );
    }
    id = sha256
        .convert(
          utf8.encode(
            jsonEncode([
              sceneFingerprint,
              ruleId,
              ruleVersion,
              relatedElementIds,
              observation,
            ]),
          ),
        )
        .toString();
  }

  late final String id;
  final String ruleId;
  final RoomInstance? room;
  static const currentRuleVersion = '1';
  String get ruleVersion => currentRuleVersion;
  final String sceneFingerprint;
  final String elementId;
  final List<String> relatedElementIds;
  final String title;

  final String detail;
  final String observation;
  final String nextAction;
  final String basis;

  String get limitations =>
      'This partial scan may miss objects, openings and '
      'surface details. Confirm the concern in the room. It does not establish '
      'safe clearance, structural capacity, clinical need or funding eligibility.';
}

final class ScanSuggestionCandidate {
  const ScanSuggestionCandidate._(this._proposal);
  final ScanSuggestion _proposal;
  String get id => _proposal.id;
  String get title => _proposal.title;
  String get detail => _proposal.detail;
  String get nextAction => _proposal.nextAction;
  String get basis => _proposal.basis;
  List<String> get relatedElementIds => _proposal.relatedElementIds;
}

List<ScanSuggestionCandidate> previewBathroomImprovements({
  required BathroomScanScene scene,
  RoomInstance? room,
  required Set<ScanDifficulty> difficulties,
  Map<String, ScanElementKind> identifiedKinds = const {},
}) => List.unmodifiable([
  for (final proposal in suggestBathroomImprovements(
    scene: scene,
    room: room,
    reviewedElementIds: {for (final element in scene.elements) element.id},
    difficulties: difficulties,
    identifiedKinds: identifiedKinds,
  ))
    ScanSuggestionCandidate._(proposal),
]);

List<ScanSuggestion> suggestBathroomImprovements({
  required BathroomScanScene scene,
  RoomInstance? room,
  required Set<String> reviewedElementIds,
  required Set<ScanDifficulty> difficulties,
  Map<String, ScanElementKind> identifiedKinds = const {},
}) {
  if (reviewedElementIds.any((id) => scene.elementById(id) == null) ||
      identifiedKinds.keys.any((id) => !reviewedElementIds.contains(id))) {
    throw ArgumentError('Review must refer to the current scan elements');
  }
  final bathroom = room == null || room.type == AssessmentLocation.bathroom;
  ScanElementKind kindOf(ScanElement element) =>
      identifiedKinds[element.id] ?? element.kind;
  final reviewed =
      scene.elements.where((e) => reviewedElementIds.contains(e.id)).toList()
        ..sort((a, b) => a.id.compareTo(b.id));
  final suggestions = <ScanSuggestion>[];
  for (final element in reviewed) {
    final kind = kindOf(element);
    final hasUserLabel = identifiedKinds.containsKey(element.id);
    final basis =
        '${hasUserLabel ? 'Your identification' : 'Reviewed scanner identification'}: '
        '${kind.label.toLowerCase()}. The scan dimensions describe model extents, '
        'not usable clearances.';
    void add({
      required String rule,
      required String title,
      required String detail,
      required String action,
    }) {
      if (suggestions.length == maxScanSuggestions) return;
      suggestions.add(
        ScanSuggestion._(
          scene: scene,
          room: room,
          ruleId: rule,
          elementId: element.id,
          relatedElementIds: [element.id],
          title: title,
          detail: detail,
          nextAction: action,
          basis: basis,
        ),
      );
    }

    if ((kind == ScanElementKind.door || kind == ScanElementKind.opening) &&
        difficulties.contains(ScanDifficulty.enteringBathroom)) {
      add(
        rule: bathroom ? 'bathroom.doorway_report' : 'room.doorway_report',
        title: bathroom
            ? 'Make the bathroom entrance easier to use'
            : 'Make the doorway easier to use',
        detail: bathroom
            ? 'Resident reports difficulty getting through the bathroom entry and has identified this doorway or opening in the scan.'
            : 'Resident reports difficulty getting through this room’s entry and has identified this doorway or opening in the scan.',
        action:
            'Check the actual clear opening, door movement and approach in '
            'person. Discuss suitable access changes with a qualified assessor; '
            'model width is not the clear opening.',
      );
    }
    if (bathroom &&
        kind == ScanElementKind.bathtub &&
        difficulties.contains(ScanDifficulty.bathing)) {
      add(
        rule: 'bathroom.bathing_report',
        title: 'Explore bathing access and grab-bar support',
        detail:
            'Resident reports difficulty getting into or using the bath '
            'and has identified the bathtub in the scan.',
        action:
            'Discuss grab bars, bathing access and transfer needs '
            'with a qualified assessor. The scan cannot verify suitable support '
            'placement or structural fixings.',
      );
    }
    if (bathroom &&
        kind == ScanElementKind.toilet &&
        difficulties.contains(ScanDifficulty.toiletTransfer)) {
      add(
        rule: 'bathroom.toilet_report',
        title: 'Explore support for sitting and standing',
        detail:
            'Resident reports difficulty sitting down on or getting up '
            'from the toilet and has identified the toilet in the scan.',
        action:
            'Discuss grab bars or other transfer supports and their '
            'placement with a qualified assessor. Do not install supports '
            'based on this model alone.',
      );
    }
    if ((bathroom || room.type == AssessmentLocation.kitchen) &&
        kind == ScanElementKind.sink &&
        difficulties.contains(ScanDifficulty.sinkUse)) {
      add(
        rule: bathroom ? 'bathroom.sink_report' : 'room.sink_report',
        title: 'Make the sink easier to reach',
        detail:
            'Resident reports difficulty reaching or using the sink '
            'and has identified the sink in the scan.',
        action:
            'Check reach, approach and the resident\'s usual way of using '
            'the sink in person. Discuss appropriate changes with an assessor.',
      );
    }
    if (suggestions.length == maxScanSuggestions) {
      return List.unmodifiable(suggestions);
    }
  }
  if (difficulties.contains(ScanDifficulty.movingAround) &&
      reviewed.isNotEmpty) {
    final element = reviewed.first;
    suggestions.add(
      ScanSuggestion._(
        scene: scene,
        room: room,
        ruleId: bathroom ? 'bathroom.movement_report' : 'room.movement_report',
        elementId: element.id,
        relatedElementIds: [element.id],
        title: bathroom
            ? 'Create an easier route through the bathroom'
            : 'Create an easier route through this room',
        detail: bathroom
            ? 'Resident reports difficulty moving around the bathroom and has reviewed part of its scanned layout.'
            : 'Resident reports difficulty moving around this room and has reviewed part of its scanned layout.',
        nextAction:
            'Walk through the usual route with an assessor and consider '
            'whether movable items can be repositioned. Check hidden obstacles '
            'and actual maneuvering space; this scan does not prove the route is clear.',
        basis:
            'Your reported difficulty and reviewed partial layout. No '
            'accessibility threshold or absent-object assumption was applied.',
      ),
    );
  }
  if (suggestions.length == maxScanSuggestions) {
    return List.unmodifiable(suggestions);
  }

  final doorways = reviewed
      .where(
        (e) =>
            kindOf(e) == ScanElementKind.door ||
            kindOf(e) == ScanElementKind.opening,
      )
      .toList();
  final objects = reviewed
      .where(
        (e) => {
          ScanElementKind.bathtub,
          ScanElementKind.toilet,
          ScanElementKind.sink,
          ScanElementKind.storage,
          ScanElementKind.furniture,
        }.contains(kindOf(e)),
      )
      .toList();
  final spans = {for (final door in doorways) door.id: _doorSpan(door)};
  final footprints = {
    for (final object in objects) object.id: _objectFootprint(object),
  };
  for (final door in doorways) {
    final span = spans[door.id];
    if (span == null) continue;
    for (final object in objects) {
      if (suggestions.length == maxScanSuggestions) {
        return List.unmodifiable(suggestions);
      }
      final footprint = footprints[object.id];
      if (footprint == null ||
          !_modeledSpanIntersectsFootprint(span, footprint)) {
        continue;
      }
      final label = kindOf(object).label.toLowerCase();
      suggestions.add(
        ScanSuggestion._(
          scene: scene,
          room: room,
          ruleId: bathroom
              ? 'bathroom.modeled_doorway_overlap'
              : 'room.modeled_doorway_overlap',
          elementId: door.id,
          relatedElementIds: [door.id, object.id],
          title: 'Check a possible doorway obstruction',
          detail:
              'The partial model places a reviewed $label across part of a '
              'reviewed doorway span. This modeled overlap needs an in-person '
              'check and may reflect scan approximation.',
          nextAction:
              'Inspect this doorway and item in the room. Correct '
              'misidentified geometry or discuss moving a movable item. Measure '
              'the actual passage before making any access decision.',
          basis:
              'The doorway span crosses the interior of the object\'s '
              'projected footprint, with overlapping modeled heights. This '
              'is a geometry comparison, not a clearance or legal threshold.',
        ),
      );
    }
  }
  return List.unmodifiable(suggestions);
}

_DoorSpan? _doorSpan(ScanElement door) {
  final dims = door.dimensions.toJson();
  final positiveAxes = [
    for (var i = 0; i < 3; i++)
      if (dims[i] > 0) i,
  ];
  final vertical = positiveAxes
      .where((i) => door.transform[i * 4 + 1].abs() > .99)
      .toList();
  final horizontal = positiveAxes
      .where((i) => door.transform[i * 4 + 1].abs() < .01)
      .toList();
  if (vertical.length != 1 || horizontal.isEmpty) return null;
  horizontal.sort((a, b) => dims[b].compareTo(dims[a]));
  final axis = horizontal.first;
  final localStart = [0.0, 0.0, 0.0], localEnd = [0.0, 0.0, 0.0];
  localStart[axis] = -dims[axis] / 2;
  localEnd[axis] = dims[axis] / 2;
  final start3 = door.transformPoint(
    ScanVector3(localStart[0], localStart[1], localStart[2]),
  );
  final end3 = door.transformPoint(
    ScanVector3(localEnd[0], localEnd[1], localEnd[2]),
  );
  final doorCorners = door.worldCorners;
  final doorLow = doorCorners.map((p) => p.y).reduce(math.min);
  final doorHigh = doorCorners.map((p) => p.y).reduce(math.max);
  return _DoorSpan(
    _Point2(start3.x, start3.z),
    _Point2(end3.x, end3.z),
    doorLow,
    doorHigh,
  );
}

_ObjectFootprint? _objectFootprint(ScanElement object) {
  if (object.dimensions.x == 0 ||
      object.dimensions.y == 0 ||
      object.dimensions.z == 0) {
    return null;
  }
  final objectCorners = object.worldCorners;
  final objectLow = objectCorners.map((p) => p.y).reduce(math.min);
  final objectHigh = objectCorners.map((p) => p.y).reduce(math.max);
  final hull = _convexHull(
    objectCorners.map((p) => _Point2(p.x, p.z)).toList(),
  );
  if (hull.length < 3) return null;
  return _ObjectFootprint(hull, objectLow, objectHigh);
}

bool _modeledSpanIntersectsFootprint(_DoorSpan door, _ObjectFootprint object) {
  const epsilon = 1e-8;
  if (math.min(door.high, object.high) - math.max(door.low, object.low) <=
      epsilon) {
    return false;
  }
  final start = door.start, end = door.end, hull = object.hull;
  if (math.max(start.x, end.x) <= object.minX + epsilon ||
      math.min(start.x, end.x) >= object.maxX - epsilon ||
      math.max(start.y, end.y) <= object.minY + epsilon ||
      math.min(start.y, end.y) >= object.maxY - epsilon) {
    return false;
  }
  var low = 0.0, high = 1.0;
  for (var i = 0; i < hull.length; i++) {
    final a = hull[i], b = hull[(i + 1) % hull.length];
    final g0 = _cross(a, b, start), g1 = _cross(a, b, end);
    final delta = g1 - g0;
    if (delta.abs() < epsilon) {
      if (g0 <= epsilon) return false;
    } else {
      final crossing = (epsilon - g0) / delta;
      if (delta > 0) {
        low = math.max(low, crossing);
      } else {
        high = math.min(high, crossing);
      }
    }
    if (high - low <= epsilon) return false;
  }
  return high - low > epsilon;
}

final class _DoorSpan {
  const _DoorSpan(this.start, this.end, this.low, this.high);
  final _Point2 start;
  final _Point2 end;
  final double low;
  final double high;
}

final class _ObjectFootprint {
  _ObjectFootprint(this.hull, this.low, this.high)
    : minX = hull.map((p) => p.x).reduce(math.min),
      maxX = hull.map((p) => p.x).reduce(math.max),
      minY = hull.map((p) => p.y).reduce(math.min),
      maxY = hull.map((p) => p.y).reduce(math.max);
  final List<_Point2> hull;
  final double low;
  final double high;
  final double minX;
  final double maxX;
  final double minY;
  final double maxY;
}

final class _Point2 {
  const _Point2(this.x, this.y);
  final double x;
  final double y;
}

double _cross(_Point2 a, _Point2 b, _Point2 p) =>
    (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x);

List<_Point2> _convexHull(List<_Point2> input) {
  input.sort((a, b) => a.x == b.x ? a.y.compareTo(b.y) : a.x.compareTo(b.x));
  final points = <_Point2>[];
  for (final p in input) {
    if (points.isEmpty || p.x != points.last.x || p.y != points.last.y) {
      points.add(p);
    }
  }
  if (points.length < 3) return points;
  List<_Point2> half(Iterable<_Point2> values) {
    final result = <_Point2>[];
    for (final p in values) {
      while (result.length >= 2 &&
          _cross(result[result.length - 2], result.last, p) <= 1e-8) {
        result.removeLast();
      }
      result.add(p);
    }
    return result..removeLast();
  }

  return [...half(points), ...half(points.reversed)];
}
