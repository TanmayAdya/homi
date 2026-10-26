import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/app/live_app.dart';
import 'package:safe_at_home/features/sharing/sharing_screens.dart';
import 'package:safe_at_home/shared/models/sharing.dart';
import 'package:safe_at_home/shared/services/matching_api_client.dart';
import '../../app/case_coordinator_test.dart' show FakeSession, FakeTransport;
import '../../app/live_workflows_test.dart' show MemoryPrivateStore;
import '../../services/case_evidence_api_client_test.dart' as http;
import 'collaboration_contract_test.dart' show collaborationFixture;
import 'sharing_contract_test.dart' show sharedFixture;

const helper = '33333333-3333-4333-8333-333333333333';

class _HelperStore extends MemoryPrivateStore {
  @override
  String get accountId => helper;
}

AppServices _app(
  FakeTransport transport, {
  bool owner = false,
  bool labels = false,
}) => AppServices(
  config: LiveAppConfig(
    apiOrigin: Uri.parse('https://fictional.example'),
    supabaseUrl: Uri.parse('https://fictional.supabase.co'),
    publishableKey: 'fictional',
    permissionSharingEnabled: true,
    sharingLabelsEnabled: labels,
  ),
  session: FakeSession()..owner = owner ? 'fictional-owner' : helper,
  store: owner ? MemoryPrivateStore() : _HelperStore(),
  transport: transport,
);
Map<String, Object?> _membership({bool viewer = false}) {
  final original = Map<String, Object?>.from(
    sharedFixture()['membership']! as Map,
  );
  return {
    ...original,
    'permissionRevision': 3,
    'recipientId': helper,
    if (viewer) 'role': 'viewer',
    if (viewer)
      'scope': {...(original['scope'] as Map), 'allowHelperNotes': false},
  };
}

Future<void> _mount(
  WidgetTester tester,
  AppServices app, {
  bool owner = false,
  bool viewer = false,
}) async {
  addTearDown(() {
    app.dispose();
    app.session.dispose();
  });
  await tester.pumpWidget(
    MaterialApp(
      home: CollaborationScreen(
        services: app,
        membership: CaseMembership.fromJson(_membership(viewer: viewer)),
        ownerView: owner,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Map<String, Object?> _meta(bool owner, {bool viewer = false}) => owner
    ? {
        'schemaVersion': '3',
        'availableProgramIds': ['fictional-program'],
        'shares': [
          {
            ..._membership(viewer: viewer),
            'projection': sharedFixture()['projection'],
            'notes': [],
            'audit': [],
          },
        ],
      }
    : {
        'schemaVersion': '3',
        'memberships': [_membership(viewer: viewer)],
      };
Future<void> _tap(WidgetTester tester, String text) async {
  await tester.scrollUntilVisible(
    find.text(text),
    180,
    scrollable: find.byType(Scrollable).first,
    maxScrolls: 40,
  );
  await tester.ensureVisible(find.text(text));
  await tester.pumpAndSettle();
  await tester.tap(find.text(text));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('viewer reads selected task details without helper controls', (
    tester,
  ) async {
    final response = {
      ...collaborationFixture('read-collaboration'),
      'scope': {
        'taskIds': ['assigned-task'],
        'allowTaskProgress': false,
        'allowStatusProposals': false,
      },
    };
    final app = _app(
      FakeTransport(
        (request) async => http.jsonResponse(
          request.endpoint.path.endsWith('read-collaboration')
              ? response
              : _meta(false, viewer: true),
        ),
      ),
    );
    await _mount(tester, app, viewer: true);
    expect(find.text('Fictional selected task'), findsOneWidget);
    expect(find.text('Task progress'), findsNothing);
    expect(find.text('Send for owner review'), findsNothing);
    expect((app.store as MemoryPrivateStore).records, isEmpty);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
    'helper task update binds task and permission revisions, and uncertain retry uses the same mutation',
    (tester) async {
      var writes = 0;
      final saved = <Map<String, Object?>>[];
      final app = _app(
        FakeTransport((request) async {
          if (request.endpoint.path.endsWith('list-shared-cases')) {
            return http.jsonResponse(_meta(false));
          }
          if (request.endpoint.path.endsWith('update-shared-task')) {
            final body = Map<String, Object?>.from(
              jsonDecode(utf8.decode(request.body)) as Map,
            );
            saved.add(body);
            writes++;
            if (writes == 1) {
              throw const MatchingTransportException(
                MatchingTransportFailure.network,
              );
            }
            return http.jsonResponse({
              ...collaborationFixture('update-shared-task'),
              'acknowledgedMutationId': body['mutationId'],
            });
          }
          return http.jsonResponse(collaborationFixture('read-collaboration'));
        }),
      );
      await _mount(tester, app);
      final dropdown = find.byKey(
        const ValueKey('shared-task-assigned-task-1'),
      );
      await tester.ensureVisible(dropdown);
      await tester.tap(dropdown);
      await tester.pumpAndSettle();
      await tester.tap(find.text('completed').last);
      await tester.pumpAndSettle();
      expect(writes, 1);
      expect(find.text('Retry same change'), findsOneWidget);
      expect(find.text('Fictional selected task'), findsNothing);
      await _tap(tester, 'Retry same change');
      expect(writes, 2);
      expect(saved[1], saved[0]);
      expect(saved[0]['expectedTaskRevision'], 1);
      expect(saved[0]['expectedPermissionRevision'], 3);
      expect(saved[0].containsKey('title'), isFalse);
      await tester.scrollUntilVisible(
        find.text(
          'Completing a task does not report a repair, a safe home, agency receipt, or approval.',
        ),
        180,
        scrollable: find.byType(Scrollable).first,
        maxScrolls: 40,
      );
      expect(
        find.text(
          'Completing a task does not report a repair, a safe home, agency receipt, or approval.',
        ),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'owner previews selected tasks before enabling account assignment',
    (tester) async {
      Map<String, Object?>? written;
      final app = _app(
        FakeTransport((request) async {
          if (request.endpoint.path.endsWith('list-sharing')) {
            return http.jsonResponse(_meta(true));
          }
          if (request.endpoint.path.endsWith('configure-collaboration')) {
            written = Map<String, Object?>.from(
              jsonDecode(utf8.decode(request.body)) as Map,
            );
            return http.jsonResponse({
              ...collaborationFixture('configure-collaboration'),
              'permissionRevision': 4,
              'acknowledgedMutationId': written!['mutationId'],
            });
          }
          return http.jsonResponse({
            ...collaborationFixture('read-collaboration'),
            'canManage': true,
          });
        }),
        owner: true,
      );
      await _mount(tester, app, owner: true);
      expect(find.text('Save task access'), findsNothing);
      await _tap(tester, 'Preview task access');
      expect(written, isNull);
      await _tap(tester, 'Save task access');
      expect(written!['assignedTaskIds'], ['assigned-task']);
      expect(
        (written!['collaborationScope'] as Map)['allowTaskProgress'],
        true,
      );
      expect(written!['expectedProgressRevision'], 2);
      expect(written!.containsKey('assigneeUserId'), isFalse);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'only the owner has accept/reject actions and proposal history identifies both people',
    (tester) async {
      final pending = collaborationFixture('propose-shared-status');
      Map<String, Object?>? reviewed;
      final app = _app(
        FakeTransport((request) async {
          if (request.endpoint.path.endsWith('list-sharing')) {
            return http.jsonResponse(_meta(true));
          }
          if (request.endpoint.path.endsWith('review-shared-status')) {
            reviewed = Map<String, Object?>.from(
              jsonDecode(utf8.decode(request.body)) as Map,
            );
            return http.jsonResponse({
              ...collaborationFixture('review-shared-status'),
              'acknowledgedMutationId': reviewed!['mutationId'],
            });
          }
          return http.jsonResponse({...pending, 'canManage': true});
        }),
        owner: true,
      );
      await _mount(tester, app, owner: true);
      await _tap(tester, 'Accept reported status');
      expect(reviewed!['decision'], 'accepted');
      expect(find.textContaining('Reviewed by You'), findsOneWidget);
      expect(
        find.textContaining('Proposed by The person you shared with'),
        findsOneWidget,
      );
      expect(find.textContaining(helper), findsNothing);
      expect(find.textContaining('fictional-owner'), findsNothing);
      expect(find.text('Accept reported status'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );
  for (final owner in [true, false]) {
    testWidgets(
      'owner-typed labels name both people; absent labels and IDs never show (owner: $owner)',
      (tester) async {
        final meta = _meta(owner);
        final row = Map<String, Object?>.from(
          ((meta[owner ? 'shares' : 'memberships']! as List).single as Map),
        );
        row['ownerLabel'] = 'Fictional Sam';
        if (owner) row['recipientLabel'] = 'Fictional neighbor Ana';
        final app = _app(
          FakeTransport(
            (request) async => http.jsonResponse(
              request.endpoint.path.endsWith('read-collaboration')
                  ? {
                      ...collaborationFixture('read-collaboration'),
                      'canManage': owner,
                      'proposals': collaborationFixture(
                        'review-shared-status',
                      )['proposals'],
                    }
                  : {
                      ...meta,
                      owner ? 'shares' : 'memberships': [row],
                    },
            ),
          ),
          owner: owner,
          labels: true,
        );
        await _mount(tester, app, owner: owner);
        await tester.scrollUntilVisible(
          find.textContaining('Reviewed by'),
          180,
          scrollable: find.byType(Scrollable).first,
          maxScrolls: 40,
        );
        expect(
          find.textContaining(
            owner ? 'Proposed by Fictional neighbor Ana' : 'Proposed by You',
          ),
          findsOneWidget,
        );
        expect(
          find.textContaining(
            owner ? 'Reviewed by You' : 'Reviewed by Fictional Sam',
          ),
          findsOneWidget,
        );
        expect(find.textContaining(helper), findsNothing);
        expect(find.textContaining('fictional-owner'), findsNothing);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
  testWidgets('helper sees the assignee as You, never an account ID', (
    tester,
  ) async {
    final app = _app(
      FakeTransport(
        (request) async => http.jsonResponse(
          request.endpoint.path.endsWith('read-collaboration')
              ? collaborationFixture('read-collaboration')
              : _meta(false),
        ),
      ),
    );
    await _mount(tester, app);
    expect(find.text('Assigned to You'), findsOneWidget);
    expect(find.textContaining(helper), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
}
