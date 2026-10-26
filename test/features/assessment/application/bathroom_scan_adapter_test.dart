import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/features/assessment/application/bathroom_scan_adapter.dart';
import 'package:safe_at_home/l10n/app_language.dart';
import 'package:safe_at_home/features/assessment/domain/assessment_location.dart';
import 'package:safe_at_home/features/assessment/domain/home_safety/home_safety.dart';

import '../domain/scan/scan_test_fixtures.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('safe_at_home/bathroom_scan_adapter_test');
  const adapter = NativeBathroomScanAdapter(channel: channel);
  const id = 'd6a4a6b3-74cb-4fa9-9cc0-13710e793d32';
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test(
    'all indoor room types pass reviewed display context without persisted IDs',
    () async {
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return scanSceneJson();
      });
      for (final type in AssessmentLocation.values.where(
        (type) => type != AssessmentLocation.outdoorPaths,
      )) {
        await adapter.startForRoom(
          id,
          RoomInstance(
            id: 'private-room-id',
            type: type,
            name: 'Fictional ${type.name}',
          ),
        );
        final args = Map<Object?, Object?>.from(calls.last.arguments as Map);
        expect(args['room'], {
          'type': type.name,
          'name': 'Fictional ${type.name}',
        });
        expect(args.keys, isNot(contains('caseId')));
        expect(args.toString(), isNot(contains('private-room-id')));
      }
      expect(calls, hasLength(6));
    },
  );

  test('outdoor and archived rooms cannot open indoor capture', () async {
    var calls = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls++;
      return scanSceneJson();
    });
    for (final room in [
      RoomInstance(
        id: 'outdoors',
        type: AssessmentLocation.outdoorPaths,
        name: null,
      ),
      RoomInstance(
        id: 'archived',
        type: AssessmentLocation.bedroom,
        name: null,
        archived: true,
      ),
    ]) {
      expect(() => adapter.startForRoom(id, room), throwsFormatException);
    }
    expect(calls, 0);
  });

  test(
    'non-English scan passes only its language and scoped ID; cancel stays ID-only',
    () async {
      final controller = AppLanguageController.instance;
      final previous = controller.value;
      controller.value = AppLanguage.chineseTraditional;
      addTearDown(() => controller.value = previous);
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return call.method == 'start' ? scanSceneJson() : null;
      });
      await adapter.start(id);
      await adapter.cancel(id);
      expect(calls[0].arguments, {'scanId': id, 'languageCode': 'zh-Hant'});
      expect(calls[1].arguments, {'scanId': id});
    },
  );

  test(
    'start sends only the scoped scan ID and returns validated geometry',
    () async {
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return scanSceneJson();
      });
      final scene = await adapter.start(id);
      expect(scene.scanId, id);
      expect(calls, hasLength(1));
      expect(calls.single.method, 'start');
      expect(calls.single.arguments, {'scanId': id});
      expect(scene.elements.single.id, 'door-1');
    },
  );

  test(
    'cancel sends its own scoped ID without cancelling a future capture globally',
    () async {
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return null;
      });
      await adapter.cancel(id);
      expect(calls.single.method, 'cancel');
      expect(calls.single.arguments, {'scanId': id});
      await adapter.cancel('invalid');
      expect(calls, hasLength(1));
    },
  );

  test('invalid request IDs never cross the native channel', () async {
    var calls = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls++;
      return scanSceneJson();
    });
    await expectLater(adapter.start('not-a-scan-id'), throwsFormatException);
    expect(calls, 0);
  });

  test('a valid scene for a different capture is rejected', () async {
    messenger.setMockMethodCallHandler(
      channel,
      (call) async =>
          scanSceneJson()..['scanId'] = 'e5804048-ab8a-4314-8330-c2d06a2ce02d',
    );
    await expectLater(adapter.start(id), throwsFormatException);
  });

  test(
    'unsupported simulator capabilities stay unsupported without opening capture',
    () async {
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return {
          'supported': false,
          'source': 'roomplan',
          'reason': 'simulator',
          'depthSupported': false,
        };
      });
      final value = await adapter.capabilities();
      expect(value.supported, false);
      expect(value.reason, 'simulator');
      expect(value.depthSupported, false);
      expect(calls.single.method, 'capabilities');
      expect(calls.single.arguments, isNull);
    },
  );

  test(
    'ARCore capability reports preserve missing-service and depth states',
    () async {
      messenger.setMockMethodCallHandler(
        channel,
        (call) async => {
          'supported': false,
          'source': 'arcore',
          'reason': 'services_missing',
          'depthSupported': null,
        },
      );
      final value = await adapter.capabilities();
      expect(value.source, 'arcore');
      expect(value.reason, 'services_missing');
      expect(value.depthSupported, isNull);
    },
  );

  test('ARKit camera fallback preserves source and has no depth', () async {
    messenger.setMockMethodCallHandler(
      channel,
      (call) async => call.method == 'capabilities'
          ? {
              'supported': true,
              'source': 'arkit',
              'reason': 'available',
              'depthSupported': false,
            }
          : scanSceneJson(source: 'arkit'),
    );
    final value = await adapter.capabilities();
    expect(value.canRequestCapture, true);
    expect(value.source, 'arkit');
    expect(value.depthSupported, false);
    expect((await adapter.start(id)).source.name, 'arkit');
  });

  test(
    'iOS permission denial prioritizes manual assessment until Settings changes',
    () {
      for (final source in ['arkit', 'roomplan']) {
        expect(
          BathroomScanCapabilities(
            supported: false,
            source: source,
            reason: 'permission_denied',
          ).canRequestCapture,
          false,
        );
      }
    },
  );

  test('malformed capability responses cannot enable the scanner', () async {
    for (final value in <Object?>[
      null,
      {'supported': 1, 'source': 'roomplan', 'reason': 'available'},
      {'supported': true, 'source': 'invented', 'reason': 'available'},
      {'supported': true, 'source': 'roomplan', 'reason': 'unknown_reason'},
      {
        'supported': true,
        'source': 'roomplan',
        'reason': 'available',
        'depthSupported': 1,
      },
    ]) {
      messenger.setMockMethodCallHandler(channel, (call) async => value);
      await expectLater(adapter.capabilities(), throwsFormatException);
    }
  });

  test('native permission failure remains a recoverable typed error', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      throw PlatformException(code: 'scan_permission_denied');
    });
    await expectLater(
      adapter.start(id),
      throwsA(
        isA<PlatformException>().having(
          (error) => error.code,
          'code',
          'scan_permission_denied',
        ),
      ),
    );
  });

  test(
    'an absent native implementation reports unavailable and permits cancellation',
    () async {
      final capability = await adapter.capabilities();
      expect(capability.supported, false);
      expect(capability.reason, 'unsupported_device');
      await adapter.cancel(id);
    },
  );
}
