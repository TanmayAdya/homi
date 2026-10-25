import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import '../../features/assessment/domain/home_safety/home_safety.dart';
import '../models/export_contract_values.dart';
import 'matching_api_client.dart';
import 'token_availability.dart';

const homeSafetyMaxResponseBytes = 288 * 1024;

class HomeSafetyApiClient {
  HomeSafetyApiClient({
    required Uri baseUri,
    required MatchingTokenProvider tokenProvider,
    required MatchingTransport transport,
    required this.catalog,
    this.timeout = const Duration(seconds: 15),
    bool allowInsecureLoopback = false,
    bool allowAndroidEmulatorLoopback = false,
  }) : _base = _validateBase(
         baseUri,
         allowInsecureLoopback,
         allowAndroidEmulatorLoopback,
       ),
       _tokens = tokenProvider,
       _transport = transport {
    if (timeout <= Duration.zero || timeout > const Duration(seconds: 15)) {
      throw ArgumentError('Invalid request timeout.');
    }
  }
  final Uri _base;
  final MatchingTokenProvider _tokens;
  final MatchingTransport _transport;
  final HomeSafetyCatalog catalog;
  final Duration timeout;
  Future<HomeSafetyState> read(
    String caseId, {
    required bool Function() isCurrent,
  }) async {
    ExportContractValues.id(caseId);
    final json = await _post('read-home-safety', {
      'schemaVersion': '3',
      'caseId': caseId,
    }, guard: () => _current(isCurrent));
    try {
      final state = HomeSafetyState.fromJson(json, catalog);
      if (state.snapshot.caseId != caseId ||
          state.acknowledgedMutationId != null) {
        throw const FormatException();
      }
      return state;
    } catch (_) {
      throw _error('UNEXPECTED_RESPONSE');
    }
  }

  Future<HomeSafetyReport> exportReport(
    HomeSafetyState state,
    int catalogRevision, {
    required bool includeNotes,
    required bool includeEvidenceReferences,
    required bool Function() isCurrent,
  }) async {
    final raw = await _post(
      'export-home-safety',
      {
        'schemaVersion': '3',
        'caseId': state.snapshot.caseId,
        'expectedCaseRevision': state.snapshot.revision,
        'expectedSafetyRevision': state.revision,
        'expectedCatalogRevision': catalogRevision,
        'includeNotes': includeNotes,
        'includeEvidenceReferences': includeEvidenceReferences,
      },
      guard: () => _current(isCurrent),
      maxResponseBytes: 3 * 1024 * 1024,
    );
    _current(isCurrent);
    try {
      final v = ExportContractValues.object(raw, {
        'schemaVersion',
        'caseId',
        'caseRevision',
        'safetyRevision',
        'catalogRevision',
        'includeNotes',
        'includeEvidenceReferences',
        'generatedAt',
        'pageCount',
        'sha256',
        'pdfBase64',
      });
      if (v['schemaVersion'] != '3' ||
          v['caseId'] != state.snapshot.caseId ||
          v['caseRevision'] != state.snapshot.revision ||
          v['safetyRevision'] != state.revision ||
          v['catalogRevision'] != catalogRevision ||
          v['includeNotes'] != includeNotes ||
          v['includeEvidenceReferences'] != includeEvidenceReferences) {
        throw const FormatException();
      }
      ExportContractValues.instant(v['generatedAt']);
      ExportContractValues.integer(v['pageCount'], max: 128);
      ExportContractValues.digest(v['sha256']);
      final bytes = base64Decode(v['pdfBase64'] as String);
      if (bytes.length < 8 ||
          bytes.length > 2 * 1024 * 1024 ||
          ascii.decode(bytes.take(5).toList()) != '%PDF-' ||
          sha256.convert(bytes).toString() != v['sha256']) {
        throw const FormatException();
      }
      _current(isCurrent);
      return HomeSafetyReport(
        bytes,
        state.snapshot.revision,
        state.revision,
        catalogRevision,
      );
    } catch (_) {
      _current(isCurrent);
      throw _error('UNEXPECTED_RESPONSE');
    }
  }

  Future<HomeSafetyState> save(
    SafetyMutation request, {
    required bool Function() isCurrent,
  }) async {
    final json = await _post(
      'save-home-safety',
      request.toJson(),
      guard: () => _current(isCurrent),
      saving: true,
    );
    try {
      final state = HomeSafetyState.fromJson(json, catalog);
      if (state.acknowledgedMutationId != request.id ||
          !state.acknowledges(request)) {
        throw const FormatException();
      }
      return state;
    } catch (_) {
      throw _error('HOME_SAFETY_SAVE_UNCERTAIN');
    }
  }

  Future<Object?> _post(
    String route,
    Map<String, Object?> body, {
    required void Function() guard,
    bool saving = false,
    int maxResponseBytes = homeSafetyMaxResponseBytes,
  }) async {
    guard();
    final clock = Stopwatch()..start();
    String? token;
    MatchingApiException? failure;
    try {
      token = await _tokens().timeout(timeout);
    } on RetryableTokenUnavailableException {
      failure = _error('NETWORK_ERROR');
    } on TimeoutException {
      failure = _error('TIMEOUT');
    } catch (_) {
      failure = _error('UNAUTHENTICATED', 401);
    }
    guard();
    if (failure != null) throw failure;
    if (token == null ||
        token.isEmpty ||
        token.length > 4096 ||
        RegExp(r'^[A-Za-z0-9\-._~+/]+=*$').stringMatch(token) != token) {
      throw _error('UNAUTHENTICATED', 401);
    }
    final remaining = timeout - clock.elapsed;
    if (remaining <= Duration.zero) throw _error('TIMEOUT');
    MatchingExchange? exchange;
    try {
      guard();
      exchange = _transport.post(
        MatchingHttpRequest(
          endpoint: _base.resolve('/v3/$route'),
          bearerToken: token,
          body: utf8.encode(jsonEncode(body)),
          maxResponseBytes: maxResponseBytes,
        ),
      );
      guard();
      final response = await exchange.response.timeout(remaining);
      guard();
      if (response.body.length > maxResponseBytes) {
        throw _error('RESPONSE_TOO_LARGE');
      }
      if (response.statusCode >= 300 && response.statusCode < 400) {
        throw _error('REDIRECT_BLOCKED');
      }
      if (response.contentType?.split(';').first.trim().toLowerCase() !=
          'application/json') {
        throw _error('UNEXPECTED_RESPONSE');
      }
      Object? json;
      try {
        json = jsonDecode(utf8.decode(response.body));
      } catch (_) {
        throw _error('UNEXPECTED_RESPONSE');
      }
      if (response.statusCode != 200) {
        throw _apiError(
          response.statusCode,
          json,
        ).withRetryAfter(response.retryAfter);
      }
      return json;
    } catch (error) {
      guard();
      final mapped = error is MatchingApiException
          ? error
          : error is TimeoutException
          ? _error('TIMEOUT')
          : error is MatchingTransportException
          ? _error(switch (error.failure) {
              MatchingTransportFailure.network => 'NETWORK_ERROR',
              MatchingTransportFailure.responseTooLarge => 'RESPONSE_TOO_LARGE',
              MatchingTransportFailure.redirectBlocked => 'REDIRECT_BLOCKED',
            })
          : _error('NETWORK_ERROR');
      if (saving && !_definiteFailureCodes.contains(mapped.code)) {
        throw _error('HOME_SAFETY_SAVE_UNCERTAIN', mapped.statusCode);
      }
      throw mapped;
    } finally {
      exchange?.response.ignore();
      try {
        exchange?.cancel();
      } catch (_) {
        // ignore: empty_catches
      }
    }
  }
}

const _definiteFailureCodes = {
  'STALE_RESPONSE',
  'INVALID_REQUEST',
  'UNAUTHENTICATED',
  'CASE_NOT_FOUND',
  'HOME_SAFETY_CONFLICT',
  'EVIDENCE_REVISION_MISMATCH',
  'CASE_REVISION_MISMATCH',
  'HOME_SAFETY_MUTATION_CONFLICT',
  'HOME_SAFETY_HISTORY_LIMIT',
  'ACCOUNT_CLOSED',
  'RATE_LIMITED',
  'PAYLOAD_TOO_LARGE',
  'METHOD_NOT_ALLOWED',
  'UNSUPPORTED_MEDIA_TYPE',
  'NOT_FOUND',
};

void _current(bool Function() isCurrent) {
  try {
    if (isCurrent()) return;
  } catch (_) {
    // ignore: empty_catches
  }
  throw _error('STALE_RESPONSE');
}

MatchingApiException _error(String code, [int? status]) =>
    MatchingApiException.forCode(code, statusCode: status);

MatchingApiException _apiError(int status, Object? json) {
  const codes = {
    400: {'INVALID_REQUEST'},
    401: {'UNAUTHENTICATED'},
    404: {'CASE_NOT_FOUND', 'NOT_FOUND'},
    405: {'METHOD_NOT_ALLOWED'},
    409: {
      'HOME_SAFETY_CONFLICT',
      'HOME_SAFETY_MUTATION_CONFLICT',
      'CASE_REVISION_MISMATCH',
      'EVIDENCE_REVISION_MISMATCH',
      'ACCOUNT_CLOSED',
    },
    422: {'REPORT_UNSUPPORTED_TEXT', 'REPORT_LIMIT', 'REPORT_FAILED'},
    507: {'HOME_SAFETY_HISTORY_LIMIT'},
    413: {'PAYLOAD_TOO_LARGE'},
    415: {'UNSUPPORTED_MEDIA_TYPE'},
    429: {'RATE_LIMITED'},
    500: {'INTERNAL_ERROR'},
    503: {'SERVICE_UNAVAILABLE', 'REPORT_BUSY'},
  };
  try {
    final value = ExportContractValues.object(json, {'schemaVersion', 'error'});
    final error = ExportContractValues.object(value['error'], {
      'code',
      'message',
    });
    if (!{'1', '2', '3'}.contains(value['schemaVersion']) ||
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

Uri _validateBase(Uri base, bool allowLoopback, bool allowEmulator) {
  final loopback =
      {'localhost', '127.0.0.1', '::1'}.contains(base.host) ||
      (allowEmulator && base.host == '10.0.2.2');
  if (!base.hasAuthority ||
      base.host.isEmpty ||
      base.userInfo.isNotEmpty ||
      base.hasQuery ||
      base.hasFragment ||
      !{'', '/'}.contains(base.path) ||
      base.port < 1 ||
      base.port > 65535 ||
      !(base.scheme == 'https' ||
          allowLoopback && loopback && base.scheme == 'http')) {
    throw ArgumentError(
      'Use a fixed HTTPS origin; HTTP requires explicit loopback opt-in.',
    );
  }
  return base;
}

class HomeSafetyReport {
  HomeSafetyReport(
    this.bytes,
    this.caseRevision,
    this.safetyRevision,
    this.catalogRevision,
  );
  final Uint8List bytes;
  final int caseRevision, safetyRevision, catalogRevision;
}
