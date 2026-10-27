import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/shared/models/case_draft.dart';
import 'package:safe_at_home/shared/services/sharing_api_client.dart';
import 'package:safe_at_home/shared/services/io_matching_transport.dart';
import '../../case_discovery_api_client_test.dart' show failure;

class _SensitiveLoopback extends HttpOverrides {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'Dart → real HTTP → restricted PostgreSQL selected helper data, report, digest and revocation',
    () => HttpOverrides.runWithHttpOverrides(() async {
      final process = await Process.start('node', [
        'test/support/sensitive-http-server.ts',
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
            other = client('other');
        final caseId = ready['caseId'] as String,
            membershipId = ready['membershipId'] as String;
        final base = <String, Object?>{
          'membershipId': membershipId,
          'expectedPermissionRevision': 2,
        };
        final options = await owner.sensitive(
          'list-sensitive-options',
          base,
          isCurrent: () => true,
          expectedCaseId: caseId,
        );
        await expectLater(
          helper.sensitive(
            'list-sensitive-options',
            base,
            isCurrent: () => true,
            expectedCaseId: caseId,
          ),
          throwsA(failure('SHARING_NOT_FOUND')),
        );
        final fields = {
          ...base,
          'expectedCaseRevision': options.caseRevision,
          'expectedCatalogRevision': options.catalogRevision,
          'selection': {
            'photoIds': [options.content!.photos.single.evidenceId],
            'measurementIds': [options.content!.measurements.single.id],
            'answerIds': options.content!.answers
                .where((a) => a.category != 'private')
                .map((a) => a.id)
                .toList(),
          },
          'allowPdf': true,
          'expiresAt': DateTime.fromMillisecondsSinceEpoch(
            DateTime.now().millisecondsSinceEpoch + 86400000,
            isUtc: true,
          ).toIso8601String(),
        };
        final preview = await owner.sensitive(
          'preview-sensitive-sharing',
          fields,
          isCurrent: () => true,
          expectedCaseId: caseId,
        );
        final pdf = await owner.sensitive(
          'preview-sensitive-report',
          {...fields, 'previewHash': preview.sourceHash},
          isCurrent: () => true,
          expectedCaseId: caseId,
        );
        expect(pdf.bytes!.length, greaterThan(100));
        expect(pdf.pageCount, greaterThan(0));
        final request = {
          ...fields,
          'previewHash': preview.sourceHash,
          'mutationId': newUuidV4(),
        };
        final saved = await owner.sensitive(
          'publish-sensitive-sharing',
          request,
          isCurrent: () => true,
          expectedCaseId: caseId,
        );
        expect(saved.permissionRevision, 3);
        expect(
          (await owner.sensitive(
            'publish-sensitive-sharing',
            request,
            isCurrent: () => true,
            expectedCaseId: caseId,
          )).acknowledgement,
          saved.acknowledgement,
        );
        base['expectedPermissionRevision'] = 3;
        final view = await helper.sensitive(
          'read-sensitive-sharing',
          base,
          isCurrent: () => true,
          expectedCaseId: caseId,
        );
        expect(
          view.content!.answers.map((a) => a.value),
          containsAll([false, 0, null]),
        );
        expect(
          view.content!.answers.any((a) => a.category == 'private'),
          false,
        );
        final photo = view.content!.photos.single;
        final bytes = await helper.sensitive(
          'read-sensitive-photo',
          {
            ...base,
            'sourceHash': view.sourceHash,
            'evidenceId': photo.evidenceId,
            'expectedEvidenceRevision': photo.evidenceRevision,
          },
          isCurrent: () => true,
          expectedCaseId: caseId,
        );
        expect(bytes.bytes!.length, photo.byteLength);
        await helper.sensitive(
          'read-sensitive-report',
          {...base, 'sourceHash': view.sourceHash},
          isCurrent: () => true,
          expectedCaseId: caseId,
        );
        await expectLater(
          other.sensitive(
            'read-sensitive-sharing',
            base,
            isCurrent: () => true,
            expectedCaseId: caseId,
          ),
          throwsA(failure('SHARING_NOT_FOUND')),
        );
        await owner.request('revoke-sharing', {
          'caseId': caseId,
          'invitationId': membershipId,
          'expectedPermissionRevision': 3,
        }, isCurrent: () => true);
        await expectLater(
          helper.sensitive(
            'read-sensitive-report',
            {...base, 'sourceHash': view.sourceHash},
            isCurrent: () => true,
            expectedCaseId: caseId,
          ),
          throwsA(failure('SHARING_NOT_FOUND')),
        );
      } finally {
        process.kill(ProcessSignal.sigterm);
        await process.exitCode.timeout(const Duration(seconds: 20));
        await errors.cancel();
      }
    }, _SensitiveLoopback()),
    timeout: const Timeout(Duration(seconds: 75)),
  );
}
