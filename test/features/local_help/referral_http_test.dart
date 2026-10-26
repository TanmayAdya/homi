import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/app/live_app.dart';
import 'package:safe_at_home/features/local_help/local_help_record.dart';
import 'package:safe_at_home/features/local_help/local_help_repository.dart';
import 'package:safe_at_home/features/local_help/referral_task_import.dart';
import 'package:safe_at_home/shared/models/case_draft.dart';
import 'package:safe_at_home/shared/services/io_matching_transport.dart';
import 'package:safe_at_home/shared/services/matching_api_client.dart';
import 'package:safe_at_home/shared/services/progress_api_client.dart';
import '../../app/case_coordinator_test.dart' show FakeSession;
import '../../app/live_workflows_test.dart' show MemoryPrivateStore;
import '../tracking/device_reminders_test.dart' show FakeNotificationDevice;

class _Network extends HttpOverrides {}

class _Session extends FakeSession {
  _Session(this.token);
  final String token;
  @override
  Future<String?> accessToken() async => token;
}

class _LoopbackTransport implements MatchingTransport {
  _LoopbackTransport(this.origin);
  final Uri origin;
  final io = IoMatchingTransport();
  bool loseSave = false;
  @override
  MatchingExchange post(MatchingHttpRequest request) {
    final exchange = io.post(
      MatchingHttpRequest(
        endpoint: origin.resolve(request.endpoint.path),
        bearerToken: request.bearerToken,
        body: request.body,
        maxResponseBytes: request.maxResponseBytes,
      ),
    );
    return MatchingExchange(
      cancel: exchange.cancel,
      response: () async {
        final response = await exchange.response;
        if (loseSave && request.endpoint.path == '/v3/save-progress') {
          loseSave = false;
          throw const MatchingTransportException(
            MatchingTransportFailure.network,
          );
        }
        return response;
      }(),
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final providerId in [
    'referral-211-national',
    'provider-habitat-east-bay-silicon-valley',
  ]) {
    test(
      'Dart referral $providerId import and real HTTP preserve provenance through lost acknowledgement and an older client edit',
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
        AppServices? app;
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
              transport = _LoopbackTransport(origin),
              session = _Session(ready['alice'] as String),
              store = MemoryPrivateStore(),
              device = FakeNotificationDevice();
          app = AppServices(
            config: LiveAppConfig(
              apiOrigin: Uri.parse('https://example.org'),
              supabaseUrl: Uri.parse('https://example.supabase.co'),
              publishableKey: 'fictional',
              trackingEnabled: true,
              localHelpEnabled: true,
            ),
            session: session,
            store: store,
            transport: transport,
            notificationDevice: device,
          );
          await app.progressReady;
          await app.coordinator.createDraft();
          await app.coordinator.save();
          final local = LocalHelpRepository(app.coordinator);
          final original = HelpFollowUp(
            id: 'fictional-http-source',
            providerId: providerId,
            title: 'Fictional agency call',
            responsible: 'Fictional resident',
            dueDate: '2026-11-01',
            createdAt: '2026-10-24T00:00:00.000Z',
          );
          await local.saveTask(original);
          await local.saveContact(original.providerId, 'Resident note {count}');
          final importer = ReferralTaskImport(app, local);
          transport.loseSave = true;
          await expectLater(
            importer.import(
              original,
              keepDueDate: true,
              confirmedContactNote: 'Resident note {count}',
            ),
            throwsA(isA<MatchingApiException>()),
          );
          expect(app.progress!.pending.length, 1);
          final imported = await importer.import(
            original,
            keepDueDate: true,
            confirmedContactNote: 'Resident note {count}',
          );
          expect(imported.referralId, original.providerId);
          expect(imported.dueOn, original.dueDate);
          expect(
            (imported.referral!['imported'] as Map)['sourceHash'],
            referralSourceHash(original),
          );
          expect(app.progress!.cached[local.caseId]!.tasks.length, 1);
          final old = ProgressApiClient(
            baseUri: origin,
            tokenProvider: session.accessToken,
            transport: IoMatchingTransport(),
            allowInsecureLoopback: true,
          );
          final oldPage = await old.read(local.caseId, isCurrent: () => true);
          expect(oldPage.tasks.single.referral, isNull);
          await old.save({
            'schemaVersion': '3',
            'caseId': local.caseId,
            'expectedCaseRevision': oldPage.caseRevision,
            'expectedProgressRevision': oldPage.revision,
            'mutationId': newUuidV4(),
            'operation': {
              'type': 'put_task',
              'expectedTaskRevision': 1,
              'task': {
                ...oldPage.tasks.single.toJson(),
                'revision': 2,
                'title': 'Fictional follow-up again',
              },
            },
          }, isCurrent: () => true);
          final refreshed = await app.progress!.refresh(local.caseId);
          expect(refreshed.tasks.single.referral, imported.referral);
          expect((await local.load()).tasks.single.toJson(), original.toJson());
          expect(device.requests, 0);
          expect(device.scheduled, isEmpty);
        } finally {
          final session = app?.session;
          app?.dispose();
          session?.dispose();
          process.kill();
          await process.exitCode;
          await errors.cancel();
        }
      }, _Network()),
    );
  }
}
