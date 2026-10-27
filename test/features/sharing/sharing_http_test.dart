import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/shared/models/case_draft.dart';
import 'package:safe_at_home/shared/services/sharing_api_client.dart';
import 'package:safe_at_home/shared/services/io_matching_transport.dart';
import '../../case_discovery_api_client_test.dart' show failure;

class _LoopbackSharingHttp extends HttpOverrides {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'four-account Dart → HTTP → restricted PostgreSQL sharing journey',
    () => HttpOverrides.runWithHttpOverrides(() async {
      final process = await Process.start('node', [
        'test/support/sharing-http-server.ts',
      ], workingDirectory: Directory('backend').absolute.path);
      final errors = process.stderr.listen((_) {});
      try {
        final ready =
            jsonDecode(
                  await process.stdout
                      .transform(utf8.decoder)
                      .transform(const LineSplitter())
                      .first
                      .timeout(const Duration(seconds: 20)),
                )
                as Map;
        SharingApiClient client(String account) => SharingApiClient(
          baseUri: Uri.parse(ready['origin'] as String),
          tokenProvider: () async => 'fictional-$account-token',
          transport: IoMatchingTransport(),
          allowInsecureLoopback: true,
        );
        final owner = client('owner'),
            viewer = client('viewer'),
            helper = client('helper'),
            other = client('other');
        final caseId = ready['caseId'] as String;
        Map<String, Object?> scope(bool notes) => {
          'findingIds': ['fictional-finding'],
          'programIds': [ready['programId']],
          'allowHelperNotes': notes,
        };
        Future<dynamic> invite(String role, String recipient, bool notes) =>
            owner.request('create-invitation', {
              'caseId': caseId,
              'expectedCaseRevision': ready['revision'],
              'invitationId': newUuidV4(),
              'recipientId': recipient,
              'role': role,
              'scope': scope(notes),
              'expiresAt': null,
            }, isCurrent: () => true);
        final v = await invite('viewer', ready['viewer'] as String, false),
            h = await invite('helper', ready['helper'] as String, true);
        expect(v.invitationCode, isNotNull);
        await expectLater(
          other.request('review-invitation', {
            'code': v.invitationCode,
          }, isCurrent: () => true),
          throwsA(failure('SHARING_NOT_FOUND')),
        );
        final reviewed = await viewer.request('review-invitation', {
          'code': v.invitationCode,
        }, isCurrent: () => true);
        final accepted = await viewer.request('accept-invitation', {
          'code': v.invitationCode,
          'expectedPermissionRevision': reviewed.membership!.revision,
        }, isCurrent: () => true);
        final helperGrant = await helper.request('accept-invitation', {
          'code': h.invitationCode,
          'expectedPermissionRevision': 1,
        }, isCurrent: () => true);
        final binding = {
          'membershipId': accepted.membership!.id,
          'expectedPermissionRevision': 2,
        };
        final view = await viewer.request(
          'read-shared-case',
          binding,
          isCurrent: () => true,
        );
        expect(view.projection!.findings.single.id, 'fictional-finding');
        expect(view.projection!.programs.single.id, ready['programId']);
        final note = {
          'membershipId': helperGrant.membership!.id,
          'expectedPermissionRevision': 2,
          'mutationId': newUuidV4(),
          'note': 'Fictional family progress',
        };
        final saved = await helper.request(
          'add-shared-note',
          note,
          isCurrent: () => true,
        );
        expect(saved.notes.single.text, note['note']);
        await expectLater(
          viewer.request('add-shared-note', {
            ...binding,
            'mutationId': newUuidV4(),
            'note': 'Denied',
          }, isCurrent: () => true),
          throwsA(failure('SHARING_NOT_FOUND')),
        );

        final helperId = helperGrant.membership!.id,
            viewerId = accepted.membership!.id;
        final configured = await owner.request('configure-collaboration', {
          'membershipId': helperId,
          'expectedPermissionRevision': 2,
          'expectedCaseRevision': 1,
          'expectedProgressRevision': 2,
          'expectedCollaborationRevision': 0,
          'mutationId': newUuidV4(),
          'collaborationScope': {
            'taskIds': ['fictional-http-task'],
            'allowTaskProgress': true,
            'allowStatusProposals': true,
          },
          'assignedTaskIds': ['fictional-http-task'],
        }, isCurrent: () => true);
        expect(
          configured.collaboration!.tasks.single.assigneeUserId,
          ready['helper'],
        );
        await owner.request('configure-collaboration', {
          'membershipId': viewerId,
          'expectedPermissionRevision': 2,
          'expectedCaseRevision': 1,
          'expectedProgressRevision': 2,
          'expectedCollaborationRevision': 1,
          'mutationId': newUuidV4(),
          'collaborationScope': {
            'taskIds': ['fictional-http-task'],
            'allowTaskProgress': false,
            'allowStatusProposals': false,
          },
          'assignedTaskIds': [],
        }, isCurrent: () => true);
        binding['expectedPermissionRevision'] = 3;
        final taskRequest = {
          'membershipId': helperId,
          'expectedPermissionRevision': 3,
          'expectedCaseRevision': 1,
          'expectedCollaborationRevision': 2,
          'mutationId': newUuidV4(),
          'taskId': 'fictional-http-task',
          'expectedTaskRevision': 1,
          'state': 'completed',
        };
        await expectLater(
          viewer.request('update-shared-task', {
            ...taskRequest,
            'membershipId': viewerId,
          }, isCurrent: () => true),
          throwsA(failure('SHARING_NOT_FOUND')),
        );
        final completed = await helper.request(
          'update-shared-task',
          taskRequest,
          isCurrent: () => true,
        );
        expect(completed.collaboration!.tasks.single.state, 'completed');
        final proposalId = newUuidV4();
        final proposed = await helper.request('propose-shared-status', {
          'membershipId': helperId,
          'expectedPermissionRevision': 3,
          'expectedCaseRevision': 1,
          'expectedCollaborationRevision': 3,
          'mutationId': proposalId,
          'programId': ready['programId'],
          'update': {
            'updateId': newUuidV4(),
            'status': 'submitted',
            'occurredOn': DateTime.now().toUtc().toIso8601String().substring(
              0,
              10,
            ),
            'source': 'self_report',
            'note': 'Fictional proposal only',
            'nextAction': null,
            'responsibleParty': null,
            'followUpOn': null,
          },
        }, isCurrent: () => true);
        expect(proposed.collaboration!.progressRevision, 3);
        expect(proposed.collaboration!.proposals.single.state, 'pending');
        final reviewedStatus = await owner.request('review-shared-status', {
          'membershipId': helperId,
          'expectedPermissionRevision': 3,
          'expectedCaseRevision': 1,
          'expectedCollaborationRevision': 4,
          'expectedProgressRevision': 3,
          'mutationId': newUuidV4(),
          'proposalId': proposalId,
          'decision': 'accepted',
        }, isCurrent: () => true);
        expect(reviewedStatus.collaboration!.progressRevision, 4);
        expect(
          reviewedStatus.collaboration!.proposals.single.reviewedBy,
          'fictional-alice',
        );
        expect(
          reviewedStatus.collaboration!.proposals.single.proposedBy,
          ready['helper'],
        );
        await owner.request('revoke-sharing', {
          'caseId': caseId,
          'invitationId': accepted.membership!.id,
          'expectedPermissionRevision': 3,
        }, isCurrent: () => true);
        await expectLater(
          viewer.request('read-shared-case', binding, isCurrent: () => true),
          throwsA(failure('SHARING_NOT_FOUND')),
        );
        final remaining = await viewer.request(
          'list-shared-cases',
          {},
          isCurrent: () => true,
        );
        expect(remaining.memberships, isEmpty);
        final stillActive = await helper.request(
          'list-shared-cases',
          {},
          isCurrent: () => true,
        );
        expect(stillActive.memberships.single.id, helperGrant.membership!.id);
      } finally {
        process.kill(ProcessSignal.sigterm);
        await process.exitCode.timeout(const Duration(seconds: 20));
        await errors.cancel();
      }
    }, _LoopbackSharingHttp()),
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
