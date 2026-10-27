import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as image_ui;

import 'package:flutter/material.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:safe_at_home/l10n/app_language.dart';
import 'package:safe_at_home/l10n/app_localizations.dart';
import 'package:safe_at_home/features/assessment/domain/capture/capture_adapter.dart';
import 'package:safe_at_home/features/assessment/presentation/saved_photo_with_marks.dart';
import 'package:safe_at_home/features/cases/case_home_screen.dart';
import 'package:safe_at_home/features/programs/live_programs_screen.dart';
import 'package:safe_at_home/features/requests/application_workspace_screen.dart';
import 'package:safe_at_home/shared/services/case_evidence_api_client.dart';
import 'package:safe_at_home/shared/services/local_private_store.dart';
import 'package:safe_at_home/shared/services/matching_api_client.dart';

import 'support/local_acceptance_harness.dart';

List<double> normalizedGlyphInkMask(List<(int, int)> ink) {
  const grid = 16;
  final left = ink.map((point) => point.$1).reduce(math.min);
  final right = ink.map((point) => point.$1).reduce(math.max) + 1;
  final top = ink.map((point) => point.$2).reduce(math.min);
  final bottom = ink.map((point) => point.$2).reduce(math.max) + 1;
  final result = List<double>.filled(grid * grid, 0);
  for (final (x, y) in ink) {
    final x0 = (x - left) * grid / (right - left);
    final x1 = (x + 1 - left) * grid / (right - left);
    final y0 = (y - top) * grid / (bottom - top);
    final y1 = (y + 1 - top) * grid / (bottom - top);
    for (var row = y0.floor(); row < y1.ceil().clamp(0, grid); row++) {
      for (var col = x0.floor(); col < x1.ceil().clamp(0, grid); col++) {
        result[row * grid + col] +=
            (math.min(col + 1, x1) - math.max(col, x0)) *
            (math.min(row + 1, y1) - math.max(row, y0));
      }
    }
  }
  return result;
}

double normalizedInkDifference(List<double> a, List<double> b) {
  var difference = 0.0, union = 0.0;
  for (var i = 0; i < a.length; i++) {
    difference += (a[i] - b[i]).abs();
    union += math.max(a[i], b[i]);
  }
  return difference / union;
}

List<PdfRect> pdfGlyphRectsForMatch(PdfPageRawText text, String value) {
  final start = text.fullText.indexOf(value);
  if (value.isEmpty || start < 0) {
    throw ArgumentError.value(value, 'value', 'Expected an exact text match');
  }
  final usesCodeUnits = text.charRects.length == text.fullText.length;
  if (!usesCodeUnits && text.charRects.length != text.fullText.runes.length) {
    throw StateError('PDF character bounds do not align with extracted text');
  }
  var index = usesCodeUnits
      ? start
      : text.fullText.substring(0, start).runes.length;
  return [
    for (final rune in value.runes)
      (() {
        final count = usesCodeUnits && rune > 0xffff ? 2 : 1;
        final parts = text.charRects.sublist(index, index + count);
        index += count;
        final visible = parts.where((rect) => rect.isNotEmpty).toList();
        return visible.isEmpty ? PdfRect.empty : visible.boundingRect();
      })(),
  ];
}

bool requiresEmbeddedChineseFont(PdfFontQuery font) =>
    font.face.toLowerCase().contains('safeathomecjk') ||
    font.charset == PdfFontCharset.gb2312 ||
    font.charset == PdfFontCharset.chineseBig5;

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'fictional iPhone journey uses real local HTTP, PostgreSQL, private storage and PDFs',
    (tester) async {
      final config = LocalFixtureConfig.fromEnvironment();
      final h = AcceptanceHarness(config);
      final packetText = config.packetText;
      final l10n = AppLocalizations(config.language.locale!);
      String ui(String english, [Map<String, Object?> arguments = const {}]) {
        if (config.language != AppLanguage.english) {
          expect(
            AppLocalizations.translations[english]?[config.language.code],
            isNotNull,
            reason: 'Missing app UI translation: $english',
          );
        }
        return l10n.text(english, arguments);
      }

      final checkpoints = <String>[];
      final screenshots = <String>[];
      var cjkGlyphsRendered = 0;
      var cjkDistinctNameChecks = 0;
      var cjkMissingFontGuards = 0;
      void checkpoint(String message) {
        checkpoints.add(message);
        debugPrint('LOCAL_ACCEPTANCE: $message');
      }

      Future<void> screenshot(String screen) async {
        if (!const bool.fromEnvironment('SAH_IOS_CAPTURE_SCREENSHOTS')) return;
        await tester.pumpAndSettle(
          const Duration(milliseconds: 100),
          EnginePhase.sendSemanticsUpdate,
          const Duration(seconds: 10),
        );
        final name =
            '${config.language.code}-${screenshots.length + 1}-$screen';
        final bytes = await binding.takeScreenshot(name);
        final directory = Directory(
          '${Directory.systemTemp.path}/sah-language-qa-${config.runId}',
        );
        await directory.create(recursive: true);
        await File(
          '${directory.path}/$name.png',
        ).writeAsBytes(bytes, flush: true);
        binding.reportData?.remove('screenshots');
        screenshots.add(name);
      }

      Future<void> verifyChineseRaster(
        PdfPage page,
        PdfPageRawText pageText,
        String value,
        String artifact,
      ) async {
        bool isHan(int codePoint) =>
            codePoint >= 0x3400 && codePoint <= 0x4dbf ||
            codePoint >= 0x4e00 && codePoint <= 0x9fff ||
            codePoint >= 0xf900 && codePoint <= 0xfaff ||
            codePoint >= 0x20000 && codePoint <= 0x2fa1f ||
            codePoint >= 0x30000 && codePoint <= 0x323af;
        final codePoints = value.runes.toList(growable: false);
        if (!codePoints.any(isHan)) return;
        final start = pageText.fullText.indexOf(value);
        if (start < 0) return;
        final rects = pdfGlyphRectsForMatch(pageText, value);
        expect(rects.length, codePoints.length);
        final bounds = rects.boundingRect();
        expect(bounds.isNotEmpty, true);
        expect(bounds.left, greaterThanOrEqualTo(0));
        expect(bounds.bottom, greaterThanOrEqualTo(0));
        expect(bounds.right, lessThanOrEqualTo(page.width));
        expect(bounds.top, lessThanOrEqualTo(page.height));
        const scale = 4.0;
        final left = (bounds.left * scale).floor();
        final top = ((page.height - bounds.top) * scale).floor();
        final right = (bounds.right * scale).ceil();
        final bottom = ((page.height - bounds.bottom) * scale).ceil();
        final raster = await page.render(
          x: left,
          y: top,
          width: right - left,
          height: bottom - top,
          fullWidth: page.width * scale,
          fullHeight: page.height * scale,
        );
        expect(raster, isNotNull);
        try {
          final pixels = raster!.pixels;
          final knownDifferent = packetText.residentName.startsWith('陈')
              ? '陈美华𠮷'.runes.toSet()
              : '陳美華𠮷'.runes.toSet();
          final nameMasks = <int, List<double>>{};
          for (var i = 0; i < codePoints.length; i++) {
            if (!isHan(codePoints[i])) continue;
            final glyph = rects[i];
            expect(glyph.isNotEmpty, true, reason: 'Visible CJK glyph bounds.');
            final x1 = (glyph.left * scale - left).floor().clamp(
              0,
              raster.width,
            );
            final y1 = ((page.height - glyph.top) * scale - top).floor().clamp(
              0,
              raster.height,
            );
            final x2 = (glyph.right * scale - left).ceil().clamp(
              0,
              raster.width,
            );
            final y2 = ((page.height - glyph.bottom) * scale - top)
                .ceil()
                .clamp(0, raster.height);
            var ink = 0;
            final strongInk = <(int, int)>[];
            for (var y = y1; y < y2; y++) {
              for (var x = x1; x < x2; x++) {
                final offset = (y * raster.width + x) * 4;
                if (pixels[offset] < 210 &&
                    pixels[offset + 1] < 210 &&
                    pixels[offset + 2] < 210) {
                  ink++;
                }
                if (value == packetText.residentName &&
                    knownDifferent.contains(codePoints[i]) &&
                    pixels[offset] < 160 &&
                    pixels[offset + 1] < 160 &&
                    pixels[offset + 2] < 160) {
                  strongInk.add((x, y));
                }
              }
            }
            if (value == packetText.residentName &&
                knownDifferent.contains(codePoints[i])) {
              expect(strongInk, isNotEmpty);
              nameMasks[codePoints[i]] = normalizedGlyphInkMask(strongInk);
            }
            expect(
              ink,
              greaterThan(8),
              reason:
                  'Chinese glyph ${String.fromCharCode(codePoints[i])} must render visible strokes.',
            );
            cjkGlyphsRendered++;
          }
          if (value == packetText.residentName) {
            expect(nameMasks.keys.toSet(), knownDifferent);
            final masks = nameMasks.entries.toList();
            for (var i = 0; i < masks.length; i++) {
              for (var j = i + 1; j < masks.length; j++) {
                expect(
                  normalizedInkDifference(masks[i].value, masks[j].value),
                  greaterThan(0.18),
                  reason:
                      'Known-distinct name glyphs '
                      '${String.fromCharCode(masks[i].key)} and '
                      '${String.fromCharCode(masks[j].key)} must not repeat tofu. '
                      'This is a missing-glyph heuristic, not glyph-identity proof.',
                );
              }
            }
            cjkDistinctNameChecks++;
          }
          if (const bool.fromEnvironment('SAH_IOS_CAPTURE_SCREENSHOTS')) {
            final image = await raster.createImage();
            try {
              final png = await image.toByteData(
                format: image_ui.ImageByteFormat.png,
              );
              expect(png, isNotNull);
              final name =
                  '${config.language.code}-${screenshots.length + 1}-$artifact-p${page.pageNumber}';
              final directory = Directory(
                '${Directory.systemTemp.path}/sah-language-qa-${config.runId}',
              );
              await directory.create(recursive: true);
              await File('${directory.path}/$name.png').writeAsBytes(
                png!.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes),
                flush: true,
              );
              screenshots.add(name);
            } finally {
              image.dispose();
            }
          }
        } finally {
          raster?.dispose();
        }
      }

      final secrets = DeviceSecretStore();
      final receiptKey = 'sah.deletion.${config.app.apiOrigin.host}';
      final receiptOwnerKey = 'sah.deletion-owner.${config.app.apiOrigin.host}';
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await h.close(clear: true);
        h.session.dispose();
        await secrets.delete(receiptKey);
        await secrets.delete(receiptOwnerKey);
      });
      Future<void> until(
        bool Function() predicate,
        String description, {
        int seconds = 35,
      }) async {
        final watch = Stopwatch()..start();
        while (!predicate()) {
          if (watch.elapsed > Duration(seconds: seconds)) {
            fail(
              'Timed out: $description. Checkpoints: ${checkpoints.join(', ')}.',
            );
          }
          await tester.pump(const Duration(milliseconds: 100));
        }
        await tester.pump(const Duration(milliseconds: 150));
      }

      Future<void> settle() async {
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
      }

      Future<void> visible(Finder finder, {double direction = 260}) async {
        FocusManager.instance.primaryFocus?.unfocus();
        await settle();
        if (finder.evaluate().isEmpty) {
          final scrollables = find
              .byType(Scrollable)
              .evaluate()
              .where((element) => ModalRoute.of(element)?.isCurrent != false);
          expect(
            scrollables,
            isNotEmpty,
            reason: 'The current route must scroll.',
          );
          final element = scrollables.first;
          final scrollable = find.byElementPredicate(
            (e) => identical(e, element),
          );
          final position = tester.state<ScrollableState>(scrollable).position;
          for (final step in [direction, -direction]) {
            final initialOffset = position.pixels;
            var moves = 0;
            for (; moves < 70 && finder.evaluate().isEmpty; moves++) {
              if (step > 0 && position.pixels >= position.maxScrollExtent - 1 ||
                  step < 0 && position.pixels <= position.minScrollExtent + 1) {
                break;
              }
              final viewport = tester.getRect(scrollable);
              await tester.dragFrom(
                Offset(viewport.right - 8, viewport.center.dy),
                Offset(0, -step),
              );
              await tester.pump(const Duration(milliseconds: 100));
            }
            if (finder.evaluate().isNotEmpty) break;
            debugPrint(
              'LOCAL_SCROLL_SEARCH_BOUND: moves=$moves '
              'step=$step from=${initialOffset.toStringAsFixed(1)} '
              'to=${position.pixels.toStringAsFixed(1)} '
              'min=${position.minScrollExtent.toStringAsFixed(1)} '
              'max=${position.maxScrollExtent.toStringAsFixed(1)} '
              'viewport=${position.viewportDimension.toStringAsFixed(1)} '
              'axis=${position.axisDirection.name}',
            );
          }
        }
        expect(
          finder,
          findsWidgets,
          reason: 'The intended action must exist on the current route.',
        );
        await Scrollable.ensureVisible(
          tester.element(finder.first),
          alignment: 0.5,
        );
        await settle();
      }

      Future<void> tapFinder(Finder finder, {double direction = 260}) async {
        await visible(finder, direction: direction);
        await until(() {
          final targets = finder.hitTestable().evaluate();
          if (targets.isEmpty) return false;
          var enabled = true;
          bool inspect(Element element) {
            final widget = element.widget;
            if (widget is ButtonStyleButton && widget.onPressed == null ||
                widget is IconButton && widget.onPressed == null ||
                widget is InkResponse && widget.onTap == null ||
                widget is CheckboxListTile && widget.onChanged == null) {
              enabled = false;
            }
            return true;
          }

          inspect(targets.first);
          targets.first.visitAncestorElements(inspect);
          return enabled;
        }, 'tap target becomes available');
        await tester.tap(finder.first);
        await settle();
      }

      Future<void> tap(String label, {double direction = 260}) =>
          tapFinder(find.text(ui(label)), direction: direction);
      Finder input(String label, {bool sourceLabel = false}) =>
          find.byWidgetPredicate(
            (widget) =>
                widget is TextField &&
                (widget.decoration?.labelText ??
                        (widget.decoration?.label is Text
                            ? (widget.decoration!.label! as Text).data
                            : null)) ==
                    (sourceLabel ? l10n.text(label) : ui(label)),
          );
      Future<void> enter(
        String label,
        String text, {
        bool sourceLabel = false,
      }) async {
        await visible(input(label, sourceLabel: sourceLabel));
        await tester.enterText(input(label, sourceLabel: sourceLabel), text);
        await settle();
      }

      Future<void> back() async {
        final button = find.byType(BackButton).hitTestable();
        await until(
          () => button.evaluate().length == 1,
          'one visible Back action after route transition',
        );
        final departingRoute = ModalRoute.of(tester.element(button));
        expect(departingRoute, isNotNull);
        await tester.tap(button);
        await until(
          () => !departingRoute!.isActive,
          'Back completes its accepted private writes and leaves the original route',
        );
        await settle();
      }

      Future<void> idle() => until(
        () => h.services != null && !h.services!.coordinator.busy,
        'case operation to finish',
      );
      Future<void> refreshPrograms() async {
        await until(
          () => find
              .byType(LiveProgramsScreen)
              .evaluate()
              .any((element) => ModalRoute.of(element)?.isCurrent == true),
          'program screen is the current route after leaving its editor',
        );
        await until(
          () =>
              h.transport.responseBodies['/v1/match-case']?['caseRevision'] ==
                  h.services!.coordinator.snapshot!.revision &&
              find
                  .descendant(
                    of: find.byType(LiveProgramsScreen),
                    matching: find.byType(LinearProgressIndicator),
                  )
                  .evaluate()
                  .isEmpty,
          'program checks update automatically for the saved revision',
        );
      }

      Future<void> workspaceReady() => until(
        () =>
            find
                .byType(ApplicationWorkspaceScreen)
                .evaluate()
                .any((element) => ModalRoute.of(element)?.isCurrent == true) &&
            find.byKey(const ValueKey('workspace-now')).evaluate().isNotEmpty &&
            find
                .descendant(
                  of: find.byType(ApplicationWorkspaceScreen),
                  matching: find.byType(LinearProgressIndicator),
                )
                .evaluate()
                .isEmpty,
        'application workspace is current and its steps are checked',
      );

      Future<void> openWorkspace(String id) async {
        await tapFinder(find.byKey(ValueKey('program-$id-start')));
        await workspaceReady();
      }

      Future<void> workspaceStep(String key) async {
        await workspaceReady();
        await tapFinder(
          find.descendant(
            of: find.byKey(ValueKey(key)),
            matching: find.byType(InkWell),
          ),
        );
      }

      Finder intakeField(String key) => find.descendant(
        of: find
            .ancestor(
              of: find.byKey(ValueKey('intake-question-$key')),
              matching: find.byType(Column),
            )
            .first,
        matching: find.byType(TextField),
      );

      Future<void> tab(String name) =>
          tapFinder(find.byKey(ValueKey('plan-tab-$name')));

      Future<void> login() async {
        await enter('Email', 'alice@example.invalid');
        await enter('Password', 'fictional-password-only');
        await tap('Sign in');
        await until(
          () =>
              h.session.userId == config.alice &&
              h.services != null &&
              find.byType(CaseHomeScreen).evaluate().isNotEmpty,
          'signed-in home',
        );
        await visible(find.text(ui('Start a home plan')));
        expect(find.text(ui('Start a home plan')), findsOneWidget);
      }

      Future<void> finishProfile() async {
        await tapFinder(find.byKey(const ValueKey('profile-keep-edits')));
        await until(
          () => find
              .byKey(const ValueKey('profile-keep-edits'))
              .evaluate()
              .isEmpty,
          'resident details closes after its private save',
        );
      }

      await tester.pumpWidget(AcceptanceHost(harness: h));
      await settle();
      await screenshot('sign-in');
      await enter('Email', 'alice@example.invalid');
      await enter('Password', 'wrong-fictional-password');
      await tap('Sign in');
      await until(
        () => find
            .text(
              ui(
                'Sign-in could not be completed. Check your account details and connection.',
              ),
            )
            .evaluate()
            .isNotEmpty,
        'safe rejected-login message',
      );
      expect(h.session.userId, isNull);
      await login();
      checkpoint('fictional login');
      await screenshot('home');
      await tap('Start a home plan');
      await tapFinder(find.byKey(const ValueKey('plan-name-save')));
      await idle();
      await tap('Resident details');
      await enter('City', 'Fictional San Jose');
      await enter('Annual household income (USD)', '0');
      final permission = find.byType(DropdownButtonFormField<bool>);
      await tapFinder(permission);
      await tap('No');
      await screenshot('resident-details');
      await finishProfile();
      await until(
        () =>
            h.services!.coordinator.snapshot != null &&
            !h.services!.coordinator.busy &&
            !h.services!.coordinator.hasUnsavedChanges &&
            h.services!.coordinator.snapshot!.profile.city ==
                'Fictional San Jose' &&
            h.services!.coordinator.snapshot!.profile.annualIncomeUsd == 0 &&
            h.services!.coordinator.snapshot!.profile.ownerConsentReported ==
                false,
        'all resident edits save automatically to the real case',
      );
      expect(
        h.services!.coordinator.snapshot!.revision,
        greaterThanOrEqualTo(1),
      );
      final profile = h.services!.coordinator.snapshot!.profile;
      expect(profile.annualIncomeUsd, 0);
      expect(profile.ageYears, isNull);
      expect(profile.ownerConsentReported, false);
      checkpoint('profile preserves zero, false and unknown');

      h.capture.outcomes.addAll([
        const CapturePermissionDenied(canAskAgain: true),
        const CaptureCancelled(),
      ]);
      await tab('rooms');
      await until(
        () => find.byKey(const ValueKey('area-entrance')).evaluate().isNotEmpty,
        'assessment loaded',
      );
      await tapFinder(find.byKey(const ValueKey('area-entrance')));
      await tap('Open camera');
      await until(
        () => find
            .text(
              ui(
                'Camera access was not allowed. You can try again or continue without a photo.',
              ),
            )
            .evaluate()
            .isNotEmpty,
        'fictional permission denial',
      );
      await tap('Open camera');
      await until(
        () => find
            .text(
              ui(
                'No photo was taken. You can try again or continue without a photo.',
              ),
            )
            .evaluate()
            .isNotEmpty,
        'fictional capture cancellation',
      );
      await tap('Open camera');
      await until(
        () => find
            .text(ui('Crop or cover private details'))
            .evaluate()
            .isNotEmpty,
        'generated photo staged',
      );
      expect(h.capture.attempts, 3);
      await tap('Crop or cover private details');
      await tap('Add opaque cover');
      await tap('Apply and review photo');
      await until(
        () => find
            .text(ui('Crop or cover private details'))
            .evaluate()
            .isNotEmpty,
        'native privacy edit applied',
      );
      await tap('Continue');
      await visible(find.byKey(const ValueKey('observation')));
      await tester.enterText(
        find.byKey(const ValueKey('observation')),
        packetText.observation,
      );
      await tap('Add measurements (optional)');
      await visible(find.byKey(const ValueKey('measurement-thresholdHeight')));
      await tester.enterText(
        find.byKey(const ValueKey('measurement-thresholdHeight')),
        ' .5 ',
      );
      await tapFinder(
        find.descendant(
          of: find.byKey(const ValueKey('unit-thresholdHeight')),
          matching: find.text(ui('in')),
        ),
      );
      final finishFinding = find.byKey(const ValueKey('assessment-review'));
      expect(
        find.descendant(of: finishFinding, matching: find.text(ui('Done'))),
        findsOneWidget,
      );
      await tapFinder(finishFinding);
      await until(
        () {
          final coordinator = h.services!.coordinator;
          final findings = coordinator.snapshot?.findings;
          return findings?.length == 1 &&
              findings!.single.reviewState == 'confirmed' &&
              !coordinator.busy &&
              finishFinding.evaluate().isEmpty &&
              find
                  .byKey(ValueKey('finding-${findings.single.id}'))
                  .evaluate()
                  .isNotEmpty;
        },
        'assessment and photo saved before returning to the plan',
        seconds: 55,
      );
      final caseAfterPhoto = h.services!.coordinator.snapshot!;
      expect(caseAfterPhoto.findings, hasLength(1));
      expect(caseAfterPhoto.findings.single.reviewState, 'confirmed');
      expect(
        caseAfterPhoto.findings.single.observation,
        packetText.observation,
      );
      expect(caseAfterPhoto.findings.single.measurements.single.value, 12.7);
      expect(
        caseAfterPhoto.findings.single.measurements.single.confirmed,
        true,
      );
      final original =
          (((h.transport.responseBodies['/v2/save-assessment']!['assessment']
                              as Map)['metadata']
                          as Map)['measurements']
                      as List)
                  .single
              as Map;
      expect(original['originalText'], ' .5 ');
      expect(original['originalUnit'], 'in');
      final evidenceId = caseAfterPhoto.findings.single.evidenceIds.single;
      final savedFinding = find.byKey(
        ValueKey('finding-${caseAfterPhoto.findings.single.id}'),
      );
      final reopenedReview = find.byKey(const ValueKey('review-state'));
      await until(
        () =>
            savedFinding.evaluate().isNotEmpty ||
            reopenedReview.evaluate().isNotEmpty,
        'saved finding restored after Continue',
      );
      if (savedFinding.evaluate().isNotEmpty) await tapFinder(savedFinding);
      await until(
        () => find.byKey(const ValueKey('review-state')).evaluate().isNotEmpty,
        'saved finding review reopened',
      );
      await tapFinder(
        find.byKey(ValueKey('review-photo-$evidenceId')),
        direction: -260,
      );
      await until(
        () =>
            find.text(ui('Mark the area on this photo')).evaluate().isNotEmpty,
        'downloaded sanitized photo is ready for annotations after resume',
        seconds: 40,
      );
      await tap('Mark the area on this photo');
      await tap('Add a box');
      await visible(find.byKey(const ValueKey('annotation-label')));
      await tester.enterText(
        find.byKey(const ValueKey('annotation-label')),
        packetText.photoLabel,
      );
      FocusManager.instance.primaryFocus?.unfocus();
      await settle();
      await screenshot('photo-annotation');
      await tap('Done', direction: -260);
      await tap(
        find.text(ui('Save to my case')).evaluate().isNotEmpty
            ? 'Save to my case'
            : 'Save findings and photo marks online',
      );
      await until(
        () =>
            h.transport.responseBodies['/v2/save-evidence-annotations'] !=
                null &&
            find.text(ui('Saved to your case.')).evaluate().isNotEmpty,
        'durable annotations saved',
        seconds: 55,
      );
      await tab('plan');
      await until(
        () => find.text(ui('Resident details')).evaluate().isNotEmpty,
        'Rooms tab is left after durable flush',
      );
      checkpoint(
        'fictional capture failures, native redaction, measurement and durable box',
      );

      h.transport.offline = true;
      await tab('plan');
      await tap('Resident details');
      await enter('City', 'Fictional offline city');
      await finishProfile();
      await until(
        () =>
            h.services!.coordinator.uncertain && !h.services!.coordinator.busy,
        'automatic offline save remains uncertain and keeps the edit',
      );
      final previousDirectory = h.directory!;
      await tester.pumpWidget(const SizedBox.shrink());
      await h.close();
      expect(await previousDirectory.exists(), true);
      await tester.pumpWidget(AcceptanceHost(harness: h));
      await until(
        () =>
            h.services != null &&
            find.byType(CaseHomeScreen).evaluate().isNotEmpty,
        'private account store reopened on home',
      );
      expect(
        await h.services!.coordinator.localCaseIds(),
        contains(caseAfterPhoto.caseId),
        reason: 'The exact encrypted case must survive service recreation.',
      );
      await tapFinder(find.byKey(const ValueKey('active-plan-selector')));
      await tap('Manage plans');
      await tapFinder(
        find.byKey(ValueKey('local-case-${caseAfterPhoto.caseId}')),
      );
      await idle();
      expect(
        h.services!.coordinator.draft!.profile.city,
        'Fictional offline city',
      );
      expect(
        h.services!.coordinator.draft!.findings.single.observation,
        packetText.observation,
        reason: 'Encrypted reopen preserves the entered script exactly.',
      );
      h.transport.offline = false;
      await tap('Check saved state');
      await until(
        () => h.services!.coordinator.conflict && !h.services!.coordinator.busy,
        'offline conflict reconciled',
      );
      await tap('Keep my edits for another save');
      await tapFinder(
        find.byKey(const ValueKey('case-save-online')),
        direction: -300,
      );
      await until(
        () =>
            !h.services!.coordinator.hasUnsavedChanges &&
            !h.services!.coordinator.busy,
        'retained edits saved',
      );
      checkpoint(
        'cold service reopen decrypts local draft; explicit reconcile',
      );

      await tab('help');
      await until(
        () => h.transport.responseBodies['/v1/match-case'] != null,
        'three-program checks',
      );
      final programs = ['scfhp-eaa', 'hpsm-eaa', 'rtp-home-repair'];
      await screenshot('programs');
      for (final program in programs) {
        await refreshPrograms();
        await openWorkspace(program);
        final workspaceStatus = find.byKey(const ValueKey('workspace-status'));
        expect(
          find.descendant(
            of: workspaceStatus,
            matching: find.text(ui('Draft · not sent')),
          ),
          findsOneWidget,
        );
        await workspaceStep('workspace-waiting');
        await until(
          () =>
              h.transport.responseBodies['/v1/prepare-packet']?['programId'] ==
              program,
          'real draft checklist for this program',
        );
        final checklist = h.transport.responseBodies['/v1/prepare-packet']!;
        expect(checklist['caseId'], h.services!.coordinator.snapshot!.caseId);
        expect(
          checklist['caseRevision'],
          h.services!.coordinator.snapshot!.revision,
        );
        expect(checklist['status'], 'draft');
        await visible(
          find.text(ui('Draft only · Nothing has been submitted.')),
        );
        expect(
          find.text(ui('Draft only · Nothing has been submitted.')),
          findsOneWidget,
        );
        await visible(find.text(ui('What is needed next')));
        expect(find.text(ui('What is needed next')), findsOneWidget);
        await screenshot('$program-checklist');
        await back();
        await workspaceStep('workspace-step-questions');
        await until(
          () =>
              (h
                      .transport
                      .responseBodies['/v2/read-program-intake']?['definition']
                  as Map?)?['programId'] ==
              program,
          'route questions $program',
        );
        final response = h.transport.responseBodies['/v2/read-program-intake']!;
        final questions = (response['definition'] as Map)['questions'] as List;
        final firstBoolean =
            questions.firstWhere((q) => q['kind'] == 'boolean') as Map;
        final booleanNo = find.byKey(ValueKey('${firstBoolean['key']}-false'));
        await visible(booleanNo);
        await until(
          () =>
              tester.widget<RadioListTile<String>>(booleanNo).enabled != false,
          'program questions ready for answers',
        );
        await tapFinder(booleanNo);
        await screenshot('$program-questions');
        Future<void> answer(String key, String text) async {
          await visible(intakeField(key));
          await tester.enterText(intakeField(key), text);
          await settle();
        }

        final money = questions.where((q) => q['kind'] == 'money');
        if (money.isNotEmpty) {
          await answer((money.first as Map)['key'] as String, '0');
        }
        if (program == programs.last) {
          await answer(
            (questions.firstWhere(
                      (q) =>
                          q['label'] ==
                          'What repairs would you like RTP to consider?',
                    )
                    as Map)['key']
                as String,
            packetText.repairRequest,
          );
        }
        final beforeRevision = h.services!.coordinator.snapshot!.revision;
        final beforeSaves = h.transport.paths
            .where((p) => p == '/v2/save-program-intake')
            .length;
        if (program == programs.first) {
          h.transport.loseNextSuccessfulResponse = '/v2/save-program-intake';
        }
        await tapFinder(find.byKey(const ValueKey('intake-save')));
        if (program == programs.first) {
          await until(
            () => h.transport.loseNextSuccessfulResponse == null,
            'committed response loss injected',
          );
          await tap('Check saved answers and reconcile', direction: -300);
          await until(
            () => find
                .text(ui('The submitted answers are confirmed saved.'))
                .evaluate()
                .isNotEmpty,
            'uncertain intake recovered',
          );
          expect(
            h.transport.paths
                .where((p) => p == '/v2/save-program-intake')
                .length,
            beforeSaves + 1,
          );
        } else {
          await until(
            () =>
                h.services!.coordinator.snapshot!.revision ==
                beforeRevision + 1,
            'route answers saved',
          );
        }
        final savedIntake =
            h.transport.responseBodies[program == programs.first
                    ? '/v2/read-program-intake'
                    : '/v2/save-program-intake']!['saved']
                as Map;
        final answers = savedIntake['answers'] as List;
        expect(
          (answers.firstWhere((a) => a['key'] == firstBoolean['key'])
              as Map)['value'],
          false,
        );
        expect(
          answers.any(
            (a) => a['value'] == null && a['reviewState'] == 'unknown',
          ),
          true,
        );
        if (money.isNotEmpty) {
          expect(
            (answers.firstWhere((a) => a['key'] == money.first['key'])
                as Map)['value'],
            0,
          );
        }
        if (program == programs.first) {
          await back();
        } else {
          await until(
            () => find.byKey(const ValueKey('intake-save')).evaluate().isEmpty,
            'saved program questions return to the workspace',
          );
        }
        await workspaceStep('workspace-step-check');
        await until(
          () =>
              (h.transport.responseBodies['/v2/read-form-answers']?['context']
                  as Map?)?['programId'] ==
              program,
          'route-specific administrative fields',
        );
        final givenName = find.descendant(
          of: find.byKey(const ValueKey('form-field-memberFirstName')),
          matching: find.byType(TextField),
        );
        await visible(givenName);
        await tester.enterText(givenName, packetText.residentName);
        await settle();
        await visible(
          find.byKey(const ValueKey('form-unconfirmed-memberFirstName')),
        );
        expect(
          find.byKey(const ValueKey('form-unconfirmed-memberFirstName')),
          findsOneWidget,
        );
        await screenshot('$program-form');
        final beforeForm = h.services!.coordinator.snapshot!.revision;
        await tapFinder(find.byKey(const ValueKey('form-save')));
        await until(
          () => h.services!.coordinator.snapshot!.revision == beforeForm + 1,
          'reviewed administrative answers saved',
        );
        final savedForm =
            ((h.transport.responseBodies['/v2/save-form-answers']!['saved']
                        as Map)['answers']
                    as List)
                .cast<Map>();
        expect(
          savedForm.singleWhere(
            (a) => a['key'] == 'memberFirstName',
          )['reviewState'],
          'reviewed',
          reason: 'Confirming records a per-field review for the given name.',
        );
        expect(
          savedForm.every(
            (a) => a['value'] == null || a['reviewState'] == 'reviewed',
          ),
          true,
          reason:
              'Every provided administrative answer is individually reviewed.',
        );
        await until(
          () => find.byKey(const ValueKey('form-save')).evaluate().isEmpty,
          'saved administrative answers return to the workspace',
        );
        await workspaceReady();
        final priorExportFormReads = h.transport.paths
            .where((path) => path == '/v2/read-form-answers')
            .length;
        await workspaceStep('workspace-step-create');
        await until(
          () =>
              h
                      .transport
                      .responseBodies['/v1/list-evidence']?['caseRevision'] ==
                  h.services!.coordinator.snapshot!.revision &&
              h.transport.paths
                      .where((path) => path == '/v2/read-form-answers')
                      .length >
                  priorExportFormReads &&
              h
                      .transport
                      .responseBodies['/v2/read-form-answers']?['caseRevision'] ==
                  h.services!.coordinator.snapshot!.revision &&
              (h.transport.responseBodies['/v2/read-form-answers']?['context']
                      as Map?)?['programId'] ==
                  program,
          'draft review loads both current evidence and administrative answers',
        );
        expect(
          find.descendant(
            of: find.byKey(const ValueKey('export-status')),
            matching: find.text(ui('Draft · not sent')),
          ),
          findsOneWidget,
        );
        await tapFinder(
          find.descendant(
            of: find.byKey(ValueKey('export-photo-$evidenceId')),
            matching: find.byType(InkWell),
          ),
        );
        await until(
          () => find.text(ui('Review private photo')).evaluate().isNotEmpty,
          'canonical evidence preview',
        );
        final markedPhoto = find.byType(SavedPhotoWithMarks);
        await visible(markedPhoto);
        expect(markedPhoto, findsOneWidget);
        expect(
          find.descendant(
            of: markedPhoto,
            matching: find.text(packetText.photoLabel),
          ),
          findsOneWidget,
        );
        final noteLegend = find.byElementPredicate((element) {
          final widget = element.widget;
          if (widget is! Text || widget.data != packetText.photoLabel) {
            return false;
          }
          var insidePhoto = false;
          element.visitAncestorElements((ancestor) {
            if (ancestor.widget is SavedPhotoWithMarks) {
              insidePhoto = true;
              return false;
            }
            return true;
          });
          return !insidePhoto;
        }, description: 'the accessible photo-note legend outside the image');
        await visible(noteLegend);
        expect(noteLegend, findsOneWidget);
        await screenshot('$program-photo-review');
        await tap('Include this reviewed photo');
        await visible(find.text(ui('Included · {number}', {'number': 1})));
        expect(
          find.text(ui('Included · {number}', {'number': 1})),
          findsOneWidget,
        );
        final pdfCount = h.transport.pdfs.length;
        await tapFinder(find.byKey(const ValueKey('export-create')));
        await until(
          () => h.transport.pdfs.length == pdfCount + 1,
          'real annotated PDF downloaded',
          seconds: 55,
        );
        await visible(find.byType(PdfViewer));
        expect(find.byType(PdfViewer), findsOneWidget);
        await until(
          () =>
              tester
                  .widget<PdfViewer>(find.byType(PdfViewer))
                  .documentRef
                  .resolveListenable()
                  .document !=
              null,
          'native viewer opens the actual document',
        );
        await screenshot('$program-pdf');
        expect(
          find.text(
            ui(
              'The PDF preview could not be opened. Reload and prepare the draft again.',
            ),
          ),
          findsNothing,
        );
        final displayed = tester
            .widget<PdfViewer>(find.byType(PdfViewer))
            .documentRef
            .resolveListenable();
        final text = StringBuffer();
        var markedPageRendered = false;
        final glyphsBeforeProgram = cjkGlyphsRendered;
        final distinctNamesBeforeProgram = cjkDistinctNameChecks;
        await displayed.useDocument<void>((viewerDocument) async {
          final missingCjkFonts = <String>{};
          void recordMissing(PdfDocumentEvent event) {
            if (event is PdfDocumentMissingFontsEvent) {
              missingCjkFonts.addAll(
                event.missingFonts
                    .where(requiresEmbeddedChineseFont)
                    .map((font) => font.face),
              );
            }
          }

          final viewerEvents = viewerDocument.events.listen(recordMissing);
          try {
            final document = await PdfDocument.openData(h.transport.pdfs.last);
            final downloadedEvents = document.events.listen(recordMissing);
            try {
              expect(viewerDocument.pages.length, document.pages.length);
              for (var index = 0; index < document.pages.length; index++) {
                final page = document.pages[index];
                final extracted = await page.loadText();
                final pageText = extracted?.fullText ?? '';
                final visibleText =
                    (await viewerDocument.pages[index].loadText())?.fullText ??
                    '';
                expect(
                  visibleText,
                  pageText,
                  reason:
                      'The displayed document must be this route’s downloaded PDF.',
                );
                text.write(pageText);
                if (extracted != null) {
                  for (final field in {
                    'name': packetText.residentName,
                    'observation': packetText.observation,
                    'photo-label': packetText.photoLabel,
                    if (program == programs.last)
                      'repair-request': packetText.repairRequest,
                  }.entries) {
                    await verifyChineseRaster(
                      page,
                      extracted,
                      field.value,
                      '$program-pdf-${field.key}',
                    );
                  }
                }
                if (pageText.contains(packetText.photoLabel)) {
                  final raster = await page.render(
                    fullWidth: 306,
                    fullHeight: 306 * page.height / page.width,
                  );
                  expect(raster, isNotNull);
                  try {
                    final pixels = raster!.pixels;
                    expect(pixels.length, raster.width * raster.height * 4);
                    var inkPixels = 0;
                    for (var i = 0; i < pixels.length; i += 4) {
                      if (pixels[i] < 245 ||
                          pixels[i + 1] < 245 ||
                          pixels[i + 2] < 245) {
                        inkPixels++;
                      }
                    }
                    expect(
                      inkPixels,
                      greaterThan(100),
                      reason:
                          'The native PDF engine must render real page content, not a blank placeholder.',
                    );
                    final visibleRaster = await viewerDocument.pages[index]
                        .render(
                          fullWidth: 306,
                          fullHeight: 306 * page.height / page.width,
                        );
                    expect(visibleRaster, isNotNull);
                    try {
                      expect(
                        sha256.convert(visibleRaster!.pixels).toString(),
                        sha256.convert(pixels).toString(),
                        reason:
                            'The displayed photo and marks must match the downloaded draft.',
                      );
                    } finally {
                      visibleRaster?.dispose();
                    }
                    markedPageRendered = true;
                  } finally {
                    raster?.dispose();
                  }
                }
              }
              await document.useNativeDocumentHandle<void>((_) {});
              await Future<void>.delayed(Duration.zero);
              expect(
                missingCjkFonts,
                isEmpty,
                reason:
                    'Embedded Chinese fonts must not fall back to system '
                    'fonts, even when the substitute paints nonblank glyphs.',
              );
              cjkMissingFontGuards += 2;
            } finally {
              await downloadedEvents.cancel();
              await document.dispose();
            }
          } finally {
            await viewerEvents.cancel();
          }
        });
        expect(markedPageRendered, true);
        expect(text.toString(), contains(packetText.photoLabel));
        expect(text.toString(), contains(packetText.residentName));
        expect(text.toString(), contains(packetText.observation));
        if (config.language == AppLanguage.chineseSimplified ||
            config.language == AppLanguage.chineseTraditional) {
          expect(cjkGlyphsRendered, greaterThan(glyphsBeforeProgram));
          expect(
            cjkDistinctNameChecks,
            greaterThan(distinctNamesBeforeProgram),
          );
          checkpoint(
            '$program exact Chinese text and visible native PDF glyphs',
          );
        }
        expect(text.toString(), contains('REPORTED FACTS ONLY'));
        expect(text.toString(), contains('Unknown'));
        expect(text.toString(), contains('Reported No'));
        if (money.isNotEmpty) {
          expect(text.toString(), contains('Reported USD 0.00'));
        }
        if (program == programs.last) {
          expect(text.toString().toLowerCase(), contains('worksheet'));
          expect(text.toString(), contains(packetText.repairRequest));
        }
        await tapFinder(
          find.byKey(const ValueKey('export-share')),
          direction: -300,
        );
        await until(
          () => find.text(ui('Share the draft file?')).evaluate().isNotEmpty,
          'draft-sharing warning',
        );
        expect(
          find.text(
            ui(
              'Sharing sends a file. It doesn’t send your application. The app or person you choose can keep a copy.',
            ),
          ),
          findsOneWidget,
        );
        await tap('Cancel');
        await back();
        await workspaceStep('workspace-step-updates');
        await tapFinder(find.byKey(const ValueKey('history-add')));
        expect(
          find.text(ui('Reported by you · not agency status')),
          findsOneWidget,
        );
        await enter(
          'Optional note',
          'Fictional resident will ask the program about missing documents.',
        );
        await tapFinder(find.byKey(const ValueKey('history-save')));
        await until(
          () =>
              h
                  .transport
                  .responseBodies['/v1/append-request-update']?['programId'] ==
              program,
          'manual update acknowledged for this program',
        );
        final historyNotice = find.text(
          ui('Manual update saved. This is not verified agency status.'),
        );
        await visible(historyNotice, direction: -260);
        expect(historyNotice, findsOneWidget);
        await screenshot('$program-history');
        expect(
          (h.transport.responseBodies['/v1/append-request-update']!['events']
                  as List)
              .single['status'],
          'preparing',
        );
        await back();
        await workspaceReady();
        expect(
          find.descendant(
            of: workspaceStatus,
            matching: find.text(ui('Draft · not sent')),
          ),
          findsOneWidget,
        );
        await back();
        checkpoint(
          '$program: checklist, intake, reviewed fields, annotated PDF and manual history',
        );
      }

      final saved = h.services!.coordinator.snapshot!;
      final bob = FixtureSession(config);
      await bob.signIn('bob@example.invalid', 'fictional-password-only');
      final client = CaseEvidenceApiClient(
        createCaseEndpoint: config.app.apiOrigin.resolve('/v1/create-case'),
        saveCaseEndpoint: config.app.apiOrigin.resolve('/v1/save-case'),
        caseEndpoint: config.app.apiOrigin.resolve('/v1/read-case'),
        uploadEvidenceEndpoint: config.app.apiOrigin.resolve(
          '/v1/upload-evidence',
        ),
        deleteEvidenceEndpoint: config.app.apiOrigin.resolve(
          '/v1/delete-evidence',
        ),
        tokenProvider: bob.accessToken,
        transport: h.transport,
      );
      await expectLater(
        client.reloadCase(
          saved.caseId,
          currentCaseId: () => saved.caseId,
          currentCase: () => null,
        ),
        throwsA(
          isA<MatchingApiException>().having(
            (error) => error.code,
            'owner-private failure',
            'CASE_NOT_FOUND',
          ),
        ),
      );
      bob.dispose();
      await tapFinder(find.byKey(const ValueKey('open-account')));
      await screenshot('settings');
      await tapFinder(find.byKey(const ValueKey('account-privacy')));
      await tap('Delete this plan');
      await tap('Continue');
      await until(
        () => h.services!.coordinator.snapshot == null,
        'case and evidence deletion',
      );
      await visible(find.text(ui('Plan deleted.')), direction: -260);
      expect(find.text(ui('Plan deleted.')), findsOneWidget);
      var status = await config.control('status', {});
      expect(status['cases'], 0);
      expect(status['evidence'], 0);
      expect(status['derivedRows'], 0);
      await tap('Sign out and clear local data');
      await tap('Continue');
      await until(
        () =>
            h.session.userId == null &&
            find.text(ui('Sign in')).evaluate().isNotEmpty,
        'sign-out returns to login',
      );
      await until(
        () => !previousDirectory.existsSync(),
        'sign-out removes account files',
      );
      checkpoint('other owner denied; case/photo deletion; sign-out cleanup');

      await login();
      await tap('Start a home plan');
      await tapFinder(find.byKey(const ValueKey('plan-name-save')));
      await idle();
      await tap('Resident details');
      await enter('City', 'Fictional deletion check');
      await finishProfile();
      await until(
        () => h.services!.coordinator.snapshot?.revision == 2,
        'new case for account-deletion check',
      );
      await idle();
      await tapFinder(find.byKey(const ValueKey('open-account')));
      await tapFinder(find.byKey(const ValueKey('account-privacy')));
      var durableReceiptBeforeConfirm = false;
      h.transport.beforeRequest = (path) async {
        if (path == '/v1/confirm-account-deletion') {
          durableReceiptBeforeConfirm =
              await secrets.read(receiptKey) != null &&
              await secrets.read(receiptOwnerKey) == config.alice;
          expect(
            durableReceiptBeforeConfirm,
            true,
            reason:
                'Native Keychain must hold the recovery receipt before deletion is sent.',
          );
        }
      };
      await tap('Delete account and application data');
      await enter('Current password', 'fictional-password-only');
      await tap('Confirm password');
      await until(
        () => find.text(ui('Delete this account?')).evaluate().isNotEmpty,
        'reviewed account-deletion confirmation',
      );
      await tap('Continue');
      await until(
        () =>
            h.session.userId == null &&
            find.text(ui('Sign in')).evaluate().isNotEmpty,
        'application account deleted',
      );
      expect(durableReceiptBeforeConfirm, true);
      status = await config.control('status', {});
      expect(status['cases'], 0);
      expect(status['evidence'], 0);
      expect(status['derivedRows'], 0);
      expect(status['closedAccounts'], 1);
      expect(await secrets.read(receiptKey), isNotNull);
      final priorReceiptReads = h.transport.paths
          .where((path) => path == '/v1/account-deletion-status')
          .length;
      await tap('Check pending account deletion');
      await until(
        () =>
            h.transport.paths
                    .where((path) => path == '/v1/account-deletion-status')
                    .length >
                priorReceiptReads &&
            h
                    .transport
                    .responseBodies['/v1/account-deletion-status']?['status'] ==
                'auth_pending',
        'logged-out receipt reads real application-deletion status',
      );
      final pendingProviderNotice = find.text(
        ui(
          'Application data is deleted. Provider account cleanup is still pending.',
        ),
      );
      await visible(pendingProviderNotice);
      expect(pendingProviderNotice, findsOneWidget);
      await screenshot('account-deletion-receipt');
      expect(h.session.userId, isNull);
      expect(await secrets.read(receiptKey), isNotNull);
      checkpoint(
        'reauthenticated application deletion; durable receipt precedes confirm and resumes while logged out',
      );
      expect(tester.takeException(), isNull);
      binding.reportData = {
        'scope': 'installed_iOS_local_HTTP_PostgreSQL_native_storage_media_PDF',
        'authentication': 'fictional_provider_only',
        'capture': 'generated_fictional_image',
        'testHostTextScale': config.textScale,
        'language': config.language.code,
        'screenshots': screenshots,
        'recovery': 'service_recreation_not_OS_process_death',
        'sharing': 'warning_and_cancel_only',
        'providerDeletion': 'pending_not_executed',
        'checkpoints': checkpoints,
        'pdfs': h.transport.pdfs.length,
        'cjkGlyphsRendered': cjkGlyphsRendered,
        'cjkDistinctNameHeuristicChecks': cjkDistinctNameChecks,
        'cjkMissingFontGuards': cjkMissingFontGuards,
        'requests': status['requests'],
        'remainingCases': status['cases'],
        'remainingEvidence': status['evidence'],
        'remainingDerivedRows': status['derivedRows'],
      };
    },
    timeout: const Timeout(Duration(minutes: 22)),
  );
}
