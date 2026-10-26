import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homi_local_llm/homi_local_llm.dart';
import 'package:safe_at_home/features/assistant/local_model_settings.dart';
import 'assistant_test.dart' show app;

class _Runtime extends HomiLocalLlm {
  bool busy = true, fail = false;
  int reads = 0;
  @override
  Future<LocalModelStatus> status() async {
    reads++;
    if (fail) throw StateError('unavailable');
    return LocalModelStatus(compiled: true, installed: false, busy: busy);
  }
}

void main() {
  for (final failure in [false, true]) {
    testWidgets(
      'model import recovers from initial ${failure ? 'failure' : 'busy'} status',
      (tester) async {
        final runtime = _Runtime()..fail = failure;
        await tester.pumpWidget(
          app(
            Scaffold(
              body: SingleChildScrollView(
                child: LocalModelSettings(runtime: runtime),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final import = find.widgetWithText(
          OutlinedButton,
          'Import verified model',
        );
        expect(tester.widget<OutlinedButton>(import).onPressed, isNull);
        runtime
          ..fail = false
          ..busy = false;
        await tester.tap(find.widgetWithText(TextButton, 'Check again'));
        await tester.pumpAndSettle();
        expect(runtime.reads, 2);
        expect(tester.widget<OutlinedButton>(import).onPressed, isNotNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
  testWidgets('return from background refreshes retained model status', (
    tester,
  ) async {
    final runtime = _Runtime();
    await tester.pumpWidget(
      app(Scaffold(body: LocalModelSettings(runtime: runtime))),
    );
    await tester.pumpAndSettle();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    runtime.busy = false;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(runtime.reads, 2);
    expect(
      tester
          .widget<OutlinedButton>(
            find.widgetWithText(OutlinedButton, 'Import verified model'),
          )
          .onPressed,
      isNotNull,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
