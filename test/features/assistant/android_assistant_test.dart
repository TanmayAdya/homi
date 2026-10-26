import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/features/assistant/assistant_context.dart';
import 'package:safe_at_home/features/assistant/assistant_controller.dart';
import 'package:safe_at_home/features/assistant/assistant_model.dart';
import 'package:safe_at_home/features/assistant/plan_assistant_screen.dart';
import 'package:safe_at_home/l10n/app_localizations.dart';
import 'package:safe_at_home/l10n/catalogs/android_features.dart';
import 'assistant_test.dart' show FakeModel, app;

class _DownloadModel extends FakeModel implements DownloadableAssistantModel {
  _DownloadModel() {
    status = AssistantAvailability.modelDownloadable;
  }
  Completer<void>? downloadResult;
  final downloads = <String>[];
  @override
  Future<void> download(String id) async {
    downloads.add(id);
    await downloadResult?.future;
    status = AssistantAvailability.ready;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'Android native model download is explicit and sends only a fresh cancellation ID',
    () async {
      const channel = MethodChannel('test/android-assistant');
      final calls = <MethodCall>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return call.method == 'availability' ? 'modelDownloadable' : null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      const model = OnDeviceAssistantModel(
        channel: channel,
        platform: TargetPlatform.android,
      );
      expect(
        await model.availability('en'),
        AssistantAvailability.modelDownloadable,
      );
      expect(calls.map((c) => c.method), ['availability']);
      await model.download('id');
      await model.cancel('id');
      expect(calls[1].method, 'download');
      expect(calls[1].arguments, {'requestId': 'id'});
      expect(calls.last.arguments, {'requestId': 'id'});
      const iphone = OnDeviceAssistantModel(
        channel: channel,
        platform: TargetPlatform.iOS,
      );
      await expectLater(
        iphone.download('id'),
        throwsA(isA<AssistantFailure>()),
      );
      expect(calls, hasLength(3));
    },
  );
  test(
    'download completion rechecks readiness without a prompt, plan write or conversation',
    () async {
      final model = _DownloadModel();
      final c = AssistantController(
        model: model,
        contextProvider: () => const AssistantContext(key: 'fictional'),
        locale: 'en',
      );
      addTearDown(c.dispose);
      await c.check();
      expect(model.downloads, isEmpty);
      await c.downloadModel();
      expect(model.downloads, hasLength(1));
      expect(model.requests, isEmpty);
      expect(c.availability, AssistantAvailability.ready);
      expect(c.turns, isEmpty);
    },
  );
  test('cancel and scope changes fence a late download result', () async {
    final model = _DownloadModel()..downloadResult = Completer<void>();
    AssistantContext? scope = const AssistantContext(key: 'first');
    final c = AssistantController(
      model: model,
      contextProvider: () => scope,
      locale: 'en',
    );
    addTearDown(c.dispose);
    await c.check();
    final pending = c.downloadModel();
    expect(c.busy, isTrue);
    scope = const AssistantContext(key: 'other');
    c.refreshContext();
    expect(model.cancelled, model.downloads);
    expect(c.busy, isFalse);
    model.downloadResult!.complete();
    await pending;
    expect(c.context!.key, 'other');
    expect(c.availability, AssistantAvailability.modelDownloadable);
    expect(c.turns, isEmpty);
  });
  for (final locale in AppLocalizations.supportedLocales) {
    testWidgets(
      '$locale Android download action is reachable at large text without automatic download',
      (tester) async {
        tester.view.physicalSize = const Size(320, 720);
        tester.view.devicePixelRatio = 1;
        tester.platformDispatcher.textScaleFactorTestValue = 3.2;
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
          tester.platformDispatcher.clearTextScaleFactorTestValue();
        });
        final model = _DownloadModel();
        await tester.pumpWidget(
          app(
            PlanAssistantScreen(onSection: (_) {}, model: model),
            locale: locale,
          ),
        );
        await tester.pumpAndSettle();
        expect(model.downloads, isEmpty);
        final button = find.byKey(const ValueKey('assistant-download-model'));
        final list = find.byKey(const ValueKey('assistant-messages'));
        tester
            .state<ScrollableState>(
              find
                  .descendant(of: list, matching: find.byType(Scrollable))
                  .first,
            )
            .position
            .jumpTo(0);
        await tester.pumpAndSettle();
        for (
          var i = 0;
          i < 30 && button.hitTestable().evaluate().isEmpty;
          i++
        ) {
          await tester.drag(list, const Offset(0, -180));
          await tester.pumpAndSettle();
        }
        expect(button.hitTestable(), findsOneWidget);
        await tester.tap(button);
        await tester.pumpAndSettle();
        expect(model.downloads, hasLength(1));
        expect(model.requests, isEmpty);
        expect(find.byKey(const ValueKey('assistant-input')), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }
  test(
    'Android feature disclosures and native guidance preserve every locale and placeholder',
    () {
      for (final row in {
        ...androidFeatureTranslations,
        ...androidFeatureNativeTranslations,
      }.entries) {
        expect(row.value.keys.toSet(), {
          'es',
          'zh-Hans',
          'zh-Hant',
          'vi',
          'fil',
        });
        final tokens = RegExp(
          r'\{[^}]+\}',
        ).allMatches(row.key).map((m) => m[0]).toSet();
        for (final value in row.value.values) {
          expect(value.trim(), isNotEmpty);
          expect(
            RegExp(r'\{[^}]+\}').allMatches(value).map((m) => m[0]).toSet(),
            tokens,
          );
        }
      }
    },
  );
}
