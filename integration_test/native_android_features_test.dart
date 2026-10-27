import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

const _assistant = MethodChannel('safe_at_home/assistant');
const _scanner = MethodChannel('safe_at_home/bathroom_scan');
const _id = '706acf81-b4bd-468f-b0ec-fdc23914404d';
const _other = '252a7f67-a085-421c-bf9f-e70fd44f552b';
const _room = 'df8ccf4d-3bc9-4d49-8cc8-feb22532ed31';
const _timeout = Duration(seconds: 12);

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  Future<Object?> call(MethodChannel channel, String method, [Object? args]) =>
      channel.invokeMethod<Object?>(method, args).timeout(_timeout);
  Matcher error(String code) => throwsA(
    isA<PlatformException>().having((e) => e.code, 'recoverable code', code),
  );
  Future<void> harness(WidgetTester tester) async {
    expect(Platform.isAndroid, isTrue);
    expect(const bool.fromEnvironment('SAH_ANDROID_ISOLATED_APP'), isTrue);
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Text('Android feature check — fictional data only'),
        ),
      ),
    );
  }

  testWidgets('Chat status uses the installed native SDK without downloading', (
    tester,
  ) async {
    await harness(tester);
    final status = await call(_assistant, 'availability', {'locale': 'en'});
    debugPrint(
      'Android native chat availability: $status (no download or inference)',
    );
    expect(
      status,
      isIn([
        'ready',
        'modelDownloadable',
        'modelDownloading',
        'unsupportedDevice',
        'requiresAndroid26',
        'unavailable',
      ]),
    );
    expect(
      await call(_assistant, 'availability', {'locale': 'unknown'}),
      'unsupportedLanguage',
    );
    for (final method in ['respond', 'download', 'cancel']) {
      for (final args in [
        null,
        {'requestId': 'invalid'},
        {'requestId': _id, 'unexpected': 'never sent to a model'},
      ]) {
        await expectLater(
          call(_assistant, method, args),
          error('INVALID_INPUT'),
        );
      }
    }
    for (final id in [_id, _other, _id]) {
      await call(_assistant, 'cancel', {'requestId': id});
    }
    await expectLater(
      call(_assistant, 'unknownAcceptanceMethod'),
      throwsA(isA<MissingPluginException>()),
    );
    binding.reportData = {
      'platform': 'android',
      'nativeAiStatus': status,
      'modelDownloaded': false,
      'inferenceTested': false,
      'physicalCaptureTested': false,
    };
  });

  testWidgets('continuous capture validates input before any native notice', (
    tester,
  ) async {
    await harness(tester);
    final capability = await call(_scanner, 'homeCapabilities');
    expect(
      capability,
      isA<Map>().having((m) => m['supported'], 'supported', isA<bool>()),
    );
    for (final args in [
      null,
      {'scanId': _id},
      {
        'scanId': _id,
        'languageCode': 'en',
        'rooms': [
          {'token': _room, 'name': 'Fictional first room'},
          {'token': _room, 'name': 'Duplicate token'},
        ],
      },
      {
        'scanId': _id,
        'languageCode': 'en',
        'accountId': 'forbidden',
        'rooms': [
          {'token': _room, 'name': 'Fictional first room'},
          {'token': _other, 'name': 'Fictional second room'},
        ],
      },
    ]) {
      await expectLater(
        call(_scanner, 'startHome', args),
        error('scan_failed'),
      );
    }
  });

  testWidgets(
    'multiroom notice cancellation is scoped and shares the single scan lock',
    (tester) async {
      await harness(tester);
      for (var attempt = 0; attempt < 3; attempt++) {
        var completed = false;
        final cancelled = expectLater(
          call(_scanner, 'startHome', {
            'scanId': _id,
            'languageCode': 'en',
            'rooms': [
              {'token': _room, 'name': 'Fictional bathroom one'},
              {'token': _other, 'name': 'Fictional bathroom two'},
            ],
          }).whenComplete(() => completed = true),
          error('scan_cancelled'),
        );
        try {
          await Future<void>.delayed(const Duration(milliseconds: 350));
          await call(_scanner, 'cancel', {'scanId': _other});
          expect(completed, isFalse);
          await expectLater(
            call(_scanner, 'start', {'scanId': _other}),
            error('scan_busy'),
          );
        } finally {
          await call(_scanner, 'cancel', {'scanId': _id});
          await cancelled;
        }
        expect(completed, isTrue);
        await Future<void>.delayed(const Duration(milliseconds: 350));
        expect(
          await call(_assistant, 'availability', {'locale': 'en'}),
          isA<String>(),
        );
      }
    },
  );
}
