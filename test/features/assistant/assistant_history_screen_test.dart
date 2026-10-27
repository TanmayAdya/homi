import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/features/assistant/assistant_model.dart';
import 'package:safe_at_home/features/assistant/plan_assistant_screen.dart';
import 'package:safe_at_home/shared/services/case_coordinator.dart';
import 'package:safe_at_home/shared/services/case_discovery_api_client.dart';
import '../../app/case_coordinator_test.dart' show FakeSession, FakeTransport;
import '../../services/case_evidence_api_client_test.dart' as http;
import '../assessment/home_safety/home_safety_support.dart';
import 'assistant_test.dart' show FakeModel;

class _DelayedStore extends SafetyStore {
  Completer<void>? readGate, deleteGate;
  @override
  Future<Uint8List?> readBytes(String key) async {
    await readGate?.future;
    return super.readBytes(key);
  }

  @override
  Future<void> delete(String key) async {
    await deleteGate?.future;
    return super.delete(key);
  }
}

void main() {
  testWidgets(
    'loading and clearing guard draft editing and leaving until recovery',
    (tester) async {
      final store = _DelayedStore()..readGate = Completer<void>();
      final auth = FakeSession();
      final transport = FakeTransport(
        (_) async => throw StateError('No network expected'),
      );
      final coordinator = CaseCoordinator(
        session: auth,
        store: store,
        cases: http.clientFor(transport),
        discovery: CaseDiscoveryApiClient(
          listCasesEndpoint: Uri.parse('https://example.org/v1/list-cases'),
          caseEndpoint: Uri.parse('https://example.org/v1/read-case'),
          tokenProvider: auth.accessToken,
          transport: transport,
        ),
      );
      addTearDown(() {
        coordinator.dispose();
        auth.dispose();
      });
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigator,
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (_) => PlanAssistantScreen(
                    coordinator: coordinator,
                    model: FakeModel(),
                    onSection: (_) {},
                  ),
                ),
              ),
              child: const Text('Open chat'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open chat'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      TextField input() =>
          tester.widget(find.byKey(const ValueKey('assistant-input')));
      expect(find.byKey(const ValueKey('assistant-input')), findsNothing);
      expect(
        tester
            .widget<IconButton>(find.widgetWithIcon(IconButton, Icons.close))
            .onPressed,
        isNull,
      );
      store.readGate!.completeError(StateError('Read failed'));
      await tester.pumpAndSettle();
      expect(input().readOnly, true);
      store.readGate = Completer<void>();
      await tester.tap(find.text('Retry'));
      await tester.pump();
      expect(input().readOnly, true);
      store.readGate!.complete();
      await tester.pumpAndSettle();
      expect(input().readOnly, false);
      await tester.enterText(
        find.byKey(const ValueKey('assistant-input')),
        'Retained draft',
      );
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(find.byKey(const ValueKey('assistant-options')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Clear history'));
      await tester.pumpAndSettle();
      store.deleteGate = Completer<void>();
      await tester.tap(find.byKey(const ValueKey('assistant-confirm-clear')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(input().readOnly, true);
      expect(
        tester
            .widget<IconButton>(find.widgetWithIcon(IconButton, Icons.close))
            .onPressed,
        isNull,
      );
      await navigator.currentState!.maybePop();
      await tester.pump();
      expect(find.byType(PlanAssistantScreen), findsOneWidget);
      store.deleteGate!.completeError(StateError('Delete failed'));
      await tester.pumpAndSettle();
      expect(
        find.text(
          'Chat history could not be cleared. Retry to finish removing it from this phone.',
        ),
        findsOneWidget,
      );
      expect(input().readOnly, true);
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      expect(find.byType(PlanAssistantScreen), findsOneWidget);
      store.deleteGate = null;
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      expect(find.byType(PlanAssistantScreen), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'saved chat survives Close, background and unavailable model; clear requires confirmation',
    (tester) async {
      final h = (await tester.runAsync(safetyHarness))!;
      addTearDown(() {
        h.services.dispose();
        h.auth.dispose();
      });
      final model = FakeModel();
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                child: const Text('Ask Homi'),
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => PlanAssistantScreen(
                      coordinator: h.services.coordinator,
                      model: model,
                      onSection: (_) {},
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      Future<void> open() async {
        await tester.tap(find.text('Ask Homi'));
        await tester.pumpAndSettle();
      }

      Future<void> close() async {
        await tester.tap(find.byTooltip('Close'));
        await tester.pumpAndSettle();
      }

      await open();
      await tester.enterText(
        find.byKey(const ValueKey('assistant-input')),
        'Fictional saved question',
      );
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pumpAndSettle();
      expect(
        find.text('Open Rooms to review the saved model.'),
        findsOneWidget,
      );
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pumpAndSettle();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(
        find.text('Open Rooms to review the saved model.'),
        findsOneWidget,
      );
      await close();
      expect(find.byType(PlanAssistantScreen), findsNothing);
      model.status = AssistantAvailability.unavailable;
      await open();
      expect(
        find.text('Open Rooms to review the saved model.'),
        findsOneWidget,
      );
      expect(model.requests, hasLength(1));
      Future<void> requestClear() async {
        await tester.tap(find.byKey(const ValueKey('assistant-options')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Clear history'));
        await tester.pumpAndSettle();
        expect(find.text('Clear chat history?'), findsOneWidget);
      }

      await requestClear();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(
        find.text('Open Rooms to review the saved model.'),
        findsOneWidget,
      );
      await requestClear();
      await tester.tap(find.byKey(const ValueKey('assistant-confirm-clear')));
      await tester.pumpAndSettle();
      expect(find.text('Open Rooms to review the saved model.'), findsNothing);
      await close();
      await open();
      expect(find.text('Fictional saved question'), findsNothing);
      expect(model.requests, hasLength(1));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
