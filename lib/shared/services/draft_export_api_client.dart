import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart' as hashing;

import '../models/contracts.dart';
import '../models/draft_export.dart';
import '../models/evidence.dart';
import '../models/export_contract_values.dart';
import '../models/form_answers.dart';
import 'matching_api_client.dart';

class ExportSelectionState {
  ExportSelectionState({
    required this.snapshot,
    required this.context,
    required this.answerRevision,
    required this.catalog,
    required List<EvidenceSelection> selectedEvidence,
  }) : selectedEvidence = List.unmodifiable(selectedEvidence);
  final CaseSnapshot snapshot;
  final FormAnswerContext context;
  final int answerRevision;
  final EvidenceCatalog catalog;
  final List<EvidenceSelection> selectedEvidence;
}

class DraftExportApiClient {
  DraftExportApiClient({
    required Uri evidenceEndpoint,
    required Uri evidenceDownloadEndpoint,
    required Uri exportEndpoint,
    required Uri exportDownloadEndpoint,
    required MatchingTokenProvider tokenProvider,
    required MatchingTransport transport,
    DateTime Function()? now,
    this.timeout = const Duration(seconds: 15),
    bool allowInsecureLoopback = false,
    bool allowAndroidEmulatorLoopback = false,
  }) : _evidence = _endpoint(
         evidenceEndpoint,
         '/v1/list-evidence',
         allowInsecureLoopback,
         allowAndroidEmulatorLoopback,
       ),
       _evidenceDownload = _endpoint(
         evidenceDownloadEndpoint,
         '/v1/download-evidence',
         allowInsecureLoopback,
         allowAndroidEmulatorLoopback,
       ),
       _export = _endpoint(
         exportEndpoint,
         '/v1/create-draft-export',
         allowInsecureLoopback,
         allowAndroidEmulatorLoopback,
       ),
       _exportDownload = _endpoint(
         exportDownloadEndpoint,
         '/v1/download-draft-export',
         allowInsecureLoopback,
         allowAndroidEmulatorLoopback,
       ),
       _tokenProvider = tokenProvider,
       _transport = transport,
       _now = now ?? DateTime.now {
    if (timeout <= Duration.zero ||
        timeout > const Duration(seconds: 15) ||
        {
              _evidence.origin,
              _evidenceDownload.origin,
              _export.origin,
              _exportDownload.origin,
            }.length !=
            1) {
      throw ArgumentError(
        'Use same-origin endpoints and a timeout of at most 15 seconds.',
      );
    }
  }
  final Uri _evidence, _evidenceDownload, _export, _exportDownload;
  final MatchingTokenProvider _tokenProvider;
  final MatchingTransport _transport;
  final DateTime Function() _now;
  final Duration timeout;

  Future<EvidenceCatalog> listEvidence(
    CaseSnapshot snapshot, {
    required CaseSnapshot Function() currentCase,
    required EvidenceCatalog? Function() currentCatalog,
  }) async {
    final body = _caseRequest(snapshot);
    var latestCatalogRevision = 0;
    void guard() {
      _caseGuard(snapshot.caseId, snapshot.revision, currentCase);
      try {
        final current = currentCatalog();
        if (current != null) {
          final parsed = EvidenceCatalog.fromJson(current.toJson());
          if (!parsed.belongsTo(snapshot)) throw const FormatException();
          if (parsed.catalogRevision > latestCatalogRevision) {
            latestCatalogRevision = parsed.catalogRevision;
          }
        }
      } catch (_) {
        throw _error('STALE_RESPONSE');
      }
    }

    final response = await _post(_evidence, body, guard: guard);
    guard();
    final EvidenceCatalog result;
    try {
      result = EvidenceCatalog.fromJson(_json(response));
    } catch (_) {
      throw _error('UNEXPECTED_RESPONSE');
    }
    guard();
    if (!result.belongsTo(snapshot) ||
        result.catalogRevision < latestCatalogRevision) {
      throw _error('STALE_RESPONSE');
    }
    return result;
  }

  Future<List<int>> downloadEvidence(
    CaseSnapshot snapshot, {
    required EvidenceCatalog catalog,
    required EvidenceDescriptor evidence,
    required CaseSnapshot Function() currentCase,
    required EvidenceCatalog Function() currentCatalog,
  }) async {
    final body = _caseRequest(snapshot);
    late final EvidenceCatalog captured;
    late final EvidenceDescriptor descriptor;
    try {
      captured = EvidenceCatalog.fromJson(catalog.toJson());
      descriptor = EvidenceDescriptor.fromJson(evidence.toJson());
      if (!captured.belongsTo(snapshot) ||
          !captured.evidence.any(
            (item) => _key(item.toJson()) == _key(descriptor.toJson()),
          )) {
        ExportContractValues.invalid();
      }
    } catch (_) {
      throw _error('INVALID_REQUEST', 400);
    }
    void guard() {
      _caseGuard(snapshot.caseId, snapshot.revision, currentCase);
      try {
        if (_key(currentCatalog().toJson()) != _key(captured.toJson())) {
          throw const FormatException();
        }
      } catch (_) {
        throw _error('STALE_RESPONSE');
      }
    }

    final response = await _post(
      _evidenceDownload,
      {
        ...body,
        'expectedCatalogRevision': captured.catalogRevision,
        'evidenceId': descriptor.evidenceId,
        'expectedEvidenceRevision': descriptor.evidenceRevision,
      },
      guard: guard,
      accept: 'image/png',
      maxBytes: maxEvidenceBytes,
    );
    final bytes = _binary(
      response,
      descriptor.byteLength,
      descriptor.sha256,
      const [137, 80, 78, 71, 13, 10, 26, 10],
    );
    guard();
    return bytes;
  }

  Future<ExportArtifactMetadata> createDraftExport(
    CaseSnapshot snapshot, {
    required FormAnswerContext context,
    required int answerRevision,
    required EvidenceCatalog catalog,
    required List<EvidenceSelection> selectedEvidence,
    required String generationKey,
    required ExportSelectionState Function() currentState,
  }) async {
    late final ExportSelectionState captured;
    try {
      captured = _capture(
        ExportSelectionState(
          snapshot: snapshot,
          context: context,
          answerRevision: answerRevision,
          catalog: catalog,
          selectedEvidence: selectedEvidence,
        ),
      );
      if (generationKey.length < 8 ||
          generationKey.length > 128 ||
          RegExp(r'[^A-Za-z0-9_-]').hasMatch(generationKey)) {
        ExportContractValues.invalid();
      }
    } catch (_) {
      throw _error('INVALID_REQUEST', 400);
    }
    void guard() => _stateGuard(captured, currentState);
    final response = await _post(_export, {
      ..._caseRequest(captured.snapshot),
      'programId': captured.context.programId,
      'expectedFormContextId': captured.context.formContextId,
      'expectedAnswerRevision': captured.answerRevision,
      'expectedEvidenceCatalogRevision': captured.catalog.catalogRevision,
      'generationKey': generationKey,
      'selectedEvidence': captured.selectedEvidence
          .map((item) => item.toJson())
          .toList(),
    }, guard: guard);
    guard();
    final ExportArtifactMetadata artifact;
    try {
      artifact = ExportArtifactMetadata.fromJson(_json(response));
    } catch (_) {
      throw _error('UNEXPECTED_RESPONSE');
    }
    _artifactGuard(artifact, captured);
    _timeGuard(artifact);
    return artifact;
  }

  Future<List<int>> downloadDraftExport(
    ExportArtifactMetadata artifact, {
    required ExportSelectionState Function() currentState,
    required ExportArtifactMetadata Function() currentArtifact,
  }) async {
    late final ExportArtifactMetadata captured;
    late final ExportSelectionState state;
    try {
      captured = ExportArtifactMetadata.fromJson(artifact.toJson());
      state = _capture(currentState());
    } catch (_) {
      throw _error('INVALID_REQUEST', 400);
    }
    void guard() {
      _stateGuard(state, currentState);
      _artifactGuard(captured, state);
      try {
        if (_key(currentArtifact().toJson()) != _key(captured.toJson())) {
          throw const FormatException();
        }
      } catch (_) {
        throw _error('STALE_RESPONSE');
      }
      _timeGuard(captured);
    }

    final response = await _post(
      _exportDownload,
      {
        'schemaVersion': '1',
        'caseId': captured.caseId,
        'expectedCaseRevision': captured.caseRevision,
        'artifactId': captured.artifactId,
      },
      guard: guard,
      accept: 'application/pdf',
      maxBytes: maxDraftExportBytes,
    );
    final bytes = _binary(
      response,
      captured.byteLength,
      captured.sha256,
      const [37, 80, 68, 70, 45],
    );
    guard();
    return bytes;
  }

  void _timeGuard(ExportArtifactMetadata artifact) {
    try {
      if (!artifact.isAvailableAt(_now().toUtc())) {
        throw const FormatException();
      }
    } catch (_) {
      throw _error('EXPORT_EXPIRED', 410);
    }
  }

  Future<MatchingHttpResponse> _post(
    Uri endpoint,
    Map<String, Object?> body, {
    required void Function() guard,
    String accept = 'application/json',
    int maxBytes = 1024 * 1024,
  }) async {
    final bytes = utf8.encode(jsonEncode(body));
    if (bytes.length > 16 * 1024) throw _error('PAYLOAD_TOO_LARGE', 413);
    guard();
    final elapsed = Stopwatch()..start();
    final String? token;
    try {
      token = await _tokenProvider().timeout(timeout);
    } on TimeoutException {
      throw _error('TIMEOUT');
    } catch (_) {
      throw _error('UNAUTHENTICATED', 401);
    }
    if (token == null ||
        token.length > 4096 ||
        RegExp(r'^[A-Za-z0-9\-._~+/]+=*$').stringMatch(token) != token) {
      throw _error('UNAUTHENTICATED', 401);
    }
    guard();
    final remaining = timeout - elapsed.elapsed;
    if (remaining <= Duration.zero) throw _error('TIMEOUT');
    MatchingExchange? exchange;
    late final MatchingHttpResponse response;
    try {
      exchange = _transport.post(
        MatchingHttpRequest(
          endpoint: endpoint,
          bearerToken: token,
          body: bytes,
          maxResponseBytes: maxBytes,
          accept: accept,
        ),
      );
      response = await exchange.response.timeout(remaining);
    } on TimeoutException {
      throw _error('TIMEOUT');
    } on MatchingTransportException catch (error) {
      throw _error(switch (error.failure) {
        MatchingTransportFailure.network => 'NETWORK_ERROR',
        MatchingTransportFailure.responseTooLarge => 'RESPONSE_TOO_LARGE',
        MatchingTransportFailure.redirectBlocked => 'REDIRECT_BLOCKED',
      });
    } catch (_) {
      throw _error('NETWORK_ERROR');
    } finally {
      try {
        exchange?.cancel();
      } catch (_) {
        // ignore: empty_catches
      }
    }
    guard();
    if (response.body.length > maxBytes) throw _error('RESPONSE_TOO_LARGE');
    if (response.statusCode >= 300 && response.statusCode < 400) {
      throw _error('REDIRECT_BLOCKED');
    }
    final mediaType = response.contentType
        ?.split(';')
        .first
        .trim()
        .toLowerCase();
    if (response.statusCode != 200) {
      if (mediaType != 'application/json' ||
          response.body.length > 1024 * 1024) {
        throw _error('UNEXPECTED_RESPONSE');
      }
      throw _apiError(
        response.statusCode,
        _json(response),
      ).withRetryAfter(response.retryAfter);
    }
    if (mediaType != accept) throw _error('UNEXPECTED_RESPONSE');
    return response;
  }
}

Map<String, Object?> _caseRequest(CaseSnapshot snapshot) {
  try {
    return {
      'schemaVersion': '1',
      'caseId': ExportContractValues.id(snapshot.caseId),
      'expectedCaseRevision': ExportContractValues.integer(snapshot.revision),
    };
  } catch (_) {
    throw _error('INVALID_REQUEST', 400);
  }
}

void _caseGuard(String id, int revision, CaseSnapshot Function() current) {
  try {
    final snapshot = current();
    if (snapshot.caseId != id || snapshot.revision != revision) {
      throw const FormatException();
    }
  } catch (_) {
    throw _error('STALE_RESPONSE');
  }
}

ExportSelectionState _capture(ExportSelectionState value) {
  _caseRequest(value.snapshot);
  final context = FormAnswerContext.fromJson(value.context.toJson());
  final catalog = EvidenceCatalog.fromJson(value.catalog.toJson());
  final selected = EvidenceSelection.parseList(
    value.selectedEvidence.map((item) => item.toJson()).toList(),
  );
  final revision = ExportContractValues.integer(value.answerRevision, min: 0);
  if (!catalog.belongsTo(value.snapshot)) ExportContractValues.invalid();
  for (final item in selected) {
    final matches = catalog.evidence.where(
      (evidence) => evidence.evidenceId == item.evidenceId,
    );
    if (matches.length != 1 ||
        matches.single.evidenceRevision != item.expectedEvidenceRevision ||
        !value.snapshot.findings.any(
          (finding) =>
              finding.id == matches.single.findingId &&
              finding.reviewState == 'confirmed',
        )) {
      ExportContractValues.invalid();
    }
  }
  return ExportSelectionState(
    snapshot: value.snapshot,
    context: context,
    answerRevision: revision,
    catalog: catalog,
    selectedEvidence: selected,
  );
}

String _stateKey(ExportSelectionState state) => _key({
  'caseId': state.snapshot.caseId,
  'revision': state.snapshot.revision,
  'context': state.context.toJson(),
  'answerRevision': state.answerRevision,
  'catalog': state.catalog.toJson(),
  'selectedEvidence': state.selectedEvidence
      .map((item) => item.toJson())
      .toList(),
});
void _stateGuard(
  ExportSelectionState captured,
  ExportSelectionState Function() current,
) {
  try {
    if (_stateKey(_capture(current())) != _stateKey(captured)) {
      throw const FormatException();
    }
  } catch (_) {
    throw _error('STALE_RESPONSE');
  }
}

void _artifactGuard(
  ExportArtifactMetadata artifact,
  ExportSelectionState state,
) {
  if (artifact.caseId != state.snapshot.caseId ||
      artifact.caseRevision != state.snapshot.revision ||
      artifact.programId != state.context.programId ||
      artifact.formContextId != state.context.formContextId ||
      artifact.formVersion != state.context.formVersion ||
      artifact.mappingVersion != state.context.mappingVersion ||
      artifact.answerRevision != state.answerRevision ||
      artifact.evidenceCatalogRevision != state.catalog.catalogRevision ||
      artifact.selectedEvidence.length != state.selectedEvidence.length) {
    throw _error('STALE_RESPONSE');
  }
  for (var i = 0; i < artifact.selectedEvidence.length; i++) {
    final returned = artifact.selectedEvidence[i],
        selected = state.selectedEvidence[i];
    final evidence = state.catalog.evidence.singleWhere(
      (item) => item.evidenceId == selected.evidenceId,
    );
    if (returned.evidenceId != selected.evidenceId ||
        returned.evidenceRevision != selected.expectedEvidenceRevision ||
        returned.sha256 != evidence.sha256 ||
        returned.findingId != evidence.findingId) {
      throw _error('STALE_RESPONSE');
    }
  }
}

List<int> _binary(
  MatchingHttpResponse response,
  int length,
  String digest,
  List<int> magic,
) {
  try {
    final bytes = response.body;
    if (bytes.length != length ||
        bytes.length < magic.length ||
        bytes.any((byte) => byte < 0 || byte > 255) ||
        Iterable.generate(magic.length).any((i) => bytes[i] != magic[i]) ||
        hashing.sha256.convert(bytes).toString() != digest) {
      throw const FormatException();
    }
    return List.unmodifiable(bytes);
  } catch (_) {
    throw _error('UNEXPECTED_RESPONSE');
  }
}

Object? _json(MatchingHttpResponse response) {
  try {
    return jsonDecode(utf8.decode(response.body));
  } catch (_) {
    throw _error('UNEXPECTED_RESPONSE');
  }
}

String _key(Object? value) {
  if (value is List) return '[${value.map(_key).join(',')}]';
  if (value is Map<String, Object?>) {
    final keys = value.keys.toList()..sort();
    return '{${keys.map((key) => '${jsonEncode(key)}:${_key(value[key])}').join(',')}}';
  }
  return jsonEncode(value);
}

MatchingApiException _error(String code, [int? status]) =>
    MatchingApiException.forCode(code, statusCode: status);
MatchingApiException _apiError(int status, Object? json) {
  const codes = {
    400: {'INVALID_REQUEST'},
    401: {'UNAUTHENTICATED'},
    404: {
      'CASE_NOT_FOUND',
      'PROGRAM_NOT_FOUND',
      'ARTIFACT_NOT_FOUND',
      'NOT_FOUND',
    },
    409: {
      'CASE_REVISION_MISMATCH',
      'EVIDENCE_CONFLICT',
      'EXPORT_GENERATION_CONFLICT',
      'FORM_NOT_AVAILABLE',
      'INTAKE_REQUIRES_V2',
      'ANNOTATIONS_REQUIRE_V2',
      'FORM_CONTEXT_MISMATCH',
      'FORM_ANSWER_REVISION_MISMATCH',
      'FORM_ANSWERS_STALE',
    },
    410: {'EXPORT_EXPIRED'},
    422: {'EXPORT_REVIEW_REQUIRED'},
    429: {'RATE_LIMITED', 'EXPORT_BUSY'},
    507: {'STORAGE_LIMIT_REACHED'},
    413: {'PAYLOAD_TOO_LARGE'},
    415: {'UNSUPPORTED_MEDIA_TYPE'},
    405: {'METHOD_NOT_ALLOWED'},
    500: {'INTERNAL_ERROR'},
    503: {'SERVICE_UNAVAILABLE'},
  };
  try {
    final value = ExportContractValues.object(json, {'schemaVersion', 'error'});
    final error = ExportContractValues.object(value['error'], {
      'code',
      'message',
    });
    if (value['schemaVersion'] != '1' ||
        error['message'] is! String ||
        (error['message'] as String).isEmpty ||
        !((codes[status] ?? {}).contains(error['code']))) {
      throw const FormatException();
    }
    return _error(error['code'] as String, status);
  } catch (_) {
    return _error('UNEXPECTED_RESPONSE');
  }
}

Uri _endpoint(
  Uri endpoint,
  String path,
  bool allowLoopback,
  bool allowEmulator,
) {
  final local =
      {'localhost', '127.0.0.1', '::1'}.contains(endpoint.host.toLowerCase()) ||
      (allowEmulator && endpoint.host == '10.0.2.2');
  if (!endpoint.hasAuthority ||
      endpoint.host.isEmpty ||
      endpoint.userInfo.isNotEmpty ||
      endpoint.hasQuery ||
      endpoint.hasFragment ||
      endpoint.path != path ||
      endpoint.port < 1 ||
      endpoint.port > 65535 ||
      !(endpoint.scheme == 'https' ||
          (endpoint.scheme == 'http' && allowLoopback && local))) {
    throw ArgumentError(
      'Use fixed same-origin HTTPS endpoints; HTTP requires explicit loopback opt-in.',
    );
  }
  return endpoint;
}
