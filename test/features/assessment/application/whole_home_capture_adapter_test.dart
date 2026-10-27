import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/features/assessment/application/whole_home_capture_adapter.dart';
import 'package:safe_at_home/shared/models/case_draft.dart';
import '../domain/scan/scan_test_fixtures.dart';
import 'whole_home_test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('sah/fictional-home-test');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));
  final id = newUuidV4(), a = newUuidV4(), b = newUuidV4();
  test(
    'ARCore shared-frame results retain ARCore provenance and reject mixed or crossed scenes',
    () {
      Map<String, Object?> scene(String id) => {
        ...scanSceneJson(
          source: 'arcore',
          elements: [
            scanElementJson(
              kind: 'unknown',
              nativeCategory: 'vertical',
              dimensions: [2, 0, 3],
              confidence: 'unknown',
            ),
          ],
        ),
        'scanId': id,
      };
      final value = {
        'version': 1,
        'sessionId': id,
        'merged': scene(id),
        'rooms': [
          {'token': a, 'scene': scene(a)},
          {'token': b, 'scene': scene(b)},
        ],
      };
      final parsed = HomeCaptureResult.parse(value, id, {a, b});
      expect(parsed.merged.source.name, 'arcore');
      expect(
        parsed.rooms.values.every((r) => r.source.name == 'arcore'),
        isTrue,
      );
      expect(
        () => HomeCaptureResult.parse(
          {
            ...value,
            'rooms': [
              {'token': a, 'scene': scene(b)},
              {'token': b, 'scene': scene(a)},
            ],
          },
          id,
          {a, b},
        ),
        throwsFormatException,
      );
      expect(
        () => HomeCaptureResult.parse(
          {...value, 'merged': homeScene(id).toJson()},
          id,
          {a, b},
        ),
        throwsFormatException,
      );
    },
  );
  Map<String, Object?> payload() => {
    'version': 1,
    'sessionId': id,
    'rooms': [
      for (final token in [a, b])
        {'token': token, 'scene': homeScene(token).toJson()},
    ],
    'merged': homeScene(id).toJson(),
  };
  test(
    'strict result binding rejects unknown fields, wrong sessions, repeated/missing tokens and wrong provenance',
    () {
      expect(HomeCaptureResult.parse(payload(), id, {a, b}).rooms.keys, [a, b]);
      for (final value in [
        {...payload(), 'accountId': 'forbidden'},
        {...payload(), 'sessionId': newUuidV4()},
        {
          ...payload(),
          'rooms': [
            {'token': a, 'scene': homeScene(a).toJson()},
            {'token': a, 'scene': homeScene(b).toJson()},
          ],
        },
        {...payload(), 'merged': homeScene(newUuidV4()).toJson()},
        {
          ...payload(),
          'rooms': [
            {'token': a, 'scene': homeScene(a).toJson()},
          ],
        },
      ]) {
        expect(
          () => HomeCaptureResult.parse(value, id, {a, b}),
          throwsFormatException,
        );
      }
    },
  );
  test(
    'bridge sends only fresh session/tokens, ephemeral names and selected language',
    () async {
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        if (call.method == 'homeCapabilities') return {'supported': true};
        if (call.method == 'startHome') return payload();
        return null;
      });
      const adapter = NativeWholeHomeCaptureAdapter(channel: channel);
      expect(await adapter.supported(), isTrue);
      await adapter.start(id, [
        HomeCaptureRoom(a, 'First bathroom'),
        HomeCaptureRoom(b, 'Kitchen'),
      ]);
      final args = calls.last.arguments as Map;
      expect(args.keys.toSet(), {'scanId', 'languageCode', 'rooms'});
      expect((args['rooms'] as List).first, {
        'token': a,
        'name': 'First bathroom',
      });
      await adapter.cancel(id);
      expect(calls.last.arguments, {'scanId': id});
      final before = calls.length;
      await expectLater(
        adapter.start(id, [
          HomeCaptureRoom(a, 'One'),
          HomeCaptureRoom(a, 'Two'),
        ]),
        throwsFormatException,
      );
      await expectLater(
        adapter.start(id, [
          HomeCaptureRoom(a, 'One\nTwo'),
          HomeCaptureRoom(b, 'Three'),
        ]),
        throwsFormatException,
      );
      expect(calls, hasLength(before));
    },
  );
  test(
    'platform without continuous capture keeps manual fallback available',
    () async {
      const adapter = NativeWholeHomeCaptureAdapter(channel: channel);
      expect(await adapter.supported(), isFalse);
      await adapter.cancel(id);
    },
  );
}
