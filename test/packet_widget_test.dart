import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/app/safe_at_home_app.dart';
import 'package:safe_at_home/features/requests/draft_packet_screen.dart';
import 'package:safe_at_home/shared/models/contracts.dart';
import 'package:safe_at_home/shared/models/draft_packet.dart';
import 'package:safe_at_home/shared/services/demo_scenario_service.dart';
import 'package:safe_at_home/shared/services/matching_api_client.dart';
import 'package:safe_at_home/shared/services/packet_preparation_service.dart';

List<DemoScenario> scenarios() => parseDemoScenarios(
  jsonDecode(File('contracts/v1/fixtures/scenarios.json').readAsStringSync()),
);

List<DraftPacket> packets() =>
    (jsonDecode(File('contracts/v1/fixtures/packets.json').readAsStringSync())
            as List)
        .map((entry) => DraftPacket.fromJson(entry['packet']))
        .toList();

Future<void> openChecklist(WidgetTester tester) async {
  final button = find.text('View draft checklist');
  await tester.ensureVisible(button);
  await tester.tap(button);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'checklist items lead to resident details, a reviewed task or Contact',
    (tester) async {
      final example = scenarios().first;
      final scenarioJson =
          (jsonDecode(
                        File(
                          'contracts/v1/fixtures/scenarios.json',
                        ).readAsStringSync(),
                      )
                      as List)
                  .first
              as Map;
      final packetJson =
          (jsonDecode(
                        File(
                          'contracts/v1/fixtures/packets.json',
                        ).readAsStringSync(),
                      )
                      as List)
                  .first['packet']
              as Map;
      final program = ProgramMatch.fromJson(
        Map<String, Object?>.from(
          ((scenarioJson['match'] as Map)['matches'] as List).first as Map,
        ),
      );
      final packet = DraftPacket.fromJson({
        ...Map<String, Object?>.from(packetJson),
        'missingItems': [
          ...(packetJson['missingItems'] as List),
          {
            'id': 'professional-order',
            'description': 'Fictional professional order.',
            'resolvedBy': 'professional',
          },
        ],
      });
      final resident = packet.missingItems.firstWhere(
        (i) => i.resolvedBy == 'resident',
      );
      final tasks = <String>[];
      var details = 0, contact = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: DraftPacketScreen(
            snapshot: example.caseSnapshot,
            program: program,
            service: _PacketService(pending: Future.value(packet)),
            currentCase: () => example.caseSnapshot,
            onContact: () => contact++,
            onResidentDetails: () => details++,
            onAddTask: tasks.add,
          ),
        ),
      );
      await tester.pumpAndSettle();
      Future<void> tap(Finder finder) async {
        await tester.ensureVisible(finder);
        await tester.pumpAndSettle();
        await tester.tap(finder);
        await tester.pumpAndSettle();
      }

      await tap(find.byKey(ValueKey('checklist-item-${resident.id}')));
      expect(details, 1);
      expect(tasks, isEmpty);
      await tap(find.byKey(ValueKey('checklist-add-task-${resident.id}')));
      expect(tasks, [resident.description]);
      expect(find.text('Ask a doctor or therapist'), findsOneWidget);
      await tap(
        find.byKey(const ValueKey('checklist-add-task-professional-order')),
      );
      expect(tasks.last, 'Fictional professional order.');
      expect(
        find.byKey(const ValueKey('checklist-add-task-intake-route')),
        findsNothing,
      );
      await tap(find.byKey(const ValueKey('checklist-item-intake-route')));
      expect(contact, 1);
      expect(tasks, hasLength(2));
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'RTP checklist calls its app-generated artifact a preparation worksheet',
    (tester) async {
      final example = scenarios().first;
      final scenarioJson =
          (jsonDecode(
                        File(
                          'contracts/v1/fixtures/scenarios.json',
                        ).readAsStringSync(),
                      )
                      as List)
                  .first
              as Map;
      final packetJson =
          (jsonDecode(
                        File(
                          'contracts/v1/fixtures/packets.json',
                        ).readAsStringSync(),
                      )
                      as List)
                  .first['packet']
              as Map;
      final program = ProgramMatch.fromJson({
        ...Map<String, Object?>.from(
          ((scenarioJson['match'] as Map)['matches'] as List).first as Map,
        ),
        'programId': 'rtp-home-repair',
      });
      final packet = DraftPacket.fromJson({
        ...Map<String, Object?>.from(packetJson),
        'programId': 'rtp-home-repair',
      });
      await tester.pumpWidget(
        MaterialApp(
          home: DraftPacketScreen(
            snapshot: example.caseSnapshot,
            program: program,
            service: _PacketService(pending: Future.value(packet)),
            currentCase: () => example.caseSnapshot,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Preparation worksheet'), findsOneWidget);
      expect(
        find.text(
          'App-generated worksheet, not an RTP application. Complete the official intake separately.',
        ),
        findsOneWidget,
      );
      expect(find.text('Application form'), findsNothing);
      expect(find.textContaining('Official form not prepared.'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'each example opens its own draft and preserves unknown/failed tasks',
    (tester) async {
      final examples = scenarios();
      final service = _PacketService();
      await tester.pumpWidget(
        SafeAtHomeApp(
          scenarioService: _Scenarios(examples),
          packetService: service,
        ),
      );
      await tester.pumpAndSettle();
      for (final scenario in examples) {
        final choice = find.byKey(ValueKey('scenario-${scenario.id}'));
        await tester.ensureVisible(choice);
        await tester.tap(choice);
        await tester.pumpAndSettle();
        await openChecklist(tester);
        expect(find.text('Fictional saved example'), findsOneWidget);
        expect(
          find.text('Draft only · Nothing has been submitted.'),
          findsOneWidget,
        );
        expect(find.text('No evidence files attached.'), findsOneWidget);
        expect(
          find.textContaining('Official form not prepared.'),
          findsOneWidget,
        );
        final expected = packets().singleWhere(
          (p) => p.caseId == scenario.caseSnapshot.caseId,
        );
        for (final item in expected.missingItems) {
          expect(find.text(item.description), findsOneWidget);
        }
        if (scenario.id == 'not-matched') {
          expect(
            find.textContaining('A requirement was not met.'),
            findsOneWidget,
          );
        }
        if (scenario.id == 'unknown') {
          expect(
            find.text('For the resident · 3 still needed'),
            findsOneWidget,
          );
        } else {
          expect(
            find.text('For the resident · 1 still needed'),
            findsOneWidget,
          );
        }
        expect(find.text('Submit'), findsNothing);
        expect(find.text('Export'), findsNothing);
        await tester.pageBack();
        await tester.pumpAndSettle();
      }
      expect(
        service.caseIds,
        examples.map((s) => s.caseSnapshot.caseId).toList(),
      );
    },
  );

  testWidgets('retry keeps the same generation key and hides raw errors', (
    tester,
  ) async {
    final service = _PacketService(
      firstError: StateError('private-token-and-case'),
    );
    await tester.pumpWidget(
      SafeAtHomeApp(
        scenarioService: _Scenarios(scenarios()),
        packetService: service,
      ),
    );
    await tester.pumpAndSettle();
    await openChecklist(tester);
    expect(find.textContaining('private-token'), findsNothing);
    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();
    expect(service.keys, hasLength(2));
    expect(service.keys.first, service.keys.last);
    expect(find.text('What is needed next'), findsOneWidget);
  });

  testWidgets('generation conflict offers a new key for preparation', (
    tester,
  ) async {
    final service = _PacketService(
      firstError: MatchingApiException.forCode(
        'PACKET_GENERATION_CONFLICT',
        statusCode: 409,
      ),
    );
    await tester.pumpWidget(
      SafeAtHomeApp(
        scenarioService: _Scenarios(scenarios()),
        packetService: service,
      ),
    );
    await tester.pumpAndSettle();
    await openChecklist(tester);
    await tester.tap(find.text('Prepare a new draft'));
    await tester.pumpAndSettle();
    expect(service.keys.first, isNot(service.keys.last));
    expect(find.text('What is needed next'), findsOneWidget);
  });

  testWidgets('late checklist for a changed case is discarded', (tester) async {
    final example = scenarios().first;
    var current = example.caseSnapshot;
    final pending = Completer<DraftPacket>();
    final service = _PacketService(pending: pending.future);
    await tester.pumpWidget(
      MaterialApp(
        home: DraftPacketScreen(
          snapshot: example.caseSnapshot,
          program: example.matchResponse.matches.single,
          service: service,
          currentCase: () => current,
        ),
      ),
    );
    await tester.pump();
    current = scenarios().last.caseSnapshot;
    pending.complete(packets().first);
    await tester.pumpAndSettle();
    expect(find.text('What is needed next'), findsNothing);
    expect(find.text('Try again'), findsNothing);
    expect(find.text('Return to program results'), findsOneWidget);
  });

  testWidgets(
    'a changed screen input starts a new draft without retaining the previous result',
    (tester) async {
      final examples = scenarios();
      final service = _PacketService();
      Widget screen(DemoScenario example) => MaterialApp(
        home: DraftPacketScreen(
          snapshot: example.caseSnapshot,
          program: example.matchResponse.matches.single,
          service: service,
          currentCase: () => example.caseSnapshot,
        ),
      );
      await tester.pumpWidget(screen(examples.last));
      await tester.pumpAndSettle();
      expect(find.text('For the resident · 3 still needed'), findsOneWidget);
      await tester.pumpWidget(screen(examples.first));
      await tester.pumpAndSettle();
      expect(find.text('For the resident · 1 still needed'), findsOneWidget);
      expect(service.keys.toSet(), hasLength(2));
    },
  );

  testWidgets('large text and a narrow screen can reach all checklist tasks', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 700);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 1.8;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      tester.platformDispatcher.clearTextScaleFactorTestValue();
    });
    final example = scenarios().last;
    await tester.pumpWidget(
      MaterialApp(
        home: DraftPacketScreen(
          snapshot: example.caseSnapshot,
          program: example.matchResponse.matches.single,
          service: _PacketService(),
          currentCase: () => example.caseSnapshot,
        ),
      ),
    );
    await tester.pumpAndSettle();
    final task = find.text(packets().last.missingItems.last.description);
    await tester.ensureVisible(task);
    await tester.pumpAndSettle();
    expect(task.hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'error recovery remains reachable with large text on a short screen',
    (tester) async {
      tester.view.physicalSize = const Size(320, 360);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 2.2;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        tester.platformDispatcher.clearTextScaleFactorTestValue();
      });
      final example = scenarios().first;
      await tester.pumpWidget(
        MaterialApp(
          home: DraftPacketScreen(
            snapshot: example.caseSnapshot,
            program: example.matchResponse.matches.single,
            service: _PacketService(
              firstError: MatchingApiException.forCode(
                'SERVICE_UNAVAILABLE',
                statusCode: 503,
              ),
            ),
            currentCase: () => example.caseSnapshot,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Return to program results'));
      await tester.pumpAndSettle();
      expect(
        find.text('Return to program results').hitTestable(),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('a response cannot remove the program fictional marker', (
    tester,
  ) async {
    final example = scenarios().first;
    final raw =
        (jsonDecode(
                      File(
                        'contracts/v1/fixtures/packets.json',
                      ).readAsStringSync(),
                    )
                    as List)
                .first['packet']
            as Map<String, dynamic>;
    raw['isDemo'] = false;
    await tester.pumpWidget(
      MaterialApp(
        home: DraftPacketScreen(
          snapshot: example.caseSnapshot,
          program: example.matchResponse.matches.single,
          service: _PacketService(
            pending: Future.value(DraftPacket.fromJson(raw)),
          ),
          currentCase: () => example.caseSnapshot,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('What is needed next'), findsNothing);
    expect(find.text('Try again'), findsOneWidget);
  });

  testWidgets('notified case changes invalidate an already loaded draft', (
    tester,
  ) async {
    final example = scenarios().first;
    final current = ValueNotifier(example.caseSnapshot);
    addTearDown(current.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: DraftPacketScreen(
          snapshot: example.caseSnapshot,
          program: example.matchResponse.matches.single,
          service: _PacketService(),
          currentCase: () => current.value,
          caseChanges: current,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('What is needed next'), findsOneWidget);
    current.value = scenarios().last.caseSnapshot;
    await tester.pumpAndSettle();
    expect(find.text('What is needed next'), findsNothing);
    expect(find.text('Return to program results'), findsOneWidget);
  });

  testWidgets('an open API draft refreshes its warning at the exact deadline', (
    tester,
  ) async {
    final example = scenarios().first;
    var now = DateTime.parse(
      packets().first.recheckAfter!,
    ).subtract(const Duration(seconds: 1));
    await tester.pumpWidget(
      MaterialApp(
        home: DraftPacketScreen(
          snapshot: example.caseSnapshot,
          program: example.matchResponse.matches.single,
          service: _PacketService(isSavedExample: false),
          currentCase: () => example.caseSnapshot,
          now: () => now,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.textContaining('This draft needs a fresh review'),
      findsNothing,
    );
    now = now.add(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    expect(
      find.textContaining('This draft needs a fresh review'),
      findsOneWidget,
    );
  });

  testWidgets('resuming the app rechecks the current case after loading', (
    tester,
  ) async {
    final example = scenarios().first;
    var current = example.caseSnapshot;
    await tester.pumpWidget(
      MaterialApp(
        home: DraftPacketScreen(
          snapshot: example.caseSnapshot,
          program: example.matchResponse.matches.single,
          service: _PacketService(),
          currentCase: () => current,
        ),
      ),
    );
    await tester.pumpAndSettle();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    current = scenarios().last.caseSnapshot;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(find.text('What is needed next'), findsNothing);
    expect(find.text('Return to program results'), findsOneWidget);
  });

  testWidgets(
    'expiry timer re-arms when wall time is still before a fractional deadline',
    (tester) async {
      final example = scenarios().first;
      final deadline = DateTime.parse(packets().first.recheckAfter!);
      var now = deadline.subtract(const Duration(microseconds: 500));
      await tester.pumpWidget(
        MaterialApp(
          home: DraftPacketScreen(
            snapshot: example.caseSnapshot,
            program: example.matchResponse.matches.single,
            service: _PacketService(isSavedExample: false),
            currentCase: () => example.caseSnapshot,
            now: () => now,
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1));
      expect(
        find.textContaining('This draft needs a fresh review'),
        findsNothing,
      );
      now = deadline;
      await tester.pump(const Duration(milliseconds: 1));
      expect(
        find.textContaining('This draft needs a fresh review'),
        findsOneWidget,
      );
    },
  );
}

class _Scenarios implements DemoScenarioService {
  _Scenarios(this.values);
  final List<DemoScenario> values;
  @override
  Future<List<DemoScenario>> loadScenarios() async => values;
}

class _PacketService implements PacketPreparationService {
  _PacketService({this.firstError, this.pending, this.isSavedExample = true});
  final Object? firstError;
  final Future<DraftPacket>? pending;
  final keys = <String>[];
  final caseIds = <String>[];
  @override
  final bool isSavedExample;
  @override
  Future<DraftPacket> prepare(
    CaseSnapshot snapshot, {
    required String programId,
    required String generationKey,
    required CaseSnapshot Function() currentCase,
  }) async {
    keys.add(generationKey);
    caseIds.add(snapshot.caseId);
    if (keys.length == 1 && firstError != null) throw firstError!;
    if (pending != null) return pending!;
    return packets().singleWhere(
      (p) => p.caseId == snapshot.caseId && p.programId == programId,
    );
  }
}
