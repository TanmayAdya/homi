import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/app/theme.dart';
import 'package:safe_at_home/features/assessment/application/bathroom_scan_adapter.dart';
import 'package:safe_at_home/features/assessment/application/bathroom_scan_availability.dart';
import 'package:safe_at_home/features/assessment/domain/scan/bathroom_scan_scene.dart';
import 'package:safe_at_home/features/assessment/presentation/assessment_scan_entry.dart';

class _Scanner implements BathroomScanAdapter {
  final replies = <Completer<BathroomScanCapabilities>>[];
  int starts = 0;
  @override
  Future<BathroomScanCapabilities> capabilities() {
    final reply = Completer<BathroomScanCapabilities>();
    replies.add(reply);
    return reply.future;
  }

  @override
  Future<BathroomScanScene> start(String id) async {
    starts++;
    throw StateError('Passive checks must never capture');
  }

  @override
  Future<void> cancel(String id) async {}
}

BathroomScanCapabilities _capability(
  String reason, {
  String source = 'roomplan',
  bool? supported,
}) => BathroomScanCapabilities(
  supported: supported ?? reason == 'available',
  source: source,
  reason: reason,
);

void main() {
  late _Scanner adapter;
  late BathroomScanAvailability availability;
  var current = true;
  var opens = 0;
  setUp(() {
    current = true;
    opens = 0;
    adapter = _Scanner();
    availability = BathroomScanAvailability(
      adapter: adapter,
      isCurrent: () => current,
    );
  });
  tearDown(() => availability.dispose());

  Future<void> pump(
    WidgetTester tester, {
    double scale = 1,
    bool enabled = true,
  }) => tester.pumpWidget(
    MaterialApp(
      theme: SafeAtHomeTheme.light(),
      home: MediaQuery(
        data: MediaQueryData(textScaler: TextScaler.linear(scale)),
        child: Scaffold(
          body: SingleChildScrollView(
            child: ListenableBuilder(
              listenable: availability,
              builder: (_, _) => AssessmentScanEntry(
                availability: availability,
                onOpen: enabled ? () => opens++ : null,
                onCheck: enabled ? availability.refresh : null,
              ),
            ),
          ),
        ),
      ),
    ),
  );

  testWidgets('LiDAR is primary without starting capture during detection', (
    tester,
  ) async {
    availability.refresh();
    await pump(tester);
    expect(find.text('Checking 3D scan support'), findsOneWidget);
    adapter.replies.single.complete(_capability('available'));
    await tester.pump();
    final open = find.byKey(const ValueKey('open-bathroom-scan'));
    expect(tester.widget(open), isA<FilledButton>());
    expect(find.text('Open 3D bathroom'), findsOneWidget);
    expect(adapter.starts, 0);
    await tester.tap(open);
    expect(opens, 1);
  });

  testWidgets('camera-only iPhone chooses ARKit without asking for a mode', (
    tester,
  ) async {
    availability.refresh();
    adapter.replies.single.complete(_capability('available', source: 'arkit'));
    await pump(tester);
    await tester.pump();
    expect(availability.prefersScan, true);
    expect(find.text('Start camera scan'), findsOneWidget);
    expect(
      tester.widget(find.byKey(const ValueKey('open-bathroom-scan'))),
      isA<FilledButton>(),
    );
    expect(adapter.starts, 0);
  });

  testWidgets(
    'camera-only iPhone with denied permission keeps manual mode primary',
    (tester) async {
      availability.refresh();
      adapter.replies.single.complete(
        _capability('permission_denied', source: 'arkit'),
      );
      await pump(tester);
      await tester.pump();
      expect(availability.prefersScan, false);
      expect(find.text('Photos and measurements work here'), findsOneWidget);
      expect(adapter.starts, 0);
    },
  );

  for (final reason in [
    'available',
    'permission_denied',
    'services_missing',
    'services_update_required',
  ]) {
    testWidgets('Android $reason offers primary scan/setup', (tester) async {
      availability.refresh();
      adapter.replies.single.complete(_capability(reason, source: 'arcore'));
      await pump(tester);
      await tester.pump();
      expect(availability.prefersScan, true);
      expect(
        tester.widget(find.byKey(const ValueKey('open-bathroom-scan'))),
        isA<FilledButton>(),
      );
      expect(adapter.starts, 0);
    });
  }

  testWidgets('unsupported device retains saved-model access and retry', (
    tester,
  ) async {
    availability.refresh();
    adapter.replies.single.complete(_capability('unsupported_device'));
    await pump(tester);
    await tester.pump();
    expect(availability.prefersScan, false);
    final open = find.byKey(const ValueKey('open-bathroom-scan'));
    expect(tester.widget(open), isA<OutlinedButton>());
    await tester.tap(open);
    expect(opens, 1);
    await tester.tap(find.byKey(const ValueKey('recheck-bathroom-scan')));
    expect(adapter.replies, hasLength(2));
    adapter.replies.last.complete(_capability('available'));
    await tester.pump();
    expect(availability.prefersScan, true);
  });

  testWidgets('checking is unresolved and a retry may discover support', (
    tester,
  ) async {
    availability.refresh();
    adapter.replies.single.complete(_capability('checking', source: 'arcore'));
    await pump(tester);
    await tester.pump();
    expect(
      find.textContaining('Device support is not confirmed yet'),
      findsOneWidget,
    );
    expect(availability.prefersScan, false);
    await tester.tap(find.byKey(const ValueKey('recheck-bathroom-scan')));
    adapter.replies.last.complete(_capability('available', source: 'arcore'));
    await tester.pump();
    expect(availability.prefersScan, true);
  });

  testWidgets('timeout permits retry and late successful reply is ignored', (
    tester,
  ) async {
    availability.refresh();
    await pump(tester);
    await tester.pump(const Duration(seconds: 5));
    expect(availability.failed, true);
    expect(availability.checking, false);
    expect(
      find.textContaining('scanner check could not finish'),
      findsOneWidget,
    );
    availability.refresh();
    adapter.replies.first.complete(_capability('available'));
    await tester.pump();
    expect(availability.checking, true);
    expect(availability.prefersScan, false);
    adapter.replies.last.complete(_capability('unsupported_device'));
    await tester.pump();
    expect(availability.failed, false);
    expect(availability.prefersScan, false);
  });

  testWidgets(
    'errors recover and an expired account cannot publish a response',
    (tester) async {
      availability.refresh();
      adapter.replies.first.completeError(StateError('Unavailable'));
      await pump(tester);
      await tester.pump();
      expect(availability.failed, true);
      availability.refresh();
      current = false;
      adapter.replies.last.complete(_capability('available'));
      await tester.pump();
      expect(availability.prefersScan, false);
      availability.refresh();
      expect(adapter.replies, hasLength(2));
    },
  );

  testWidgets('large text and narrow viewport keep disabled controls usable', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    availability.refresh();
    adapter.replies.single.complete(_capability('available'));
    await pump(tester, scale: 2, enabled: false);
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(
      tester
          .widget<ButtonStyleButton>(
            find.byKey(const ValueKey('open-bathroom-scan')),
          )
          .enabled,
      false,
    );
    expect(opens, 0);
  });
}
