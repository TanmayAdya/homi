import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/app/private_content_cover.dart';

String exposedSemantics(WidgetTester tester) => tester
    .binding
    .renderViews
    .single
    .owner!
    .semanticsOwner!
    .rootSemanticsNode!
    .toStringDeep();

void main() {
  testWidgets(
    'inactive private routes disappear from semantics and reject input',
    (tester) async {
      final semantics = tester.ensureSemantics();
      final controller = TextEditingController(
        text: 'Fictional resident draft',
      );
      try {
        var saved = 0;
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pumpWidget(
          MaterialApp(
            builder: (context, child) => PrivateContentCover(child: child!),
            home: Scaffold(
              body: Column(
                children: [
                  TextField(
                    controller: controller,
                    decoration: const InputDecoration(
                      labelText: 'Resident notes',
                    ),
                  ),
                  FilledButton(
                    onPressed: () => saved++,
                    child: const Text('Save private details'),
                  ),
                ],
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(exposedSemantics(tester), contains('Resident notes'));
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        await tester.pump();
        final covered = exposedSemantics(tester);
        expect(covered, isNot(contains('Resident notes')));
        expect(covered, isNot(contains('Fictional resident draft')));
        expect(covered, isNot(contains('Save private details')));
        expect(covered, contains('Safe at Home'));
        await tester.tap(
          find.text('Save private details'),
          warnIfMissed: false,
        );
        await tester.pump();
        expect(saved, 0);
        expect(controller.text, 'Fictional resident draft');
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pumpAndSettle();
        expect(exposedSemantics(tester), contains('Resident notes'));
        await tester.tap(find.text('Save private details'));
        expect(saved, 1);
        expect(controller.text, 'Fictional resident draft');
      } finally {
        semantics.dispose();
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pumpWidget(const SizedBox.shrink());
        controller.dispose();
      }
    },
  );

  testWidgets('a route opened while already inactive starts covered', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    try {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pumpWidget(
        const MaterialApp(
          home: PrivateContentCover(
            child: Scaffold(body: Text('Fictional sensitive details')),
          ),
        ),
      );
      await tester.pump();
      expect(
        exposedSemantics(tester),
        isNot(contains('Fictional sensitive details')),
      );
      expect(exposedSemantics(tester), contains('Safe at Home'));
      expect(tester.takeException(), isNull);
    } finally {
      semantics.dispose();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    }
  });
}
