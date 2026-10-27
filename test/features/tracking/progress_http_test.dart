import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/features/tracking/progress_service.dart';
import 'package:safe_at_home/features/tracking/device_reminders.dart';
import 'package:safe_at_home/shared/models/case_draft.dart';
import 'package:safe_at_home/shared/services/progress_api_client.dart';
import 'package:safe_at_home/shared/services/io_matching_transport.dart';
import 'package:safe_at_home/shared/services/matching_api_client.dart';
import '../../app/live_workflows_test.dart' show MemoryPrivateStore;
import 'device_reminders_test.dart' show FakeNotificationDevice;

class _LoopbackHttp extends HttpOverrides {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'real HTTP service save journal retries once, tasks survive restart and foreign accounts are denied',
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
      ProgressService? service, restarted;
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
            caseId =
                ((ready['caseIds'] as Map)['alice'] as List).first as String;
        final store = MemoryPrivateStore(), device = FakeNotificationDevice();
        ProgressApiClient api(String token) => ProgressApiClient(
          baseUri: origin,
          tokenProvider: () async => token,
          transport: IoMatchingTransport(),
          allowInsecureLoopback: true,
        );
        ProgressService create() => ProgressService(
          api: api(ready['alice'] as String),
          store: store,
          isCurrent: () => true,
          reminders: DeviceReminders(
            store: store,
            device: device,
            isCurrent: () => true,
            body: () => 'You have a Safe at Home next step.',
            onTap: () {},
          ),
        );
        service = create();
        await service.initialize();
        var state = await service.refresh(caseId);
        final task = <String, Object?>{
          'id': newUuidV4(),
          'programId': null,
          'findingId': null,
          'formId': null,
          'title': 'Fictional agency follow-up',
          'kind': 'contact',
          'state': 'pending',
          'responsiblePerson': null,
          'dueOn': '2030-01-05',
          'basedOnCaseRevision': state.caseRevision,
          'basedOnRuleVersion': null,
          'revision': 1,
          'sourceEventId': null,
        };
        state = await service.mutate(caseId, state.caseRevision, {
          'type': 'put_task',
          'expectedTaskRevision': 0,
          'task': task,
        });
        expect(state.tasks.single.title, task['title']);
        expect(service.pending, isEmpty);
        expect(store.records.containsKey('progress-cache.$caseId'), true);
        final pending = <String, Object?>{
          'schemaVersion': '3',
          'caseId': caseId,
          'expectedCaseRevision': state.caseRevision,
          'expectedProgressRevision': state.revision,
          'mutationId': newUuidV4(),
          'operation': {
            'type': 'put_task',
            'expectedTaskRevision': 0,
            'task': {
              ...task,
              'id': newUuidV4(),
              'title': 'Fictional document review',
            },
          },
        };
        await store.writeJson('progress-pending.$caseId', pending);
        await service.api.save(pending, isCurrent: () => true);
        await service.stop();
        service.dispose();
        service = null;
        restarted = create();
        await restarted.initialize();
        expect(restarted.pending[caseId], pending);
        state = await restarted.retry(caseId);
        expect(state.revision, 2);
        expect(state.tasks.length, 2);
        expect(restarted.pending, isEmpty);
        state = await restarted.mutate(caseId, state.caseRevision, {
          'type': 'put_task',
          'expectedTaskRevision': state.tasks.first.revision,
          'task': {
            ...state.tasks.first.toJson(),
            'state': 'completed',
            'revision': 2,
          },
        });
        expect(state.tasks.where((t) => t.open).length, 1);
        await expectLater(
          api(ready['bob'] as String).read(caseId, isCurrent: () => true),
          throwsA(
            isA<MatchingApiException>().having(
              (e) => e.code,
              'code',
              'CASE_NOT_FOUND',
            ),
          ),
        );
        await expectLater(
          restarted.api.read(caseId, isCurrent: () => false),
          throwsA(
            isA<MatchingApiException>().having(
              (e) => e.code,
              'code',
              'STALE_RESPONSE',
            ),
          ),
        );
        await restarted.stop();
        restarted.dispose();
        restarted = null;
        await store.writeJson('reminders.v3', {
          'deviceId': 'fictional-device',
          'preferences': [
            {'invalid': true},
          ],
        });
        restarted = create();
        await restarted.initialize();
        expect(restarted.cached[caseId]!.tasks.length, 2);
        expect(
          restarted.reminders.feedback,
          contains('settings could not be read'),
        );
        expect(restarted.reminders.requiresReset, true);
        expect((store.records['reminders.v3']!['preferences'] as List).single, {
          'invalid': true,
        });
        await restarted.reminders.reset();
        await restarted.reconcileReminders();
        expect(restarted.cached[caseId]!.tasks.length, 2);
        expect(restarted.reminders.requiresReset, false);
        expect(device.scheduled, isEmpty);
      } finally {
        service?.dispose();
        restarted?.dispose();
        process.kill();
        await process.exitCode;
        await errors.cancel();
      }
    }, _LoopbackHttp()),
  );
}
