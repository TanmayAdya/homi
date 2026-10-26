import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:safe_at_home/features/assessment/application/bathroom_scan_adapter.dart';

const _channel = MethodChannel('safe_at_home/bathroom_scan');
const _adapter = NativeBathroomScanAdapter();
const _scanId = '706acf81-b4bd-468f-b0ec-fdc23914404d';
const _otherId = '252a7f67-a085-421c-bf9f-e70fd44f552b';
const _timeout = Duration(seconds: 10);

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  Future<void> showHarness(WidgetTester tester) => tester.pumpWidget(
    const MaterialApp(
      home: Scaffold(
        body: SafeArea(
          child: Text('Native scanner contract check — no room capture'),
        ),
      ),
    ),
  );

  testWidgets('the installed native bridge reports platform capabilities', (
    tester,
  ) async {
    await showHarness(tester);
    final raw = await _channel
        .invokeMethod<Object?>('capabilities')
        .timeout(_timeout);
    final value = BathroomScanCapabilities.fromJson(raw);
    expect(
      value.source,
      isIn(Platform.isIOS ? ['roomplan', 'arkit'] : ['arcore']),
    );
    binding.reportData = {
      'platform': Platform.operatingSystem,
      'source': value.source,
      'supported': value.supported,
      'reason': value.reason,
      'depthSupported': value.depthSupported,
      'physicalRoomCaptureTested': false,
    };
  });

  for (final method in ['start', 'cancel']) {
    testWidgets('$method rejects malformed arguments before opening capture', (
      tester,
    ) async {
      await showHarness(tester);
      for (final arguments in <Object?>[
        null,
        'invalid',
        <Object?>[],
        <String, Object?>{},
        {'scanId': 1},
        {'scanId': '../../case'},
        {'scanId': '706acf81-b4bd-168f-b0ec-fdc23914404d'},
        {'scanId': '$_scanId\n'},
        {'scanId': _scanId, 'unexpected': true},
      ]) {
        await expectLater(
          _channel.invokeMethod<Object?>(method, arguments).timeout(_timeout),
          throwsA(
            isA<PlatformException>().having(
              (error) => error.code,
              'recoverable code',
              'scan_failed',
            ),
          ),
        );
      }
    });
  }

  testWidgets(
    'idle scoped cancellations are repeatable and leave bridge usable',
    (tester) async {
      await showHarness(tester);
      for (final id in [_scanId, _scanId, _otherId, _scanId]) {
        await _adapter.cancel(id).timeout(_timeout);
      }
      final value = await _adapter.capabilities().timeout(_timeout);
      expect(
        value.source,
        isIn(Platform.isIOS ? ['roomplan', 'arkit'] : ['arcore']),
      );
    },
  );

  testWidgets('unknown native methods fail without entering capture', (
    tester,
  ) async {
    await showHarness(tester);
    await expectLater(
      _channel.invokeMethod<void>('unknownAcceptanceMethod').timeout(_timeout),
      throwsA(isA<MissingPluginException>()),
    );
  });

  testWidgets('repeated rejected requests do not leave a pending scan', (
    tester,
  ) async {
    await showHarness(tester);
    for (var iteration = 0; iteration < 25; iteration++) {
      await expectLater(
        _channel
            .invokeMethod<void>('start', {'scanId': 'invalid'})
            .timeout(_timeout),
        throwsA(
          isA<PlatformException>().having(
            (error) => error.code,
            'code',
            'scan_failed',
          ),
        ),
      );
      await _adapter.cancel(_scanId).timeout(_timeout);
      await _adapter.capabilities().timeout(_timeout);
    }
  });

  testWidgets(
    'Android notice cancellation releases the request and ignores stale cancel',
    (tester) async {
      await showHarness(tester);
      for (var attempt = 0; attempt < 3; attempt++) {
        final id = attempt.isEven ? _scanId : _otherId;
        final staleId = attempt.isEven ? _otherId : _scanId;
        var completed = false;
        final cancelled = expectLater(
          _adapter.start(id).timeout(_timeout).whenComplete(() {
            completed = true;
          }),
          throwsA(
            isA<PlatformException>().having(
              (error) => error.code,
              'code',
              'scan_cancelled',
            ),
          ),
        );
        try {
          await Future<void>.delayed(const Duration(milliseconds: 250));
          await _adapter.cancel(staleId).timeout(_timeout);
          expect(completed, false);
          await expectLater(
            _adapter.start(staleId).timeout(_timeout),
            throwsA(
              isA<PlatformException>().having(
                (error) => error.code,
                'code',
                'scan_busy',
              ),
            ),
          );
        } finally {
          await _adapter.cancel(id).timeout(_timeout);
          await cancelled;
        }
        expect(completed, true);
      }
    },
    skip: !Platform.isAndroid,
  );

  testWidgets(
    'Android system Back cancels the native notice and allows another request',
    (tester) async {
      await showHarness(tester);
      final cancelled = expectLater(
        _adapter.start(_scanId).timeout(const Duration(seconds: 30)),
        throwsA(
          isA<PlatformException>().having(
            (error) => error.code,
            'code',
            'scan_cancelled',
          ),
        ),
      );
      try {
        debugPrint('SAH_NATIVE_NOTICE_READY_FOR_SYSTEM_BACK');
        await cancelled;
      } finally {
        await _adapter.cancel(_scanId).timeout(_timeout);
      }
      final next = expectLater(
        _adapter.start(_otherId).timeout(_timeout),
        throwsA(
          isA<PlatformException>().having(
            (error) => error.code,
            'code',
            'scan_cancelled',
          ),
        ),
      );
      await _adapter.cancel(_otherId).timeout(_timeout);
      await next;
    },
    skip:
        !Platform.isAndroid ||
        !const bool.fromEnvironment('SAH_TEST_SYSTEM_BACK'),
  );

  testWidgets(
    'iOS simulator refuses a valid capture without pretending to scan',
    (tester) async {
      await showHarness(tester);
      final value = await _adapter.capabilities().timeout(_timeout);
      if (value.reason != 'simulator') {
        binding.reportData = {
          ...?binding.reportData,
          'simulatorStartCheck': 'not applicable to this device',
        };
        return;
      }
      expect(value.supported, false);
      for (var attempt = 0; attempt < 3; attempt++) {
        await expectLater(
          _adapter.start(_scanId).timeout(_timeout),
          throwsA(
            isA<PlatformException>().having(
              (error) => error.code,
              'code',
              'scan_unavailable',
            ),
          ),
        );
      }
    },
    skip: !Platform.isIOS,
  );
}
