import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/features/assessment/application/bathroom_scan_session.dart';
import 'package:safe_at_home/features/assessment/application/bathroom_scan_adapter.dart';
import 'package:safe_at_home/features/assessment/domain/scan/bathroom_scan_scene.dart';
import 'package:safe_at_home/features/assessment/presentation/bathroom_scan_screen.dart';
import 'package:safe_at_home/l10n/app_localizations.dart';
import 'package:safe_at_home/l10n/catalogs/scan_sync.dart';
import 'scan_model_sync_test.dart'
    show SyncStore, SyncServer, syncCaseId, scanSyncFixtures;

class _NoCamera implements BathroomScanAdapter {
  int starts = 0;
  @override
  Future<BathroomScanCapabilities> capabilities() async =>
      const BathroomScanCapabilities(
        supported: false,
        source: 'roomplan',
        reason: 'unsupported_device',
      );
  @override
  Future<BathroomScanScene> start(String scanId) async {
    starts++;
    throw StateError('A restore must not open the camera.');
  }

  @override
  Future<void> cancel(String scanId) async {}
}

void main() {
  testWidgets(
    'unsupported phone explicitly restores an account model, cancellation changes nothing and no finding is imported',
    (tester) async {
      final server = SyncServer()
            ..set(scanSyncFixtures[0]['request']['reviewJson'] as String),
          camera = _NoCamera();
      final scan = BathroomScanSession(
        store: SyncStore(),
        caseId: syncCaseId,
        isCurrent: () => true,
        adapter: camera,
        syncApi: server.api(),
        caseRevision: () => 1,
      );
      var imports = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: BathroomScanScreen(
            session: scan,
            importedFinding: (_) => null,
            onImport: (_) async {
              imports++;
              return 'unexpected';
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(server.reads, 0);
      expect(server.writes, isEmpty);
      expect(camera.starts, 0);
      await tester.ensureVisible(find.text('Check account copy'));
      await tester.tap(find.text('Check account copy'));
      await tester.pumpAndSettle();
      expect(scan.review.scene, isNull);
      await tester.ensureVisible(find.text('Restore account model'));
      await tester.tap(find.text('Restore account model'));
      await tester.pump(const Duration(milliseconds: 350));
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(scan.review.scene, isNull);
      await tester.tap(find.text('Restore account model'));
      await tester.pump(const Duration(milliseconds: 350));
      await tester.ensureVisible(
        find.widgetWithText(FilledButton, 'Restore account model').last,
      );
      await tester.tap(
        find.widgetWithText(FilledButton, 'Restore account model').last,
      );
      await tester.pumpAndSettle();
      expect(scan.review.scene, isNotNull);
      expect(imports, 0);
      expect(camera.starts, 0);
      expect(server.writes, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'Spanish model upload confirmation remains usable at 320px and 3.2x text',
    (tester) async {
      tester.view.physicalSize = const Size(320, 812);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final server = SyncServer(), store = SyncStore(), camera = _NoCamera();
      final scan = BathroomScanSession(
        store: store,
        caseId: syncCaseId,
        isCurrent: () => true,
        adapter: camera,
        syncApi: server.api(),
        caseRevision: () => 1,
      );
      store.binary[scan.key] = Uint8List.fromList(
        utf8.encode(scanSyncFixtures[0]['request']['reviewJson'] as String),
      );
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('es'),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          builder: (ctx, child) => MediaQuery(
            data: MediaQuery.of(
              ctx,
            ).copyWith(textScaler: const TextScaler.linear(3.2)),
            child: child!,
          ),
          home: BathroomScanScreen(
            session: scan,
            importedFinding: (_) => null,
            onImport: (_) async => 'unexpected',
          ),
        ),
      );
      await tester.pumpAndSettle();
      await Scrollable.ensureVisible(
        tester.element(find.text('Consultar copia de la cuenta')),
        alignment: .5,
      );
      await tester.pump();
      await tester.tap(find.text('Consultar copia de la cuenta'));
      await tester.pumpAndSettle();
      await Scrollable.ensureVisible(
        tester.element(find.text('Guardar modelo en la cuenta')),
        alignment: .5,
      );
      await tester.pump();
      await tester.tap(find.text('Guardar modelo en la cuenta'));
      await tester.pump(const Duration(milliseconds: 350));
      final confirm = find
          .widgetWithText(FilledButton, 'Guardar modelo en la cuenta')
          .last;
      await tester.ensureVisible(confirm);
      await tester.tap(confirm);
      await tester.pumpAndSettle();
      expect(server.writes.length, 1);
      expect(camera.starts, 0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
  test(
    'all model-sync copy preserves placeholders in all five app translations',
    () {
      final placeholders = RegExp(r'\{[a-zA-Z]+\}');
      for (final entry in scanSyncTranslations.entries) {
        expect(entry.value.keys.toSet(), {
          'es',
          'zh-Hans',
          'zh-Hant',
          'vi',
          'fil',
        });
        final expected = placeholders
            .allMatches(entry.key)
            .map((m) => m.group(0))
            .toSet();
        for (final value in entry.value.values) {
          expect(
            placeholders.allMatches(value).map((m) => m.group(0)).toSet(),
            expected,
          );
        }
      }
    },
  );
}
