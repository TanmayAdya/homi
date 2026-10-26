import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:safe_at_home/features/cases/case_home_screen.dart';
import 'package:safe_at_home/shared/services/local_private_store.dart';

import 'support/local_acceptance_harness.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'installed local case/account deletion and receipt recovery',
    (tester) async {
      final config = LocalFixtureConfig.fromEnvironment();
      final harness = AcceptanceHarness(config);
      final secrets = DeviceSecretStore();
      final receiptKey = 'sah.deletion.${config.app.apiOrigin.host}';
      final receiptOwnerKey = 'sah.deletion-owner.${config.app.apiOrigin.host}';
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await harness.close(clear: true);
        harness.session.dispose();
        if (await secrets.read(receiptOwnerKey) == config.alice) {
          await secrets.delete(receiptKey);
          await secrets.delete(receiptOwnerKey);
        }
      });
      Future<void> until(bool Function() ready, String description) async {
        final wait = Stopwatch()..start();
        while (!ready()) {
          if (wait.elapsed > const Duration(seconds: 35)) {
            fail('Timed out: $description');
          }
          await tester.pump(const Duration(milliseconds: 100));
        }
        await tester.pump(const Duration(milliseconds: 300));
      }

      Future<void> reveal(Finder finder, {double direction = 260}) async {
        FocusManager.instance.primaryFocus?.unfocus();
        await tester.pump(const Duration(milliseconds: 250));
        if (find.byType(Scrollable).evaluate().isNotEmpty) {
          await tester.scrollUntilVisible(
            finder,
            direction,
            scrollable: find.byType(Scrollable).first,
            maxScrolls: 60,
          );
        }
        await Scrollable.ensureVisible(
          tester.element(finder.first),
          alignment: .5,
        );
        await tester.pump(const Duration(milliseconds: 250));
      }

      Future<void> tap(Finder finder, {double direction = 260}) async {
        await reveal(finder, direction: direction);
        await until(() {
          final candidates = finder.hitTestable().evaluate();
          if (candidates.length != 1) return false;
          var enabled = true;
          bool check(Element element) {
            final widget = element.widget;
            if (widget is ButtonStyleButton && widget.onPressed == null ||
                widget is IconButton && widget.onPressed == null) {
              enabled = false;
            }
            return true;
          }

          check(candidates.single);
          candidates.single.visitAncestorElements(check);
          return enabled;
        }, 'enabled action');
        await tester.tap(finder.hitTestable());
        await tester.pump(const Duration(milliseconds: 350));
      }

      Future<void> text(String label, String value) async {
        final field = find.byWidgetPredicate(
          (widget) =>
              widget is TextField &&
              (widget.decoration?.labelText == label ||
                  (widget.decoration?.label is Text &&
                      (widget.decoration!.label! as Text).data == label)),
        );
        await reveal(field);
        await tester.enterText(field, value);
        await tester.pump(const Duration(milliseconds: 100));
      }

      Future<void> loginAndCreate() async {
        await text('Email', 'alice@example.invalid');
        await text('Password', 'fictional-password-only');
        await tap(find.text('Sign in'));
        await until(
          () => find.byType(CaseHomeScreen).evaluate().isNotEmpty,
          'signed-in home',
        );
        await tap(find.text('Start a home plan'));
        await tap(find.byKey(const ValueKey('plan-name-save')));
        await until(
          () =>
              harness.services!.coordinator.draft != null &&
              !harness.services!.coordinator.busy,
          'local case',
        );
        await tap(find.text('Resident details'));
        await text('City', 'Fictional lifecycle check');
        await tap(find.byKey(const ValueKey('profile-keep-edits')));
        await until(
          () =>
              harness.services!.coordinator.snapshot?.revision == 2 &&
              harness.services!.coordinator.snapshot?.profile.city ==
                  'Fictional lifecycle check' &&
              !harness.services!.coordinator.hasUnsavedChanges &&
              !harness.services!.coordinator.busy &&
              find
                  .byKey(const ValueKey('profile-keep-edits'))
                  .evaluate()
                  .isEmpty,
          'resident details automatically update the newly saved case',
        );
        await tap(find.byKey(const ValueKey('open-account')));
        await tap(find.byKey(const ValueKey('account-privacy')));
      }

      final initial = await config.control('status', {});
      expect(initial['cases'], 0);
      expect(initial['closedAccounts'], 0);
      await tester.pumpWidget(AcceptanceHost(harness: harness));
      await tester.pump(const Duration(milliseconds: 350));
      await loginAndCreate();
      final accountDirectory = harness.directory!;
      await tap(find.text('Delete this plan'));
      await tap(find.text('Continue'));
      await until(
        () => harness.services!.coordinator.snapshot == null,
        'case deletion',
      );
      await reveal(find.text('Plan deleted.'), direction: -260);
      expect(find.text('Plan deleted.'), findsOneWidget);
      var status = await config.control('status', {});
      expect(status['cases'], 0);
      expect(status['derivedRows'], 0);
      await tap(find.text('Sign out and clear local data'), direction: -260);
      await tap(find.text('Continue'));
      await until(
        () =>
            harness.session.userId == null &&
            !harness.session.cleaningUp &&
            find.text('Sign in').evaluate().isNotEmpty,
        'complete sign-out cleanup',
      );
      expect(await accountDirectory.exists(), false);
      debugPrint(
        'LOCAL_LIFECYCLE: case deleted and private sign-out cleanup finished',
      );

      await loginAndCreate();
      var receiptPrecedesConfirm = false;
      harness.transport.beforeRequest = (path) async {
        if (path == '/v1/confirm-account-deletion') {
          receiptPrecedesConfirm =
              await secrets.read(receiptKey) != null &&
              await secrets.read(receiptOwnerKey) == config.alice;
          expect(receiptPrecedesConfirm, true);
        }
      };
      await tap(find.text('Delete account and application data'));
      await text('Current password', 'fictional-password-only');
      await tap(find.text('Confirm password'));
      await until(
        () => find.text('Delete this account?').evaluate().isNotEmpty,
        'deletion review',
      );
      await tap(find.text('Continue'));
      await until(
        () =>
            harness.session.userId == null &&
            !harness.session.cleaningUp &&
            find.text('Sign in').evaluate().isNotEmpty,
        'application deletion and local cleanup',
      );
      expect(receiptPrecedesConfirm, true);
      expect(await harness.directory!.exists(), false);
      status = await config.control('status', {});
      expect(status['cases'], 0);
      expect(status['evidence'], 0);
      expect(status['derivedRows'], 0);
      expect(status['closedAccounts'], 1);
      expect(await secrets.read(receiptKey), isNotNull);
      await tap(find.text('Check pending account deletion'));
      await until(
        () => find
            .text(
              'Application data is deleted. Provider account cleanup is still pending.',
            )
            .evaluate()
            .isNotEmpty,
        'logged-out real receipt status',
      );
      expect(harness.session.userId, isNull);
      expect(await secrets.read(receiptKey), isNotNull);
      expect(tester.takeException(), isNull);
      debugPrint(
        'LOCAL_LIFECYCLE: receipt persisted before confirm and resumed while signed out',
      );
      binding.reportData = {
        'scope': 'installed_iOS_local_HTTP_PostgreSQL_native_storage_lifecycle',
        'authentication': 'fictional_provider_only',
        'providerDeletion': 'pending_not_executed',
        'receiptPrecedesConfirm': receiptPrecedesConfirm,
        'cases': status['cases'],
        'evidence': status['evidence'],
        'derivedRows': status['derivedRows'],
        'closedAccounts': status['closedAccounts'],
      };
    },
    timeout: const Timeout(Duration(minutes: 8)),
  );
}
