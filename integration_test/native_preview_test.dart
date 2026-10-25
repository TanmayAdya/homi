import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:safe_at_home/app/private_content_cover.dart';
import 'package:safe_at_home/app/theme.dart';
import 'package:safe_at_home/features/requests/private_draft_preview.dart';
import 'package:safe_at_home/features/requests/private_pdf_document_lease.dart';
import 'package:safe_at_home/shared/models/case_draft.dart';

import 'support/local_acceptance_harness.dart';

const _soakEnabled = bool.fromEnvironment('SAH_NATIVE_PREVIEW_SOAK');
const _soakMinutesSetting = String.fromEnvironment(
  'SAH_NATIVE_PREVIEW_SOAK_MINUTES',
  defaultValue: '20',
);

int _boundedSoakMinutes() => switch (_soakMinutesSetting) {
  '20' => 20,
  '45' => 45,
  _ => throw ArgumentError(
    'Native preview soak duration must be 20 or 45 minutes.',
  ),
};

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final soakMinutes = _boundedSoakMinutes();
  testWidgets(
    'native draft previews isolate documents and reset accessible paging',
    (tester) async {
      final config = LocalFixtureConfig.fromEnvironment();
      final h = AcceptanceHarness(config);
      addTearDown(() async {
        try {
          await tester.pumpWidget(const SizedBox.shrink());
        } finally {
          try {
            await h.close(clear: true);
          } finally {
            h.session.dispose();
          }
        }
      });
      Future<void> until(bool Function() ready, String reason) async {
        final clock = Stopwatch()..start();
        while (!ready()) {
          if (clock.elapsed > const Duration(seconds: 40)) {
            fail('Timed out: $reason');
          }
          await tester.pump(const Duration(milliseconds: 100));
        }
        await tester.pump(const Duration(milliseconds: 100));
      }

      final initial = await config.control('status', {});
      expect(initial['cases'], 0);
      expect(initial['closedAccounts'], 0);
      await h.session.signIn(
        'alice@example.invalid',
        'fictional-password-only',
      );
      final app = await h.open();
      await app.coordinator.createDraft();
      await app.coordinator.save();
      final snapshot = app.coordinator.currentCase();
      final catalog = await app.exports.listEvidence(
        snapshot,
        currentCase: app.coordinator.currentCase,
        currentCatalog: () => null,
      );
      expect(catalog.evidence, isEmpty);
      bool current() =>
          app.coordinator.isCurrent &&
          app.coordinator.snapshot?.caseId == snapshot.caseId &&
          app.coordinator.snapshot?.revision == snapshot.revision;
      Future<Uint8List> draft(String programId) async {
        final answers = await app.answers.readAnswers(
          snapshot,
          programId: programId,
          currentCase: app.coordinator.currentCase,
          currentProgramId: () => programId,
          currentContext: () => null,
        );
        final artifact = await app.annotatedExports.createDraftExport({
          'schemaVersion': '2',
          'caseId': snapshot.caseId,
          'expectedCaseRevision': snapshot.revision,
          'programId': programId,
          'expectedFormContextId': answers.context.formContextId,
          'expectedAnswerRevision': answers.saved?.answerRevision ?? 0,
          'expectedEvidenceCatalogRevision': catalog.catalogRevision,
          'generationKey': newUuidV4(),
          'selectedEvidence': <Object>[],
        }, isCurrent: current);
        return Uint8List.fromList(
          await app.annotatedExports.downloadDraftExport(
            artifact,
            isCurrent: current,
          ),
        );
      }

      final first = await draft('scfhp-eaa');
      final second = await draft('rtp-home-repair');
      expect(
        sha256.convert(first).toString(),
        isNot(sha256.convert(second).toString()),
      );
      final loadEntered = Completer<void>(), releaseLoad = Completer<void>();
      var nativeDisposals = 0, nativePageChecked = false;
      final earlyReference = PdfDocumentRefByLoader((_) async {
        loadEntered.complete();
        await releaseLoad.future;
        final document = await PdfDocument.openData(
          first,
          sourceName: 'native-early-close-${newUuidV4()}',
          onDispose: () => nativeDisposals++,
        );
        try {
          expectSync(document.pages, isNotEmpty);
          expectSync(
            (await document.pages.first.loadText())?.fullText.trim(),
            isNotEmpty,
          );
          nativePageChecked = true;
          return document;
        } catch (_) {
          await document.dispose();
          rethrow;
        }
      }, key: PdfDocumentRefKey('native-early-close-${newUuidV4()}'));
      final earlyLease = PrivatePdfDocumentLease(earlyReference);
      final earlyListenable = earlyReference.resolveListenable();
      try {
        await loadEntered.future;
        final closing = earlyLease.close();
        expect(nativeDisposals, 0);
        expect(nativePageChecked, isFalse);
        releaseLoad.complete();
        await closing;
        await until(
          () => nativeDisposals == 1,
          'actual native disposal after the preview closed during loading',
        );
        expect(nativePageChecked, isTrue);
        expect(earlyListenable.document, isNull);
        await earlyLease.close();
        await tester.pump(const Duration(milliseconds: 100));
        expect(nativeDisposals, 1);
      } finally {
        if (!releaseLoad.isCompleted) releaseLoad.complete();
        await earlyLease.close();
      }
      debugPrint('LOCAL_NATIVE_PDF_EARLY_CLOSE_PASSED');
      Finder scope(String name) => find.byKey(ValueKey('preview-$name'));
      Finder viewers(String name) => find.descendant(
        of: scope(name),
        matching: find.byType(PdfViewer, skipOffstage: false),
        skipOffstage: false,
      );
      PdfDocumentListenable displayed(String name) => tester
          .widget<PdfViewer>(viewers(name))
          .documentRef
          .resolveListenable();
      Finder control(String name, String key) =>
          find.descendant(of: scope(name), matching: find.byKey(ValueKey(key)));
      Finder counter(String name, int page, int count) => find.descendant(
        of: scope(name),
        matching: find.text('Page $page of $count'),
      );
      Widget screen(Uint8List bytes) => MaterialApp(
        theme: SafeAtHomeTheme.light(),
        home: Scaffold(
          body: SafeArea(
            child: PrivateContentCover(
              child: Column(
                children: [
                  Expanded(
                    child: SingleChildScrollView(
                      child: PrivateDraftPreview(
                        key: const ValueKey('preview-first'),
                        bytes: bytes,
                      ),
                    ),
                  ),
                  const Divider(height: 2),
                  Expanded(
                    child: SingleChildScrollView(
                      child: PrivateDraftPreview(
                        key: const ValueKey('preview-second'),
                        bytes: second,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      Future<void> ready(String name) => until(
        () =>
            viewers(name).evaluate().length == 1 &&
            displayed(name).document != null,
        'actual native PDF for $name',
      );
      Future<int> verify(String name, Uint8List expectedBytes) async {
        await ready(name);
        final expected = await PdfDocument.openData(expectedBytes);
        var checked = 0;
        try {
          await displayed(name).useDocument<void>((actual) async {
            expect(actual.pages.length, expected.pages.length);
            expect(actual.pages.length, inInclusiveRange(1, 20));
            for (var index = 0; index < actual.pages.length; index++) {
              final actualText =
                  (await actual.pages[index].loadText())?.fullText ?? '';
              final expectedText =
                  (await expected.pages[index].loadText())?.fullText ?? '';
              expect(
                sha256.convert(utf8.encode(actualText)).toString(),
                sha256.convert(utf8.encode(expectedText)).toString(),
                reason:
                    'Displayed PDF text must match its actual downloaded route.',
              );
              final height =
                  204 *
                  expected.pages[index].height /
                  expected.pages[index].width;
              final actualRaster = await actual.pages[index].render(
                fullWidth: 204,
                fullHeight: height,
              );
              final expectedRaster = await expected.pages[index].render(
                fullWidth: 204,
                fullHeight: height,
              );
              try {
                expect(actualRaster, isNotNull);
                expect(expectedRaster, isNotNull);
                expect(
                  sha256.convert(actualRaster!.pixels).toString(),
                  sha256.convert(expectedRaster!.pixels).toString(),
                  reason:
                      'Displayed PDF pixels must match its actual downloaded route.',
                );
              } finally {
                actualRaster?.dispose();
                expectedRaster?.dispose();
              }
              checked++;
            }
          });
          expect(checked, expected.pages.length);
          return checked;
        } finally {
          await expected.dispose();
        }
      }

      bool enabled(Finder finder) {
        final widget = tester.widget(finder);
        if (widget is ButtonStyleButton) return widget.onPressed != null;
        if (widget is IconButton) return widget.onPressed != null;
        throw StateError('Expected an actual paging button.');
      }

      Future<void> page(String name, String key, int target, int count) async {
        final button = control(name, key);
        expect(button, findsOneWidget);
        await until(
          () => enabled(button),
          'paging action finishes its prior movement',
        );
        await tester.ensureVisible(button);
        await tester.tap(button);
        await until(
          () => counter(name, target, count).evaluate().length == 1,
          'accessible page $target of $count',
        );
      }

      await tester.pumpWidget(screen(first));
      final firstCount = await verify('first', first);
      final secondCount = await verify('second', second);
      final firstKey = tester
          .widget<PdfViewer>(viewers('first'))
          .documentRef
          .key;
      final secondKey = tester
          .widget<PdfViewer>(viewers('second'))
          .documentRef
          .key;
      expect(firstKey, isNot(secondKey));
      expect(firstCount, greaterThan(1));
      await until(
        () => counter('first', 1, firstCount).evaluate().length == 1,
        'initial page count',
      );
      final expectedText = await displayed('first').useDocument<String>(
        (document) async =>
            (await document.pages.first.loadText())!.fullText.trim(),
      );
      expect(expectedText, isNotEmpty);
      final readText = control('first', 'private-pdf-read-text');
      await tester.ensureVisible(readText);
      await tester.tap(readText);
      await until(
        () =>
            find
                .descendant(
                  of: control('first', 'private-pdf-page-text'),
                  matching: find.text(expectedText!),
                )
                .evaluate()
                .length ==
            1,
        'reflowed actual current-page text',
      );
      expect(
        find.descendant(
          of: scope('first'),
          matching: find.text(
            'Text view does not show photo markings. Review the page image too.',
          ),
        ),
        findsOneWidget,
      );
      expect(tester.widget<SwitchListTile>(readText).value, true);
      final viewerFocus = tester
          .widget<PdfViewer>(viewers('first'))
          .controller!
          .focusNode;
      expect(viewerFocus, isNotNull);
      expect(viewerFocus!.canRequestFocus, false);
      viewerFocus.requestFocus();
      await tester.pump();
      expect(viewerFocus.hasFocus, false);
      await tester.ensureVisible(readText);
      await tester.tap(readText);
      await until(
        () => !tester.widget<SwitchListTile>(readText).value,
        'return to page image',
      );
      expect(viewerFocus.canRequestFocus, true);
      expect(enabled(control('first', 'private-pdf-previous')), false);
      for (var next = 2; next <= firstCount; next++) {
        await page('first', 'private-pdf-next', next, firstCount);
      }
      expect(enabled(control('first', 'private-pdf-next')), false);
      for (var previous = firstCount - 1; previous >= 1; previous--) {
        await page('first', 'private-pdf-previous', previous, firstCount);
      }
      expect(enabled(control('first', 'private-pdf-previous')), false);

      await until(
        () => enabled(control('first', 'private-pdf-next')),
        'ready for replacement during paging',
      );
      await tester.tap(control('first', 'private-pdf-next'));
      await tester.pumpWidget(screen(second));
      await verify('first', second);
      await verify('second', second);
      expect(
        tester.widget<PdfViewer>(viewers('first')).documentRef.key,
        isNot(firstKey),
      );
      expect(
        tester.widget<PdfViewer>(viewers('first')).documentRef.key,
        isNot(secondKey),
      );
      await until(
        () => counter('first', 1, secondCount).evaluate().length == 1,
        'replacement resets accessible page state',
      );
      await tester.pump(const Duration(seconds: 1));
      expect(counter('first', 1, secondCount), findsOneWidget);

      await tester.pumpWidget(screen(first));
      await verify('first', first);
      await verify('second', second);
      await until(
        () => counter('first', 1, firstCount).evaluate().length == 1,
        'restored route starts at page one',
      );
      expect(tester.takeException(), isNull);
      Map<String, Object?>? soakReport;
      if (_soakEnabled) {
        Future<({String text, String raster, int pages, double height})> sample(
          Uint8List bytes,
        ) async {
          final document = await PdfDocument.openData(bytes);
          try {
            final page = document.pages.first;
            final height = 128 * page.height / page.width;
            final image = await page.render(fullWidth: 128, fullHeight: height);
            try {
              expect(image, isNotNull);
              return (
                text: (await page.loadText())!.fullText.trim(),
                raster: sha256.convert(image!.pixels).toString(),
                pages: document.pages.length,
                height: height,
              );
            } finally {
              image?.dispose();
            }
          } finally {
            await document.dispose();
          }
        }

        final firstSample = await sample(first),
            secondSample = await sample(second);
        expect(firstSample.text, isNotEmpty);
        expect(secondSample.text, isNotEmpty);
        Future<void> checkSample(
          String name,
          ({String text, String raster, int pages, double height}) expected,
        ) async {
          await ready(name);
          var checked = false;
          await displayed(name).useDocument<void>((document) async {
            expect(document.pages.length, expected.pages);
            expect(
              (await document.pages.first.loadText())!.fullText.trim(),
              expected.text,
            );
            final image = await document.pages.first.render(
              fullWidth: 128,
              fullHeight: expected.height,
            );
            try {
              expect(image, isNotNull);
              expect(sha256.convert(image!.pixels).toString(), expected.raster);
              checked = true;
            } finally {
              image?.dispose();
            }
          });
          expect(checked, true);
          await until(
            () => counter(name, 1, expected.pages).evaluate().length == 1,
            'soak page state is ready',
          );
        }

        await tester.pumpWidget(const SizedBox.shrink());
        final started = DateTime.now().toUtc();
        final elapsed = Stopwatch()..start();
        debugPrint(
          'LOCAL_NATIVE_PREVIEW_SOAK_READY: pid=$pid cycles=${soakMinutes * 5} durationSeconds=${soakMinutes * 60} startedAt=${started.toIso8601String()}',
        );
        var cycles = 0;
        for (var index = 0; index < soakMinutes * 5; index++) {
          if (elapsed.elapsed > Duration(minutes: soakMinutes + 4)) {
            fail(
              'Native preview soak exceeded its bounded ${soakMinutes + 4}-minute session.',
            );
          }
          final startBytes = index.isEven ? first : second;
          final startSample = index.isEven ? firstSample : secondSample;
          final replacement = index.isEven ? second : first;
          final replacementSample = index.isEven ? secondSample : firstSample;
          await tester.pumpWidget(screen(startBytes));
          await checkSample('first', startSample);
          await checkSample('second', secondSample);
          final textSwitch = control('first', 'private-pdf-read-text');
          await tester.ensureVisible(textSwitch);
          await tester.tap(textSwitch);
          await until(
            () =>
                find
                    .descendant(
                      of: control('first', 'private-pdf-page-text'),
                      matching: find.text(startSample.text),
                    )
                    .evaluate()
                    .length ==
                1,
            'soak current-page text extraction',
          );
          await tester.ensureVisible(textSwitch);
          await tester.tap(textSwitch);
          await until(
            () => !tester.widget<SwitchListTile>(textSwitch).value,
            'soak returns to page image',
          );
          if (startSample.pages > 1) {
            await page('first', 'private-pdf-next', 2, startSample.pages);
          }
          await tester.pumpWidget(screen(replacement));
          await checkSample('first', replacementSample);
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump(const Duration(milliseconds: 250));
          expect(tester.takeException(), isNull);
          cycles++;
          final due = Duration(seconds: 12 * cycles);
          while (elapsed.elapsed < due) {
            await tester.pump(const Duration(milliseconds: 250));
          }
          debugPrint(
            'LOCAL_NATIVE_PREVIEW_SOAK_CHECKPOINT: cycle=$cycles elapsedMs=${elapsed.elapsedMilliseconds} utc=${DateTime.now().toUtc().toIso8601String()}',
          );
        }
        elapsed.stop();
        expect(
          elapsed.elapsed,
          greaterThanOrEqualTo(Duration(minutes: soakMinutes)),
        );
        expect(
          elapsed.elapsed,
          lessThanOrEqualTo(Duration(minutes: soakMinutes + 4)),
        );
        soakReport = {
          'cycles': cycles,
          'requestedMinutes': soakMinutes,
          'startedAt': started.toIso8601String(),
          'finishedAt': DateTime.now().toUtc().toIso8601String(),
          'durationMilliseconds': elapsed.elapsedMilliseconds,
          'forcedGarbageCollection': false,
          'downloadCount': h.transport.pdfs.length,
          'memoryConclusion': 'requires_separate_native_process_observation',
        };
        expect(h.transport.pdfs, hasLength(2));
        debugPrint(
          'LOCAL_NATIVE_PREVIEW_SOAK_PASSED: cycles=$cycles elapsedMs=${elapsed.elapsedMilliseconds} functionalAssertionsOnly=true',
        );
      }
      debugPrint(
        'LOCAL_NATIVE_PREVIEW_PASSED: simultaneous routes, exact pixels, replacement and paging',
      );
      binding.reportData = {
        'scope': 'installed_iOS_native_PDF_viewer_with_local_real_route_drafts',
        'authentication': 'fictional_provider_only',
        'routes': ['scfhp-eaa', 'rtp-home-repair'],
        'pages': [firstCount, secondCount],
        'simultaneousPreviews': 2,
        'sameFrameReplacement': true,
        'nativeDisposalsAfterEarlyClose': nativeDisposals,
        'actualDisplayedTextAndRasterMatched': true,
        'pagingBoundaries': true,
        'currentPageReflowTextMatched': true,
        'resourceSoak': soakReport,
      };
    },
    timeout: Timeout(Duration(minutes: _soakEnabled ? soakMinutes + 8 : 8)),
  );
}
