import 'homi_navigation_support.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/app/live_app.dart';
import 'package:safe_at_home/features/auth/login_screen.dart';
import 'package:safe_at_home/features/cases/case_home_screen.dart';
import 'package:safe_at_home/features/cases/case_workspace_screen.dart';
import 'package:safe_at_home/shared/models/case_draft.dart';
import 'package:safe_at_home/features/cases/plan_deletion_dialog.dart';
import 'package:safe_at_home/features/settings/account_settings_screen.dart';
import 'package:safe_at_home/l10n/app_language.dart';
import 'package:safe_at_home/l10n/app_localizations.dart';
import 'package:safe_at_home/main.dart' show DemoEntry;
import 'package:safe_at_home/shared/presentation/draft_exit_guard.dart';
import 'package:safe_at_home/shared/presentation/sah_components.dart';
import 'package:safe_at_home/shared/presentation/startup_error_screen.dart';
import 'package:safe_at_home/shared/services/draft_save_tracker.dart';

import '../services/case_evidence_api_client_test.dart' as http;
import '../services/lifecycle_api_client_test.dart' show previewJson;
import 'account_reauthentication_test.dart' show PasswordSession;
import 'app_design_test.dart' show narrowLargeText, reveal;
import 'case_coordinator_test.dart' show FakeSession, FakeTransport;
import 'core_localization_test.dart' show localized;
import 'live_workflows_test.dart' show MemoryPrivateStore, services;

const _languages = [
  AppLanguage.spanish,
  AppLanguage.chineseSimplified,
  AppLanguage.chineseTraditional,
];

class _AuthSession extends FakeSession {
  bool recovery = false;
  int resetRequests = 0, passwordUpdates = 0;
  @override
  bool get recoveryRequired => recovery;
  @override
  String? get callbackNotice =>
      'This sign-in link could not be completed. Open a fresh recovery link or sign in again.';
  @override
  Future<void> signIn(String email, String password) async =>
      throw StateError('Private provider details');
  @override
  Future<void> requestRecovery(String email) async => resetRequests++;
  @override
  Future<void> updatePassword(String password) async => passwordUpdates++;
}

void _translatedText(WidgetTester tester, AppLocalizations l10n, String key) {
  final translated = l10n.text(key);
  expect(translated, isNot(key), reason: 'Missing translation for $key');
  final finder = find.text(translated);
  expect(finder, findsWidgets, reason: key);
  for (final element in finder.evaluate()) {
    final paragraph = element.renderObject! as RenderParagraph;
    expect(paragraph.didExceedMaxLines, false, reason: key);
  }
}

Future<void> _readFullWorkspaceText(WidgetTester tester, Finder finder) async {
  expect(tester.renderObject<RenderParagraph>(finder).didExceedMaxLines, false);
  for (final alignment in [0.0, 1.0]) {
    await Scrollable.ensureVisible(
      tester.element(finder),
      alignment: alignment,
    );
    await tester.pumpAndSettle();
    final bounds = tester.getRect(finder);
    final viewport = tester.getRect(find.byType(ListView));
    expect(bounds.left, greaterThanOrEqualTo(viewport.left));
    expect(bounds.right, lessThanOrEqualTo(viewport.right));
    if (alignment == 0) {
      expect(bounds.top, greaterThanOrEqualTo(viewport.top - 0.01));
      expect(bounds.top, lessThan(viewport.bottom));
    } else {
      expect(bounds.bottom, lessThanOrEqualTo(viewport.bottom + 0.01));
      expect(bounds.bottom, greaterThan(viewport.top));
    }
  }
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.pumpAndSettle();
  if (finder.evaluate().isEmpty) await reveal(tester, finder);
  await Scrollable.ensureVisible(tester.element(finder), alignment: .5);
  await tester.pumpAndSettle();
  expect(finder.hitTestable(), findsOneWidget);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

const _controlledRecoveryCopy = <String>[
  "Sign-out could not be confirmed. Try again, or unlock your phone and restart the app.",
  "Restored on this device. Check saved state before continuing.",
  "Restored on this device. Its custom name could not be loaded.",
  "This plan’s custom name could not be loaded.",
  "The saved case changed. Compare it with your local edits before saving.",
  "Saved on this device; not yet saved online.",
  "The latest changes were not saved on this device. Keep this screen open and retry.",
  "Saved on this device. Check the unresolved saved-state result before another online save.",
  "Earlier changes saved online. Newer edits are kept on this device.",
  "Saved online.",
  "The save could not be confirmed. Check saved state before trying again.",
  "Your changes are saved online.",
  "The server and this device differ. Choose which version to keep.",
  "No saved case was found. You can retry saving this same draft.",
  "Local edits retained. Review and save them explicitly.",
  "Using the saved version.",
  "A server operation completed while local edits changed. Review both versions.",
  "The private local save could not finish.",
  "A photo is saved, but we cannot prove it is your upload. Review it before choosing which version to keep.",
  "The saved state could not be recorded privately on this device. Free device space, then check again.",
  "Rooms and concerns",
  "Home safety plan",
  "Changes need review",
  "Newer version online",
];

void main() {
  test(
    'controlled recovery and home-status copy covers all five translated locales',
    () {
      final placeholders = RegExp(r'\{[A-Za-z][A-Za-z0-9_]*\}');
      for (final language in AppLanguage.values.where(
        (value) => value != AppLanguage.system && value != AppLanguage.english,
      )) {
        final l10n = AppLocalizations(language.locale!);
        for (final english in _controlledRecoveryCopy) {
          final localized =
              AppLocalizations.translations[english]?[language.code];
          expect(localized, isNotNull, reason: '${language.code}: $english');
          expect(l10n.text(english), isNot(english));
          expect(
            placeholders.allMatches(localized!).map((m) => m[0]).toSet(),
            placeholders.allMatches(english).map((m) => m[0]).toSet(),
          );
        }
      }
    },
  );
  for (final language in _languages) {
    final locale = language.locale!;
    final l10n = AppLocalizations(locale);
    for (final scale in [1.0, 3.2]) {
      final description = '${language.code} at 320px / ${scale}x';
      testWidgets('$description sign-in, reset and callback errors', (
        tester,
      ) async {
        narrowLargeText(tester, scale: scale);
        final session = _AuthSession();
        addTearDown(session.dispose);
        await tester.pumpWidget(
          localized(
            locale,
            LoginScreen(
              key: const ValueKey('sign-in'),
              session: session,
              emailDeliveryEnabled: true,
            ),
          ),
        );
        await tester.pumpAndSettle();
        _translatedText(tester, l10n, 'Welcome back');
        _translatedText(tester, l10n, session.callbackNotice!);
        await _tap(tester, find.byKey(const ValueKey('auth-sign-in')));
        _translatedText(
          tester,
          l10n,
          'Sign-in could not be completed. Check your account details and connection.',
        );
        expect(find.textContaining('Private provider details'), findsNothing);
        await reveal(tester, find.byKey(const ValueKey('login-email')));
        await tester.enterText(
          find.byKey(const ValueKey('login-email')),
          'fictional@example.invalid',
        );
        await _tap(tester, find.text(l10n.text('Forgot password')));
        _translatedText(
          tester,
          l10n,
          'If an account can receive email at this address, a password reset link will arrive shortly.',
        );
        expect(session.resetRequests, 1);
        session.recovery = true;
        await tester.pumpWidget(
          localized(
            locale,
            LoginScreen(
              key: const ValueKey('password-reset'),
              session: session,
              emailDeliveryEnabled: true,
            ),
          ),
        );
        await tester.pumpAndSettle();
        _translatedText(tester, l10n, 'Choose a new password');
        _translatedText(tester, l10n, 'New password (12+ characters)');
        await reveal(tester, find.byType(TextField));
        await tester.enterText(find.byType(TextField), 'short');
        await _tap(tester, find.byKey(const ValueKey('auth-sign-in')));
        _translatedText(
          tester,
          l10n,
          'Use a password with at least 12 characters. If the link expired, request another.',
        );
        expect(session.passwordUpdates, 0);
        await reveal(tester, find.byType(TextField));
        await tester.enterText(find.byType(TextField), 'fictional-password-42');
        await _tap(tester, find.byKey(const ValueKey('auth-sign-in')));
        expect(session.passwordUpdates, 1);
        expect(tester.takeException(), isNull);
      });

      testWidgets('$description settings reauthentication and cancellation', (
        tester,
      ) async {
        narrowLargeText(tester, scale: scale);
        final session = PasswordSession()..reject = true;
        final transport = FakeTransport(
          (_) async => http.jsonResponse(previewJson()),
        );
        final app = AppServices(
          config: LiveAppConfig(
            apiOrigin: Uri.parse('https://example.org'),
            supabaseUrl: Uri.parse('https://example.supabase.co'),
            publishableKey: 'fictional',
          ),
          session: session,
          store: MemoryPrivateStore(),
          transport: transport,
        );
        addTearDown(() {
          app.dispose();
          session.dispose();
        });
        await tester.pumpWidget(
          localized(locale, AccountSettingsScreen(services: app)),
        );
        await tester.pumpAndSettle();
        _translatedText(tester, l10n, 'Language and display');
        _translatedText(tester, l10n, 'Privacy and data');
        await _tap(
          tester,
          find.descendant(
            of: find.byKey(const ValueKey('account-display')),
            matching: find.text(l10n.text('Language and display')),
          ),
        );
        _translatedText(tester, l10n, 'Match phone setting');
        await _tap(tester, find.byType(BackButton));
        await _tap(
          tester,
          find.descendant(
            of: find.byKey(const ValueKey('account-privacy')),
            matching: find.text(l10n.text('Privacy and data')),
          ),
        );
        await reveal(
          tester,
          find.byKey(const ValueKey('settings-delete-account')),
        );
        await _tap(
          tester,
          find.byKey(const ValueKey('settings-delete-account')),
        );
        _translatedText(tester, l10n, 'Confirm your password');
        _translatedText(tester, l10n, 'Current password');
        await reveal(tester, find.byType(TextField));
        await tester.enterText(find.byType(TextField), 'fictional-password');
        await _tap(tester, find.text(l10n.text('Confirm password')));
        _translatedText(
          tester,
          l10n,
          'Password confirmation failed. Check your password and connection. Nothing was deleted.',
        );
        expect(transport.requests, isEmpty);
        expect(
          tester.widget<TextField>(find.byType(TextField)).controller!.text,
          isEmpty,
        );
        session.reject = false;
        await tester.ensureVisible(find.byType(TextField));
        await tester.enterText(find.byType(TextField), 'fictional-password');
        await _tap(tester, find.text(l10n.text('Confirm password')));
        _translatedText(tester, l10n, 'Delete this account?');
        expect(
          transport.requests.single.endpoint.path,
          '/v1/prepare-account-deletion',
        );
        await _tap(tester, find.text(l10n.text('Cancel')));
        expect(transport.requests, hasLength(1));
        await reveal(tester, find.byKey(const ValueKey('settings-sign-out')));
        await _tap(tester, find.byKey(const ValueKey('settings-sign-out')));
        _translatedText(tester, l10n, 'Sign out and clear this device?');
        await _tap(tester, find.text(l10n.text('Cancel')));
        expect(session.userId, 'fictional-owner');
        expect(tester.takeException(), isNull);
      });

      testWidgets('$description startup, storage and cleanup failures', (
        tester,
      ) async {
        narrowLargeText(tester, scale: scale);
        var callbacks = 0;
        for (final screen in [
          const StartupErrorScreen.startup(),
          StartupErrorScreen.storage(
            onSignOut: () => callbacks++,
            error:
                'Sign-out could not be confirmed. Try again, or unlock your phone and restart the app.',
          ),
          StartupErrorScreen.cleanup(onRetry: () => callbacks++),
        ]) {
          await tester.pumpWidget(localized(locale, screen));
          await tester.pumpAndSettle();
          _translatedText(tester, l10n, screen.message);
          if (screen.error != null) {
            _translatedText(tester, l10n, screen.error!);
          }
          final button = find.byKey(
            ValueKey(
              screen.title == 'Private storage'
                  ? 'startup-sign-out'
                  : 'startup-retry-cleanup',
            ),
          );
          if (screen.title != 'Could not start') {
            await _tap(tester, button);
            expect(tester.getSize(button).height, greaterThanOrEqualTo(48));
          }
          expect(tester.takeException(), isNull);
        }
        expect(callbacks, 2);
      });

      testWidgets(
        '$description restore and conflict recovery keep guidance translated',
        (tester) async {
          narrowLargeText(tester, scale: scale);
          Map<String, Object?>? server;
          final transport = FakeTransport((request) async {
            if (request.endpoint.path == '/v1/create-case') {
              server = {...http.requestJson(request), 'revision': 1};
              return http.jsonResponse(server);
            }
            expect(request.endpoint.path, '/v1/read-case');
            return http.jsonResponse(server);
          });
          final app = services(MemoryPrivateStore(), transport);
          addTearDown(() {
            app.dispose();
            app.session.dispose();
          });
          await app.coordinator.createDraft();
          await app.coordinator.save();
          final original = app.coordinator.draft!.toJson();
          await app.coordinator.updateDraft(
            CaseDraft.fromJson({
              ...original,
              'profile': {
                ...original['profile']! as Map,
                'city': 'Fictional {name} 李家',
              },
            }),
          );
          await app.coordinator.restoreLocal(app.coordinator.draft!.caseId);
          await tester.pumpWidget(
            localized(locale, CaseWorkspaceScreen(services: app)),
          );
          await tester.pumpAndSettle();
          Future<void> checkNotice(String message) async {
            final scroll = tester.state<ScrollableState>(
              find.byType(Scrollable).first,
            );
            scroll.position.jumpTo(0);
            await tester.pumpAndSettle();
            final notice = find.byKey(const ValueKey('case-latest-update'));
            await reveal(tester, notice);
            expect(tester.widget<Text>(notice).data, l10n.text(message));
            _translatedText(tester, l10n, message);
            await _readFullWorkspaceText(tester, notice);
          }

          await checkNotice(
            'Restored on this device. Check saved state before continuing.',
          );
          await app.coordinator.reconcile();
          await tester.pumpAndSettle();
          expect(app.coordinator.conflict, true);
          await checkNotice(
            'The server and this device differ. Choose which version to keep.',
          );
          await app.coordinator.resolveConflict(keepLocal: true);
          await tester.pumpAndSettle();
          expect(app.coordinator.draft!.profile.city, 'Fictional {name} 李家');
          await checkNotice(
            'Local edits retained. Review and save them explicitly.',
          );
          await app.coordinator.reconcile();
          await app.coordinator.resolveConflict(keepLocal: false);
          await tester.pumpAndSettle();
          expect(app.coordinator.draft!.profile.city, isNull);
          await checkNotice('Using the saved version.');
          final title = find.byKey(const ValueKey('case-plan-title'));
          tester
              .state<ScrollableState>(find.byType(Scrollable).first)
              .position
              .jumpTo(0);
          await tester.pumpAndSettle();
          await reveal(tester, title);
          expect(
            tester.widget<SahPageHeader>(title).title,
            l10n.text('Home safety plan'),
          );
          await _readFullWorkspaceText(
            tester,
            find.descendant(
              of: title,
              matching: find.text(l10n.text('Home safety plan')),
            ),
          );
          expect(
            transport.requests.where(
              (request) => request.endpoint.path == '/v1/create-case',
            ),
            hasLength(1),
          );
          expect(
            transport.requests.where(
              (request) => request.endpoint.path == '/v1/read-case',
            ),
            hasLength(2),
          );
          expect(tester.takeException(), isNull);
        },
      );

      testWidgets('$description account deletion receipts', (tester) async {
        narrowLargeText(tester, scale: scale);
        FlutterSecureStorage.setMockInitialValues({});
        addTearDown(() => FlutterSecureStorage.setMockInitialValues({}));
        final config = LiveAppConfig(
          apiOrigin: Uri.parse('https://example.org'),
          supabaseUrl: Uri.parse('https://example.supabase.co'),
          publishableKey: 'fictional',
        );
        String? status;
        final transport = FakeTransport(
          (_) async => http.jsonResponse({
            'schemaVersion': '1',
            'status': status,
            'applicationDataDeleted': status != 'awaiting_confirmation',
            'providerIdentityDeleted': status == 'complete',
          }),
        );
        for (final entry in <String?, String>{
          null: 'No account deletion receipt is stored on this device.',
          'awaiting_confirmation':
              'Deletion is awaiting confirmation; data has not been deleted.',
          'auth_pending':
              'Application data is deleted. Provider account cleanup is still pending.',
          'complete': 'Application data and the provider account were deleted.',
        }.entries) {
          status = entry.key;
          if (status != null) {
            FlutterSecureStorage.setMockInitialValues({
              'sah.deletion.example.org': 'a' * 64,
            });
          }
          await tester.pumpWidget(
            localized(
              locale,
              DeletionReceiptScreen(
                key: ValueKey(status),
                config: config,
                transport: transport,
              ),
            ),
          );
          await tester.pumpAndSettle();
          await reveal(tester, find.text(l10n.text(entry.value)));
          _translatedText(tester, l10n, entry.value);
          await _tap(tester, find.text(l10n.text('Refresh status')));
          expect(tester.takeException(), isNull);
        }
        expect(transport.requests, hasLength(6));
      });

      testWidgets('$description failed editor save and discard review', (
        tester,
      ) async {
        narrowLargeText(tester, scale: scale);
        final tracker = DraftSaveTracker(isCurrent: () => true);
        addTearDown(tracker.dispose);
        await tester.pumpWidget(
          localized(
            locale,
            Builder(
              builder: (context) => Scaffold(
                body: FilledButton(
                  key: const ValueKey('open-editor'),
                  onPressed: () {
                    Navigator.of(context).push<void>(
                      MaterialPageRoute(
                        builder: (_) => DraftExitGuard(
                          tracker: tracker,
                          builder: (context, exit, exiting) => Scaffold(
                            appBar: AppBar(
                              leading: BackButton(onPressed: exit),
                            ),
                            body: const Text('Fictional resident text {count}'),
                          ),
                        ),
                      ),
                    );
                  },
                  child: const Text('Fixture'),
                ),
              ),
            ),
          ),
        );
        await _tap(tester, find.byKey(const ValueKey('open-editor')));
        await expectLater(
          tracker.track(() => Future<void>.error(StateError('disk'))),
          throwsStateError,
        );
        await tracker.settle();
        await tester.pump();
        await tester.tap(find.byType(BackButton));
        await tester.pumpAndSettle();
        _translatedText(tester, l10n, 'Changes are not saved on this device');
        await _tap(tester, find.byKey(const ValueKey('draft-exit-discard')));
        _translatedText(tester, l10n, 'Leave this editor?');
        _translatedText(
          tester,
          l10n,
          'Unsaved entries kept only in this editor will be lost. Earlier device-saved entries remain. Changes already applied to the case or saved online are not undone.',
        );
        await _tap(
          tester,
          find.byKey(const ValueKey('draft-exit-cancel-discard')),
        );
        expect(tracker.failed, true);
        expect(find.text('Fictional resident text {count}'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });

      testWidgets('$description local plan removal preserves another plan', (
        tester,
      ) async {
        narrowLargeText(tester, scale: scale);
        final store = MemoryPrivateStore();
        final transport = FakeTransport(
          (_) async => throw StateError('No network expected'),
        );
        final app = services(store, transport);
        addTearDown(() {
          app.dispose();
          app.session.dispose();
        });
        await app.coordinator.createDraft();
        final targetId = app.coordinator.draft!.caseId;
        await app.coordinator.createDraft();
        final selectedId = app.coordinator.draft!.caseId;
        bool? removed;
        await tester.pumpWidget(
          localized(
            locale,
            Builder(
              builder: (context) => Scaffold(
                body: FilledButton(
                  key: const ValueKey('open-delete'),
                  onPressed: () async {
                    removed = await showPlanDeletionDialog(
                      context: context,
                      services: app,
                      caseId: targetId,
                      title: 'Cancel owner {count}',
                    );
                  },
                  child: const Text('Fixture'),
                ),
              ),
            ),
          ),
        );
        await _tap(tester, find.byKey(const ValueKey('open-delete')));
        _translatedText(tester, l10n, 'Delete this plan?');
        _translatedText(
          tester,
          l10n,
          'This removes this device-only plan and its staged photos. Your other plans stay saved.',
        );
        expect(find.text('Cancel owner {count}'), findsOneWidget);
        await _tap(tester, find.text(l10n.text('Cancel')));
        expect(removed, false);
        expect(store.records.containsKey('case.$targetId'), true);
        await _tap(tester, find.byKey(const ValueKey('open-delete')));
        await _tap(
          tester,
          find.byKey(const ValueKey('confirm-delete-home-plan')),
        );
        expect(removed, true);
        expect(store.records.containsKey('case.$targetId'), false);
        expect(app.coordinator.draft!.caseId, selectedId);
        expect(store.records.containsKey('case.$selectedId'), true);
        expect(transport.requests, isEmpty);
        expect(tester.takeException(), isNull);
      });

      testWidgets('$description offline plan name and uncertain-save labels', (
        tester,
      ) async {
        narrowLargeText(tester, scale: scale);
        final store = MemoryPrivateStore();
        final transport = FakeTransport((request) async {
          expect(request.endpoint.path, '/v2/list-cases');
          return http.jsonResponse({
            'schemaVersion': '2',
            'cases': [],
            'nextAfterCaseId': null,
          });
        });
        final app = services(store, transport);
        addTearDown(() {
          app.dispose();
          app.session.dispose();
        });
        await app.coordinator.createDraft(name: 'Resident {name}');
        final id = app.coordinator.draft!.caseId;
        store.records['case.$id']!['uncertain'] = true;
        app.coordinator.uncertain = true;
        await tester.pumpWidget(
          localized(locale, CaseHomeScreen(services: app)),
        );
        await tester.pumpAndSettle();
        await openManagePlans(tester);
        await tester.pumpAndSettle();
        await reveal(tester, find.byKey(ValueKey('local-case-$id')));
        final status = find.text(
          l10n.text('Name saved on this device — sync pending'),
        );
        if (status.evaluate().isNotEmpty) {
          await Scrollable.ensureVisible(tester.element(status), alignment: .5);
          await tester.pumpAndSettle();
        }
        _translatedText(
          tester,
          l10n,
          'Name saved on this device — sync pending',
        );
        expect(
          find.textContaining(l10n.text('Check whether changes saved')),
          findsOneWidget,
        );
        expect(
          find.textContaining('Check whether changes saved'),
          findsNothing,
        );
        expect(tester.takeException(), isNull);
      });

      testWidgets(
        '$description conflict review translates measurements without changing source text',
        (tester) async {
          narrowLargeText(tester, scale: scale);
          final transport = FakeTransport(
            (_) async => throw StateError('No network expected'),
          );
          final app = services(MemoryPrivateStore(), transport);
          addTearDown(() {
            app.dispose();
            app.session.dispose();
          });
          await app.coordinator.createDraft();
          final json = app.coordinator.draft!.toJson();
          json['profile'] = {
            ...json['profile']! as Map<String, Object?>,
            'city': 'owner',
            'county': 'renter',
            'healthPlan': 'owner',
            'tenure': 'owner',
          };
          const observation = 'Stairs: manual confirmed owner {count}';
          json['findings'] = [
            {
              'id': 'fictional-finding',
              'room': 'bathroom',
              'observation': observation,
              'reviewState': 'confirmed',
              'evidenceIds': <String>[],
              'measurements': [
                {
                  'type': 'clearOpening',
                  'value': 800,
                  'unit': 'mm',
                  'method': 'manual',
                  'confirmed': true,
                },
                {
                  'type': 'thresholdHeight',
                  'value': 25,
                  'unit': 'mm',
                  'method': 'estimated',
                  'confirmed': false,
                },
                {
                  'type': 'fictional_width',
                  'value': 40,
                  'unit': 'mm',
                  'method': 'manual',
                  'confirmed': true,
                },
              ],
            },
          ];
          final draft = CaseDraft.fromJson(json);
          app.coordinator.draft = draft;
          app.coordinator.snapshot = draft.atRevision(1);
          app.coordinator.conflict = true;
          final before = draft.toJson();
          await tester.pumpWidget(
            localized(locale, CaseWorkspaceScreen(services: app)),
          );
          await tester.pumpAndSettle();
          await reveal(tester, find.text(l10n.text('Compare versions')));
          await _tap(tester, find.text(l10n.text('Compare versions')));
          expect(find.text('${l10n.text('City')}: owner'), findsNWidgets(2));
          expect(find.text('${l10n.text('County')}: renter'), findsNWidgets(2));
          expect(
            find.text('${l10n.text('Health plan')}: owner'),
            findsNWidgets(2),
          );
          expect(
            find.text('${l10n.text('Housing')}: ${l10n.text('Owner')}'),
            findsNWidgets(2),
          );
          for (final paragraph in tester.widgetList<Text>(
            find.textContaining(observation),
          )) {
            expect(paragraph.data, contains(l10n.text('Clear opening width')));
            expect(paragraph.data, contains(l10n.text('Threshold height')));
            expect(paragraph.data, contains(l10n.text('Measured')));
            expect(paragraph.data, contains(l10n.text('Your estimate')));
            expect(paragraph.data, contains('fictional width'));
          }
          expect(find.textContaining(observation), findsNWidgets(2));
          expect(app.coordinator.draft!.toJson(), before);
          expect(transport.requests, isEmpty);
          expect(tester.takeException(), isNull);
        },
      );

      testWidgets(
        '$description a cleared selection keeps its recovery message readable',
        (tester) async {
          narrowLargeText(tester, scale: scale);
          final transport = FakeTransport(
            (_) async => throw StateError('No network expected'),
          );
          final app = services(MemoryPrivateStore(), transport);
          addTearDown(() {
            app.dispose();
            app.session.dispose();
          });
          await tester.pumpWidget(
            localized(locale, CaseWorkspaceScreen(services: app)),
          );
          await tester.pumpAndSettle();
          _translatedText(tester, l10n, 'This case is no longer selected.');
          _translatedText(
            tester,
            l10n,
            'Return to your cases to open it again.',
          );
          await reveal(
            tester,
            find.text(l10n.text('Return to your cases to open it again.')),
          );
          expect(tester.takeException(), isNull);
          expect(transport.requests, isEmpty);
        },
      );

      testWidgets('$description demo welcome is translated and scrollable', (
        tester,
      ) async {
        narrowLargeText(tester, scale: scale);
        final previous = AppLanguageController.instance.value;
        AppLanguageController.instance.value = language;
        addTearDown(() => AppLanguageController.instance.value = previous);
        await tester.pumpWidget(const DemoEntry());
        await tester.pumpAndSettle();
        _translatedText(tester, l10n, 'A safer home starts here.');
        await reveal(tester, find.text(l10n.text('Fictional demonstration')));
        _translatedText(tester, l10n, 'Fictional demonstration');
        expect(find.byKey(const ValueKey('choose-language')), findsOneWidget);
        final button = find.text(l10n.text('Open fictional examples'));
        await reveal(tester, button);
        expect(button.hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
