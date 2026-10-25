import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/app/theme.dart';
import 'package:safe_at_home/features/programs/program_intake_screen.dart';
import 'package:safe_at_home/features/requests/form_review_screen.dart';
import 'case_coordinator_test.dart' show FakeTransport;
import 'live_workflows_test.dart'
    show MemoryPrivateStore, services, program, input;
import '../contracts/form_answers_test.dart' as fixture;
import '../services/case_evidence_api_client_test.dart' as http;

class _EditorStore extends MemoryPrivateStore {
  bool fail = false, hold = false, holdConfirmedReceipt = false;
  final entered = Completer<void>(), release = Completer<void>();
  int writes = 0;
  @override
  Future<void> writeJson(String key, Map<String, Object?> value) async {
    if (key.startsWith('intake.') || key.startsWith('form.')) {
      writes++;
      if ((hold || (holdConfirmedReceipt && value['uncertain'] == false)) &&
          !entered.isCompleted) {
        entered.complete();
        await release.future;
      }
      if (fail) throw StateError('fictional disk failure');
    }
    await super.writeJson(key, value);
  }
}

Future<({String key, Finder field, FakeTransport transport})> _open(
  WidgetTester tester,
  _EditorStore store,
  bool intake, {
  bool allowFormSave = false,
}) async {
  final transport = FakeTransport((request) async {
    final body = http.requestJson(request);
    if (request.endpoint.path == '/v1/create-case') {
      return http.jsonResponse({...body, 'revision': 1});
    }
    if (intake) {
      expect(request.endpoint.path, '/v2/read-program-intake');
      return http.jsonResponse({
        'schemaVersion': '2',
        'caseId': body['caseId'],
        'caseRevision': 1,
        'definition': {
          'programId': 'fictional-program',
          'questionnaireVersion': 'a' * 64,
          'questions': [
            {
              'key': 'details',
              'label': 'Reported details',
              'kind': 'text',
              'maxLength': 160,
              'description': 'Use reported information.',
            },
          ],
        },
        'saved': null,
        'isCurrent': false,
      });
    }
    if (allowFormSave && request.endpoint.path == '/v2/save-form-answers') {
      return http.jsonResponse({
        ...fixture.responseJson(),
        'schemaVersion': '2',
        'caseId': body['caseId'],
        'caseRevision': 2,
        'saved': {
          ...fixture.savedJson(),
          'caseId': body['caseId'],
          'answers': [
            for (final answer in body['answers']! as List)
              fixture.savedAnswerJson(
                key: (answer as Map)['key'] as String,
                value: answer['value'],
                reviewState: answer['reviewState'] as String,
              ),
          ],
        },
        'fieldDefinitions': [
          {
            'key': 'memberFirstName',
            'label': 'Given name',
            'kind': 'text',
            'maxLength': 160,
          },
        ],
        'artifactKind': 'official_form_draft',
      });
    }
    expect(request.endpoint.path, '/v2/read-form-answers');
    return http.jsonResponse({
      ...fixture.responseJson(),
      'schemaVersion': '2',
      'caseId': body['caseId'],
      'caseRevision': 1,
      'saved': null,
      'isCurrent': false,
      'fieldDefinitions': [
        {
          'key': 'memberFirstName',
          'label': 'Given name',
          'kind': 'text',
          'maxLength': 160,
        },
      ],
      'artifactKind': 'official_form_draft',
    });
  });
  final app = services(store, transport);
  addTearDown(app.dispose);
  await app.coordinator.createDraft();
  await app.coordinator.save();
  final programId = intake ? 'fictional-program' : 'scfhp-eaa';
  final key =
      '${intake ? 'intake' : 'form'}.${app.coordinator.snapshot!.caseId}.$programId';
  await tester.pumpWidget(
    MaterialApp(
      theme: SafeAtHomeTheme.light(),
      home: Builder(
        builder: (context) => Scaffold(
          body: FilledButton(
            onPressed: () => Navigator.of(context).push<void>(
              MaterialPageRoute(
                builder: (_) => intake
                    ? ProgramIntakeScreen(services: app, program: program())
                    : FormReviewScreen(
                        services: app,
                        program: program(programId: programId),
                      ),
              ),
            ),
            child: const Text('Open editor'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open editor'));
  await tester.pumpAndSettle();
  final field = input(intake ? 'Reported details' : 'Given name');
  await tester.ensureVisible(field);
  await tester.enterText(field, 'Earlier durable entry');
  await tester.pumpAndSettle();
  expect(
    (store.records[key]!['values'] as Map).values,
    contains('Earlier durable entry'),
  );
  store.writes = 0;
  return (key: key, field: field, transport: transport);
}

void _noOnlineSave(FakeTransport transport) => expect(
  transport.requests.where((r) => r.endpoint.path.startsWith('/v2/save-')),
  isEmpty,
);

void main() {
  testWidgets(
    'confirmed online form save may exit immediately after final receipt settles before a frame',
    (tester) async {
      final store = _EditorStore();
      final f = await _open(tester, store, false, allowFormSave: true);
      store.holdConfirmedReceipt = true;
      final save = find.byKey(const ValueKey('form-save'));
      await tester.ensureVisible(save);
      await tester.tap(save);
      await tester.pump();
      expect(store.entered.isCompleted, isTrue);
      final back = tester
          .widget<BackButton>(find.byType(BackButton))
          .onPressed!;
      expect(
        tester.widget<PopScope<void>>(find.byType(PopScope<void>)).canPop,
        isFalse,
      );
      store.release.complete();
      await tester.idle();
      expect(store.records[f.key]!['uncertain'], isFalse);
      expect(store.records[f.key]!['caseRevision'], 2);
      back();
      await tester.pumpAndSettle();
      expect(find.text('Open editor'), findsOneWidget);
      expect(
        f.transport.requests.where(
          (r) => r.endpoint.path == '/v2/save-form-answers',
        ),
        hasLength(1),
      );
      expect(tester.takeException(), isNull);
    },
  );
  for (final intake in [true, false]) {
    final name = intake ? 'intake' : 'form';
    testWidgets(
      '$name failed edit is retained and exact retry saves before Back',
      (tester) async {
        final store = _EditorStore();
        final f = await _open(tester, store, intake);
        store.fail = true;
        await tester.enterText(f.field, 'Latest unfinished entry');
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Back'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('draft-exit-keep-editing')));
        await tester.pumpAndSettle();
        expect(
          tester.widget<TextField>(f.field).controller!.text,
          'Latest unfinished entry',
        );
        expect(store.writes, 1);
        store.fail = false;
        await tester.tap(find.byTooltip('Back'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('draft-exit-retry')));
        await tester.pumpAndSettle();
        expect(find.text('Open editor'), findsOneWidget);
        expect(store.writes, 2);
        await tester.tap(find.text('Open editor'));
        await tester.pumpAndSettle();
        expect(
          tester.widget<TextField>(f.field).controller!.text,
          'Latest unfinished entry',
        );
        _noOnlineSave(f.transport);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      '$name delayed failure blocks system Back until explicit discard',
      (tester) async {
        final store = _EditorStore();
        final f = await _open(tester, store, intake);
        store.hold = true;
        store.fail = true;
        await tester.enterText(f.field, 'Latest unfinished entry');
        await tester.pump();
        expect(store.entered.isCompleted, isTrue);
        await tester.binding.handlePopRoute();
        await tester.pump();
        expect(
          find.byKey(const ValueKey('draft-exit-waiting')),
          findsOneWidget,
        );
        expect(find.byKey(const ValueKey('draft-exit-discard')), findsNothing);
        store.release.complete();
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('draft-exit-discard')));
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const ValueKey('draft-exit-cancel-discard')),
        );
        await tester.pumpAndSettle();
        expect(
          tester.widget<TextField>(f.field).controller!.text,
          'Latest unfinished entry',
        );
        await tester.tap(find.byTooltip('Back'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('draft-exit-discard')));
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const ValueKey('draft-exit-confirm-discard')),
        );
        await tester.pumpAndSettle();
        expect(find.text('Open editor'), findsOneWidget);
        expect(
          (store.records[f.key]!['values'] as Map).values,
          contains('Earlier durable entry'),
        );
        expect(store.writes, 1);
        _noOnlineSave(f.transport);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
