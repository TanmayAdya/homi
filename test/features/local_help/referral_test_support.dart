import 'package:safe_at_home/app/live_app.dart';
import 'package:safe_at_home/shared/models/contracts.dart';
import 'package:safe_at_home/shared/services/matching_api_client.dart';
import '../../app/case_coordinator_test.dart' show FakeSession, FakeTransport;
import '../../app/live_workflows_test.dart' show MemoryPrivateStore;
import '../../services/case_evidence_api_client_test.dart' as http;
import '../tracking/device_reminders_test.dart' show FakeNotificationDevice;

class ReferralStore extends MemoryPrivateStore {
  bool failReceipt = false;
  @override
  Future<void> writeJson(String key, Map<String, Object?> value) async {
    if (failReceipt && key.startsWith('referral-import.')) {
      throw StateError('Fictional full disk');
    }
    await super.writeJson(key, value);
  }
}

class ReferralServer {
  final tasks = <String, Map<String, Object?>>{};
  final mutations = <String>{};
  late CaseSnapshot snapshot;
  bool loseSave = false, offline = false, limit = false;
  Future<void> Function()? beforeRead;
  Future<MatchingHttpResponse> handle(MatchingHttpRequest request) async {
    if (offline) {
      throw const MatchingTransportException(MatchingTransportFailure.network);
    }
    final body = http.requestJson(request);
    if (request.endpoint.path == '/v1/create-case') {
      snapshot = CaseSnapshot.fromJson({...body, 'revision': 1});
      return http.jsonResponse(snapshot.toJson());
    }
    String? ack;
    if (request.endpoint.path == '/v3/read-progress') await beforeRead?.call();
    if (request.endpoint.path == '/v3/save-progress') {
      if (limit) {
        return http.jsonResponse({
          'schemaVersion': '3',
          'error': {'code': 'PROGRESS_LIMIT', 'message': 'Fictional limit'},
        }, status: 507);
      }
      ack = body['mutationId'] as String;
      if (mutations.add(ack)) {
        final operation = body['operation'] as Map;
        final task = Map<String, Object?>.from(operation['task'] as Map);
        tasks[task['id'] as String] = {...task, 'needsReview': false};
      }
      if (loseSave) {
        loseSave = false;
        throw const MatchingTransportException(
          MatchingTransportFailure.network,
        );
      }
    }
    final offset = body['offset'] as int? ?? 0;
    return http.jsonResponse({
      'schemaVersion': '3',
      'caseId': snapshot.caseId,
      'caseRevision': snapshot.revision,
      'revision': mutations.length,
      'historyVersion': 'f' * 64,
      'programs': <Object>[],
      'tasks': tasks.values.skip(offset).take(20).toList(),
      'nextOffset': offset + 20 < tasks.length ? offset + 20 : null,
      'acknowledgedMutationId': ack,
    });
  }
}

class ReferralHarness {
  ReferralHarness(this.app, this.server, this.store, this.device);
  final AppServices app;
  final ReferralServer server;
  final ReferralStore store;
  final FakeNotificationDevice device;
  static Future<ReferralHarness> create({
    ReferralStore? store,
    ReferralServer? server,
  }) async {
    final saved = store ?? ReferralStore(),
        backend = server ?? ReferralServer(),
        device = FakeNotificationDevice();
    final app = AppServices(
      config: LiveAppConfig(
        apiOrigin: Uri.parse('https://example.org'),
        supabaseUrl: Uri.parse('https://example.supabase.co'),
        publishableKey: 'fictional',
        localHelpEnabled: true,
        trackingEnabled: true,
      ),
      session: FakeSession(),
      store: saved,
      transport: FakeTransport(backend.handle),
      notificationDevice: device,
    );
    await app.progressReady;
    if (server == null) {
      await app.coordinator.createDraft();
      await app.coordinator.save();
    } else {
      await app.coordinator.restoreLocal(backend.snapshot.caseId);
    }
    return ReferralHarness(app, backend, saved, device);
  }

  void dispose() {
    app.dispose();
    app.session.dispose();
  }
}
