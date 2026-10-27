import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/app/live_app.dart';
import 'package:safe_at_home/features/sharing/sharing_screens.dart';
import 'package:safe_at_home/shared/models/sharing.dart';
import 'package:safe_at_home/shared/models/case_draft.dart';
import 'package:safe_at_home/shared/services/matching_api_client.dart';
import '../../app/case_coordinator_test.dart' show FakeTransport, FakeSession;
import '../../app/live_workflows_test.dart' show MemoryPrivateStore, services;
import '../../services/case_evidence_api_client_test.dart' as http;
import 'sharing_contract_test.dart' show sharedFixture;

Map<String, Object?> _view({bool viewer = false}) {
  final v = sharedFixture(),
      member = Map<String, Object?>.from(v['membership']! as Map);
  if (viewer) {
    member['role'] = 'viewer';
    member['scope'] = {...(member['scope']! as Map), 'allowHelperNotes': false};
  }
  return {...v, 'membership': member};
}

AppServices _ownerServices(
  bool email,
  MemoryPrivateStore store,
  FakeTransport transport, {
  bool labels = false,
}) => AppServices(
  config: LiveAppConfig(
    apiOrigin: Uri.parse('https://example.org'),
    supabaseUrl: Uri.parse('https://fictional.supabase.co'),
    publishableKey: 'fictional',
    permissionSharingEnabled: true,
    simpleInvitationsEnabled: email,
    sharingLabelsEnabled: labels,
  ),
  session: FakeSession(),
  store: store,
  transport: transport,
);

Future<void> _mount(WidgetTester tester, AppServices app, Widget screen) async {
  addTearDown(() {
    app.dispose();
    app.session.dispose();
  });
  await tester.pumpWidget(MaterialApp(home: screen));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'viewer sees a selected online projection without editors, helper writes, or local storage',
    (tester) async {
      final view = _view(viewer: true), paths = <String>[];
      final store = MemoryPrivateStore();
      final app = services(
        store,
        FakeTransport((request) async {
          paths.add(request.endpoint.path);
          return http.jsonResponse(
            request.endpoint.path.endsWith('list-shared-cases')
                ? {
                    'schemaVersion': '3',
                    'memberships': [view['membership']],
                  }
                : view,
          );
        }),
      );
      await _mount(
        tester,
        app,
        SharedCaseScreen(
          services: app,
          membership: CaseMembership.fromJson(view['membership']),
        ),
      );
      expect(find.text('Fictional step to review'), findsOneWidget);
      expect(find.text('Add progress note'), findsNothing);
      expect(find.text('Edit profile'), findsNothing);
      expect(store.records, isEmpty);
      expect(paths.every((p) => p.startsWith('/v3/')), isTrue);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'revocation hides previously visible content when access is revalidated',
    (tester) async {
      final view = _view();
      var revoked = false;
      final app = services(
        MemoryPrivateStore(),
        FakeTransport((request) async {
          if (revoked) {
            return http.jsonResponse({
              'schemaVersion': '3',
              'error': {
                'code': 'SHARING_NOT_FOUND',
                'message': 'private server detail',
              },
            }, status: 404);
          }
          return http.jsonResponse(
            request.endpoint.path.endsWith('list-shared-cases')
                ? {
                    'schemaVersion': '3',
                    'memberships': [view['membership']],
                  }
                : view,
          );
        }),
      );
      await _mount(
        tester,
        app,
        SharedCaseScreen(
          services: app,
          membership: CaseMembership.fromJson(view['membership']),
        ),
      );
      expect(find.text('Fictional step to review'), findsOneWidget);
      revoked = true;
      await tester.tap(find.byTooltip('Refresh access'));
      await tester.pumpAndSettle();
      expect(find.text('Fictional step to review'), findsNothing);
      expect(find.text('Add progress note'), findsNothing);
      expect(find.textContaining('private server detail'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'backgrounding clears content and a signed-out late response cannot restore it',
    (tester) async {
      final view = _view();
      Completer<MatchingHttpResponse>? gate;
      final app = services(
        MemoryPrivateStore(),
        FakeTransport((request) async {
          if (gate != null) return gate.future;
          return http.jsonResponse(
            request.endpoint.path.endsWith('list-shared-cases')
                ? {
                    'schemaVersion': '3',
                    'memberships': [view['membership']],
                  }
                : view,
          );
        }),
      );
      await _mount(
        tester,
        app,
        SharedCaseScreen(
          services: app,
          membership: CaseMembership.fromJson(view['membership']),
        ),
      );
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      expect(find.text('Fictional step to review'), findsNothing);
      gate = Completer<MatchingHttpResponse>();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      await app.session.signOut();
      gate.complete(
        http.jsonResponse({
          'schemaVersion': '3',
          'memberships': [view['membership']],
        }),
      );
      await tester.pumpAndSettle();
      expect(find.text('Fictional step to review'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'helper notes send only the granted membership revision and a mutation ID',
    (tester) async {
      final view = _view();
      Map<String, Object?>? saved;
      final app = services(
        MemoryPrivateStore(),
        FakeTransport((request) async {
          if (request.endpoint.path.endsWith('add-shared-note')) {
            saved = Map<String, Object?>.from(
              jsonDecode(utf8.decode(request.body)) as Map,
            );
          }
          return http.jsonResponse(
            request.endpoint.path.endsWith('list-shared-cases')
                ? {
                    'schemaVersion': '3',
                    'memberships': [view['membership']],
                  }
                : view,
          );
        }),
      );
      await _mount(
        tester,
        app,
        SharedCaseScreen(
          services: app,
          membership: CaseMembership.fromJson(view['membership']),
        ),
      );
      await tester.scrollUntilVisible(
        find.byType(TextField),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.enterText(find.byType(TextField), 'Fictional note');
      await tester.ensureVisible(find.text('Add progress note'));
      await tester.tap(find.text('Add progress note'));
      await tester.pumpAndSettle();
      expect(saved?['expectedPermissionRevision'], 2);
      expect(saved?['note'], 'Fictional note');
      expect(saved?.keys.toSet(), {
        'schemaVersion',
        'membershipId',
        'expectedPermissionRevision',
        'mutationId',
        'note',
      });
      expect(saved?['mutationId'], isNotEmpty);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'recipient reviews invitation permissions before an explicit accept',
    (tester) async {
      final view = _view();
      var accepted = false;
      final pending = {
        ...(view['membership']! as Map),
        'permissionRevision': 1,
        'state': 'pending',
      };
      final app = services(
        MemoryPrivateStore(),
        FakeTransport((request) async {
          if (request.endpoint.path.endsWith('review-invitation')) {
            return http.jsonResponse({
              'schemaVersion': '3',
              'membership': pending,
            });
          }
          if (request.endpoint.path.endsWith('accept-invitation')) {
            accepted = true;
            return http.jsonResponse({
              'schemaVersion': '3',
              'membership': view['membership'],
            });
          }
          return http.jsonResponse({
            'schemaVersion': '3',
            'memberships': accepted ? [view['membership']] : [],
          });
        }),
      );
      await _mount(tester, app, SharedWithMeScreen(services: app));
      expect(find.text('Accept invitation'), findsNothing);
      await tester.enterText(
        find.byType(TextField),
        List.filled(43, 'a').join(),
      );
      await tester.tap(find.text('Review invitation'));
      await tester.pumpAndSettle();
      expect(accepted, isFalse);
      expect(find.text('Progress notes allowed'), findsOneWidget);
      await tester.ensureVisible(find.text('Accept invitation'));
      await tester.tap(find.text('Accept invitation'));
      await tester.pumpAndSettle();
      expect(accepted, isTrue);
      expect(find.text('Plan shared with you'), findsOneWidget);
      expect(find.textContaining('Invited by account'), findsNothing);
      expect(
        find.textContaining(
          (view['membership']! as Map)['membershipId'] as String,
        ),
        findsNothing,
      );
    },
  );
  for (final emailInvites in [false, true]) {
    testWidgets(
      'owner previews an explicit selection before creating a recipient-bound code (email: $emailInvites)',
      (tester) async {
        tester.view.physicalSize = emailInvites
            ? const Size(340, 1000)
            : const Size(900, 1600);
        tester.view.devicePixelRatio = 1;
        if (emailInvites) {
          tester.platformDispatcher.textScaleFactorTestValue = 2;
        }
        addTearDown(() {
          tester.view.resetPhysicalSize();
          tester.view.resetDevicePixelRatio();
          tester.platformDispatcher.clearTextScaleFactorTestValue();
        });
        Map<String, Object?>? snapshot, created;
        Map<String, Object?>? selected;
        String? clipboard, shared;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              const MethodChannel('dev.fluttercommunity.plus/share'),
              (call) async {
                shared = (call.arguments as Map)['text'] as String;
                return 'dev.fluttercommunity.plus/share/unavailable';
              },
            );
        addTearDown(
          () => TestDefaultBinaryMessengerBinding
              .instance
              .defaultBinaryMessenger
              .setMockMethodCallHandler(
                const MethodChannel('dev.fluttercommunity.plus/share'),
                null,
              ),
        );
        if (emailInvites) {
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(SystemChannels.platform, (call) async {
                if (call.method == 'Clipboard.setData') {
                  clipboard = (call.arguments as Map)['text'] as String;
                }
                return null;
              });
          addTearDown(
            () => TestDefaultBinaryMessengerBinding
                .instance
                .defaultBinaryMessenger
                .setMockMethodCallHandler(SystemChannels.platform, null),
          );
        }
        final app = _ownerServices(
          emailInvites,
          MemoryPrivateStore(),
          labels: !emailInvites,
          FakeTransport((request) async {
            final body = Map<String, Object?>.from(
              jsonDecode(utf8.decode(request.body)) as Map,
            );
            expect(
              body.containsKey('includeLabels'),
              !emailInvites && request.endpoint.path.contains('list'),
            );
            switch (request.endpoint.path) {
              case '/v1/create-case':
                snapshot = {...body, 'revision': 1};
                return http.jsonResponse(snapshot);
              case '/v3/list-sharing':
              case '/v3/list-email-sharing':
                return http.jsonResponse({
                  'schemaVersion': '3',
                  'shares': [],
                  'availableProgramIds': [],
                });
              case '/v3/preview-sharing':
                selected = body;
                return http.jsonResponse({
                  'schemaVersion': '3',
                  'projection': {
                    'schemaVersion': '3',
                    'caseId': snapshot!['caseId'],
                    'sourceRevision': 1,
                    'publishedAt': '2026-10-24T00:00:00.000Z',
                    'stale': false,
                    'summary': 'Selected home safety information',
                    'findings':
                        ((snapshot!['findings'] as List).cast<Map>().where(
                              (f) => (body['scope'] as Map)['findingIds']
                                  .contains(f['id']),
                            ))
                            .map(
                              (f) => {
                                'id': f['id'],
                                'room': f['room'],
                                'observation': f['observation'],
                                'reviewState': f['reviewState'],
                              },
                            )
                            .toList(),
                    'programs': [],
                  },
                });
              case '/v3/create-invitation':
              case '/v3/create-email-invitation':
                created = body;
                return http.jsonResponse({
                  'schemaVersion': '3',
                  'created': true,
                  'invitationCode': List.filled(43, 'a').join(),
                  'membership': {
                    'membershipId': body['invitationId'],
                    'caseId': body['caseId'],
                    'recipientId': body['recipientId'] ?? body['invitationId'],
                    'grantorId': 'fictional-owner',
                    'role': body['role'],
                    'scope': body['scope'],
                    'permissionRevision': 1,
                    'state': 'pending',
                    'expiresAt': body['expiresAt'],
                    'invitationExpiresAt': '2026-10-31T00:00:00.000Z',
                  },
                });
              default:
                throw StateError('Unexpected request');
            }
          }),
        );
        await app.coordinator.createDraft();
        await app.coordinator.updateDraft(
          CaseDraft.fromJson({
            ...app.coordinator.draft!.toJson(),
            'findings': [
              {
                'id': 'selected',
                'room': 'bathroom',
                'observation': 'Selected observation',
                'reviewState': 'confirmed',
                'measurements': [],
                'evidenceIds': [],
              },
              {
                'id': 'excluded',
                'room': 'entrance',
                'observation': 'Excluded observation',
                'reviewState': 'needs_review',
                'measurements': [],
                'evidenceIds': [],
              },
            ],
          }),
        );
        await app.coordinator.save();
        await _mount(tester, app, PeopleWithAccessScreen(services: app));
        expect(find.text('Only you can see this plan.'), findsOneWidget);
        expect(find.byType(TextField), findsNothing, reason: 'list only');
        await tester.scrollUntilVisible(
          find.byKey(const ValueKey('invite-someone')),
          250,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.tap(find.byKey(const ValueKey('invite-someone')));
        await tester.pumpAndSettle();
        expect(find.text('Step 1 of 3 · Who'), findsOneWidget);
        await tester.enterText(
          find.byType(TextField).first,
          emailInvites
              ? 'helper@fictional.example'
              : '22222222-2222-4222-8222-222222222222',
        );
        expect(
          find.text('Who is this for? (optional)'),
          emailInvites ? findsNothing : findsOneWidget,
          reason: 'label fields only with the labels flag',
        );
        expect(find.byType(TextField), findsNWidgets(emailInvites ? 1 : 3));
        if (!emailInvites) {
          await tester.enterText(
            find.byType(TextField).at(1),
            '  Fictional neighbor Ana  ',
          );
          await tester.enterText(find.byType(TextField).at(2), 'Fictional Sam');
        }
        tester.testTextInput.hide();
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('Next'));
        await tester.tap(find.text('Next'));
        await tester.pumpAndSettle();
        expect(find.text('Step 2 of 3 · What they can do'), findsOneWidget);
        await tester.scrollUntilVisible(
          find.text('Selected observation'),
          250,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.ensureVisible(find.text('Selected observation'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Selected observation'));
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(
          find.text('Next'),
          250,
          scrollable: find.byType(Scrollable).first,
        );
        expect(
          tester
              .getRect(
                find.text(
                  'Photos, PDFs, income, health answers, and downloads are not shared.',
                ),
              )
              .bottom,
          lessThanOrEqualTo(
            tester.getRect(find.text('Access expires')).top - 16,
          ),
          reason: 'The note must not overlap the floating expiry label.',
        );
        await tester.tap(find.text('Next'));
        await tester.pumpAndSettle();
        expect((selected!['scope'] as Map)['findingIds'], ['selected']);
        expect(created, isNull);
        expect(find.text('Selected observation'), findsOneWidget);
        expect(find.text('Excluded observation'), findsNothing);
        expect(find.textContaining('revision'), findsNothing);
        if (!emailInvites) {
          expect(find.text('Fictional neighbor Ana'), findsOneWidget);
        }
        await tester.scrollUntilVisible(
          find.text('Create invitation'),
          250,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.tap(find.text('Create invitation'));
        await tester.pumpAndSettle();
        final link = 'https://example.org/invite#code=${'a' * 43}';
        if (emailInvites) {
          expect(created!['recipientEmail'], 'helper@fictional.example');
          expect(created!.containsKey('recipientId'), false);
          expect(created!.containsKey('recipientLabel'), false);
          expect(created!.containsKey('ownerLabel'), false);
          await tester.scrollUntilVisible(
            find.text('Copy invitation link'),
            250,
            scrollable: find.byType(Scrollable).first,
          );
          await tester.tap(find.text('Copy invitation link'));
          await tester.pumpAndSettle();
          expect(clipboard, link);
        } else {
          expect(
            created!['recipientId'],
            '22222222-2222-4222-8222-222222222222',
          );
          expect(created!['recipientLabel'], 'Fictional neighbor Ana');
          expect(created!['ownerLabel'], 'Fictional Sam');
        }
        await tester.ensureVisible(
          find.byKey(const ValueKey('invitation-share')),
        );
        await tester.tap(find.byKey(const ValueKey('invitation-share')));
        await tester.pumpAndSettle();
        expect(shared, emailInvites ? link : 'a' * 43);
        expect((created!['scope'] as Map)['findingIds'], ['selected']);
        expect((created!['scope'] as Map)['allowHelperNotes'], false);
        expect(
          created!['expiresAt'],
          matches(RegExp(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$')),
          reason: 'The HTTP contract requires millisecond UTC precision.',
        );
        expect(find.byKey(const ValueKey('invitation-code')), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets(
    'owner-typed labels name people and plans; neutral fallbacks without labels or IDs',
    (tester) async {
      final fixtures =
          (jsonDecode(
                    File(
                      'contracts/v3/fixtures/sharing-labels.json',
                    ).readAsStringSync(),
                  )
                  as List)
              .cast<Map<String, Object?>>();
      Map<String, Object?> response(String route) =>
          fixtures.firstWhere((f) => f['route'] == route)['response']!
              as Map<String, Object?>;
      final bodies = <String, Map>{};
      Map<String, Object?>? snapshot;
      final app = _ownerServices(
        true,
        MemoryPrivateStore(),
        labels: true,
        FakeTransport((request) async {
          final path = request.endpoint.path,
              body = jsonDecode(utf8.decode(request.body)) as Map;
          bodies[path] = body;
          if (path == '/v1/create-case') {
            snapshot = {...body, 'revision': 1};
            return http.jsonResponse(snapshot);
          }
          if (path == '/v3/list-email-sharing') {
            final labelled = Map<String, Object?>.from(
              (response('list-sharing')['shares']! as List).single as Map,
            )..['caseId'] = snapshot!['caseId'];
            final unlabelled = Map<String, Object?>.from(labelled)
              ..remove('recipientLabel')
              ..['membershipId'] = '55555555-5555-4555-8555-555555555555'
              ..['projection'] = null;
            return http.jsonResponse({
              'schemaVersion': '3',
              'availableProgramIds': [],
              'shares': [
                {...labelled, 'invitedEmail': 'ana@fictional.example'},
                {...unlabelled, 'invitedEmail': null},
              ],
            });
          }
          if (path == '/v3/review-invitation') {
            return http.jsonResponse(response('review-invitation'));
          }
          final mine = response('list-shared-cases'),
              row = (mine['memberships']! as List).single as Map;
          return http.jsonResponse({
            ...mine,
            'memberships': [
              row,
              {...row, 'membershipId': '66666666-6666-4666-8666-666666666666'}
                ..remove('ownerLabel'),
            ],
          });
        }),
      );
      await app.coordinator.createDraft();
      await app.coordinator.save();
      await _mount(tester, app, PeopleWithAccessScreen(services: app));
      expect(bodies['/v3/list-email-sharing']!['includeLabels'], true);
      expect(find.text('Fictional neighbor Ana'), findsOneWidget);
      expect(find.text('ana@fictional.example'), findsOneWidget);
      expect(find.text('Someone you invited'), findsOneWidget);
      expect(find.textContaining('2222-4222'), findsNothing);
      await tester.pumpWidget(
        MaterialApp(home: SharedWithMeScreen(services: app)),
      );
      await tester.pumpAndSettle();
      expect(bodies['/v3/list-shared-cases']!['includeLabels'], true);
      expect(find.text('Shared by Fictional Sam'), findsOneWidget);
      expect(find.text('Plan shared with you'), findsOneWidget);
      expect(find.textContaining('neighbor Ana'), findsNothing);
      await tester.enterText(
        find.byType(TextField),
        List.filled(43, 'a').join(),
      );
      await tester.tap(find.text('Review invitation'));
      await tester.pumpAndSettle();
      expect(bodies['/v3/review-invitation']!['includeLabels'], true);
      expect(find.text('Invitation from Fictional Sam'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'labels flag off: no label requests or fields, neutral fallbacks, no IDs',
    (tester) async {
      final bodies = <String, Map>{};
      final view = _view(),
          member = view['membership']! as Map<String, Object?>;
      final app = _ownerServices(
        false,
        MemoryPrivateStore(),
        FakeTransport((request) async {
          final path = request.endpoint.path,
              body = jsonDecode(utf8.decode(request.body)) as Map;
          bodies[path] = body;
          if (path == '/v1/create-case') {
            return http.jsonResponse({...body, 'revision': 1});
          }
          if (path == '/v3/list-sharing') {
            return http.jsonResponse({
              'schemaVersion': '3',
              'availableProgramIds': [],
              'shares': [
                {
                  ...member,
                  'caseId': body['caseId'],
                  'projection': null,
                  'notes': [],
                  'audit': [],
                },
              ],
            });
          }
          return http.jsonResponse({
            'schemaVersion': '3',
            'memberships': [member],
          });
        }),
      );
      await app.coordinator.createDraft();
      await app.coordinator.save();
      await _mount(tester, app, PeopleWithAccessScreen(services: app));
      expect(find.text('Someone you invited'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('invite-someone')));
      await tester.pumpAndSettle();
      expect(find.text('Who is this for? (optional)'), findsNothing);
      expect(find.byType(TextField), findsOneWidget);
      await tester.pumpWidget(
        MaterialApp(
          key: UniqueKey(),
          home: SharedWithMeScreen(services: app),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Plan shared with you'), findsOneWidget);
      expect(find.textContaining('Shared by'), findsNothing);
      for (final body in bodies.values) {
        for (final key in ['includeLabels', 'recipientLabel', 'ownerLabel']) {
          expect(body.containsKey(key), isFalse);
        }
      }
      expect(
        bodies.keys,
        containsAll(['/v3/list-sharing', '/v3/list-shared-cases']),
      );
      expect(
        find.textContaining(member['recipientId']! as String),
        findsNothing,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );
}
