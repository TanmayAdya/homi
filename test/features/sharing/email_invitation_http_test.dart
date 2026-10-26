import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/shared/models/case_draft.dart';
import 'package:safe_at_home/shared/services/sharing_api_client.dart';
import 'package:safe_at_home/shared/services/io_matching_transport.dart';
import 'package:safe_at_home/shared/services/invitation_links.dart';
import '../../case_discovery_api_client_test.dart' show failure;

class _InvitationLoopback extends HttpOverrides {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'Dart email invitation and pasted HTTPS link traverse real HTTP and restricted PostgreSQL without a recipient UUID',
    () => HttpOverrides.runWithHttpOverrides(() async {
      final process = await Process.start('node', [
        'test/support/sensitive-http-server.ts',
        '--email-invitations',
      ], workingDirectory: Directory('backend').absolute.path);
      final errors = process.stderr.listen((_) {});
      try {
        final ready =
            jsonDecode(
                  await process.stdout
                      .transform(utf8.decoder)
                      .transform(const LineSplitter())
                      .first
                      .timeout(const Duration(seconds: 25)),
                )
                as Map;
        SharingApiClient client(String who) => SharingApiClient(
          baseUri: Uri.parse(ready['origin'] as String),
          tokenProvider: () async => 'fictional-$who-token',
          transport: IoMatchingTransport(),
          allowInsecureLoopback: true,
        );
        final owner = client('owner'),
            helper = client('helper'),
            other = client('other'),
            id = newUuidV4();
        final created = await owner.request('create-email-invitation', {
          'caseId': ready['caseId'],
          'expectedCaseRevision': 2,
          'invitationId': id,
          'recipientEmail': 'Helper@Fictional.Example',
          'role': 'helper',
          'scope': {
            'findingIds': ['fictional-finding'],
            'programIds': ['scfhp-eaa'],
            'allowHelperNotes': false,
          },
          'expiresAt': null,
        }, isCurrent: () => true);
        final origin = Uri.parse('https://fictional.example');
        final link = invitationLink(origin, created.invitationCode!);
        final code = readInvitationCode(link.toString(), origin)!;
        await expectLater(
          other.request('review-invitation', {
            'code': code,
          }, isCurrent: () => true),
          throwsA(failure('SHARING_NOT_FOUND')),
        );
        final preview = await helper.request('review-invitation', {
          'code': code,
        }, isCurrent: () => true);
        expect(preview.membership!.recipientId, ready['helper']);
        await expectLater(
          helper.request('read-shared-case', {
            'membershipId': id,
            'expectedPermissionRevision': 1,
          }, isCurrent: () => true),
          throwsA(failure('SHARING_NOT_FOUND')),
        );
        final accepted = await helper.request('accept-invitation', {
          'code': code,
          'expectedPermissionRevision': preview.membership!.revision,
        }, isCurrent: () => true);
        expect(accepted.membership!.revision, 2);
        final view = await helper.request('read-shared-case', {
          'membershipId': id,
          'expectedPermissionRevision': 2,
        }, isCurrent: () => true);
        expect(view.projection!.findings.single.id, 'fictional-finding');
        await expectLater(
          helper.request('accept-invitation', {
            'code': code,
            'expectedPermissionRevision': 1,
          }, isCurrent: () => true),
          throwsA(failure('SHARING_NOT_FOUND')),
        );
        await owner.request('revoke-sharing', {
          'caseId': ready['caseId'],
          'invitationId': id,
          'expectedPermissionRevision': 2,
        }, isCurrent: () => true);
        await expectLater(
          helper.request('read-shared-case', {
            'membershipId': id,
            'expectedPermissionRevision': 2,
          }, isCurrent: () => true),
          throwsA(failure('SHARING_NOT_FOUND')),
        );
      } finally {
        process.kill(ProcessSignal.sigterm);
        await process.exitCode.timeout(const Duration(seconds: 15));
        await errors.cancel();
      }
    }, _InvitationLoopback()),
    timeout: const Timeout(Duration(seconds: 75)),
  );
}
