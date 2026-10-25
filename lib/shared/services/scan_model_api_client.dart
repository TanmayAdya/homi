import '../models/home_model_sync.dart';
import 'dart:async';
import 'dart:convert';
import '../models/scan_model_sync.dart';
import '../../features/assessment/domain/home_safety/home_safety.dart';
import '../models/export_contract_values.dart';
import 'matching_api_client.dart';
import 'token_availability.dart';

const scanModelMaxResponseBytes = 768 * 1024;

class ScanModelApiClient {
  ScanModelApiClient({
    required Uri baseUri,
    required MatchingTokenProvider tokenProvider,
    required MatchingTransport transport,
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
  final Duration timeout;
  Future<ScanModelState> read(
    String caseId, {
    RoomInstance? room,
    required bool Function() isCurrent,
  }) async {
    ExportContractValues.id(caseId);
    final value = await _post('read-scan-model', {
      'schemaVersion': '3',
      'caseId': caseId,
      'roomId': room?.id,
    }, guard: () => _current(isCurrent));
    try {
      final state = ScanModelState.fromJson(value, caseId: caseId, room: room);
      if (state.acknowledgedMutationId != null) throw const FormatException();
      return state;
    } catch (_) {
      throw _error('UNEXPECTED_RESPONSE');
    }
  }

  Future<ScanModelState> save(
    Map<String, Object?> request, {
    RoomInstance? room,
    required bool Function() isCurrent,
  }) async {
    if (utf8.encode(jsonEncode(request)).length > scanSyncMaxBytes) {
      throw _error('INVALID_REQUEST');
    }
    final value = await _post(
      'save-scan-model',
      request,
      guard: () => _current(isCurrent),
      saving: true,
    );
    try {
      final state = ScanModelState.fromJson(
        value,
        caseId: request['caseId'] as String,
        room: room,
      );
      if (state.acknowledgedMutationId != request['mutationId']) {
        throw const FormatException();
      }
      return state;
    } catch (_) {
      throw _error('SCAN_MODEL_SAVE_UNCERTAIN');
    }
  }

  Future<HomeModelState> readHome(
    String caseId, {
    required bool Function() isCurrent,
  }) async {
    ExportContractValues.id(caseId);
    final value = await _post(
      'read-home-model',
      {'schemaVersion': '3', 'caseId': caseId},
      guard: () => _current(isCurrent),
      maxBytes: homeSyncMaxBytes,
    );
    try {
      final state = HomeModelState.fromJson(value, caseId: caseId);
      if (state.acknowledgedMutationId != null) throw const FormatException();
      return state;
    } catch (_) {
      throw _error('UNEXPECTED_RESPONSE');
    }
  }

  Future<HomeModelState> saveHome(
    Map<String, Object?> request, {
    required bool Function() isCurrent,
  }) async {
    if (utf8.encode(jsonEncode(request)).length > homeSyncMaxBytes) {
      throw _error('INVALID_REQUEST');
    }
    final value = await _post(
      'save-home-model',
      request,
      guard: () => _current(isCurrent),
      saving: true,
      maxBytes: homeSyncMaxBytes,
    );
    try {
      final state = HomeModelState.fromJson(
        value,
        caseId: request['caseId'] as String,
      );
      if (state.acknowledgedMutationId != request['mutationId']) {
        throw const FormatException();
      }
      return state;
    } catch (_) {
      throw _error('SCAN_MODEL_SAVE_UNCERTAIN');
    }
  }

  Future<Object?> _post(
    String route,
    Map<String, Object?> body, {
    required void Function() guard,
    bool saving = false,
    int maxBytes = scanModelMaxResponseBytes,
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
          maxResponseBytes: maxBytes,
        ),
      );
      guard();
      final response = await exchange.response.timeout(remaining);
      guard();
      if (response.body.length > maxBytes) {
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
        throw _error('SCAN_MODEL_SAVE_UNCERTAIN', mapped.statusCode);
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
  'SCAN_MODEL_CONFLICT',
  'CASE_REVISION_MISMATCH',
  'SCAN_MODEL_MUTATION_CONFLICT',
  'SCAN_MODEL_LIMIT',
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
      'SCAN_MODEL_CONFLICT',
      'SCAN_MODEL_MUTATION_CONFLICT',
      'CASE_REVISION_MISMATCH',
      'ACCOUNT_CLOSED',
    },
    507: {'SCAN_MODEL_LIMIT'},
    413: {'PAYLOAD_TOO_LARGE'},
    415: {'UNSUPPORTED_MEDIA_TYPE'},
    429: {'RATE_LIMITED'},
    500: {'INTERNAL_ERROR'},
    503: {'SERVICE_UNAVAILABLE'},
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
