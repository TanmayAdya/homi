import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../models/case_draft.dart';
import '../models/contracts.dart';
import '../models/evidence.dart';
import '../models/evidence_mutation.dart';
import '../models/export_contract_values.dart';
import 'matching_api_client.dart';

const maxOriginalImageBytes = 8 * 1024 * 1024;
const maxImageUploadRequestBytes =
    ((maxOriginalImageBytes + 2) ~/ 3) * 4 + 16384;

class CaseEvidenceApiClient {
  CaseEvidenceApiClient({
    required Uri createCaseEndpoint,
    required Uri saveCaseEndpoint,
    required Uri caseEndpoint,
    required Uri uploadEvidenceEndpoint,
    required Uri deleteEvidenceEndpoint,
    required MatchingTokenProvider tokenProvider,
    required MatchingTransport transport,
    this.timeout = const Duration(seconds: 15),
    bool allowInsecureLoopback = false,
    bool allowAndroidEmulatorLoopback = false,
  }) : _create = _endpoint(
         createCaseEndpoint,
         '/v1/create-case',
         allowInsecureLoopback,
         allowAndroidEmulatorLoopback,
       ),
       _save = _endpoint(
         saveCaseEndpoint,
         '/v1/save-case',
         allowInsecureLoopback,
         allowAndroidEmulatorLoopback,
       ),
       _read = _endpoint(
         caseEndpoint,
         '/v1/read-case',
         allowInsecureLoopback,
         allowAndroidEmulatorLoopback,
       ),
       _upload = _endpoint(
         uploadEvidenceEndpoint,
         '/v1/upload-evidence',
         allowInsecureLoopback,
         allowAndroidEmulatorLoopback,
       ),
       _delete = _endpoint(
         deleteEvidenceEndpoint,
         '/v1/delete-evidence',
         allowInsecureLoopback,
         allowAndroidEmulatorLoopback,
       ),
       _tokenProvider = tokenProvider,
       _transport = transport {
    if (timeout <= Duration.zero ||
        timeout > const Duration(seconds: 15) ||
        {
              _create.origin,
              _save.origin,
              _read.origin,
              _upload.origin,
              _delete.origin,
            }.length !=
            1) {
      throw ArgumentError(
        'Use same-origin endpoints and a timeout of at most 15 seconds.',
      );
    }
  }
  final Uri _create, _save, _read, _upload, _delete;
  final MatchingTokenProvider _tokenProvider;
  final MatchingTransport _transport;
  final Duration timeout;

  Future<CaseSnapshot> createCase(
    CaseDraft draft, {
    required CaseDraft Function() currentDraft,
  }) async {
    late final CaseDraft captured;
    late final Map<String, Object?> request;
    try {
      captured = CaseDraft.fromJson(draft.toJson());
      request = captured.toCreateRequest();
    } catch (_) {
      throw _error('INVALID_REQUEST', 400);
    }
    void guard() => _draftGuard(captured, currentDraft);
    final json = await _post(
      _create,
      request,
      guard: guard,
      uncertain: 'CASE_SAVE_UNCERTAIN',
    );
    return _savedCase(json, captured, 1, guard);
  }

  Future<CaseSnapshot> saveCase(
    CaseSnapshot saved, {
    required CaseDraft replacement,
    required CaseSnapshot Function() currentCase,
    required CaseDraft Function() currentDraft,
  }) async {
    late final CaseSnapshot original;
    late final CaseDraft captured;
    late final Map<String, Object?> request;
    try {
      original = parseCurrentCase(saved.toJson());
      captured = CaseDraft.fromJson(replacement.toJson());
      if (captured.caseId != original.caseId) ExportContractValues.invalid();
      request = captured.toSaveRequest(original.revision);
    } catch (_) {
      throw _error('INVALID_REQUEST', 400);
    }
    void guard() {
      _caseGuard(original, currentCase);
      _draftGuard(captured, currentDraft);
    }

    final json = await _post(
      _save,
      request,
      guard: guard,
      uncertain: 'CASE_SAVE_UNCERTAIN',
    );
    return _savedCase(json, captured, original.revision + 1, guard);
  }

  Future<CaseSnapshot> reloadCase(
    String caseId, {
    required String Function() currentCaseId,
    required CaseSnapshot? Function() currentCase,
  }) async {
    try {
      ExportContractValues.id(caseId);
    } catch (_) {
      throw _error('INVALID_REQUEST', 400);
    }
    var highestRevision = 0;
    void guard() {
      try {
        if (currentCaseId() != caseId) throw const FormatException();
        final current = currentCase();
        if (current != null) {
          if (current.caseId != caseId) throw const FormatException();
          final revision = ExportContractValues.integer(current.revision);
          if (revision > highestRevision) highestRevision = revision;
        }
      } catch (_) {
        throw _error('STALE_RESPONSE');
      }
    }

    final json = await _post(_read, {
      'schemaVersion': '1',
      'caseId': caseId,
    }, guard: guard);
    guard();
    late final CaseSnapshot result;
    try {
      result = parseCurrentCase(json);
    } catch (_) {
      throw _error('UNEXPECTED_RESPONSE');
    }
    if (result.caseId != caseId || result.revision < highestRevision) {
      throw _error('STALE_RESPONSE');
    }
    return result;
  }

  Future<EvidenceUploadResponse> uploadEvidence(
    CaseSnapshot snapshot, {
    required EvidenceCatalog catalog,
    required String evidenceId,
    required int expectedEvidenceRevision,
    required String findingId,
    required String? capturedAt,
    required List<int> imageBytes,
    required CaseSnapshot Function() currentCase,
    required EvidenceCatalog Function() currentCatalog,
  }) async {
    late final CaseSnapshot saved;
    late final EvidenceCatalog captured;
    late final List<int> bytes;
    try {
      saved = parseCurrentCase(snapshot.toJson());
      captured = _catalog(saved, catalog);
      ExportContractValues.id(evidenceId);
      ExportContractValues.id(findingId);
      ExportContractValues.integer(
        expectedEvidenceRevision,
        min: 0,
        max: ExportContractValues.maxInteger - 1,
      );
      if (capturedAt != null) ExportContractValues.instant(capturedAt);
      if (!saved.findings.any(
        (finding) =>
            finding.id == findingId && finding.evidenceIds.contains(evidenceId),
      )) {
        ExportContractValues.invalid();
      }
      final existing = captured.evidence.where(
        (item) => item.evidenceId == evidenceId,
      );
      if ((existing.isEmpty && expectedEvidenceRevision != 0) ||
          (existing.isNotEmpty &&
              (existing.single.evidenceRevision != expectedEvidenceRevision ||
                  existing.single.findingId != findingId))) {
        ExportContractValues.invalid();
      }
      if (imageBytes.length < 8 ||
          imageBytes.length > maxOriginalImageBytes ||
          imageBytes.any((byte) => byte < 0 || byte > 255)) {
        ExportContractValues.invalid();
      }
      bytes = Uint8List.fromList(imageBytes).asUnmodifiableView();
    } catch (_) {
      throw _error('INVALID_REQUEST', 400);
    }
    void guard() =>
        _evidenceGuard(saved, captured, currentCase, currentCatalog);
    final json = await _post(
      _upload,
      {
        'schemaVersion': '1',
        'caseId': saved.caseId,
        'expectedCaseRevision': saved.revision,
        'expectedCatalogRevision': captured.catalogRevision,
        'evidenceId': evidenceId,
        'expectedEvidenceRevision': expectedEvidenceRevision,
        'findingId': findingId,
        'capturedAt': capturedAt,
        'imageBase64': base64Encode(bytes),
      },
      guard: guard,
      uncertain: 'EVIDENCE_SAVE_UNCERTAIN',
      maxRequestBytes: maxImageUploadRequestBytes,
    );
    try {
      guard();
      final result = EvidenceUploadResponse.fromJson(json);
      if (result.caseId != saved.caseId ||
          result.caseRevision != saved.revision ||
          result.catalogRevision != captured.catalogRevision + 1 ||
          result.evidence.evidenceId != evidenceId ||
          result.evidence.evidenceRevision != expectedEvidenceRevision + 1 ||
          result.evidence.findingId != findingId ||
          result.evidence.capturedAt != capturedAt) {
        throw const FormatException();
      }
      return result;
    } catch (_) {
      throw _error('EVIDENCE_SAVE_UNCERTAIN');
    }
  }

  Future<EvidenceDeleteResponse> deleteEvidence(
    CaseSnapshot snapshot, {
    required EvidenceCatalog catalog,
    required EvidenceDescriptor evidence,
    required CaseSnapshot Function() currentCase,
    required EvidenceCatalog Function() currentCatalog,
  }) async {
    late final CaseSnapshot saved;
    late final EvidenceCatalog captured;
    late final EvidenceDescriptor item;
    try {
      saved = parseCurrentCase(snapshot.toJson());
      captured = _catalog(saved, catalog);
      item = EvidenceDescriptor.fromJson(evidence.toJson());
      if (item.evidenceRevision >= ExportContractValues.maxInteger ||
          !captured.evidence.any(
            (value) => _same(value.toJson(), item.toJson()),
          )) {
        ExportContractValues.invalid();
      }
    } catch (_) {
      throw _error('INVALID_REQUEST', 400);
    }
    void guard() =>
        _evidenceGuard(saved, captured, currentCase, currentCatalog);
    final json = await _post(
      _delete,
      {
        'schemaVersion': '1',
        'caseId': saved.caseId,
        'expectedCaseRevision': saved.revision,
        'expectedCatalogRevision': captured.catalogRevision,
        'evidenceId': item.evidenceId,
        'expectedEvidenceRevision': item.evidenceRevision,
      },
      guard: guard,
      uncertain: 'EVIDENCE_SAVE_UNCERTAIN',
    );
    try {
      guard();
      final result = EvidenceDeleteResponse.fromJson(json);
      if (result.caseId != saved.caseId ||
          result.caseRevision != saved.revision ||
          result.catalogRevision != captured.catalogRevision + 1 ||
          result.evidenceId != item.evidenceId ||
          result.evidenceRevision != item.evidenceRevision + 1) {
        throw const FormatException();
      }
      return result;
    } catch (_) {
      throw _error('EVIDENCE_SAVE_UNCERTAIN');
    }
  }

  Future<Object?> _post(
    Uri endpoint,
    Map<String, Object?> body, {
    required void Function() guard,
    String? uncertain,
    int maxRequestBytes = 16 * 1024,
  }) async {
    final bytes = utf8.encode(jsonEncode(body));
    if (bytes.length > maxRequestBytes) throw _error('PAYLOAD_TOO_LARGE', 413);
    guard();
    final clock = Stopwatch()..start();
    late final String? token;
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
    final remaining = timeout - clock.elapsed;
    if (remaining <= Duration.zero) throw _error('TIMEOUT');
    MatchingExchange? exchange;
    late final MatchingHttpResponse response;
    try {
      exchange = _transport.post(
        MatchingHttpRequest(
          endpoint: endpoint,
          bearerToken: token,
          body: bytes,
          maxResponseBytes: 1024 * 1024,
        ),
      );
      response = await exchange.response.timeout(remaining);
    } on TimeoutException {
      throw _error(uncertain ?? 'TIMEOUT');
    } on MatchingTransportException catch (error) {
      throw _error(
        uncertain ??
            switch (error.failure) {
              MatchingTransportFailure.network => 'NETWORK_ERROR',
              MatchingTransportFailure.responseTooLarge => 'RESPONSE_TOO_LARGE',
              MatchingTransportFailure.redirectBlocked => 'REDIRECT_BLOCKED',
            },
      );
    } catch (_) {
      throw _error(uncertain ?? 'NETWORK_ERROR');
    } finally {
      try {
        exchange?.cancel();
      } catch (_) {
        // ignore: empty_catches
      }
    }
    try {
      guard();
    } catch (_) {
      throw _error(uncertain ?? 'STALE_RESPONSE');
    }
    if (response.body.length > 1024 * 1024) {
      throw _error(uncertain ?? 'RESPONSE_TOO_LARGE');
    }
    if (response.statusCode >= 300 && response.statusCode < 400) {
      throw _error(uncertain ?? 'REDIRECT_BLOCKED');
    }
    if (response.contentType?.split(';').first.trim().toLowerCase() !=
        'application/json') {
      throw _error(uncertain ?? 'UNEXPECTED_RESPONSE');
    }
    late final Object? json;
    try {
      json = jsonDecode(utf8.decode(response.body));
    } catch (_) {
      throw _error(uncertain ?? 'UNEXPECTED_RESPONSE');
    }
    if (response.statusCode != 200) {
      final error = _apiError(response.statusCode, json);
      if (uncertain != null &&
          (error.code == 'UNEXPECTED_RESPONSE' ||
              (response.statusCode >= 500 &&
                  error.code != 'STORAGE_LIMIT_REACHED'))) {
        throw _error(uncertain);
      }
      throw error;
    }
    return json;
  }
}

CaseSnapshot _savedCase(
  Object? json,
  CaseDraft draft,
  int revision,
  void Function() guard,
) {
  try {
    guard();
    final result = parseWritableCase(json);
    if (result.revision != revision ||
        !_same(CaseDraft.fromSnapshot(result).toJson(), draft.toJson())) {
      throw const FormatException();
    }
    return result;
  } catch (_) {
    throw _error('CASE_SAVE_UNCERTAIN');
  }
}

void _draftGuard(CaseDraft captured, CaseDraft Function() current) {
  try {
    if (!_same(
      CaseDraft.fromJson(current().toJson()).toJson(),
      captured.toJson(),
    )) {
      throw const FormatException();
    }
  } catch (_) {
    throw _error('STALE_RESPONSE');
  }
}

void _caseGuard(CaseSnapshot captured, CaseSnapshot Function() current) {
  try {
    final value = current();
    if (value.caseId != captured.caseId ||
        value.revision != captured.revision) {
      throw const FormatException();
    }
  } catch (_) {
    throw _error('STALE_RESPONSE');
  }
}

EvidenceCatalog _catalog(CaseSnapshot snapshot, EvidenceCatalog value) {
  final catalog = EvidenceCatalog.fromJson(value.toJson());
  if (!catalog.belongsTo(snapshot) ||
      catalog.catalogRevision >= ExportContractValues.maxInteger) {
    ExportContractValues.invalid();
  }
  return catalog;
}

void _evidenceGuard(
  CaseSnapshot saved,
  EvidenceCatalog captured,
  CaseSnapshot Function() currentCase,
  EvidenceCatalog Function() currentCatalog,
) {
  _caseGuard(saved, currentCase);
  try {
    if (!_same(_catalog(saved, currentCatalog()).toJson(), captured.toJson())) {
      throw const FormatException();
    }
  } catch (_) {
    throw _error('STALE_RESPONSE');
  }
}

bool _same(Object? left, Object? right) {
  if (left is Map<String, Object?> && right is Map<String, Object?>) {
    return left.length == right.length &&
        left.keys.every(
          (key) => right.containsKey(key) && _same(left[key], right[key]),
        );
  }
  if (left is List && right is List) {
    return left.length == right.length &&
        Iterable.generate(
          left.length,
        ).every((index) => _same(left[index], right[index]));
  }
  return left == right;
}

MatchingApiException _error(String code, [int? status]) =>
    MatchingApiException.forCode(code, statusCode: status);
MatchingApiException _apiError(int status, Object? json) {
  const codes = {
    400: {'INVALID_REQUEST'},
    401: {'UNAUTHENTICATED'},
    404: {'CASE_NOT_FOUND', 'ARTIFACT_NOT_FOUND', 'NOT_FOUND'},
    409: {'CASE_REVISION_MISMATCH', 'CASE_ID_UNAVAILABLE', 'EVIDENCE_CONFLICT'},
    422: {'INVALID_IMAGE'},
    429: {'UPLOAD_BUSY'},
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
        !(codes[status] ?? {}).contains(error['code'])) {
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
