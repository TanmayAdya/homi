import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/features/assessment/application/bathroom_scan_session.dart';
import 'package:safe_at_home/features/assessment/domain/assessment_location.dart';
import 'package:safe_at_home/features/assessment/domain/local_place_rooms.dart';
import '../../tracking/program_progress_screen_test.dart' as tracking show app;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('local place identities are stable, typed and unique', () {
    expect(LocalPlaceRooms.all.map((r) => r.type), AssessmentLocation.values);
    expect(LocalPlaceRooms.all.map((r) => r.id).toSet(), hasLength(7));
    expect(LocalPlaceRooms.all.every(LocalPlaceRooms.contains), true);
    expect(LocalPlaceRooms.containsId('named-bedroom'), false);
    expect(() => LocalPlaceRooms.all.clear(), throwsUnsupportedError);
  });

  test(
    'clearing one plan deletes local place records without touching another plan',
    () async {
      final app = await tracking.app();
      addTearDown(() {
        app.dispose();
        app.session.dispose();
      });
      final id = app.coordinator.snapshot!.caseId;
      const other = '22222222-0000-4000-8000-000000000002';
      final keys = [
        for (final room in LocalPlaceRooms.all)
          BathroomScanSession.storageKey(id, room: room),
        LocalPlaceRooms.homeKey(id),
        '${LocalPlaceRooms.homeKey(id)}:draft',
        '${LocalPlaceRooms.homeKey(id)}:capture',
      ];
      final retained = LocalPlaceRooms.homeKey(other);
      for (final key in [...keys, retained]) {
        await app.store.writeJson(key, {'fictional': true});
      }
      await app.coordinator.clearSelected();
      final remaining = await app.store.keys();
      expect(remaining.where(keys.contains), isEmpty);
      expect(remaining, contains(retained));
    },
  );
}
