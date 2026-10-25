import 'assessment_location.dart';
import 'home_safety/home_safety.dart';

/// Keep device-only capture slots separate from server room IDs
abstract final class LocalPlaceRooms {
  static final List<RoomInstance> all = List.unmodifiable([
    for (final type in AssessmentLocation.values)
      RoomInstance(id: 'device-area-${type.name}', type: type, name: null),
  ]);

  static bool contains(RoomInstance? room) =>
      room != null && containsId(room.id);

  static bool containsId(String id) => all.any((r) => r.id == id);

  static String homeKey(String caseId) => 'assessment:$caseId:place-home';
}
