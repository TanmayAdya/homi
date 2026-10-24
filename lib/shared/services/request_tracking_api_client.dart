import 'dart:async';
import 'dart:convert';

import '../models/contracts.dart';
import '../models/export_contract_values.dart';
import '../models/request_tracking.dart';
import 'matching_api_client.dart';

const requestTrackingMaxResponseBytes = 256 * 1024;

class RequestTrackingApiClient {
  RequestTrackingApiClient({
    required Uri readHistoryEndpoint,
    required Uri appendUpdateEndpoint,
    required MatchingTokenProvider tokenProvider,
    required MatchingTransport transport,
    this.timeout = const Duration(seconds: 15),
    bool allowInsecureLoopback = false,
    bool allowAndroidEmulatorLoopback = false,
  }) : _read = _endpoint(
         readHistoryEndpoint,
         '/v1/read-request-history',
         allowInsecureLoopback,
         allowAndroidEmulatorLoopback,
       ),
       _append = _endpoint(
         appendUpdateEndpoint,
         '/v1/append-request-update',
         allowInsecureLoopback,
         allowAndroidEmulatorLoopback,
       ),
       _tokenProvider = tokenProvider,
       _transport = transport {
    if (_read.origin != _append.origin ||
        timeout <= Duration.zero ||
        timeout > const Duration(seconds: 15)) {
      throw ArgumentError(
        'Use same-origin endpoints and a timeout of at most 15 seconds.',
      );
    }
  }
  final Uri _read, _append;
  final MatchingTokenProvider _tokenProvider;
  final MatchingTransport _transport;
  final Duration timeout;

  Future<RequestHistory> readHistory(
    ReadRequestHistoryRequest request, {
    required CaseSnapshot Function() currentCase,
    required String Function() currentProgramId,
    required RequestHistory? Function() currentHistory,
    required bool Function() isCurrent,
  }) => _run(
    request,
    null,
    currentCase,
    currentProgramId,
    currentHistory,
    isCurrent,
  );

  Future<RequestHistory> appendUpdate(
    PendingRequestUpdate pending, {
    required CaseSnapshot Function() currentCase,
    required String Function() currentProgramId,
    required RequestHistory? Function() currentHistory,
    required bool Function() isCurrent,
  }) => _run(
    pending.request,
    pending,
    currentCase,
    currentProgramId,
    currentHistory,
    isCurrent,
  );

  Future<RequestHistory> _run(
    ReadRequestHistoryRequest request,
    PendingRequestUpdate? pending,
    CaseSnapshot Function() currentCase,
    String Function() currentProgramId,
    RequestHistory? Function() currentHistory,
    bool Function() isCurrent,
  ) async {
    var highestRevision = 0;
    void guard() {
      _current(isCurrent);
      try {
        final current = currentCase();
        if (current.caseId != request.caseId ||
            current.revision != request.expectedCaseRevision ||
            currentProgramId() != request.programId) {
          throw const FormatException();
        }
        final history = currentHistory();
        if (history != null) {
          if (history.caseId != request.caseId ||
              history.programId != request.programId ||
              history.caseRevision > request.expectedCaseRevision) {
            throw const FormatException();
          }
          if (history.requestRevision > highestRevision) {
            highestRevision = history.requestRevision;
          }
        }
      } catch (_) {
        throw _error('STALE_RESPONSE');
      }
    }

    guard();
    var sent = false;
    Object? json;
    try {
      json = await _post(
        pending == null ? _read : _append,
        pending?.toJson() ?? request.toJson(),
        guard,
        onSend: () => sent = true,
      );
    } on MatchingApiException catch (error) {
      if (pending != null &&
          sent &&
          !{
            'STALE_RESPONSE',
            'INVALID_REQUEST',
            'UNAUTHENTICATED',
            'CASE_NOT_FOUND',
            'PROGRAM_NOT_FOUND',
            'CASE_REVISION_MISMATCH',
            'REQUEST_REVISION_MISMATCH',
            'REQUEST_UPDATE_CONFLICT',
            'REQUEST_HISTORY_FULL',
            'RATE_LIMITED',
            'PAYLOAD_TOO_LARGE',
            'UNSUPPORTED_MEDIA_TYPE',
            'METHOD_NOT_ALLOWED',
            'NOT_FOUND',
          }.contains(error.code)) {
        throw _error('REQUEST_UPDATE_UNCERTAIN', error.statusCode);
      }
      rethrow;
    }
    guard();
    late final RequestHistory history;
    try {
      history = RequestHistory.fromJson(json);
    } catch (_) {
      throw _error(
        pending == null ? 'UNEXPECTED_RESPONSE' : 'REQUEST_UPDATE_UNCERTAIN',
      );
    }
    if (history.caseId != request.caseId ||
        history.programId != request.programId ||
        history.caseRevision != request.expectedCaseRevision ||
        history.requestRevision < highestRevision) {
      throw _error('STALE_RESPONSE');
    }
    if (pending != null && !history.acknowledges(pending)) {
      throw _error('REQUEST_UPDATE_UNCERTAIN');
    }
    return history;
  }

  Future<Object?> _post(
    Uri endpoint,
    Map<String, Object?> body,
    void Function() guard, {
    required void Function() onSend,
  }) async {
    guard();
    final clock = Stopwatch()..start();
    String? token;
    MatchingApiException? failure;
    try {
      token = await _tokenProvider().timeout(timeout);
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
    MatchingHttpResponse? response;
    try {
      guard();
      onSend();
      exchange = _transport.post(
        MatchingHttpRequest(
          endpoint: endpoint,
          bearerToken: token,
          body: utf8.encode(jsonEncode(body)),
          maxResponseBytes: requestTrackingMaxResponseBytes,
        ),
      );
      guard();
      response = await exchange.response.timeout(remaining);
    } on MatchingApiException catch (error) {
      failure = error;
    } on TimeoutException {
      failure = _error('TIMEOUT');
    } on MatchingTransportException catch (error) {
      failure = _error(switch (error.failure) {
        MatchingTransportFailure.network => 'NETWORK_ERROR',
        MatchingTransportFailure.responseTooLarge => 'RESPONSE_TOO_LARGE',
        MatchingTransportFailure.redirectBlocked => 'REDIRECT_BLOCKED',
      });
    } catch (_) {
      failure = _error('NETWORK_ERROR');
    } finally {
      exchange?.response.ignore();
      try {
        exchange?.cancel();
      } catch (_) {
        // ignore: empty_catches
      }
    }
    guard();
    if (failure != null) throw failure;
    if (response == null) throw _error('UNEXPECTED_RESPONSE');
    if (response.body.length > requestTrackingMaxResponseBytes) {
      throw _error('RESPONSE_TOO_LARGE');
    }
    if (response.statusCode >= 300 && response.statusCode < 400) {
      throw _error('REDIRECT_BLOCKED');
    }
    if (response.contentType?.split(';').first.trim().toLowerCase() !=
        'application/json') {
      throw _error('UNEXPECTED_RESPONSE');
    }
    late final Object? json;
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
  }
}

void _current(bool Function() isCurrent) {
  try {
    if (!isCurrent()) throw const FormatException();
  } catch (_) {
    throw _error('STALE_RESPONSE');
  }
}

MatchingApiException _error(String code, [int? status]) =>
    MatchingApiException.forCode(code, statusCode: status);
MatchingApiException _apiError(int status, Object? json) {
  const codes = {
    400: {'INVALID_REQUEST'},
    401: {'UNAUTHENTICATED'},
    404: {'CASE_NOT_FOUND', 'PROGRAM_NOT_FOUND', 'NOT_FOUND'},
    409: {
      'CASE_REVISION_MISMATCH',
      'REQUEST_REVISION_MISMATCH',
      'REQUEST_UPDATE_CONFLICT',
      'REQUEST_HISTORY_FULL',
    },
    405: {'METHOD_NOT_ALLOWED'},
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
