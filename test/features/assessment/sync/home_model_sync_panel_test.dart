import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/l10n/app_localizations.dart';
import 'package:safe_at_home/features/assessment/presentation/home_model_sync_panel.dart';
import 'home_model_sync_test.dart';

void main() {
  for (final locale in [
    const Locale('en'),
    const Locale('es'),
    const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hans'),
    const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant'),
    const Locale('vi'),
    const Locale('fil'),
  ]) {
    testWidgets(
      '${locale.toLanguageTag()} account layout controls fit narrow large-text screens and require confirmation',
      (tester) async {
        final server = HomeSyncServer()..set(portableHome().encode()),
            device = HomeDevice(server)..bundle = portableHome();
        await device.sync.initialize();
        await device.sync.refresh();
        var prompts = 0;
        tester.view.physicalSize = const Size(320, 1600);
        tester.view.devicePixelRatio = 1;
        addTearDown(() {
          device.sync.dispose();
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
        });
        await tester.pumpWidget(
          MaterialApp(
            locale: locale,
            supportedLocales: AppLocalizations.supportedLocales,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            home: Scaffold(
              body: Builder(
                builder: (context) => MediaQuery(
                  data: MediaQuery.of(
                    context,
                  ).copyWith(textScaler: TextScaler.linear(3.2)),
                  child: SingleChildScrollView(
                    child: HomeModelSyncPanel(
                      sync: device.sync,
                      enabled: true,
                      localAvailable: true,
                      run: (work) => work(),
                      confirm: (title, description, label) async {
                        prompts++;
                        return false;
                      },
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final l = AppLocalizations(locale),
            button = find.text(l.text('Save model to account'));
        await tester.ensureVisible(button);
        await tester.tap(button);
        await tester.pumpAndSettle();
        expect(prompts, 1);
        expect(server.writes, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
