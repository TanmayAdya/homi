import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/app/live_app.dart';
import 'package:safe_at_home/app/theme.dart';
import 'package:safe_at_home/features/assessment/presentation/live_assessment_screen.dart';
import 'package:safe_at_home/shared/models/case_draft.dart';
import 'package:safe_at_home/shared/models/contracts.dart';
import 'package:safe_at_home/shared/services/matching_api_client.dart';
import '../../../app/case_coordinator_test.dart' show FakeTransport;
import '../../../app/live_workflows_test.dart'
    show MemoryPrivateStore, services;
import '../../../contracts/draft_export_test.dart' as fixture;

class _RetainedJournal extends MemoryPrivateStore {
  _RetainedJournal(this.bytes);
  Uint8List bytes;
  final writes = <String>[];
  @override
  Future<Uint8List?> readBytes(String key) async =>
      key.endsWith(':draft') ? Uint8List.fromList(bytes) : null;
  @override
  Future<void> writeBytes(String key, Uint8List value) async {
    writes.add(key);
    bytes = Uint8List.fromList(value);
  }
}

void main() {
  late AppServices app;
  late _RetainedJournal store;
  late FakeTransport transport;
  late Uint8List original;
  setUp(() {
    final saved = fixture.snapshot().toJson()..['findings'] = <Object>[];
    original = Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'version': 1,
          'caseId': saved['caseId'],
          'controller': {
            'version': 999,
            'retainedFictionalEntry': 'Do not replace a rejected journal.',
          },
        }),
      ),
    );
    store = _RetainedJournal(Uint8List.fromList(original));
    transport = FakeTransport((request) async {
      expect(request.endpoint.path, '/v2/read-assessment');
      return MatchingHttpResponse(
        statusCode: 200,
        contentType: 'application/json',
        body: utf8.encode(
          jsonEncode({
            'schemaVersion': '2',
            'case': saved,
            'caseFingerprint': sha256
                .convert(utf8.encode(jsonEncode(saved)))
                .toString(),
            'catalogRevision': 0,
            'assessment': {
              'schemaVersion': '2',
              'caseId': saved['caseId'],
              'caseRevision': saved['revision'],
              'assessmentRevision': 0,
              'metadata': {'measurements': <Object>[], 'reviews': <Object>[]},
              'history': <Object>[],
            },
            'acknowledgedMutationId': null,
          }),
        ),
      );
    });
    app = services(store, transport);
    app.coordinator.snapshot = CaseSnapshot.fromJson(saved);
    app.coordinator.draft = CaseDraft.fromSnapshot(app.coordinator.snapshot!);
  });
  tearDown(() {
    app.dispose();
    app.session.dispose();
  });

  Future<void> open(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: SafeAtHomeTheme.light(),
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: FilledButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => LiveAssessmentScreen(services: app),
                  ),
                ),
                child: const Text('Open assessment'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open assessment'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('saved assessment could not be opened'),
      findsOneWidget,
    );
    expect(transport.requests, hasLength(1));
    expect(store.bytes, orderedEquals(original));
    expect(store.writes, isEmpty);
  }

  for (final size in [const Size(320, 568), const Size(932, 430)]) {
    for (final appBar in [true, false]) {
      testWidgets(
        'failed initialization ${appBar ? 'AppBar' : 'body'} Back preserves journal at 3.2x in $size',
        (tester) async {
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = size;
          tester.platformDispatcher.textScaleFactorTestValue = 3.2;
          addTearDown(() {
            tester.view.resetDevicePixelRatio();
            tester.view.resetPhysicalSize();
            tester.platformDispatcher.clearTextScaleFactorTestValue();
          });
          await open(tester);
          expect(tester.takeException(), isNull);
          final action = appBar
              ? find.byTooltip('Back')
              : find.byKey(const ValueKey('assessment-error-back'));
          await tester.ensureVisible(action);
          await tester.pumpAndSettle();
          expect(action.hitTestable(), findsOneWidget);
          expect(tester.getSize(action).height, greaterThanOrEqualTo(48));
          await tester.tap(action);
          await tester.pumpAndSettle();
          expect(find.text('Open assessment'), findsOneWidget);
          expect(find.byType(LiveAssessmentScreen), findsNothing);
          expect(store.bytes, orderedEquals(original));
          expect(store.writes, isEmpty);
          expect(transport.requests, hasLength(1));
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets('backgrounding a failed restoration never replaces its journal', (
    tester,
  ) async {
    await open(tester);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(store.bytes, orderedEquals(original));
    expect(store.writes, isEmpty);
    expect(find.byType(LiveAssessmentScreen), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('system Back leaves failed restoration without a partial save', (
    tester,
  ) async {
    await open(tester);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(LiveAssessmentScreen), findsNothing);
    expect(find.text('Open assessment'), findsOneWidget);
    expect(store.bytes, orderedEquals(original));
    expect(store.writes, isEmpty);
    expect(transport.requests, hasLength(1));
    expect(tester.takeException(), isNull);
  });
}
