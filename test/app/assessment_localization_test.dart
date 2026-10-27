import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/features/assessment/application/assessment_controller.dart';
import 'package:safe_at_home/features/assessment/application/assessment_flow.dart';
import 'package:safe_at_home/features/assessment/domain/annotation/box_annotation.dart';
import 'package:safe_at_home/features/assessment/domain/capture/photo_capture_coordinator.dart';
import 'package:safe_at_home/features/assessment/domain/capture/staging_store.dart';
import 'package:safe_at_home/features/assessment/presentation/annotation_editor_screen.dart';
import 'package:safe_at_home/features/assessment/presentation/assessment_flow_screen.dart';
import 'package:safe_at_home/features/cases/profile_editor_screen.dart';
import 'package:safe_at_home/l10n/app_localizations.dart';

import '../features/assessment/fakes/decodable_photo.dart';
import '../features/assessment/fakes/fakes.dart';
import '../services/case_evidence_api_client_test.dart' as http;
import 'app_design_test.dart' show narrowLargeText;
import 'case_coordinator_test.dart' show FakeTransport;
import 'core_localization_test.dart' show localized;
import 'live_workflows_test.dart' show MemoryPrivateStore, services;

Future<void> _tap(WidgetTester tester, Finder target) async {
  FocusManager.instance.primaryFocus?.unfocus();
  await tester.pump();
  await Scrollable.ensureVisible(tester.element(target), alignment: .5);
  await tester.pumpAndSettle();
  await tester.tap(target);
  await tester.pumpAndSettle();
}

void main() {
  for (final locale in [
    const Locale('es'),
    const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hans'),
    const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant'),
    const Locale('vi'),
    const Locale('fil'),
  ]) {
    testWidgets('$locale guided assessment remains usable at 3.2x text', (
      tester,
    ) async {
      narrowLargeText(tester, scale: 3.2);
      final words = AppLocalizations(locale);
      final staging = InMemoryStagingStore();
      final controller = AssessmentController(ids: SequentialIdFactory());
      final flow = AssessmentFlow(
        controller: controller,
        capture: PhotoCaptureCoordinator(
          adapter: ScriptedCaptureAdapter(),
          staging: staging,
        ),
        staging: staging,
      );
      addTearDown(flow.dispose);
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        localized(locale, AssessmentFlowScreen(flow: flow)),
      );
      await tester.pumpAndSettle();
      expect(words.text('Choose a place'), isNot('Choose a place'));
      expect(find.text(words.text('Choose a place')), findsWidgets);
      await _tap(tester, find.byKey(const ValueKey('area-stairs')));
      expect(
        find.text(
          words.text(
            'Take photos from a stable place. Don’t use stairs or lean on a rail just to test it.',
          ),
        ),
        findsOneWidget,
      );
      await _tap(tester, find.text(words.text('Continue without a photo')));
      const observation = 'Resident text {count}: baño original.';
      await tester.enterText(
        find.byKey(const ValueKey('observation')),
        observation,
      );
      await _tap(tester, find.text(words.text('Review')));
      expect(
        find.text('${words.text('Stairs')}: $observation'),
        findsOneWidget,
      );
      await _tap(tester, find.text(words.text('Confirm this finding')));
      expect(controller.findings.single.observation, 'Stairs: $observation');
      expect(controller.findings.single.room, 'other');
      expect(controller.findings.single.reviewState, 'confirmed');
      expect(controller.findings.single.measurements, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets(
    'profile language changes preserve input and canonical county autofill',
    (tester) async {
      final store = MemoryPrivateStore();
      final transport = FakeTransport((request) async {
        expect(request.endpoint.path, '/v1/create-case');
        return http.jsonResponse({...http.requestJson(request), 'revision': 1});
      });
      final app = services(store, transport);
      addTearDown(() {
        app.dispose();
        app.session.dispose();
      });
      await app.coordinator.createDraft();
      final screen = ProfileEditorScreen(services: app);
      await tester.pumpWidget(localized(const Locale('es'), screen));
      await tester.pumpAndSettle();
      final city = find.widgetWithText(TextField, 'Ciudad');
      await tester.ensureVisible(city);
      await tester.enterText(city, 'San J');
      await tester.pump();
      const chinese = Locale.fromSubtags(
        languageCode: 'zh',
        scriptCode: 'Hant',
      );
      await tester.pumpWidget(localized(chinese, screen));
      await tester.pumpAndSettle();
      final changedCity = find.widgetWithText(TextField, '城市');
      expect(tester.widget<TextField>(changedCity).controller!.text, 'San J');
      await tester.ensureVisible(changedCity);
      await tester.pumpAndSettle();
      final suggestion = find.byKey(
        const ValueKey('profile-suggestion-city-San José'),
      );
      await tester.ensureVisible(suggestion);
      await tester.tap(suggestion);
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(changedCity).controller!.text,
        'San José',
      );
      final county = find.widgetWithText(
        TextField,
        AppLocalizations(chinese).text('County'),
      );
      expect(tester.widget<TextField>(county).controller!.text, 'Santa Clara');
      expect(find.text('已根據San José填寫。您可以變更。'), findsOneWidget);
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(
        app.coordinator.currentDraft().profile.toJson()['city'],
        'San José',
      );
      expect(
        app.coordinator.currentDraft().profile.toJson()['county'],
        'Santa Clara',
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('localized annotation controls retain resident labels verbatim', (
    tester,
  ) async {
    final store = AnnotationStore(newId: () => 'fictional-box');
    const image = AnnotatedImage(
      evidenceId: 'fictional-photo',
      version: 'local:fictional',
      width: 1200,
      height: 900,
    );
    const observation = 'Photo {number}: resident original';
    await tester.pumpWidget(
      localized(
        const Locale('vi'),
        AnnotationEditorScreen(
          store: store,
          findingId: 'fictional-finding',
          image: image,
          bytes: fictionalPng(),
          observation: observation,
        ),
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pumpAndSettle();
    expect(find.text('Ghi nhận của bạn: $observation'), findsOneWidget);
    await _tap(tester, find.text('Thêm khung'));
    const label = 'Move left {label} — residents’ words';
    await tester.enterText(
      find.byKey(const ValueKey('annotation-label')),
      label,
    );
    await _tap(tester, find.byTooltip('Sang phải'));
    expect(store.on(image).single.label, label);
    expect(store.on(image).single.rect.left, 460);
    expect(tester.takeException(), isNull);
  });
}
