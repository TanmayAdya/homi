import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/features/assessment/application/assessment_controller.dart';
import 'package:safe_at_home/features/assessment/application/assessment_flow.dart';
import 'package:safe_at_home/features/assessment/application/bathroom_scan_adapter.dart';
import 'package:safe_at_home/features/assessment/application/bathroom_scan_session.dart';
import 'package:safe_at_home/features/assessment/application/export_review.dart';
import 'package:safe_at_home/features/assessment/domain/annotation/box_annotation.dart';
import 'package:safe_at_home/features/assessment/domain/assessment_location.dart';
import 'package:safe_at_home/features/assessment/domain/capture/capture_adapter.dart';
import 'package:safe_at_home/features/assessment/domain/capture/photo_capture_coordinator.dart';
import 'package:safe_at_home/features/assessment/domain/capture/staging_store.dart';
import 'package:safe_at_home/features/assessment/domain/image/image_validator.dart';
import 'package:safe_at_home/features/assessment/domain/image/private_media_platform.dart';
import 'package:safe_at_home/features/assessment/domain/measurement/measurement_fields.dart';
import 'package:safe_at_home/features/assessment/domain/measurement/measurement_input.dart';
import 'package:safe_at_home/features/assessment/domain/scan/bathroom_scan_scene.dart';
import 'package:safe_at_home/features/assessment/presentation/annotation_editor_screen.dart';
import 'package:safe_at_home/features/assessment/presentation/assessment_copy.dart';
import 'package:safe_at_home/features/assessment/presentation/assessment_flow_screen.dart';
import 'package:safe_at_home/features/assessment/presentation/assessment_location_guide.dart';
import 'package:safe_at_home/features/assessment/presentation/bathroom_scan_screen.dart';
import 'package:safe_at_home/features/assessment/presentation/export_review_screen.dart';
import 'package:safe_at_home/features/assessment/presentation/photo_privacy_screen.dart';
import 'package:safe_at_home/features/assessment/presentation/recovery_photo_review_card.dart';
import 'package:safe_at_home/features/assessment/presentation/saved_photo_with_marks.dart';
import 'package:safe_at_home/features/assessment/presentation/save_status_card.dart';
import 'package:safe_at_home/l10n/app_localizations.dart';
import 'package:safe_at_home/shared/models/evidence.dart';

import '../features/assessment/application/export_review_test.dart'
    show Fixture;
import '../features/assessment/fakes/decodable_photo.dart';
import '../features/assessment/fakes/fake_case_server.dart';
import '../features/assessment/fakes/fakes.dart';
import '../features/assessment/fakes/image_bytes.dart';
import 'app_design_test.dart' show narrowLargeText;
import 'core_localization_test.dart' show localized;
import 'live_workflows_test.dart' show MemoryPrivateStore;

const locales = [
  Locale('es'),
  Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hans'),
  Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant'),
];

Future<void> tap(WidgetTester tester, Finder finder) async {
  FocusManager.instance.primaryFocus?.unfocus();
  await tester.pump();
  if (finder.evaluate().isEmpty) {
    await tester.scrollUntilVisible(
      finder,
      250,
      scrollable: find.byType(Scrollable).first,
      maxScrolls: 100,
    );
  }
  await Scrollable.ensureVisible(tester.element(finder), alignment: .5);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<void> decode(WidgetTester tester) async {
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 80)),
  );
  await tester.pumpAndSettle();
}

void untruncated(WidgetTester tester, String text) {
  final found = find.text(text);
  expect(found, findsWidgets, reason: text);
  for (final element in found.evaluate()) {
    final paragraph = element.findRenderObject()! as RenderParagraph;
    expect(paragraph.didExceedMaxLines, false, reason: text);
  }
}

class FailingMedia extends PrivateMediaPlatform {
  final calls = <({List<double>? crop, List<List<double>> covers})>[];
  @override
  Future<Uint8List> edit(
    Uint8List bytes, {
    List<double>? crop,
    List<List<double>> redactions = const [],
  }) async {
    calls.add((crop: crop, covers: redactions));
    throw StateError('Fictional decoder failure');
  }
}

class ScanMemoryStore extends MemoryPrivateStore {
  final bytes = <String, Uint8List>{};
  @override
  Future<Uint8List?> readBytes(String key) async => bytes[key];
  @override
  Future<void> writeBytes(String key, Uint8List value) async {
    bytes[key] = Uint8List.fromList(value);
  }
}

class FailingScanner implements BathroomScanAdapter {
  String code = 'scan_permission_denied';
  @override
  Future<BathroomScanCapabilities> capabilities() async =>
      const BathroomScanCapabilities(
        supported: true,
        source: 'roomplan',
        reason: 'available',
        depthSupported: true,
      );
  @override
  Future<BathroomScanScene> start(String scanId) async =>
      throw PlatformException(
        code: code,
        message: 'Private untranslated native detail',
      );
  @override
  Future<void> cancel(String scanId) async {}
}

void main() {
  for (final locale in locales) {
    final words = AppLocalizations(locale);
    String tr(String text, [Map<String, Object?> values = const {}]) =>
        words.text(text, values);

    test(
      '$locale includes every capture, location and measurement safety state',
      () {
        final keys = <String>{
          for (final location in AssessmentLocation.values) ...[
            location.title,
            location.description,
            location.safetyNote,
            location.observationExample,
            for (final view in CaptureView.values) location.photoPrompt(view),
          ],
          for (final spec in proposedMeasurementFields) ...[
            spec.label,
            spec.definition,
            spec.howToMeasure,
          ],
          for (final error in LengthParseError.values)
            AssessmentCopy.measurementError(error),
          for (final error in ImageRejection.values)
            AssessmentCopy.rejected(error),
          for (final notice in <FlowNotice>[
            const CaptureCancelledNotice(),
            const PermissionNotice(canAskAgain: true),
            const PermissionNotice(canAskAgain: false),
            const CameraUnavailableNotice(),
            const CaptureFailedNotice(),
            const PhotoImportFailedNotice(timedOut: true),
            const PhotoImportFailedNotice(timedOut: false),
            const PhotoPreviewUnavailableNotice(),
            const PhotoRemovedNotice(),
            const InterruptedCaptureNotice(),
            const InterruptedPrivacyNotice(),
            const PrivatePhotoSaveFailedNotice(),
            const PhotoTargetChangedNotice(),
            const PhotoCaptureLimitNotice(),
          ])
            AssessmentCopy.notice(notice)!,
          for (final code in [
            'scan_cancelled',
            'scan_interrupted',
            'scan_permission_denied',
            'scan_unavailable',
            'scan_busy',
            'scan_limit',
            'unknown',
          ])
            scanErrorMessage(PlatformException(code: code)),
        };
        for (final key in keys) {
          expect(tr(key), isNot(key), reason: '$locale missing: $key');
        }
      },
    );

    for (final large in [false, true]) {
      testWidgets(
        '$locale all room routes preserve input and localize review (${large ? '320px/3.2x' : 'normal'})',
        (tester) async {
          if (large) narrowLargeText(tester, scale: 3.2);
          final staging = InMemoryStagingStore();
          final controller = AssessmentController(ids: SequentialIdFactory());
          final adapter = ScriptedCaptureAdapter();
          final flow = AssessmentFlow(
            controller: controller,
            capture: PhotoCaptureCoordinator(
              adapter: adapter,
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
          for (final location in AssessmentLocation.values) {
            await tap(tester, find.byKey(ValueKey('area-${location.name}')));
            expect(find.text(tr(location.safetyNote)), findsOneWidget);
            if (location == AssessmentLocation.bathroom) {
              adapter.enqueue(
                const CapturePermissionDenied(canAskAgain: false),
              );
              await tap(tester, find.text(tr('Open camera')));
              expect(
                find.text(
                  tr(
                    AssessmentCopy.notice(
                      const PermissionNotice(canAskAgain: false),
                    )!,
                  ),
                ),
                findsOneWidget,
              );
              await tap(tester, find.text(tr('I changed the setting')));
            }
            await tap(tester, find.text(tr('Continue without a photo')));
            await tap(tester, find.text(tr('Review')));
            untruncated(tester, tr(AssessmentCopy.observationRequired));
            final resident =
                'Original {count}: manual / confirmed / 家人的话 ${location.name}';
            await tester.enterText(
              find.byKey(const ValueKey('observation')),
              resident,
            );
            await tap(tester, find.text(tr('Review')));
            final shown = location.area == AssessmentArea.other
                ? '${tr(location.title)}: $resident'
                : resident;
            expect(find.text(shown), findsOneWidget);
            await tap(tester, find.text(tr('Confirm this finding')));
            expect(
              controller.findings.last.observation,
              location.observationWithLocation(resident),
            );
            expect(controller.findings.last.room, location.area.name);
            await tap(tester, find.text(tr('Done, add another finding')));
            expect(find.text(shown), findsOneWidget);
            expect(tester.takeException(), isNull);
          }
        },
      );
    }

    for (final large in [false, true]) {
      testWidgets(
        '$locale measurement labels keep the full question and units at ${large ? '3.2x' : 'normal'} text',
        (tester) async {
          narrowLargeText(tester, scale: large ? 3.2 : 1);
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
          await tap(tester, find.byKey(const ValueKey('area-entrance')));
          await tap(tester, find.text(tr('Continue without a photo')));
          await tap(tester, find.text(tr('Add measurements (optional)')));
          for (final type in flow.measurementTypes) {
            final label = find.byKey(ValueKey('measurement-full-label-$type'));
            await tester.ensureVisible(label);
            await tester.pumpAndSettle();
            final spec = measurementFieldSpecFor(type)!;
            final expected = tr('{label} ({unit})', {
              'label': tr(spec.label),
              'unit': tr(flow.entryFor(type).unit.symbol),
            });
            expect(tester.widget<Text>(label).data, expected);
            final paragraph = tester.renderObject<RenderParagraph>(label);
            expect(paragraph.didExceedMaxLines, false);
            expect(paragraph.maxLines, isNull);
            expect(tester.getRect(label).width, lessThanOrEqualTo(320));
            final field = tester.widget<TextField>(
              find.byKey(ValueKey('measurement-$type')),
            );
            expect(field.decoration!.labelText, expected);
          }
          expect(tester.takeException(), isNull);
        },
      );
    }

    testWidgets(
      '$locale measurements validate, correct, clear and retain original history at 3.2x',
      (tester) async {
        narrowLargeText(tester, scale: 3.2);
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
        await tap(tester, find.byKey(const ValueKey('area-entrance')));
        await tap(tester, find.text(tr('Continue without a photo')));
        await tester.enterText(
          find.byKey(const ValueKey('observation')),
          'Resident doorway note {value}',
        );
        await tap(tester, find.text(tr('Add measurements (optional)')));
        final field = find.byKey(const ValueKey('measurement-clearOpening'));
        await tester.enterText(field, '1,500');
        await tap(tester, find.text(tr('Review')));
        untruncated(
          tester,
          tr(
            AssessmentCopy.measurementError(
              LengthParseError.unexpectedSeparator,
            ),
          ),
        );
        await tester.enterText(field, ' 02.50 ');
        await tap(
          tester,
          find.descendant(
            of: find.byKey(const ValueKey('unit-clearOpening')),
            matching: find.text(tr('cm')),
          ),
        );
        await tap(tester, find.byKey(const ValueKey('estimate-clearOpening')));
        await tap(tester, find.text(tr('Review')));
        final recorded = controller.drafts.single.measurements.single;
        expect(recorded.input.originalText, ' 02.50 ');
        expect(recorded.input.millimetres, 25);
        expect(recorded.method, MeasurementMethod.estimated);
        await tap(tester, find.text(tr('Confirm this finding')));
        await tap(tester, find.text(tr('Edit')));
        await tester.enterText(field, '3');
        await tap(tester, find.text(tr('Review')));
        expect(
          controller.measurementHistoryOf(flow.findingId!, 'clearOpening'),
          hasLength(1),
        );
        expect(find.textContaining('02.50'), findsOneWidget);
        await tap(tester, find.text(tr('Edit')));
        await tester.enterText(field, '');
        await tap(tester, find.text(tr('Review')));
        expect(
          find.text(
            tr('{label}: not recorded now', {
              'label': tr('Clear opening width'),
            }),
          ),
          findsOneWidget,
        );
        expect(controller.drafts.single.measurements, isEmpty);
        expect(
          controller.measurementHistoryOf(flow.findingId!, 'clearOpening'),
          hasLength(2),
        );
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      '$locale privacy edits fail safely; photo recovery and annotation controls wrap',
      (tester) async {
        narrowLargeText(tester, scale: 3.2);
        final media = FailingMedia();
        await tester.pumpWidget(
          localized(
            locale,
            PhotoPrivacyScreen(bytes: fictionalPng(), media: media),
          ),
        );
        await decode(tester);
        await tap(tester, find.byTooltip(tr('Make wider')));
        await tap(tester, find.text(tr('Add opaque cover')));
        await tap(tester, find.text(tr('Crop to outlined area')));
        await tap(tester, find.text(tr('Apply and review photo')));
        expect(
          find.text(
            tr(
              'The edit could not be applied. Your original photo and selected edits are still available. Try again.',
            ),
          ),
          findsOneWidget,
        );
        await tap(tester, find.text(tr('Apply and review photo')));
        expect(media.calls, hasLength(2));
        expect(media.calls[0].crop, media.calls[1].crop);
        expect(media.calls[0].covers, media.calls[1].covers);
        expect(tester.takeException(), isNull);
        var keptSaved = false, keptDevice = false;
        await tester.pumpWidget(
          localized(
            locale,
            Scaffold(
              body: SingleChildScrollView(
                child: RecoveryPhotoReviewCard(
                  bytes: pngHeader(width: 1200, height: 900),
                  busy: false,
                  onShowSaved: () {},
                  onKeepSaved: () => keptSaved = true,
                  onKeepDevice: () => keptDevice = true,
                ),
              ),
            ),
          ),
        );
        await decode(tester);
        expect(
          tester
              .widget<FilledButton>(
                find.widgetWithText(FilledButton, tr('Keep the saved photo')),
              )
              .onPressed,
          isNull,
        );
        await tap(
          tester,
          find.text(tr('Keep device photo to upload after review')),
        );
        expect(keptSaved, false);
        expect(keptDevice, true);
        final annotations = AnnotationStore(newId: () => 'box');
        const image = AnnotatedImage(
          evidenceId: 'photo',
          version: 'local:fixture',
          width: 1200,
          height: 900,
        );
        await tester.pumpWidget(
          localized(
            locale,
            AnnotationEditorScreen(
              store: annotations,
              findingId: 'finding',
              image: image,
              bytes: fictionalPng(),
              observation: 'Resident original {label}',
            ),
          ),
        );
        await decode(tester);
        await tap(tester, find.text(tr('Add a box')));
        await tester.enterText(
          find.byKey(const ValueKey('annotation-label')),
          'Move right {label}',
        );
        await tap(tester, find.byTooltip(tr('Move right')));
        await tap(tester, find.text(tr('Hide the box')));
        expect(annotations.on(image).single.hidden, true);
        await tap(tester, find.text(tr('Show the box')));
        expect(annotations.on(image).single.label, 'Move right {label}');
        expect(annotations.on(image).single.rect.left, 460);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      '$locale saved photo failures and history translate app copy only',
      (tester) async {
        narrowLargeText(tester, scale: 3.2);
        late String history;
        await tester.pumpWidget(
          localized(
            locale,
            Builder(
              builder: (context) {
                history = assessmentHistoryValue(context, {
                  'findingId': 'private-id',
                  'originalText': ' 02.50 ',
                  'originalUnit': 'cm',
                  'source': 'manual',
                  'recorder': 'helper',
                  'state': 'needs_review',
                  'confirmed': false,
                  'observation': 'manual',
                  'note': 'confirmed',
                });
                return Scaffold(
                  body: SingleChildScrollView(
                    child: Column(
                      children: [
                        Text(history),
                        SavedPhotoWithMarks(
                          bytes: Uint8List.fromList([1, 2]),
                          width: 1,
                          height: 1,
                          marks: const [],
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        );
        await decode(tester);
        expect(history, contains('${tr('Original input')}:  02.50 '));
        expect(
          history,
          contains('${tr('Measurement source')}: ${tr('Measured')}'),
        );
        expect(
          history,
          contains('${tr('Review state')}: ${tr('Needs your review')}'),
        );
        expect(history, contains('${tr('Observation')}: manual'));
        expect(history, contains('${tr('Note')}: confirmed'));
        expect(history, isNot(contains('private-id')));
        expect(find.text(tr('Photo preview unavailable')), findsOneWidget);
        expect(
          find.byWidgetPredicate(
            (w) =>
                w is Semantics &&
                w.properties.label ==
                    '${tr('Saved photo with observations')}. ',
          ),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      '$locale native scan failures explain recovery at 3.2x without exposing raw error text',
      (tester) async {
        narrowLargeText(tester, scale: 3.2);
        final scanner = FailingScanner();
        final session = BathroomScanSession(
          store: ScanMemoryStore(),
          caseId: 'f4b1b823-f3e5-4a77-825c-9b1696f21fe6',
          isCurrent: () => true,
          adapter: scanner,
        );
        await tester.pumpWidget(
          localized(
            locale,
            BathroomScanScreen(
              session: session,
              importedFinding: (_) => null,
              onImport: (_) async => 'unused',
            ),
          ),
        );
        await tester.pumpAndSettle();
        for (final code in [
          'scan_permission_denied',
          'scan_interrupted',
          'scan_limit',
          'scan_unavailable',
        ]) {
          scanner.code = code;
          await tap(tester, find.byKey(const ValueKey('bathroom-start-scan')));
          final notice = find.text(
            tr(scanErrorMessage(PlatformException(code: code))),
          );
          await tester.scrollUntilVisible(
            notice,
            -200,
            scrollable: find.byType(Scrollable).first,
            maxScrolls: 100,
          );
          await tester.pumpAndSettle();
          expect(notice, findsOneWidget);
          expect(find.textContaining('Private untranslated'), findsNothing);
          expect(
            tr('Use photos and measurements'),
            isNot('Use photos and measurements'),
          );
          expect(tester.takeException(), isNull);
        }
      },
    );

    testWidgets(
      '$locale photo export checks, orders and removes selection at 3.2x',
      (tester) async {
        narrowLargeText(tester, scale: 3.2);
        late Fixture fx;
        late List<String> photos;
        await tester.runAsync(() async {
          fx = await Fixture.create(photoBytes: fictionalPng());
          photos = (await fx.seed()).photos;
        });
        final review = ExportReview(
          gateway: fx.server,
          currentCase: () => fx.sync.savedCase,
        );
        List<EvidenceSelection>? handed;
        await tester.pumpWidget(
          localized(
            locale,
            ExportReviewScreen(
              review: review,
              savedCase: () => fx.sync.savedCase,
              onDone: (s) => handed = s,
            ),
          ),
        );
        await tester.pumpAndSettle();
        for (final photo in photos.take(2)) {
          final card = find.byKey(ValueKey('candidate-$photo'));
          await tap(
            tester,
            find.descendant(of: card, matching: find.text(tr('Show photo'))),
          );
          await decode(tester);
          await tap(
            tester,
            find.descendant(
              of: card,
              matching: find.text(tr('I checked this photo')),
            ),
          );
          await tap(tester, find.byKey(ValueKey('include-$photo')));
        }
        await tap(
          tester,
          find.byTooltip(tr('Move photo {number} earlier', {'number': 2})),
        );
        expect(review.selections.first.evidenceId, photos[1]);
        await tap(
          tester,
          find.byTooltip(
            tr('Remove photo {number} from the draft', {'number': 2}),
          ),
        );
        await tap(tester, find.text(tr('Use these photos')));
        expect(handed!.single.evidenceId, photos[1]);
        expect(handed!.single.reviewedForExport, true);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      '$locale saving failure localizes known API error and retains findings',
      (tester) async {
        narrowLargeText(tester, scale: 3.2);
        late Fixture fx;
        await tester.runAsync(() async {
          fx = await Fixture.create();
          final id = fx.controller.startFinding(AssessmentArea.entrance);
          fx.controller.setObservation(id, 'Resident original');
          fx.server.failNext['saveCase'] = (
            'SERVICE_UNAVAILABLE',
            FailMode.before,
          );
          await fx.sync.save();
        });
        await tester.pumpWidget(
          localized(
            locale,
            Scaffold(
              body: SingleChildScrollView(child: SaveStatusCard(sync: fx.sync)),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(fx.sync.errorMessage, isNotNull);
        final message = tr('{error} Your findings are still here.', {
          'error': tr(fx.sync.errorMessage!),
        });
        expect(find.text(message), findsOneWidget);
        expect(fx.controller.findings.single.observation, 'Resident original');
        expect(tester.takeException(), isNull);
      },
    );
  }
}
