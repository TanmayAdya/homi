import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:crypto/crypto.dart';
import 'package:safe_at_home/app/live_app.dart';
import 'package:safe_at_home/features/assessment/domain/home_safety/home_safety.dart';
import 'package:safe_at_home/shared/models/case_draft.dart';
import 'package:safe_at_home/shared/models/contracts.dart';
import 'package:safe_at_home/shared/services/matching_api_client.dart';
import '../../../app/case_coordinator_test.dart'
    show FakeSession, FakeTransport;
import '../../../app/live_workflows_test.dart' show MemoryPrivateStore;
import '../../../services/case_evidence_api_client_test.dart' as http;
import '../../tracking/device_reminders_test.dart' show FakeNotificationDevice;

class SafetyStore extends MemoryPrivateStore {
  final bytes = <String, Uint8List>{};
  @override
  Future<Uint8List?> readBytes(String key) async =>
      bytes[key] == null ? null : Uint8List.fromList(bytes[key]!);
  @override
  Future<void> writeBytes(String key, Uint8List value) async {
    bytes[key] = Uint8List.fromList(value);
  }

  @override
  Future<void> delete(String key) async {
    bytes.remove(key);
    await super.delete(key);
  }

  bool fail = false;
  @override
  Future<void> writeJson(String key, Map<String, Object?> value) {
    if (fail && key.startsWith('home-safety.')) {
      throw StateError('Fictional full device');
    }
    return super.writeJson(key, value);
  }
}

class SafetyServer {
  SafetyServer(this.catalog);
  final HomeSafetyCatalog catalog;
  late CaseSnapshot snapshot;
  SafetyDocument document = SafetyDocument.empty();
  final history = <Map<String, Object?>>[];
  bool offline = false, loseNextSave = false;
  int saves = 0;
  int progressRevision = 0;
  final tasks = <Map<String, Object?>>[];
  Future<void> Function()? beforeRead;
  Map<String, Object?> state([String? ack]) => {
    'schemaVersion': '3',
    'case': snapshot.toJson(),
    'safety': {
      'schemaVersion': '3',
      'caseId': snapshot.caseId,
      'revision': history.length,
      'document': document.toJson(),
      'history': history,
    },
    'acknowledgedMutationId': ack,
  };
  void apply(SafetyMutation request) {
    final result = projectSafety(
      document,
      snapshot,
      request.operation,
      catalog,
    );
    document = result.document;
    snapshot = result.snapshot;
    history.add({
      'mutationId': request.id,
      'requestHash': safetyHash(request.toJson()),
      'revision': history.length + 1,
      'caseRevision': snapshot.revision,
      'recordedAt': '2026-10-24T18:00:00.000Z',
      'recordedBy': 'fictional-owner',
      'operation': request.operation,
    });
  }

  Future<MatchingHttpResponse> handle(MatchingHttpRequest request) async {
    final body = http.requestJson(request);
    switch (request.endpoint.path) {
      case '/v1/list-evidence':
        return http.jsonResponse({
          'schemaVersion': '1',
          'caseId': snapshot.caseId,
          'caseRevision': snapshot.revision,
          'catalogRevision': 0,
          'evidence': <Object>[],
        });
      case '/v3/export-home-safety':
        final bytes = utf8.encode('%PDF-1.7\nFictional report test bytes');
        return http.jsonResponse({
          'schemaVersion': '3',
          'caseId': snapshot.caseId,
          'caseRevision': snapshot.revision,
          'safetyRevision': history.length,
          'catalogRevision': 0,
          'includeNotes': body['includeNotes'],
          'includeEvidenceReferences': body['includeEvidenceReferences'],
          'generatedAt': '2026-10-25T12:00:00.000Z',
          'pageCount': 1,
          'sha256': sha256.convert(bytes).toString(),
          'pdfBase64': base64Encode(bytes),
        });
      case '/v3/read-progress':
      case '/v3/save-progress':
        String? ack;
        if (request.endpoint.path == '/v3/save-progress') {
          final task = Map<String, Object?>.from(
            (body['operation'] as Map)['task'] as Map,
          );
          tasks.removeWhere((t) => t['id'] == task['id']);
          tasks.add({...task, 'needsReview': false});
          progressRevision++;
          ack = body['mutationId'] as String;
        }
        return http.jsonResponse({
          'schemaVersion': '3',
          'caseId': snapshot.caseId,
          'caseRevision': snapshot.revision,
          'revision': progressRevision,
          'programs': <Object>[],
          'tasks': tasks,
          'nextOffset': null,
          'acknowledgedMutationId': ack,
          'historyVersion': 'f' * 64,
        });
      case '/v1/create-case':
        snapshot = parseCurrentCase({...body, 'revision': 1});
        return http.jsonResponse(snapshot.toJson());
      case '/v2/read-plan-name':
        return http.jsonResponse({
          'schemaVersion': '2',
          'caseId': body['caseId'],
          'name': null,
          'nameRevision': 0,
          'lastMutationId': null,
        });
      case '/v3/read-home-safety':
        await beforeRead?.call();
        if (offline) {
          throw const MatchingTransportException(
            MatchingTransportFailure.network,
          );
        }
        return http.jsonResponse(state());
      case '/v3/save-home-safety':
        if (offline) {
          throw const MatchingTransportException(
            MatchingTransportFailure.network,
          );
        }
        final op = SafetyMutation.fromJson(body, catalog);
        if (op.safetyRevision != history.length ||
            op.caseRevision != snapshot.revision) {
          throw StateError('Unexpected test mutation conflict');
        }
        saves++;
        apply(op);
        if (loseNextSave) {
          loseNextSave = false;
          throw const MatchingTransportException(
            MatchingTransportFailure.network,
          );
        }
        return http.jsonResponse(state(op.id));
      default:
        throw StateError('Unexpected test route ${request.endpoint.path}');
    }
  }
}

Future<
  ({
    AppServices services,
    SafetyStore store,
    SafetyServer server,
    FakeSession auth,
  })
>
safetyHarness({
  bool tracking = false,
  bool homeSafety = false,
  HomeSafetyCatalog? loadedCatalog,
}) async {
  final catalog = loadedCatalog ?? await HomeSafetyCatalog.load(),
      store = SafetyStore(),
      server = SafetyServer(catalog),
      auth = FakeSession();
  final services = AppServices(
    config: LiveAppConfig(
      apiOrigin: Uri.parse('https://example.org'),
      supabaseUrl: Uri.parse('https://example.supabase.co'),
      publishableKey: 'fictional',
      trackingEnabled: tracking,
      homeSafetyEnabled: homeSafety,
    ),
    session: auth,
    store: store,
    transport: FakeTransport(server.handle),
    pdfPreviewBuilder: (_) => const Text('Fictional report preview'),
    notificationDevice: tracking ? FakeNotificationDevice() : null,
  );
  await services.coordinator.createDraft();
  await services.coordinator.save();
  await services.progressReady;
  return (services: services, store: store, server: server, auth: auth);
}

Map<String, Object?> addRoom(
  String id, {
  String type = 'bedroom',
  String? name,
}) => {
  'type': 'add_room',
  'room': {'id': id, 'type': type, 'name': name},
};
Map<String, Object?> answer(String id, String value) => {
  'type': 'answer',
  'roomId': id,
  'questionId': 'bedroom.path',
  'value': value,
};
Map<String, Object?> detached(Map<String, Object?> value) =>
    Map<String, Object?>.from(jsonDecode(jsonEncode(value)) as Map);
