import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/app/safe_at_home_app.dart';
import 'package:safe_at_home/shared/models/contracts.dart';
import 'package:safe_at_home/shared/services/demo_scenario_service.dart';

void main() {
  testWidgets('bundled examples distinguish pass, fail and missing facts', (
    tester,
  ) async {
    final scenarios = await tester.runAsync(
      () => AssetDemoScenarioService().loadScenarios(),
    );
    await tester.pumpWidget(
      SafeAtHomeApp(scenarioService: _FixedScenarioService(scenarios!)),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('Fictional demo'), findsOneWidget);
    expect(find.text('Meets the example criteria'), findsOneWidget);
    expect(find.text('Health plan: Example Plan'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('scenario-not-matched')));
    await tester.pumpAndSettle();
    expect(find.text('An example criterion is not met'), findsOneWidget);
    expect(find.text('Health plan: Another Plan'), findsOneWidget);
    expect(find.text('Meets the example criteria'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('scenario-unknown')));
    await tester.pumpAndSettle();
    expect(find.text('More information is needed'), findsOneWidget);
    expect(find.text('Health plan: Not provided'), findsOneWidget);
    expect(find.text('Needs confirmation'), findsOneWidget);
    expect(
      find.text('Next step: confirm the missing resident details.'),
      findsOneWidget,
    );
    expect(find.text('An example criterion is not met'), findsNothing);
  });

  testWidgets('asset loading failure offers a working retry', (tester) async {
    final scenarios = await tester.runAsync(
      () => AssetDemoScenarioService().loadScenarios(),
    );
    final service = _RetryScenarioService(scenarios!);
    await tester.pumpWidget(SafeAtHomeApp(scenarioService: service));
    await tester.pumpAndSettle();
    expect(find.text('The example cases could not be loaded.'), findsOneWidget);

    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();
    expect(service.attempts, 2);
    expect(find.text('Meets the example criteria'), findsOneWidget);
  });

  testWidgets('narrow screen with large text can reach result explanations', (
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

    final scenarios = await tester.runAsync(
      () => AssetDemoScenarioService().loadScenarios(),
    );
    await tester.pumpWidget(
      SafeAtHomeApp(scenarioService: _FixedScenarioService(scenarios!)),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final missing = find.byKey(const ValueKey('scenario-unknown'));
    await tester.ensureVisible(missing);
    await tester.tap(missing);
    await tester.pumpAndSettle();
    final nextStep = find.text(
      'Next step: confirm the missing resident details.',
    );
    await tester.ensureVisible(nextStep);
    await tester.pumpAndSettle();
    expect(nextStep.hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

class _RetryScenarioService implements DemoScenarioService {
  _RetryScenarioService(this.scenarios);

  final List<DemoScenario> scenarios;
  int attempts = 0;

  @override
  Future<List<DemoScenario>> loadScenarios() async {
    attempts += 1;
    if (attempts == 1) throw StateError('Simulated missing asset');
    return scenarios;
  }
}

class _FixedScenarioService implements DemoScenarioService {
  _FixedScenarioService(this.scenarios);
  final List<DemoScenario> scenarios;

  @override
  Future<List<DemoScenario>> loadScenarios() async => scenarios;
}
