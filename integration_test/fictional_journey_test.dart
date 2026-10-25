import 'package:flutter/material.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:safe_at_home/features/assessment/domain/capture/capture_adapter.dart';
import 'package:safe_at_home/features/assessment/presentation/saved_photo_with_marks.dart';
import 'package:safe_at_home/features/cases/case_home_screen.dart';
import 'package:safe_at_home/features/programs/live_programs_screen.dart';
import 'package:safe_at_home/shared/services/case_evidence_api_client.dart';
import 'package:safe_at_home/shared/services/local_private_store.dart';
import 'package:safe_at_home/shared/services/matching_api_client.dart';

import 'support/local_acceptance_harness.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'fictional iPhone journey uses real local HTTP, PostgreSQL, private storage and PDFs',
    (tester) async {
      final config = LocalFixtureConfig.fromEnvironment();
      final h = AcceptanceHarness(config);
      final checkpoints = <String>[];
      void checkpoint(String message) {
        checkpoints.add(message);
        debugPrint('LOCAL_ACCEPTANCE: $message');
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
          tapFinder(find.text(label), direction: direction);
      Finder input(String label) => find.byWidgetPredicate(
        (widget) =>
            widget is TextField && widget.decoration?.labelText == label,
      );
      Future<void> enter(String label, String text) async {
        await visible(input(label));
        await tester.enterText(input(label), text);
        await settle();
      }

      Future<void> back() async {
        final button = find.byTooltip('Back').hitTestable();
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
        final before = h.transport.paths
            .where((p) => p == '/v1/match-case')
            .length;
        final programList = find.descendant(
          of: find.byType(LiveProgramsScreen),
          matching: find.byType(ListView),
        );
        expect(programList, findsOneWidget);
        final outerScrollable = find
            .descendant(of: programList, matching: find.byType(Scrollable))
            .first;
        final position = tester
            .state<ScrollableState>(outerScrollable)
            .position;
        debugPrint(
          'LOCAL_PROGRAM_SCROLL: before=${position.pixels.toStringAsFixed(1)} '
          'min=${position.minScrollExtent.toStringAsFixed(1)} '
          'max=${position.maxScrollExtent.toStringAsFixed(1)} '
          'viewport=${position.viewportDimension.toStringAsFixed(1)} '
          'axis=${position.axisDirection.name}',
        );
        position.jumpTo(position.minScrollExtent);
        await settle();
        expect(position.pixels, closeTo(position.minScrollExtent, 1));
        await tapFinder(find.byKey(const ValueKey('program-refresh')));
        await until(
          () =>
              h.transport.paths.where((p) => p == '/v1/match-case').length >
                  before &&
              h.transport.responseBodies['/v1/match-case']?['caseRevision'] ==
                  h.services!.coordinator.snapshot!.revision,
          'current program checks',
        );
      }

      Future<void> programAction(String id, String action) async {
        final card = find.byKey(ValueKey('program-$id'));
        await tapFinder(find.descendant(of: card, matching: find.text(action)));
      }

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
        await visible(find.text('Start a case'));
        expect(find.text('Start a case'), findsOneWidget);
      }

      await tester.pumpWidget(AcceptanceHost(harness: h));
      await settle();
      await enter('Email', 'alice@example.invalid');
      await enter('Password', 'wrong-fictional-password');
      await tap('Sign in');
      await until(
        () =>
            find.textContaining('Sign in failed').evaluate().isNotEmpty ||
            find
                .textContaining('Sign-in could not be completed')
                .evaluate()
                .isNotEmpty,
        'safe rejected-login message',
      );
      expect(h.session.userId, isNull);
      await login();
      checkpoint('fictional login');
      await tap('Start a case');
      await idle();
      await tap('Resident details');
      await enter('City', 'Fictional San Jose');
      await enter('Annual household income (USD)', '0');
      final permission = find.byType(DropdownButtonFormField<bool>);
      await tapFinder(permission);
      await tap('No');
      await tap('Keep edits on this device');
      await tap('Save online', direction: -300);
      await until(
        () => h.services!.coordinator.snapshot?.revision == 1,
        'initial real case save',
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
      await tap('Home assessment');
      await until(
        () => find.byKey(const ValueKey('area-entrance')).evaluate().isNotEmpty,
        'assessment loaded',
      );
      await tapFinder(find.byKey(const ValueKey('area-entrance')));
      await tap('Open camera');
      await until(
        () => find
            .textContaining('Camera access was not allowed')
            .evaluate()
            .isNotEmpty,
        'fictional permission denial',
      );
      await tap('Open camera');
      await until(
        () => find.textContaining('No photo was taken').evaluate().isNotEmpty,
        'fictional capture cancellation',
      );
      await tap('Open camera');
      await until(
        () => find.text('Crop or cover private details').evaluate().isNotEmpty,
        'generated photo staged',
      );
      expect(h.capture.attempts, 3);
      await tap('Crop or cover private details');
      await tap('Add opaque cover');
      await tap('Apply and review photo');
      await until(
        () => find.text('Crop or cover private details').evaluate().isNotEmpty,
        'native privacy edit applied',
      );
      await tap('Continue');
      await visible(find.byKey(const ValueKey('observation')));
      await tester.enterText(
        find.byKey(const ValueKey('observation')),
        'Fictional threshold needs a closer look.',
      );
      await visible(find.byKey(const ValueKey('measurement-thresholdHeight')));
      await tester.enterText(
        find.byKey(const ValueKey('measurement-thresholdHeight')),
        ' .5 ',
      );
      await tapFinder(
        find.descendant(
          of: find.byKey(const ValueKey('unit-thresholdHeight')),
          matching: find.text('in'),
        ),
      );
      await tap('Review');
      await tap('This Threshold height is right');
      await tap('Confirm this finding');
      await tap('Save findings and photo marks online');
      await until(
        () => find.text('Saved to your case.').evaluate().isNotEmpty,
        'assessment and photo saved',
        seconds: 55,
      );
      final caseAfterPhoto = h.services!.coordinator.snapshot!;
      expect(caseAfterPhoto.findings, hasLength(1));
      expect(caseAfterPhoto.findings.single.measurements.single.value, 12.7);
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
      await tapFinder(
        find.byKey(ValueKey('review-photo-$evidenceId')),
        direction: -260,
      );
      await tap('Mark the area on this photo');
      await tap('Add a box');
      await visible(find.byKey(const ValueKey('annotation-label')));
      await tester.enterText(
        find.byKey(const ValueKey('annotation-label')),
        'Fictional step marker',
      );
      await tap('Done', direction: -260);
      await tap('Save findings and photo marks online');
      await until(
        () =>
            h.transport.responseBodies['/v2/save-evidence-annotations'] !=
                null &&
            find.text('Saved to your case.').evaluate().isNotEmpty,
        'durable annotations saved',
        seconds: 55,
      );
      await tapFinder(find.byTooltip('Save on device and close'));
      await until(
        () => find.byTooltip('Save on device and close').evaluate().isEmpty,
        'assessment route closes after durable flush',
      );
      checkpoint(
        'fictional capture failures, native redaction, measurement and durable box',
      );

      h.transport.offline = true;
      await tap('Resident details');
      await enter('City', 'Fictional offline city');
      await tap('Keep edits on this device');
      await tap('Save online', direction: -300);
      await until(
        () =>
            h.services!.coordinator.uncertain && !h.services!.coordinator.busy,
        'offline edit retained',
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
      await tapFinder(
        find.byKey(ValueKey('local-case-${caseAfterPhoto.caseId}')),
      );
      await idle();
      expect(
        h.services!.coordinator.draft!.profile.city,
        'Fictional offline city',
      );
      h.transport.offline = false;
      await tap('Check saved state');
      await until(
        () => h.services!.coordinator.conflict && !h.services!.coordinator.busy,
        'offline conflict reconciled',
      );
      await tap('Keep my edits for another save');
      await tap('Save online', direction: -300);
      await until(
        () =>
            !h.services!.coordinator.hasUnsavedChanges &&
            !h.services!.coordinator.busy,
        'retained edits saved',
      );
      checkpoint(
        'cold service reopen decrypts local draft; explicit reconcile',
      );

      await tap('Possible assistance and drafts');
      await until(
        () => h.transport.responseBodies['/v1/match-case'] != null,
        'three-program checks',
      );
      final programs = ['scfhp-eaa', 'hpsm-eaa', 'rtp-home-repair'];
      for (final program in programs) {
        await programAction(program, 'Draft checklist');
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
        await visible(find.text('Draft only · Nothing has been submitted.'));
        expect(
          find.text('Draft only · Nothing has been submitted.'),
          findsOneWidget,
        );
        await visible(find.text('What is needed next'));
        expect(find.text('What is needed next'), findsOneWidget);
        await back();
        await programAction(program, 'Review program questions');
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
        final booleanField = find.byWidgetPredicate(
          (widget) =>
              widget is DropdownButtonFormField<String> &&
              widget.decoration.labelText == firstBoolean['label'],
        );
        await tapFinder(booleanField);
        await tap('No');
        final money = questions.where((q) => q['kind'] == 'money');
        if (money.isNotEmpty) {
          await enter((money.first as Map)['label'] as String, '0');
        }
        if (program == programs.last) {
          await enter(
            'What repairs would you like RTP to consider?',
            'Fictional threshold repair request.',
          );
        }
        final beforeRevision = h.services!.coordinator.snapshot!.revision;
        final beforeSaves = h.transport.paths
            .where((p) => p == '/v2/save-program-intake')
            .length;
        if (program == programs.first) {
          h.transport.loseNextSuccessfulResponse = '/v2/save-program-intake';
        }
        await tap('Save these reported answers');
        if (program == programs.first) {
          await until(
            () => h.transport.loseNextSuccessfulResponse == null,
            'committed response loss injected',
          );
          await tap('Check saved answers and reconcile', direction: -300);
          await until(
            () => find
                .text('The submitted answers are confirmed saved.')
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
        await back();
        await refreshPrograms();
        await programAction(program, 'Review administrative answers');
        await until(
          () =>
              (h.transport.responseBodies['/v2/read-form-answers']?['context']
                  as Map?)?['programId'] ==
              program,
          'route-specific administrative fields',
        );
        await enter('Given name', 'Fictional Resident');
        await tapFinder(
          find.byKey(const ValueKey('form-review-memberFirstName')),
        );
        final beforeForm = h.services!.coordinator.snapshot!.revision;
        await tap('Save reviewed administrative answers');
        await until(
          () => h.services!.coordinator.snapshot!.revision == beforeForm + 1,
          'reviewed administrative answers saved',
        );
        await back();
        await refreshPrograms();
        final priorExportFormReads = h.transport.paths
            .where((path) => path == '/v2/read-form-answers')
            .length;
        await programAction(program, 'Review evidence and draft PDF');
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
        await tap('Photo 1');
        await until(
          () => find.text('Review private photo').evaluate().isNotEmpty,
          'canonical evidence preview',
        );
        final markedPhoto = find.byType(SavedPhotoWithMarks);
        await visible(markedPhoto);
        expect(markedPhoto, findsOneWidget);
        expect(
          find.descendant(
            of: markedPhoto,
            matching: find.text('Fictional step marker'),
          ),
          findsOneWidget,
        );
        final noteLegend = find.byElementPredicate((element) {
          final widget = element.widget;
          if (widget is! Text || widget.data != 'Fictional step marker') {
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
        await tap('Include this reviewed photo');
        final pdfCount = h.transport.pdfs.length;
        await tap('Prepare or recover this draft');
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
        expect(
          find.textContaining('The PDF preview could not be opened'),
          findsNothing,
        );
        final displayed = tester
            .widget<PdfViewer>(find.byType(PdfViewer))
            .documentRef
            .resolveListenable();
        final text = StringBuffer();
        var markedPageRendered = false;
        await displayed.useDocument<void>((viewerDocument) async {
          final document = await PdfDocument.openData(h.transport.pdfs.last);
          try {
            expect(viewerDocument.pages.length, document.pages.length);
            for (var index = 0; index < document.pages.length; index++) {
              final page = document.pages[index];
              final pageText = (await page.loadText())?.fullText ?? '';
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
              if (pageText.contains('Fictional step marker')) {
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
          } finally {
            await document.dispose();
          }
        });
        expect(markedPageRendered, true);
        expect(text.toString(), contains('Fictional step marker'));
        expect(text.toString(), contains('Fictional Resident'));
        expect(text.toString(), contains('REPORTED FACTS ONLY'));
        expect(text.toString(), contains('Unknown'));
        expect(text.toString(), contains('Reported No'));
        if (money.isNotEmpty) {
          expect(text.toString(), contains('Reported USD 0.00'));
        }
        if (program == programs.last) {
          expect(text.toString().toLowerCase(), contains('worksheet'));
          expect(
            text.toString(),
            contains('Fictional threshold repair request.'),
          );
        }
        await tap('Share or save draft', direction: -300);
        await until(
          () => find.text('Share an incomplete draft?').evaluate().isNotEmpty,
          'draft-sharing warning',
        );
        await tap('Cancel');
        await back();
        await programAction(program, 'Manual request history');
        await enter(
          'Optional note',
          'Fictional resident will ask the program about missing documents.',
        );
        await tap('Save manual update');
        await until(
          () =>
              h
                  .transport
                  .responseBodies['/v1/append-request-update']?['programId'] ==
              program,
          'manual update acknowledged for this program',
        );
        final historyNotice = find.text(
          'Manual update saved. This is not verified agency status.',
        );
        await visible(historyNotice, direction: -260);
        expect(historyNotice, findsOneWidget);
        expect(
          (h.transport.responseBodies['/v1/append-request-update']!['events']
                  as List)
              .single['status'],
          'preparing',
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
      await back();
      await back();
      await tapFinder(find.byTooltip('Settings'));
      await tap('Delete selected case');
      await tap('Continue');
      await until(
        () => h.services!.coordinator.snapshot == null,
        'case and evidence deletion',
      );
      await visible(find.text('Selected case deleted.'), direction: -260);
      expect(find.text('Selected case deleted.'), findsOneWidget);
      var status = await config.control('status', {});
      expect(status['cases'], 0);
      expect(status['evidence'], 0);
      expect(status['derivedRows'], 0);
      await tap('Sign out and clear local data');
      await tap('Continue');
      await until(
        () =>
            h.session.userId == null &&
            find.text('Sign in').evaluate().isNotEmpty,
        'sign-out returns to login',
      );
      await until(
        () => !previousDirectory.existsSync(),
        'sign-out removes account files',
      );
      checkpoint('other owner denied; case/photo deletion; sign-out cleanup');

      await login();
      await tap('Start a case');
      await idle();
      await tap('Save online');
      await until(
        () => h.services!.coordinator.snapshot?.revision == 1,
        'new case for account-deletion check',
      );
      await idle();
      await back();
      await tapFinder(find.byTooltip('Settings'));
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
        () => find.text('Delete this account?').evaluate().isNotEmpty,
        'reviewed account-deletion confirmation',
      );
      await tap('Continue');
      await until(
        () =>
            h.session.userId == null &&
            find.text('Sign in').evaluate().isNotEmpty,
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
        'Application data is deleted. Provider account cleanup is still pending.',
      );
      await visible(pendingProviderNotice);
      expect(pendingProviderNotice, findsOneWidget);
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
        'recovery': 'service_recreation_not_OS_process_death',
        'sharing': 'warning_and_cancel_only',
        'providerDeletion': 'pending_not_executed',
        'checkpoints': checkpoints,
        'pdfs': h.transport.pdfs.length,
        'requests': status['requests'],
        'remainingCases': status['cases'],
        'remainingEvidence': status['evidence'],
        'remainingDerivedRows': status['derivedRows'],
      };
    },
    timeout: const Timeout(Duration(minutes: 22)),
  );
}
