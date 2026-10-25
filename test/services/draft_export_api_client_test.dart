import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart' as hashing;
import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/shared/models/draft_export.dart';
import 'package:safe_at_home/shared/models/evidence.dart';
import 'package:safe_at_home/shared/models/form_answers.dart';
import 'package:safe_at_home/shared/services/draft_export_api_client.dart';
import 'package:safe_at_home/shared/services/matching_api_client.dart';

import '../contracts/draft_export_test.dart' as f;

MatchingHttpResponse jsonResponse(Object? value, {int status = 200}) =>
    MatchingHttpResponse(
      statusCode: status,
      contentType: 'application/json',
      body: utf8.encode(jsonEncode(value)),
    );
MatchingHttpResponse binary(List<int> bytes, String type) =>
    MatchingHttpResponse(statusCode: 200, contentType: type, body: bytes);
TypeMatcher<MatchingApiException> failure(String code) =>
    isA<MatchingApiException>().having((e) => e.code, 'code', code);
ExportSelectionState state({
  EvidenceCatalog? catalog,
  List<EvidenceSelection>? selected,
  FormAnswerContext? context,
  int answerRevision = 0,
  int caseRevision = 2,
  String review = 'confirmed',
}) => ExportSelectionState(
  snapshot: f.snapshot(revision: caseRevision, review: review),
  context: context ?? f.context(),
  answerRevision: answerRevision,
  catalog: catalog ?? f.catalog(),
  selectedEvidence: selected ?? [f.selection()],
);
DraftExportApiClient client(
  MatchingTransport transport, {
  MatchingTokenProvider? tokenProvider,
  DateTime Function()? now,
  Duration timeout = const Duration(seconds: 15),
}) => DraftExportApiClient(
  evidenceEndpoint: Uri.parse('https://example.org/v1/list-evidence'),
  evidenceDownloadEndpoint: Uri.parse(
    'https://example.org/v1/download-evidence',
  ),
  exportEndpoint: Uri.parse('https://example.org/v1/create-draft-export'),
  exportDownloadEndpoint: Uri.parse(
    'https://example.org/v1/download-draft-export',
  ),
  tokenProvider: tokenProvider ?? () async => 'fictional-token',
  transport: transport,
  now: now ?? () => DateTime.parse(f.stamp),
  timeout: timeout,
);
Future<ExportArtifactMetadata> create(
  DraftExportApiClient api, {
  ExportSelectionState? selection,
  ExportSelectionState Function()? current,
  String key = 'fictional-key',
}) {
  final input = selection ?? state();
  return api.createDraftExport(
    input.snapshot,
    context: input.context,
    answerRevision: input.answerRevision,
    catalog: input.catalog,
    selectedEvidence: input.selectedEvidence,
    generationKey: key,
    currentState: current ?? () => input,
  );
}

Future<List<int>> download(
  DraftExportApiClient api, {
  ExportSelectionState Function()? current,
  ExportArtifactMetadata Function()? currentArtifact,
  ExportArtifactMetadata? artifact,
}) {
  final input = artifact ?? f.artifact();
  return api.downloadDraftExport(
    input,
    currentState: current ?? state,
    currentArtifact: currentArtifact ?? () => input,
  );
}

void main() {
  test(
    'metadata and binary requests use exact authenticated bodies and explicit Accept',
    () async {
      var tokens = 0;
      final transport = _Transport(
        (request) async => switch (request.endpoint.path) {
          '/v1/list-evidence' => jsonResponse(f.catalogJson()),
          '/v1/download-evidence' => binary(f.png, 'image/png'),
          '/v1/create-draft-export' => jsonResponse(f.artifactJson()),
          _ => binary(f.pdf, 'application/pdf'),
        },
      );
      final api = client(
        transport,
        tokenProvider: () async => 'token-${++tokens}',
      );
      final catalog = await api.listEvidence(
        f.snapshot(),
        currentCase: f.snapshot,
        currentCatalog: () => null,
      );
      final image = await api.downloadEvidence(
        f.snapshot(),
        catalog: catalog,
        evidence: catalog.evidence.single,
        currentCase: f.snapshot,
        currentCatalog: () => catalog,
      );
      final artifact = await create(api);
      final pdf = await download(api, artifact: artifact);
      expect(image, f.png);
      expect(pdf, f.pdf);
      expect(() => pdf.clear(), throwsUnsupportedError);
      expect(transport.requests.map((r) => r.accept), [
        'application/json',
        'image/png',
        'application/json',
        'application/pdf',
      ]);
      expect(transport.requests.map((r) => r.bearerToken), [
        'token-1',
        'token-2',
        'token-3',
        'token-4',
      ]);
      final bodies = transport.requests
          .map((r) => jsonDecode(utf8.decode(r.body)))
          .toList();
      expect(bodies[0], {
        'schemaVersion': '1',
        'caseId': 'fictional-case',
        'expectedCaseRevision': 2,
      });
      expect(bodies[1], {
        ...bodies[0],
        'expectedCatalogRevision': 1,
        'evidenceId': 'fictional-evidence',
        'expectedEvidenceRevision': 1,
      });
      expect(bodies[2], {
        ...bodies[0],
        'programId': 'fictional-program',
        'expectedFormContextId': f.digest,
        'expectedAnswerRevision': 0,
        'expectedEvidenceCatalogRevision': 1,
        'generationKey': 'fictional-key',
        'selectedEvidence': [f.selectionJson()],
      });
      expect(bodies[3], {...bodies[0], 'artifactId': 'fictional-artifact'});
      expect(transport.requests[1].maxResponseBytes, 24 * 1024 * 1024);
      expect(transport.requests[3].maxResponseBytes, 32 * 1024 * 1024);
      expect(transport.cancellations, 4);
    },
  );
  test('unchanged transport callers keep JSON Accept by default', () {
    final request = MatchingHttpRequest(
      endpoint: Uri.parse('https://example.org'),
      bearerToken: 'token',
      body: [],
      maxResponseBytes: 1,
    );
    expect(request.accept, 'application/json');
  });
  test(
    'empty explicit selection and multiple images for one finding are supported',
    () async {
      final empty = f.artifactJson()..['selectedEvidence'] = [];
      expect(
        (await create(
          client(_Transport((_) async => jsonResponse(empty))),
          selection: state(selected: []),
        )).selectedEvidence,
        isEmpty,
      );
      final catalog = f.catalogJson();
      (catalog['evidence'] as List).add(
        f.descriptorJson(id: 'second-evidence'),
      );
      final artifact = f.artifactJson();
      (artifact['selectedEvidence'] as List).add({
        ...Map<String, Object?>.from(
          (artifact['selectedEvidence'] as List).single as Map,
        ),
        'evidenceId': 'second-evidence',
      });
      final selected = [
        f.selection(),
        EvidenceSelection.fromJson(f.selectionJson(id: 'second-evidence')),
      ];
      final result = await create(
        client(_Transport((_) async => jsonResponse(artifact))),
        selection: state(
          catalog: EvidenceCatalog.fromJson(catalog),
          selected: selected,
        ),
      );
      expect(result.selectedEvidence, hasLength(2));
    },
  );
  test(
    'invalid generation keys unreviewed associations and stale selected revisions reject before I/O',
    () async {
      final transport = _Transport((_) async => jsonResponse(f.artifactJson()));
      final api = client(transport);
      for (final key in [
        'short',
        'fictional-key\n',
        'fictional-key\r\n',
        List.filled(129, 'a').join(),
      ]) {
        await expectLater(
          create(api, key: key),
          throwsA(failure('INVALID_REQUEST')),
        );
      }
      for (final input in [
        state(review: 'needs_review'),
        state(answerRevision: -1),
        state(selected: [f.selection(), f.selection()]),
        state(
          selected: [EvidenceSelection.fromJson(f.selectionJson(revision: 2))],
        ),
      ]) {
        await expectLater(
          create(api, selection: input),
          throwsA(failure('INVALID_REQUEST')),
        );
      }
      expect(transport.requests, isEmpty);
    },
  );
  test(
    'missing malformed oversized and failing tokens never dispatch',
    () async {
      for (final token in [
        null,
        '',
        'token\n',
        'Bearer token',
        List.filled(4097, 'a').join(),
      ]) {
        final transport = _Transport(
          (_) async => jsonResponse(f.catalogJson()),
        );
        await expectLater(
          client(transport, tokenProvider: () async => token).listEvidence(
            f.snapshot(),
            currentCase: f.snapshot,
            currentCatalog: () => null,
          ),
          throwsA(failure('UNAUTHENTICATED')),
        );
        expect(transport.requests, isEmpty);
      }
      final transport = _Transport((_) async => jsonResponse(f.catalogJson()));
      await expectLater(
        client(
          transport,
          tokenProvider: () async => throw StateError('private-token'),
        ).listEvidence(
          f.snapshot(),
          currentCase: f.snapshot,
          currentCatalog: () => null,
        ),
        throwsA(failure('UNAUTHENTICATED')),
      );
    },
  );
  test(
    'case changes during token acquisition never dispatch metadata or bytes',
    () async {
      var current = f.snapshot();
      final transport = _Transport((_) async => jsonResponse(f.catalogJson()));
      final api = client(
        transport,
        tokenProvider: () async {
          current = f.snapshot(revision: 3);
          return 'token';
        },
      );
      await expectLater(
        api.listEvidence(
          f.snapshot(),
          currentCase: () => current,
          currentCatalog: () => null,
        ),
        throwsA(failure('STALE_RESPONSE')),
      );
      expect(transport.requests, isEmpty);
    },
  );
  test('late evidence catalog must match case finding and revision', () async {
    for (final json in [
      f.catalogJson()..['caseRevision'] = 3,
      f.catalogJson()
        ..['evidence'] = [f.descriptorJson()..['findingId'] = 'other-finding'],
    ]) {
      await expectLater(
        client(_Transport((_) async => jsonResponse(json))).listEvidence(
          f.snapshot(),
          currentCase: f.snapshot,
          currentCatalog: () => null,
        ),
        throwsA(failure('STALE_RESPONSE')),
      );
    }
    var current = f.snapshot();
    final api = client(
      _Transport((_) async {
        current = f.snapshot(revision: 3);
        return jsonResponse(f.catalogJson());
      }),
    );
    await expectLater(
      api.listEvidence(
        f.snapshot(),
        currentCase: () => current,
        currentCatalog: () => null,
      ),
      throwsA(failure('STALE_RESPONSE')),
    );
  });
  test(
    'list rejects a late catalog older than the latest locally known catalog',
    () async {
      for (final advance in [false, true]) {
        var current = EvidenceCatalog.fromJson(
          f.catalogJson()..['catalogRevision'] = advance ? 1 : 2,
        );
        final transport = _Transport((_) async {
          current = EvidenceCatalog.fromJson(
            f.catalogJson()..['catalogRevision'] = 2,
          );
          return jsonResponse(f.catalogJson());
        });
        await expectLater(
          client(transport).listEvidence(
            f.snapshot(),
            currentCase: f.snapshot,
            currentCatalog: () => current,
          ),
          throwsA(failure('STALE_RESPONSE')),
        );
      }
      var current = f.catalog();
      final result =
          await client(
            _Transport((_) async {
              current = EvidenceCatalog.fromJson(
                f.catalogJson()..['catalogRevision'] = 2,
              );
              return jsonResponse(f.catalogJson()..['catalogRevision'] = 3);
            }),
          ).listEvidence(
            f.snapshot(),
            currentCase: f.snapshot,
            currentCatalog: () => current,
          );
      expect(result.catalogRevision, 3);
      expect(current.catalogRevision, 2, reason: 'No automatic state adoption');
    },
  );

  test(
    'evidence download rejects changed catalog after awaiting bytes',
    () async {
      var current = f.catalog();
      final api = client(
        _Transport((_) async {
          current = EvidenceCatalog.fromJson(
            f.catalogJson()..['catalogRevision'] = 2,
          );
          return binary(f.png, 'image/png');
        }),
      );
      await expectLater(
        api.downloadEvidence(
          f.snapshot(),
          catalog: f.catalog(),
          evidence: f.catalog().evidence.single,
          currentCase: f.snapshot,
          currentCatalog: () => current,
        ),
        throwsA(failure('STALE_RESPONSE')),
      );
    },
  );
  test('all selected state changes discard late export metadata', () async {
    final changed = [
      state(answerRevision: 1),
      state(selected: []),
      state(caseRevision: 3),
      state(
        context: FormAnswerContext.fromJson(
          f.contextJson()..['programId'] = 'other-program',
        ),
      ),
      state(
        context: FormAnswerContext.fromJson(
          f.contextJson()..['mappingVersion'] = 'mapping-v2',
        ),
      ),
      state(
        catalog: EvidenceCatalog.fromJson(
          f.catalogJson()..['catalogRevision'] = 2,
        ),
      ),
    ];
    for (final replacement in changed) {
      var current = state();
      final api = client(
        _Transport((_) async {
          current = replacement;
          return jsonResponse(f.artifactJson());
        }),
      );
      await expectLater(
        create(api, current: () => current),
        throwsA(failure('STALE_RESPONSE')),
      );
    }
  });
  test(
    'selection list input is detached and current-state review still governs',
    () async {
      final selected = [f.selection()];
      final stable = state();
      final transport = _Transport((_) async => jsonResponse(f.artifactJson()));
      final api = client(
        transport,
        tokenProvider: () async {
          selected.clear();
          return 'token';
        },
      );
      final artifact = await api.createDraftExport(
        f.snapshot(),
        context: f.context(),
        answerRevision: 0,
        catalog: f.catalog(),
        selectedEvidence: selected,
        generationKey: 'fictional-key',
        currentState: () => stable,
      );
      expect(artifact.selectedEvidence, hasLength(1));
    },
  );
  test(
    'artifact metadata must match requested full known context and selected digests',
    () async {
      for (final update in [
        {'caseRevision': 3},
        {'programId': 'other'},
        {'answerRevision': 1},
        {'evidenceCatalogRevision': 2},
        {'formContextId': f.digest.replaceAll('a', 'b')},
        {'formVersion': 'form-v2'},
        {'selectedEvidence': <Object>[]},
      ]) {
        await expectLater(
          create(
            client(
              _Transport(
                (_) async => jsonResponse(f.artifactJson()..addAll(update)),
              ),
            ),
          ),
          throwsA(failure('STALE_RESPONSE')),
        );
      }
      final json = f.artifactJson();
      ((json['selectedEvidence'] as List).single as Map)['sha256'] = f.digest;
      await expectLater(
        create(client(_Transport((_) async => jsonResponse(json)))),
        throwsA(failure('STALE_RESPONSE')),
      );
    },
  );
  test(
    'PDF and PNG byte size magic and digest mismatches are rejected',
    () async {
      for (final bytes in [
        f.pdf.sublist(0, f.pdf.length - 1),
        [0, ...f.pdf.skip(1)],
        [...f.pdf.take(f.pdf.length - 1), 0],
      ]) {
        await expectLater(
          download(
            client(_Transport((_) async => binary(bytes, 'application/pdf'))),
          ),
          throwsA(failure('UNEXPECTED_RESPONSE')),
        );
      }
      final malicious = List<int>.filled(f.pdf.length, 120);
      final json = f.artifactJson()
        ..['sha256'] = hashing.sha256.convert(malicious).toString();
      await expectLater(
        download(
          client(_Transport((_) async => binary(malicious, 'application/pdf'))),
          artifact: ExportArtifactMetadata.fromJson(json),
        ),
        throwsA(failure('UNEXPECTED_RESPONSE')),
      );
      final api = client(
        _Transport(
          (_) async =>
              binary([...f.png.take(f.png.length - 1), 0], 'image/png'),
        ),
      );
      await expectLater(
        api.downloadEvidence(
          f.snapshot(),
          catalog: f.catalog(),
          evidence: f.catalog().evidence.single,
          currentCase: f.snapshot,
          currentCatalog: f.catalog,
        ),
        throwsA(failure('UNEXPECTED_RESPONSE')),
      );
    },
  );
  test(
    'PDF expiry before dispatch and after download discards all bytes',
    () async {
      var clock = DateTime.parse(f.stamp);
      final transport = _Transport((_) async {
        clock = DateTime.parse(f.artifact().expiresAt);
        return binary(f.pdf, 'application/pdf');
      });
      await expectLater(
        download(client(transport, now: () => clock)),
        throwsA(failure('EXPORT_EXPIRED')),
      );
      expect(transport.requests, hasLength(1));
      final expired = _Transport((_) async => binary(f.pdf, 'application/pdf'));
      await expectLater(
        download(client(expired, now: () => clock)),
        throwsA(failure('EXPORT_EXPIRED')),
      );
      expect(expired.requests, isEmpty);
    },
  );
  test('changed artifact and case reject late valid PDF bytes', () async {
    var artifact = f.artifact();
    final api = client(
      _Transport((_) async {
        artifact = ExportArtifactMetadata.fromJson(
          f.artifactJson()..['artifactId'] = 'new-artifact',
        );
        return binary(f.pdf, 'application/pdf');
      }),
    );
    await expectLater(
      download(api, currentArtifact: () => artifact),
      throwsA(failure('STALE_RESPONSE')),
    );
    var current = state();
    final changed = client(
      _Transport((_) async {
        current = state(answerRevision: 1);
        return binary(f.pdf, 'application/pdf');
      }),
    );
    await expectLater(
      download(changed, current: () => current),
      throwsA(failure('STALE_RESPONSE')),
    );
  });
  test(
    'create timeout cancels and never generates a replacement key or retries',
    () async {
      final pending = Completer<MatchingHttpResponse>();
      final transport = _Transport((_) => pending.future);
      await expectLater(
        create(client(transport, timeout: const Duration(milliseconds: 15))),
        throwsA(failure('TIMEOUT')),
      );
      expect(transport.requests, hasLength(1));
      expect(transport.cancellations, 1);
      pending.complete(jsonResponse(f.artifactJson()));
      await Future<void>.delayed(Duration.zero);
      expect(transport.requests, hasLength(1));
    },
  );
  test(
    'known server errors use safe local text and exact status mappings',
    () async {
      const errors = {
        'EVIDENCE_CONFLICT': 409,
        'EXPORT_GENERATION_CONFLICT': 409,
        'EXPORT_EXPIRED': 410,
        'EXPORT_REVIEW_REQUIRED': 422,
        'EXPORT_BUSY': 429,
        'STORAGE_LIMIT_REACHED': 507,
        'FORM_NOT_AVAILABLE': 409,
        'FORM_CONTEXT_MISMATCH': 409,
        'FORM_ANSWER_REVISION_MISMATCH': 409,
        'FORM_ANSWERS_STALE': 409,
        'ARTIFACT_NOT_FOUND': 404,
      };
      for (final error in errors.entries) {
        final transport = _Transport(
          (_) async => jsonResponse({
            'schemaVersion': '1',
            'error': {
              'code': error.key,
              'message': 'private-record /private/path token',
            },
          }, status: error.value),
        );
        await expectLater(
          download(client(transport)),
          throwsA(
            failure(error.key).having(
              (e) => e.message,
              'sanitized',
              isNot(contains('private-record')),
            ),
          ),
        );
      }
    },
  );
  test(
    'unknown errors raw failures invalid JSON and media types cannot leak details',
    () async {
      for (final response in [
        jsonResponse({
          'schemaVersion': '1',
          'error': {'code': 'APPROVED', 'message': 'private'},
        }, status: 409),
        binary(utf8.encode('private'), 'application/json'),
        binary(f.pdf, 'text/html'),
        jsonResponse({
          'schemaVersion': '1',
          'error': {'code': 'ARTIFACT_NOT_FOUND', 'message': 'private'},
        }, status: 500),
      ]) {
        await expectLater(
          download(client(_Transport((_) async => response))),
          throwsA(failure('UNEXPECTED_RESPONSE')),
        );
      }
      await expectLater(
        download(
          client(_Transport((_) async => throw StateError('private token'))),
        ),
        throwsA(failure('NETWORK_ERROR')),
      );
    },
  );
  test(
    'redirect and streamed size failures are bounded and cancelled',
    () async {
      for (final failureType in MatchingTransportFailure.values) {
        final transport = _Transport(
          (_) async => throw MatchingTransportException(failureType),
        );
        await expectLater(
          download(client(transport)),
          throwsA(isA<MatchingApiException>()),
        );
        expect(transport.cancellations, 1);
      }
      await expectLater(
        download(
          client(
            _Transport(
              (_) async => MatchingHttpResponse(
                statusCode: 302,
                contentType: null,
                body: [],
              ),
            ),
          ),
        ),
        throwsA(failure('REDIRECT_BLOCKED')),
      );
    },
  );
  test(
    'fixed endpoints prohibit credentials queries fragments and other origins',
    () {
      for (final endpoint in [
        'https://other.org/v1/download-draft-export',
        'https://example.org/v1/download-draft-export?token=x',
        'https://user@example.org/v1/download-draft-export',
        'https://example.org/v1/download-draft-export#x',
        'https://example.org/v1/download-draft-export/',
        'http://example.org/v1/download-draft-export',
      ]) {
        expect(
          () => DraftExportApiClient(
            evidenceEndpoint: Uri.parse('https://example.org/v1/list-evidence'),
            evidenceDownloadEndpoint: Uri.parse(
              'https://example.org/v1/download-evidence',
            ),
            exportEndpoint: Uri.parse(
              'https://example.org/v1/create-draft-export',
            ),
            exportDownloadEndpoint: Uri.parse(endpoint),
            tokenProvider: () async => 'token',
            transport: _Transport((_) async => jsonResponse({})),
          ),
          throwsArgumentError,
        );
      }
      for (final timeout in [Duration.zero, const Duration(seconds: 16)]) {
        expect(
          () => client(
            _Transport((_) async => jsonResponse({})),
            timeout: timeout,
          ),
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
