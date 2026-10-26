import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/l10n/app_localizations.dart';
import 'package:safe_at_home/features/tracking/reminder_recovery_notice.dart';

void main() {
  testWidgets(
    'reset explains the scope, requires confirmation, and supports cancellation',
    (tester) async {
      var resets = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ReminderRecoveryNotice(
              enabled: true,
              onReset: () async {
                resets++;
              },
            ),
          ),
        ),
      );
      await tester.tap(find.text('Reset device reminders'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Your tasks and target dates stay saved.'),
        findsOneWidget,
      );
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(resets, 0);
      await tester.tap(find.text('Reset device reminders'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.widgetWithText(FilledButton, 'Reset device reminders'),
      );
      await tester.pumpAndSettle();
      expect(resets, 1);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'Spanish reset remains reachable on a narrow display at 3.2x text',
    (tester) async {
      tester.view.physicalSize = const Size(320, 812);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var resets = 0;
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('es'),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(3.2)),
            child: child!,
          ),
          home: Scaffold(
            body: SingleChildScrollView(
              child: ReminderRecoveryNotice(
                enabled: true,
                onReset: () async {
                  resets++;
                },
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Restablecer recordatorios del dispositivo'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byType(FilledButton));
      await tester.tap(find.byType(FilledButton));
      await tester.pumpAndSettle();
      expect(resets, 1);
      expect(tester.takeException(), isNull);
    },
  );
}
