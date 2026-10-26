import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/features/assessment/domain/scan/bathroom_scan_review.dart';
import 'package:safe_at_home/shared/services/scan_model_api_client.dart';
import 'package:safe_at_home/shared/services/io_matching_transport.dart';
import 'package:safe_at_home/shared/services/matching_api_client.dart';
import 'package:safe_at_home/shared/models/case_draft.dart';
import 'scan_model_sync_test.dart' show scanSyncFixtures;

class _LoopbackHttp extends HttpOverrides {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'real Dart-to-HTTP model upload survives a second phone, preserves large native geometry and denies foreign owners',
    () => HttpOverrides.runWithHttpOverrides(() async {
      final process = await Process.start('node', [
        'src/api/demo-server.ts',
        '--fixtures',
        File('contracts/v1/fixtures/scenarios.json').absolute.path,
        '--port',
        '0',
        '--machine',
      ], workingDirectory: Directory('backend').absolute.path);
      final errors = process.stderr.listen((_) {});
      try {
        final ready =
            jsonDecode(
                  await process.stdout
                      .transform(utf8.decoder)
                      .transform(const LineSplitter())
                      .first
                      .timeout(const Duration(seconds: 15)),
                )
                as Map;
        final caseId =
            ((ready['caseIds'] as Map)['alice'] as List).first as String;
        ScanModelApiClient client(String token) => ScanModelApiClient(
          baseUri: Uri.parse(ready['endpoint'] as String).resolve('/'),
          tokenProvider: () async => token,
          transport: IoMatchingTransport(),
          allowInsecureLoopback: true,
        );
        final first = client(ready['alice'] as String),
            second = client(ready['alice'] as String),
            foreign = client(ready['bob'] as String);
        final raw = Map<String, Object?>.from(
          jsonDecode(scanSyncFixtures[0]['request']['reviewJson'] as String)
              as Map,
        )..['caseId'] = caseId;
        final scene = Map<String, Object?>.from(raw['scene'] as Map)
          ..['points'] = List.generate(4096, (i) => [0.123, 0.234, 0.345, 0.5]);
        raw['scene'] = scene;
        final review = BathroomScanReview.fromJson(raw, caseId),
            encoded = jsonEncode(review.toJson(caseId));
        final request = <String, Object?>{
          'schemaVersion': '3',
          'caseId': caseId,
          'roomId': null,
          'expectedCaseRevision': 1,
          'expectedModelRevision': 0,
          'mutationId': newUuidV4(),
          'reviewJson': encoded,
        };
        expect(utf8.encode(jsonEncode(request)).length, greaterThan(16384));
        final saved = await first.save(request, isCurrent: () => true);
        expect(saved.modelRevision, 1);
        expect(saved.reviewJson, encoded);
        final restored = await second.read(caseId, isCurrent: () => true);
        expect(restored.review!.scene!.fingerprint, review.scene!.fingerprint);
        expect(restored.review!.scene!.points.length, 4096);
        final retry = await second.save(request, isCurrent: () => true);
        expect(retry.modelRevision, 1);
        await expectLater(
          foreign.read(caseId, isCurrent: () => true),
          throwsA(
            isA<MatchingApiException>().having(
              (e) => e.code,
              'code',
              'CASE_NOT_FOUND',
            ),
          ),
        );
        final removed = await first.save({
          ...request,
          'expectedModelRevision': 1,
          'mutationId': newUuidV4(),
          'reviewJson': null,
        }, isCurrent: () => true);
        expect(removed.review, isNull);
        final replay = await second.save(request, isCurrent: () => true);
        expect(replay.review, isNull);
        expect(replay.modelRevision, 2);
      } finally {
        process.kill();
        await process.exitCode;
        await errors.cancel();
      }
    }, _LoopbackHttp()),
  );
}
