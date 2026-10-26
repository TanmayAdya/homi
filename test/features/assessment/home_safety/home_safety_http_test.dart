import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/features/assessment/domain/home_safety/home_safety.dart';
import 'package:safe_at_home/shared/services/home_safety_api_client.dart';
import 'package:safe_at_home/shared/services/io_matching_transport.dart';
import 'package:safe_at_home/shared/services/matching_api_client.dart';
import 'package:safe_at_home/shared/services/progress_api_client.dart';

class _LoopbackHttp extends HttpOverrides {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'real Dart client and Node HTTP server agree on rooms, polarity, receipts and ownership',
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
        final origin = Uri.parse(ready['endpoint'] as String).resolve('/'),
            catalog = await HomeSafetyCatalog.load();
        final api = HomeSafetyApiClient(
          baseUri: origin,
          tokenProvider: () async => ready['alice'] as String,
          transport: IoMatchingTransport(),
          catalog: catalog,
          allowInsecureLoopback: true,
        );
        final caseId =
            ((ready['caseIds'] as Map)['alice'] as List).first as String;
        var state = await api.read(caseId, isCurrent: () => true);
        SafetyMutation request(Map<String, Object?> operation) =>
            SafetyMutation.fromJson({
              'schemaVersion': '3',
              'caseId': caseId,
              'expectedCaseRevision': state.snapshot.revision,
              'expectedSafetyRevision': state.revision,
              'mutationId': 'fictional-http-${state.revision}',
              'operation': operation,
            }, catalog);
        final initialCaseRevision = state.snapshot.revision;
        final add = request({
          'type': 'add_room',
          'room': {
            'id': 'fictional-http-room',
            'type': 'stairs',
            'name': 'Fictional back stairs',
          },
        });
        state = await api.save(add, isCurrent: () => true);
        state = await api.save(
          request({
            'type': 'answer',
            'roomId': 'fictional-http-room',
            'questionId': 'stairs.lighting',
            'value': 'no',
          }),
          isCurrent: () => true,
        );
        expect(state.snapshot.revision, initialCaseRevision);
        expect(state.document.answers.single.value, 'no');
        state = await api.save(
          request({
            'type': 'review_concern',
            'roomId': 'fictional-http-room',
            'questionId': 'stairs.lighting',
            'findingId': 'fictional-http-finding',
            'observation': 'Fictional resident reports missing stair lighting.',
            'state': 'confirmed',
          }),
          isCurrent: () => true,
        );
        expect(state.snapshot.revision, initialCaseRevision + 1);
        expect(
          state.document.findingRooms.single.findingId,
          'fictional-http-finding',
        );
        final retry = await api.save(add, isCurrent: () => true);
        expect(retry.revision, 3);
        expect(retry.acknowledges(add), true);
        final progress = ProgressApiClient(
          baseUri: origin,
          tokenProvider: () async => ready['alice'] as String,
          transport: IoMatchingTransport(),
          allowInsecureLoopback: true,
        );
        var tasks = await progress.read(caseId, isCurrent: () => true);
        final taskRequest = <String, Object?>{
          'schemaVersion': '3',
          'caseId': caseId,
          'expectedCaseRevision': state.snapshot.revision,
          'expectedProgressRevision': tasks.revision,
          'mutationId': 'fictional-checklist-task',
          'operation': {
            'type': 'put_task',
            'expectedTaskRevision': 0,
            'task': {
              'id': 'fictional-checklist-task',
              'programId': null,
              'findingId': 'fictional-http-finding',
              'formId': null,
              'title': 'Fictional review of stair lighting',
              'kind': 'room_review',
              'state': 'completed',
              'responsiblePerson': null,
              'dueOn': null,
              'basedOnCaseRevision': state.snapshot.revision,
              'basedOnRuleVersion': null,
              'revision': 1,
              'sourceEventId': null,
            },
          },
        };
        tasks = await progress.save(taskRequest, isCurrent: () => true);
        await progress.save(taskRequest, isCurrent: () => true);
        expect(
          tasks.tasks
              .where((t) => t.data['findingId'] == 'fictional-http-finding')
              .length,
          1,
        );
        state = await api.read(caseId, isCurrent: () => true);
        final link = state.document.findingRooms.single;
        Iterable<Map<String, Object?>> operations() => state.history.map(
          (e) => Map<String, Object?>.from(e['operation'] as Map),
        );
        expect(
          concernIsAddressed(
            state.document,
            state.snapshot,
            link,
            operations(),
          ),
          false,
        );
        final addressed = request({
          'type': 'set_addressed',
          'roomId': link.roomId,
          'findingId': link.findingId,
          'findingFingerprint': safetyHash(
            state.snapshot.findings
                .firstWhere((f) => f.id == link.findingId)
                .toJson(),
          ),
          'answerRevision': 1,
          'addressed': true,
        });
        state = await api.save(addressed, isCurrent: () => true);
        state = await api.save(addressed, isCurrent: () => true);
        expect(state.snapshot.revision, initialCaseRevision + 1);
        expect(
          concernIsAddressed(
            state.document,
            state.snapshot,
            link,
            operations(),
          ),
          true,
        );
        state = await api.read(caseId, isCurrent: () => true);
        expect(
          concernIsAddressed(
            state.document,
            state.snapshot,
            link,
            operations(),
          ),
          true,
        );
        state = await api.save(
          request({
            'type': 'annotate_answer',
            'roomId': 'fictional-http-room',
            'questionId': 'stairs.lighting',
            'answerRevision': 1,
            'note': 'Fictional report note',
            'evidence': <Object>[],
            'expectedCatalogRevision': 0,
          }),
          isCurrent: () => true,
        );
        final exported = await api.exportReport(
          state,
          state.evidenceCatalogRevision ?? 0,
          includeNotes: true,
          includeEvidenceReferences: false,
          isCurrent: () => true,
        );
        expect(ascii.decode(exported.bytes.take(5).toList()), '%PDF-');
        expect(exported.safetyRevision, state.revision);
        final other = HomeSafetyApiClient(
          baseUri: origin,
          tokenProvider: () async => ready['bob'] as String,
          transport: IoMatchingTransport(),
          catalog: catalog,
          allowInsecureLoopback: true,
        );
        await expectLater(
          other.exportReport(
            state,
            state.evidenceCatalogRevision ?? 0,
            includeNotes: false,
            includeEvidenceReferences: false,
            isCurrent: () => true,
          ),
          throwsA(
            isA<MatchingApiException>().having(
              (e) => e.code,
              'code',
              'CASE_NOT_FOUND',
            ),
          ),
        );
        await expectLater(
          other.read(caseId, isCurrent: () => true),
          throwsA(
            isA<MatchingApiException>().having(
              (e) => e.code,
              'code',
              'CASE_NOT_FOUND',
            ),
          ),
        );
      } finally {
        process.kill(ProcessSignal.sigterm);
        await process.exitCode.timeout(
          const Duration(seconds: 15),
          onTimeout: () {
            process.kill(ProcessSignal.sigkill);
            return -1;
          },
        );
        await errors.cancel();
      }
    }, _LoopbackHttp()),
  );
}
