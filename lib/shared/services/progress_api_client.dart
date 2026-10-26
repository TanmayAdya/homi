import 'dart:async';
import 'dart:convert';
import '../../features/tracking/progress_models.dart';
import '../models/export_contract_values.dart';
import 'matching_api_client.dart';
import 'token_availability.dart';

const progressMaxResponseBytes = 288 * 1024;

class ProgressApiClient {
  ProgressApiClient({
    required Uri baseUri,
    required MatchingTokenProvider tokenProvider,
    required MatchingTransport transport,
    this.timeout = const Duration(seconds: 15),
    this.includeReferrals = false,
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
  final bool includeReferrals;
  Future<ProgressPage> read(
    String caseId, {
    required bool Function() isCurrent,
    int offset = 0,
    int? revision,
    int? caseRevision,
    String? historyVersion,
  }) async {
    ExportContractValues.id(caseId);
    final json = await _post('read-progress', {
      'schemaVersion': '3',
      if (includeReferrals) 'includeReferrals': true,
      'caseId': caseId,
      'offset': offset,
      'limit': 20,
      'expectedProgressRevision': revision,
      'expectedCaseRevision': caseRevision,
      'expectedHistoryVersion': historyVersion,
    }, guard: () => _current(isCurrent));
    final page = ProgressPage.fromJson(json);
    if (page.caseId != caseId ||
        page.acknowledgement != null ||
        historyVersion != null && page.historyVersion != historyVersion ||
        revision != null && page.revision != revision ||
        caseRevision != null && page.caseRevision != caseRevision ||
        page.nextOffset != null && page.nextOffset != offset + 20) {
      throw _error('UNEXPECTED_RESPONSE');
    }
    return page;
  }

  Future<ProgressPage> save(
    Map<String, Object?> request, {
    required bool Function() isCurrent,
  }) async {
    final json = await _post(
      'save-progress',
      request,
      guard: () => _current(isCurrent),
      saving: true,
    );
    final page = ProgressPage.fromJson(json);
    if (page.caseId != request['caseId'] ||
        page.acknowledgement != request['mutationId']) {
      throw _error('PROGRESS_SAVE_UNCERTAIN');
    }
    return page;
  }

  Future<Map<String, Object?>> history(
    String caseId,
    String programId, {
    required bool Function() isCurrent,
    required int revision,
    required int caseRevision,
    required String historyVersion,
    int offset = 0,
  }) async {
    final raw = await _post('read-progress-history', {
      'schemaVersion': '3',
      'caseId': caseId,
      'programId': programId,
      'offset': offset,
      'limit': 20,
      'expectedProgressRevision': revision,
      'expectedCaseRevision': caseRevision,
      'expectedHistoryVersion': historyVersion,
    }, guard: () => _current(isCurrent));
    final v = ExportContractValues.object(raw, {
      'schemaVersion',
      'caseId',
      'programId',
      'revision',
      'caseRevision',
      'reports',
      'historyVersion',
      'nextOffset',
    });
    if (v['schemaVersion'] != '3' ||
        v['caseId'] != caseId ||
        v['programId'] != programId ||
        v['revision'] != revision ||
        v['caseRevision'] != caseRevision ||
        v['historyVersion'] != historyVersion ||
        v['reports'] is! List ||
        (v['reports'] as List).length > 20 ||
        v['nextOffset'] != null && v['nextOffset'] != offset + 20) {
      throw _error('UNEXPECTED_RESPONSE');
    }
    for (final report in v['reports'] as List) {
      parseProgressReport(report);
    }
    return v;
  }

  Future<Object?> _post(
    String route,
    Map<String, Object?> body, {
    required void Function() guard,
    bool saving = false,
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
          maxResponseBytes: progressMaxResponseBytes,
        ),
      );
      guard();
      final response = await exchange.response.timeout(remaining);
      guard();
      if (response.body.length > progressMaxResponseBytes) {
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
        throw _error('PROGRESS_SAVE_UNCERTAIN', mapped.statusCode);
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
  'PROGRESS_CONFLICT',
  'TASK_CONFLICT',
  'CASE_REVISION_MISMATCH',
  'PROGRESS_MUTATION_CONFLICT',
  'PROGRESS_LIMIT',
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
      'PROGRESS_CONFLICT',
      'TASK_CONFLICT',
      'PROGRESS_MUTATION_CONFLICT',
      'CASE_REVISION_MISMATCH',
      'ACCOUNT_CLOSED',
    },
    507: {'PROGRESS_LIMIT'},
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
