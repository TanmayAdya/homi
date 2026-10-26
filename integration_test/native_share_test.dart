import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:safe_at_home/app/private_content_cover.dart';
import 'package:safe_at_home/app/theme.dart';
import 'package:safe_at_home/features/requests/private_export_screen.dart';
import 'support/local_acceptance_harness.dart';

Future<bool> _isOwnedShareFile(File file, Directory directory) async {
  if (!RegExp(
        r'^draft-[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\.pdf$',
      ).hasMatch(file.uri.pathSegments.last) ||
      file.parent.absolute.path != directory.absolute.path ||
      await FileSystemEntity.type(directory.path, followLinks: false) !=
          FileSystemEntityType.directory ||
      await FileSystemEntity.type(file.path, followLinks: false) !=
          FileSystemEntityType.file) {
    return false;
  }
  final root = await directory.resolveSymbolicLinks();
  return await file.resolveSymbolicLinks() ==
      '$root/${file.uri.pathSegments.last}';
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'operator cancels a real native draft share without submission',
    (tester) async {
      final config = LocalFixtureConfig.fromEnvironment();
      final h = AcceptanceHarness(config);
      File? ownedShare;
      Directory? shareDirectory;
      addTearDown(() async {
        try {
          await tester.pumpWidget(const SizedBox.shrink());
        } finally {
          try {
            if (ownedShare != null &&
                shareDirectory != null &&
                await _isOwnedShareFile(ownedShare, shareDirectory)) {
              await ownedShare.delete();
            }
          } finally {
            try {
              await h.close(clear: true);
            } finally {
              h.session.dispose();
            }
          }
        }
      });
      Future<void> until(
        bool Function() ready,
        String reason, {
        int seconds = 40,
      }) async {
        final clock = Stopwatch()..start();
        while (!ready()) {
          if (clock.elapsed > Duration(seconds: seconds)) {
            fail('Timed out: $reason');
          }
          await tester.pump(const Duration(milliseconds: 100));
        }
        await tester.pump(const Duration(milliseconds: 300));
      }

      Future<void> tap(String label) async {
        final finder = find.text(label);
        await tester.scrollUntilVisible(
          finder,
          280,
          scrollable: find.byType(Scrollable).first,
          maxScrolls: 70,
        );
        await tester.ensureVisible(finder);
        await tester.pump(const Duration(milliseconds: 400));
        await tester.tap(finder);
        await tester.pump(const Duration(milliseconds: 400));
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
      final checks = await app.matching.matchCase(
        app.coordinator.currentCase(),
        currentCase: app.coordinator.currentCase,
      );
      final program = checks.matches.singleWhere(
        (p) => p.programId == 'scfhp-eaa',
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: SafeAtHomeTheme.light(),
          home: PrivateContentCover(
            child: PrivateExportScreen(services: app, program: program),
          ),
        ),
      );
      await until(
        () => h.transport.responseBodies['/v2/read-form-answers'] != null,
        'draft inputs',
      );
      await tap('Create draft PDF');
      await until(() => h.transport.pdfs.length == 1, 'real draft download');
      final pdf = h.transport.pdfs.single;
      final doc = await PdfDocument.openData(
        pdf,
        sourceName: 'fictional-share-check',
      );
      expect(doc.pages, isNotEmpty);
      await doc.dispose();
      const native = MethodChannel('safe_at_home/private_media');
      final privateRoot = await native.invokeMethod<String>(
        'privateRootDirectory',
      );
      expect(privateRoot, isNotNull);
      final shares = Directory('$privateRoot/temporary-shares');
      shareDirectory = shares;
      final before = await shares.exists()
          ? (await shares.list(followLinks: false).toList())
                .map((e) => e.path)
                .toSet()
          : <String>{};
      final writesBefore = h.transport.paths
          .where((p) => p == '/v1/append-request-update')
          .length;
      await tap('Share draft file');
      expect(
        find.textContaining(
          'It doesn’t send your application. The app or person you choose can keep a copy.',
        ),
        findsOneWidget,
      );
      await tester.tap(find.text('Open share sheet'));
      await tester.pump(const Duration(milliseconds: 500));
      final watch = Stopwatch()..start();
      final expectedDigest = sha256.convert(pdf);
      var completePdf = false;
      while (!completePdf) {
        if (watch.elapsed > const Duration(seconds: 20)) {
          fail('Complete native share PDF was not prepared');
        }
        if (await shares.exists()) {
          final files = <File>[];
          await for (final entity in shares.list(followLinks: false)) {
            if (entity is File &&
                !before.contains(entity.path) &&
                await _isOwnedShareFile(entity, shares)) {
              files.add(entity);
            }
          }
          if (files.length == 1) ownedShare = files.single;
          if (files.length > 1) {
            fail('Unexpected concurrent private share files');
          }
        }
        final candidate = ownedShare;
        if (candidate != null) {
          try {
            completePdf =
                await _isOwnedShareFile(candidate, shares) &&
                await candidate.length() == pdf.length &&
                sha256.convert(await candidate.readAsBytes()) == expectedDigest;
          } on FileSystemException {
            completePdf = false;
          }
        }
        await tester.pump(const Duration(milliseconds: 100));
      }
      final sharedFile = ownedShare;
      if (sharedFile == null) fail('No owned share file was recorded');
      debugPrint(
        'LOCAL_NATIVE_SHARE_READY: inspect the native sheet and cancel; do not send or save',
      );
      await until(
        () => find.text('Opening sharing…').evaluate().isEmpty,
        'operator to cancel native sheet',
        seconds: 150,
      );
      expect(find.text('Share draft file'), findsOneWidget);
      expect(
        h.transport.paths.where((p) => p == '/v1/append-request-update').length,
        writesBefore,
      );
      expect(find.byType(SnackBar), findsNothing);
      final cleanup = Stopwatch()..start();
      while (await sharedFile.exists()) {
        if (cleanup.elapsed > const Duration(seconds: 135)) {
          fail('Owned temporary share was not removed');
        }
        await tester.pump(const Duration(milliseconds: 250));
      }
      debugPrint(
        'LOCAL_NATIVE_SHARE_RETURNED: real PDF bytes, no history write, temporary file removed',
      );
      expect(tester.takeException(), isNull);
    },
    skip: !const bool.fromEnvironment('SAH_NATIVE_SHARE_REVIEW'),
    timeout: const Timeout(Duration(minutes: 7)),
  );
}
