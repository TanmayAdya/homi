import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/shared/models/case_draft.dart';
import 'package:safe_at_home/shared/models/evidence.dart';
import 'package:safe_at_home/shared/services/case_evidence_api_client.dart';
import 'package:safe_at_home/shared/services/matching_api_client.dart';

import '../contracts/case_evidence_test.dart' as c;
import '../contracts/draft_export_test.dart' as f;

MatchingHttpResponse jsonResponse(Object? body, {int status = 200}) =>
    MatchingHttpResponse(
      statusCode: status,
      contentType: 'application/json',
      body: utf8.encode(jsonEncode(body)),
    );
MatchingHttpResponse apiError(String code, int status) => jsonResponse({
  'schemaVersion': '1',
  'error': {
    'code': code,
    'message': 'Private server details must never display',
  },
}, status: status);
TypeMatcher<MatchingApiException> failure(String code) =>
    isA<MatchingApiException>().having((e) => e.code, 'code', code);
CaseEvidenceApiClient clientFor(
  MatchingTransport transport, {
  MatchingTokenProvider? tokenProvider,
  Duration timeout = const Duration(seconds: 15),
  String origin = 'https://example.org',
  bool allowLoopback = false,
  bool allowEmulator = false,
}) => CaseEvidenceApiClient(
  createCaseEndpoint: Uri.parse('$origin/v1/create-case'),
  saveCaseEndpoint: Uri.parse('$origin/v1/save-case'),
  caseEndpoint: Uri.parse('$origin/v1/read-case'),
  uploadEvidenceEndpoint: Uri.parse('$origin/v1/upload-evidence'),
  deleteEvidenceEndpoint: Uri.parse('$origin/v1/delete-evidence'),
  transport: transport,
  tokenProvider: tokenProvider ?? () async => 'fictional-token',
  timeout: timeout,
  allowInsecureLoopback: allowLoopback,
  allowAndroidEmulatorLoopback: allowEmulator,
);
Map<String, dynamic> requestJson(MatchingHttpRequest request) =>
    jsonDecode(utf8.decode(request.body)) as Map<String, dynamic>;
Future<Object> save(CaseEvidenceApiClient client) {
  final draft = c.draft(caseId: 'fictional-case');
  return client.saveCase(
    f.snapshot(),
    replacement: draft,
    currentCase: f.snapshot,
    currentDraft: () => draft,
  );
}

Future<Object> upload(CaseEvidenceApiClient client, {List<int>? bytes}) =>
    client.uploadEvidence(
      f.snapshot(),
      catalog: f.catalog(),
      evidenceId: 'fictional-evidence',
      expectedEvidenceRevision: 1,
      findingId: 'fictional-finding',
      capturedAt: null,
      imageBytes: bytes ?? f.png,
      currentCase: f.snapshot,
      currentCatalog: f.catalog,
    );
Future<Object> delete(CaseEvidenceApiClient client) => client.deleteEvidence(
  f.snapshot(),
  catalog: f.catalog(),
  evidence: f.catalog().evidence.single,
  currentCase: f.snapshot,
  currentCatalog: f.catalog,
);

void main() {
  test(
    'transport byte values use detached compact immutable storage without truncation',
    () {
      final bytes = <int>[0, 127, 128, 255];
      final request = MatchingHttpRequest(
        endpoint: Uri.parse('https://example.org/v1/save-case'),
        bearerToken: 'token',
        body: bytes,
        maxResponseBytes: 1024,
      );
      final response = MatchingHttpResponse(
        statusCode: 200,
        contentType: 'application/json',
        body: bytes,
      );
      bytes[0] = 1;
      expect(request.body, [0, 127, 128, 255]);
      expect(response.body, [0, 127, 128, 255]);
      expect(request.body, isA<Uint8List>());
      expect(response.body, isA<Uint8List>());
      expect(() => request.body[0] = 4, throwsUnsupportedError);
      expect(() => response.body[0] = 4, throwsUnsupportedError);
      for (final invalid in [
        [-1],
        [256],
      ]) {
        expect(
          () => MatchingHttpRequest(
            endpoint: request.endpoint,
            bearerToken: 'token',
            body: invalid,
            maxResponseBytes: 1,
          ),
          throwsArgumentError,
        );
        expect(
          () => MatchingHttpResponse(
            statusCode: 200,
            contentType: null,
            body: invalid,
          ),
          throwsArgumentError,
        );
      }
    },
  );
  test(
    'create sends exact full content and returns authoritative revision without adoption',
    () async {
      final draft = c.draft();
      final transport = _Transport(
        (_) async => jsonResponse(draft.atRevision(1).toJson()),
      );
      final result = await clientFor(
        transport,
      ).createCase(draft, currentDraft: () => draft);
      expect(result.revision, 1);
      expect(result.caseId, c.caseUuid);
      expect(transport.requests.single.endpoint.path, '/v1/create-case');
      expect(requestJson(transport.requests.single), draft.toJson());
      expect(
        requestJson(transport.requests.single).keys,
        isNot(contains('ownerId')),
      );
      expect(transport.cancellations, 1);
    },
  );
  test(
    'save is a full replacement and uses a fresh session token each time',
    () async {
      final input = c.draftJson(caseId: 'fictional-case')
        ..['findings'] = <Object>[];
      (input['profile'] as Map)['city'] = 'Fictional Town';
      final draft = CaseDraft.fromJson(input);
      var tokens = 0;
      final transport = _Transport(
        (_) async => jsonResponse(draft.atRevision(3).toJson()),
      );
      final client = clientFor(
        transport,
        tokenProvider: () async => 'token-${++tokens}',
      );
      for (var i = 0; i < 2; i++) {
        final result = await client.saveCase(
          f.snapshot(),
          replacement: draft,
          currentCase: f.snapshot,
          currentDraft: () => draft,
        );
        expect(result.revision, 3);
        expect(result.findings, isEmpty);
        expect(result.profile.city, 'Fictional Town');
      }
      expect(transport.requests.map((r) => r.bearerToken), [
        'token-1',
        'token-2',
      ]);
      expect(requestJson(transport.requests.first), {
        ...draft.toJson(),
        'expectedCaseRevision': 2,
      });
      expect(f.snapshot().revision, 2);
    },
  );
  test('server-normalized integral doubles preserve numeric meaning', () async {
    for (final amount in [45000.0, -0.0, 1e25]) {
      final input = c.draftJson(caseId: 'fictional-case');
      (input['profile'] as Map)['annualIncomeUsd'] = amount;
      (input['findings'] as List).first['measurements'] = [
        <String, Object?>{
          'type': 'door width',
          'value': 800.0,
          'unit': 'mm',
          'method': 'manual',
          'confirmed': false,
        },
      ];
      final draft = CaseDraft.fromJson(input);
      final normalized = draft.atRevision(3).toJson();
      (normalized['profile'] as Map)['annualIncomeUsd'] = amount.abs() < 1e20
          ? amount.toInt()
          : amount;
      (normalized['findings'] as List).first['measurements'][0]['value'] = 800;
      final client = clientFor(
        _Transport((_) async => jsonResponse(normalized)),
      );
      final result = await client.saveCase(
        f.snapshot(),
        replacement: draft,
        currentCase: f.snapshot,
        currentDraft: () => draft,
      );
      expect(result.profile.annualIncomeUsd, amount);
      expect(result.findings.single.measurements.single.value, 800);
      if (amount == 1e25) {
        (normalized['profile'] as Map)['annualIncomeUsd'] = 1e26;
        await expectLater(
          client.saveCase(
            f.snapshot(),
            replacement: draft,
            currentCase: f.snapshot,
            currentDraft: () => draft,
          ),
          throwsA(failure('CASE_SAVE_UNCERTAIN')),
        );
      }
    }
  });
  test(
    'new local edits during token lookup prevent dispatch even at same case revision',
    () async {
      var draft = c.draft(caseId: 'fictional-case');
      final captured = draft;
      final token = Completer<String?>();
      final transport = _Transport(
        (_) async => jsonResponse(captured.atRevision(3).toJson()),
      );
      final pending = clientFor(transport, tokenProvider: () => token.future)
          .saveCase(
            f.snapshot(),
            replacement: captured,
            currentCase: f.snapshot,
            currentDraft: () => draft,
          );
      final changed = draft.toJson();
      (changed['profile'] as Map)['city'] = 'Changed locally';
      draft = CaseDraft.fromJson(changed);
      token.complete('fictional-token');
      await expectLater(pending, throwsA(failure('STALE_RESPONSE')));
      expect(transport.requests, isEmpty);
    },
  );
  test(
    'local edits after dispatch produce uncertain save and retain the local draft',
    () async {
      var draft = c.draft(caseId: 'fictional-case');
      final captured = draft;
      final response = Completer<MatchingHttpResponse>();
      final sent = Completer<void>();
      final transport = _Transport((_) {
        sent.complete();
        return response.future;
      });
      final pending = clientFor(transport).saveCase(
        f.snapshot(),
        replacement: captured,
        currentCase: f.snapshot,
        currentDraft: () => draft,
      );
      await sent.future;
      final changed = draft.toJson();
      (changed['profile'] as Map)['city'] = 'New local text';
      draft = CaseDraft.fromJson(changed);
      response.complete(jsonResponse(captured.atRevision(3).toJson()));
      await expectLater(pending, throwsA(failure('CASE_SAVE_UNCERTAIN')));
      expect(draft.profile.city, 'New local text');
      expect(transport.requests, hasLength(1));
    },
  );
  test(
    'lost first-create response reloads same UUID without retry or guessed revision',
    () async {
      final draft = c.draft();
      final lost = Completer<MatchingHttpResponse>();
      final transport = _Transport(
        (request) => request.endpoint.path == '/v1/create-case'
            ? lost.future
            : Future.value(jsonResponse(draft.atRevision(1).toJson())),
      );
      final client = clientFor(
        transport,
        timeout: const Duration(milliseconds: 20),
      );
      await expectLater(
        client.createCase(draft, currentDraft: () => draft),
        throwsA(failure('CASE_SAVE_UNCERTAIN')),
      );
      final result = await client.reloadCase(
        draft.caseId,
        currentCaseId: () => draft.caseId,
        currentCase: () => null,
      );
      expect(result.revision, 1);
      expect(result.caseId, draft.caseId);
      expect(transport.requests.map((r) => r.endpoint.path), [
        '/v1/create-case',
        '/v1/read-case',
      ]);
      expect(requestJson(transport.requests.last), {
        'schemaVersion': '1',
        'caseId': draft.caseId,
      });
      lost.complete(jsonResponse(result.toJson()));
    },
  );
  test(
    'lost save reloads new revision and does not mutate the old snapshot',
    () async {
      final lost = Completer<MatchingHttpResponse>();
      final transport = _Transport(
        (request) => request.endpoint.path == '/v1/save-case'
            ? lost.future
            : Future.value(jsonResponse(f.snapshot(revision: 3).toJson())),
      );
      final client = clientFor(
        transport,
        timeout: const Duration(milliseconds: 20),
      );
      final saved = f.snapshot();
      await expectLater(save(client), throwsA(failure('CASE_SAVE_UNCERTAIN')));
      final result = await client.reloadCase(
        saved.caseId,
        currentCaseId: () => saved.caseId,
        currentCase: () => saved,
      );
      expect(result.revision, 3);
      expect(saved.revision, 2);
      expect(transport.requests, hasLength(2));
      lost.complete(jsonResponse(result.toJson()));
    },
  );
  test(
    'reload rejects selected ID change and same-ID revision regression',
    () async {
      for (final changeId in [false, true]) {
        var current = f.snapshot();
        var selected = current.caseId;
        final response = Completer<MatchingHttpResponse>();
        final sent = Completer<void>();
        final transport = _Transport((_) {
          sent.complete();
          return response.future;
        });
        final pending = clientFor(transport).reloadCase(
          selected,
          currentCaseId: () => selected,
          currentCase: () => current,
        );
        await sent.future;
        if (changeId) {
          selected = 'other-case';
        } else {
          current = f.snapshot(revision: 4);
        }
        response.complete(jsonResponse(f.snapshot(revision: 3).toJson()));
        await expectLater(pending, throwsA(failure('STALE_RESPONSE')));
      }
    },
  );
  test(
    'reload revision-grown case then shrink-save; larger replacements stay blocked',
    () async {
      final input = c.draftJson(caseId: 'fictional-case');
      final profile = input['profile'] as Map;
      profile['city'] = 'x';
      final base = utf8.encode(jsonEncode({...input, 'revision': 9})).length;
      profile['city'] = 'x' * (maxSavedCaseBytes - base + 1);
      final prior = CaseDraft.fromJson(input).atRevision(9);
      final grownJson = {...input, 'revision': 10};
      final smallerJson = c.draftJson(caseId: 'fictional-case');
      (smallerJson['profile'] as Map)['city'] = 'Shorter answer';
      final smaller = CaseDraft.fromJson(smallerJson);
      final transport = _Transport(
        (request) async => jsonResponse(
          request.endpoint.path == '/v1/read-case'
              ? grownJson
              : smaller.atRevision(11).toJson(),
        ),
      );
      final client = clientFor(transport);
      final grown = await client.reloadCase(
        prior.caseId,
        currentCaseId: () => prior.caseId,
        currentCase: () => prior,
      );
      expect(
        utf8.encode(jsonEncode(grown.toJson())),
        hasLength(maxSavedCaseBytes + 1),
      );
      final unchanged = CaseDraft.fromSnapshot(grown);
      await expectLater(
        client.saveCase(
          grown,
          replacement: unchanged,
          currentCase: () => grown,
          currentDraft: () => unchanged,
        ),
        throwsA(failure('INVALID_REQUEST')),
      );
      expect(transport.requests, hasLength(1));
      final result = await client.saveCase(
        grown,
        replacement: smaller,
        currentCase: () => grown,
        currentDraft: () => smaller,
      );
      expect(result.revision, 11);
      expect(result.profile.city, 'Shorter answer');
      expect(transport.requests, hasLength(2));
    },
  );
  test(
    'wrong case content or revision in a save success is uncertain',
    () async {
      for (final response in [
        f.snapshot().toJson(),
        f.snapshot(revision: 4).toJson(),
        f.snapshot(revision: 3).toJson()..['caseId'] = 'other',
        f.snapshot(revision: 3).toJson()..['ownerId'] = 'private',
      ]) {
        final client = clientFor(
          _Transport((_) async => jsonResponse(response)),
        );
        await expectLater(
          save(client),
          throwsA(failure('CASE_SAVE_UNCERTAIN')),
        );
      }
      final response = f.snapshot(revision: 3).toJson();
      (response['profile'] as Map)['city'] = 'Server changed answer';
      await expectLater(
        save(clientFor(_Transport((_) async => jsonResponse(response)))),
        throwsA(failure('CASE_SAVE_UNCERTAIN')),
      );
    },
  );
  test(
    'upload sends canonical detached image bytes with exact evidence context',
    () async {
      final bytes = f.png.toList();
      final original = bytes.toList();
      final token = Completer<String?>();
      final transport = _Transport((_) async => jsonResponse(c.uploadJson()));
      final pending = upload(
        clientFor(transport, tokenProvider: () => token.future),
        bytes: bytes,
      );
      bytes.fillRange(0, bytes.length, 0);
      token.complete('fictional-token');
      final result = await pending;
      expect(result, isNotNull);
      final body = requestJson(transport.requests.single);
      expect(body, {
        'schemaVersion': '1',
        'caseId': 'fictional-case',
        'expectedCaseRevision': 2,
        'expectedCatalogRevision': 1,
        'evidenceId': 'fictional-evidence',
        'expectedEvidenceRevision': 1,
        'findingId': 'fictional-finding',
        'capturedAt': null,
        'imageBase64': base64Encode(original),
      });
      expect(transport.requests.single.endpoint.path, '/v1/upload-evidence');
    },
  );
  test(
    'new image requires saved finding link and expected asset revision zero',
    () async {
      final catalog = EvidenceCatalog.fromJson(
        f.catalogJson()
          ..['catalogRevision'] = 0
          ..['evidence'] = <Object>[],
      );
      final transport = _Transport(
        (_) async =>
            jsonResponse(c.uploadJson(catalogRevision: 1, evidenceRevision: 1)),
      );
      final result = await clientFor(transport).uploadEvidence(
        f.snapshot(),
        catalog: catalog,
        evidenceId: 'fictional-evidence',
        expectedEvidenceRevision: 0,
        findingId: 'fictional-finding',
        capturedAt: null,
        imageBytes: f.png,
        currentCase: f.snapshot,
        currentCatalog: () => catalog,
      );
      expect(result.evidence.evidenceRevision, 1);
      expect(result.catalogRevision, 1);
      await expectLater(
        clientFor(transport).uploadEvidence(
          f.snapshot(),
          catalog: catalog,
          evidenceId: 'not-saved-in-case',
          expectedEvidenceRevision: 0,
          findingId: 'fictional-finding',
          capturedAt: null,
          imageBytes: f.png,
          currentCase: f.snapshot,
          currentCatalog: () => catalog,
        ),
        throwsA(failure('INVALID_REQUEST')),
      );
      expect(transport.requests, hasLength(1));
    },
  );
  test('image bytes are bounded and malformed inputs never dispatch', () async {
    final transport = _Transport((_) async => jsonResponse(c.uploadJson()));
    final client = clientFor(transport);
    for (final bytes in [
      <int>[],
      List.filled(7, 0),
      [...List.filled(7, 0), 256],
      [...List.filled(7, 0), -1],
      List.filled(maxOriginalImageBytes + 1, 0),
    ]) {
      await expectLater(
        upload(client, bytes: bytes),
        throwsA(failure('INVALID_REQUEST')),
      );
    }
    expect(transport.requests, isEmpty);
  });
  test('8 MiB original image fits explicit upload request cap', () async {
    final transport = _Transport((_) async => apiError('INVALID_IMAGE', 422));
    await expectLater(
      upload(
        clientFor(transport),
        bytes: List.filled(maxOriginalImageBytes, 0),
      ),
      throwsA(failure('INVALID_IMAGE')),
    );
    expect(
      transport.requests.single.body.length,
      lessThanOrEqualTo(maxImageUploadRequestBytes),
    );
    expect(
      base64Decode(
        requestJson(transport.requests.single)['imageBase64'] as String,
      ),
      hasLength(maxOriginalImageBytes),
    );
  });
  test('upload rejects mismatched current catalog before dispatch', () async {
    final transport = _Transport((_) async => jsonResponse(c.uploadJson()));
    final changed = EvidenceCatalog.fromJson(
      f.catalogJson()..['catalogRevision'] = 2,
    );
    await expectLater(
      clientFor(transport).uploadEvidence(
        f.snapshot(),
        catalog: f.catalog(),
        evidenceId: 'fictional-evidence',
        expectedEvidenceRevision: 1,
        findingId: 'fictional-finding',
        capturedAt: null,
        imageBytes: f.png,
        currentCase: f.snapshot,
        currentCatalog: () => changed,
      ),
      throwsA(failure('STALE_RESPONSE')),
    );
    expect(transport.requests, isEmpty);
  });
  test(
    'catalog changes after image dispatch make the write outcome uncertain',
    () async {
      var current = f.catalog();
      final response = Completer<MatchingHttpResponse>();
      final sent = Completer<void>();
      final transport = _Transport((_) {
        sent.complete();
        return response.future;
      });
      final pending = clientFor(transport).uploadEvidence(
        f.snapshot(),
        catalog: current,
        evidenceId: 'fictional-evidence',
        expectedEvidenceRevision: 1,
        findingId: 'fictional-finding',
        capturedAt: null,
        imageBytes: f.png,
        currentCase: f.snapshot,
        currentCatalog: () => current,
      );
      await sent.future;
      current = EvidenceCatalog.fromJson(
        f.catalogJson()..['catalogRevision'] = 2,
      );
      response.complete(jsonResponse(c.uploadJson()));
      await expectLater(pending, throwsA(failure('EVIDENCE_SAVE_UNCERTAIN')));
      expect(transport.requests, hasLength(1));
    },
  );
  test(
    'upload response cannot advance case or use wrong asset revision or capture time',
    () async {
      final mismatches = [
        c.uploadJson()..['caseRevision'] = 3,
        c.uploadJson(catalogRevision: 3),
        c.uploadJson(evidenceRevision: 1),
      ];
      final bad = c.uploadJson();
      (bad['evidence'] as Map)['capturedAt'] = f.stamp;
      mismatches.add(bad);
      final wrongFinding = c.uploadJson();
      (wrongFinding['evidence'] as Map)['findingId'] = 'other';
      mismatches.add(wrongFinding);
      for (final response in mismatches) {
        await expectLater(
          upload(clientFor(_Transport((_) async => jsonResponse(response)))),
          throwsA(failure('EVIDENCE_SAVE_UNCERTAIN')),
        );
      }
    },
  );
  test(
    'delete sends exact revision context and returns the new catalog and tombstone revisions',
    () async {
      final transport = _Transport((_) async => jsonResponse(c.deleteJson()));
      final result = await clientFor(transport).deleteEvidence(
        f.snapshot(),
        catalog: f.catalog(),
        evidence: f.catalog().evidence.single,
        currentCase: f.snapshot,
        currentCatalog: f.catalog,
      );
      expect(result.deleted, isTrue);
      expect(result.caseRevision, 2);
      expect(result.catalogRevision, 2);
      expect(result.evidenceRevision, 2);
      expect(requestJson(transport.requests.single), {
        'schemaVersion': '1',
        'caseId': 'fictional-case',
        'expectedCaseRevision': 2,
        'expectedCatalogRevision': 1,
        'evidenceId': 'fictional-evidence',
        'expectedEvidenceRevision': 1,
      });
      expect(transport.requests.single.endpoint.path, '/v1/delete-evidence');
    },
  );
  test('delete rejects detached descriptor or mismatched receipt', () async {
    final transport = _Transport(
      (_) async => jsonResponse(c.deleteJson()..['evidenceRevision'] = 1),
    );
    await expectLater(
      delete(clientFor(transport)),
      throwsA(failure('EVIDENCE_SAVE_UNCERTAIN')),
    );
    final other = EvidenceDescriptor.fromJson(
      f.descriptorJson()..['width'] = 2,
    );
    await expectLater(
      clientFor(transport).deleteEvidence(
        f.snapshot(),
        catalog: f.catalog(),
        evidence: other,
        currentCase: f.snapshot,
        currentCatalog: f.catalog,
      ),
      throwsA(failure('INVALID_REQUEST')),
    );
    expect(transport.requests, hasLength(1));
  });
  test('lost image upload or deletion never auto retries', () async {
    for (final operation in [upload, delete]) {
      final response = Completer<MatchingHttpResponse>();
      final transport = _Transport((_) => response.future);
      await expectLater(
        operation(
          clientFor(transport, timeout: const Duration(milliseconds: 20)),
        ),
        throwsA(failure('EVIDENCE_SAVE_UNCERTAIN')),
      );
      expect(transport.requests, hasLength(1));
      expect(transport.cancellations, 1);
      response.complete(jsonResponse(c.deleteJson()));
    }
  });
  test(
    'safe known errors preserve status/code and suppress server messages',
    () async {
      const codes = {
        'CASE_ID_UNAVAILABLE': 409,
        'CASE_REVISION_MISMATCH': 409,
        'EVIDENCE_CONFLICT': 409,
        'INVALID_IMAGE': 422,
        'UPLOAD_BUSY': 429,
        'STORAGE_LIMIT_REACHED': 507,
        'CASE_NOT_FOUND': 404,
        'UNAUTHENTICATED': 401,
      };
      for (final entry in codes.entries) {
        try {
          await save(
            clientFor(
              _Transport((_) async => apiError(entry.key, entry.value)),
            ),
          );
          fail('Expected error');
        } on MatchingApiException catch (error) {
          expect(error.code, entry.key);
          expect(error.statusCode, entry.value);
          expect(error.message, isNot(contains('Private server')));
        }
      }
    },
  );
  test(
    'server exceptions, malformed responses and redirects cannot prove write failure',
    () async {
      final responses = [
        apiError('INTERNAL_ERROR', 500),
        apiError('SERVICE_UNAVAILABLE', 503),
        apiError('INVALID_IMAGE', 409),
        jsonResponse({'unexpected': true}),
        MatchingHttpResponse(
          statusCode: 302,
          contentType: 'text/plain',
          body: [],
        ),
        MatchingHttpResponse(
          statusCode: 200,
          contentType: 'text/plain',
          body: [],
        ),
        MatchingHttpResponse(
          statusCode: 200,
          contentType: 'application/json',
          body: [255],
        ),
        MatchingHttpResponse(
          statusCode: 200,
          contentType: 'application/json',
          body: List.filled(1024 * 1024 + 1, 32),
        ),
      ];
      for (final response in responses) {
        await expectLater(
          save(clientFor(_Transport((_) async => response))),
          throwsA(failure('CASE_SAVE_UNCERTAIN')),
        );
      }
    },
  );
  test('transport errors cancel and become mutation uncertainty', () async {
    for (final error in [
      const MatchingTransportException(MatchingTransportFailure.network),
      const MatchingTransportException(
        MatchingTransportFailure.responseTooLarge,
      ),
      const MatchingTransportException(
        MatchingTransportFailure.redirectBlocked,
      ),
      StateError('private'),
    ]) {
      final transport = _Transport((_) async => throw error);
      await expectLater(
        upload(clientFor(transport)),
        throwsA(failure('EVIDENCE_SAVE_UNCERTAIN')),
      );
      expect(transport.cancellations, 1);
    }
  });
  test(
    'invalid or oversized token and slow login fail before any write dispatch',
    () async {
      final transport = _Transport((_) async => jsonResponse(c.uploadJson()));
      for (final token in [null, '', 'token\n', 'a' * 4097]) {
        await expectLater(
          upload(clientFor(transport, tokenProvider: () async => token)),
          throwsA(failure('UNAUTHENTICATED')),
        );
      }
      final token = Completer<String?>();
      await expectLater(
        upload(
          clientFor(
            transport,
            tokenProvider: () => token.future,
            timeout: const Duration(milliseconds: 10),
          ),
        ),
        throwsA(failure('TIMEOUT')),
      );
      token.complete('token');
      expect(transport.requests, isEmpty);
    },
  );
  test(
    'endpoint origin, exact path, credentials, query and loopback gates are enforced',
    () {
      final transport = _Transport((_) async => jsonResponse(c.deleteJson()));
      for (final origin in [
        'http://example.org',
        'http://127.0.0.1',
        'https://user:secret@example.org',
      ]) {
        expect(() => clientFor(transport, origin: origin), throwsArgumentError);
      }
      expect(
        clientFor(transport, origin: 'http://127.0.0.1', allowLoopback: true),
        isA<CaseEvidenceApiClient>(),
      );
      expect(
        () => clientFor(
          transport,
          origin: 'http://10.0.2.2',
          allowLoopback: true,
        ),
        throwsArgumentError,
      );
      expect(
        clientFor(
          transport,
          origin: 'http://10.0.2.2',
          allowLoopback: true,
          allowEmulator: true,
        ),
        isA<CaseEvidenceApiClient>(),
      );
      for (final uri in [
        'https://other.example/v1/create-case',
        'https://example.org/v1/create-case?x=1',
        'https://example.org/v1/create-case/',
        'https://example.org/v1/create-case#x',
      ]) {
        expect(
          () => CaseEvidenceApiClient(
            createCaseEndpoint: Uri.parse(uri),
            saveCaseEndpoint: Uri.parse('https://example.org/v1/save-case'),
            caseEndpoint: Uri.parse('https://example.org/v1/read-case'),
            uploadEvidenceEndpoint: Uri.parse(
              'https://example.org/v1/upload-evidence',
            ),
            deleteEvidenceEndpoint: Uri.parse(
              'https://example.org/v1/delete-evidence',
            ),
            tokenProvider: () async => 'token',
            transport: transport,
          ),
          throwsArgumentError,
        );
      }
      for (final duration in [Duration.zero, const Duration(seconds: 16)]) {
        expect(
          () => clientFor(transport, timeout: duration),
          throwsArgumentError,
        );
      }
    },
  );
}

class _Transport implements MatchingTransport {
  _Transport(this.handler);
  final Future<MatchingHttpResponse> Function(MatchingHttpRequest) handler;
  final requests = <MatchingHttpRequest>[];
  var cancellations = 0;
  @override
  MatchingExchange post(MatchingHttpRequest request) {
    requests.add(request);
    return MatchingExchange(
      response: handler(request),
      cancel: () {
        cancellations++;
      },
    );
  }
}
