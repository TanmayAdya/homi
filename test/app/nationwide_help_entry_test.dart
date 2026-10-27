import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/app/live_app.dart';
import 'package:safe_at_home/features/cases/case_home_screen.dart';
import 'package:safe_at_home/features/local_help/nationwide_help_browser.dart';
import 'case_coordinator_test.dart' show FakeSession, FakeTransport;
import 'core_localization_test.dart' show localized;
import 'live_workflows_test.dart' show MemoryPrivateStore;

void main() {
  for (final enabled in [true, false]) {
    testWidgets(
      'actual shell Help without any plan respects feature flag $enabled',
      (tester) async {
        final store = MemoryPrivateStore();
        final app = AppServices(
          config: LiveAppConfig(
            apiOrigin: Uri.parse('https://example.org'),
            supabaseUrl: Uri.parse('https://example.supabase.co'),
            publishableKey: 'fictional',
            localHelpEnabled: enabled,
          ),
          session: FakeSession(),
          store: store,
          transport: FakeTransport(
            (_) async => throw StateError('Fictional offline discovery'),
          ),
        );
        addTearDown(() {
          app.dispose();
          app.session.dispose();
        });
        await tester.pumpWidget(
          localized(const Locale('en'), CaseHomeScreen(services: app)),
        );
        await tester.pumpAndSettle();
        expect(app.coordinator.draft, isNull);
        await tester.tap(find.byKey(const ValueKey('plan-tab-help')));
        await tester.pumpAndSettle();
        expect(
          find.byType(NationwideHelpBrowser),
          enabled ? findsOneWidget : findsNothing,
        );
        if (enabled) {
          expect(
            find.byKey(const ValueKey('help-location-state')),
            findsOneWidget,
          );
        }
        expect(await store.keys(), isEmpty);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
