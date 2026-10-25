import 'dart:async';
import 'dart:convert';

import '../models/case_draft.dart';
import '../models/case_list.dart';
import '../models/contracts.dart';
import '../models/export_contract_values.dart';
import 'matching_api_client.dart';

const caseDiscoveryMaxResponseBytes = 64 * 1024;

class CaseDiscoveryApiClient {
  CaseDiscoveryApiClient({
    required Uri listCasesEndpoint,
    required Uri caseEndpoint,
    required MatchingTokenProvider tokenProvider,
    required MatchingTransport transport,
    this.timeout = const Duration(seconds: 15),
    bool allowInsecureLoopback = false,
    bool allowAndroidEmulatorLoopback = false,
  }) : _list = _endpoint(
         listCasesEndpoint,
         '/v1/list-cases',
         allowInsecureLoopback,
         allowAndroidEmulatorLoopback,
       ),
       _read = _endpoint(
         caseEndpoint,
         '/v1/read-case',
         allowInsecureLoopback,
         allowAndroidEmulatorLoopback,
       ),
       _tokenProvider = tokenProvider,
       _transport = transport {
    if (_list.origin != _read.origin ||
        timeout <= Duration.zero ||
        timeout > const Duration(seconds: 15)) {
      throw ArgumentError(
        'Use same-origin endpoints and a timeout of at most 15 seconds.',
      );
    }
  }
  final Uri _list, _read;
  final MatchingTokenProvider _tokenProvider;
  final MatchingTransport _transport;
  final Duration timeout;

  Future<CaseListPage> listCases({
    int limit = 20,
    String? afterCaseId,
    required bool Function() isCurrent,
  }) async {
    late final CaseListRequest request;
    try {
      request = CaseListRequest(limit: limit, afterCaseId: afterCaseId);
    } catch (_) {
      throw _error('INVALID_REQUEST', 400);
    }
    void guard() => _current(isCurrent);
    guard();
    final json = await _post(_list, request.toJson(), guard);
    guard();
    try {
      return CaseListPage.fromJson(json, request: request);
    } catch (_) {
      throw _error('UNEXPECTED_RESPONSE');
    }
  }

  Future<CaseSnapshot> resumeCase(
    String caseId, {
    int minimumCaseRevision = 1,
    required String Function() currentCaseId,
    required CaseSnapshot? Function() currentCase,
    required bool Function() isCurrent,
  }) async {
    try {
      ExportContractValues.id(caseId);
      ExportContractValues.integer(minimumCaseRevision);
    } catch (_) {
      throw _error('INVALID_REQUEST', 400);
    }
    var highestRevision = minimumCaseRevision;
    void guard() {
      _current(isCurrent);
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

    guard();
    final json = await _post(_read, {
      'schemaVersion': '1',
      'caseId': caseId,
    }, guard);
    guard();
    late final CaseSnapshot snapshot;
    try {
      snapshot = parseCurrentCase(json);
    } catch (_) {
      throw _error('UNEXPECTED_RESPONSE');
    }
    if (snapshot.caseId != caseId || snapshot.revision < highestRevision) {
      throw _error('STALE_RESPONSE');
    }
    return snapshot;
  }

  Future<Object?> _post(
    Uri endpoint,
    Map<String, Object?> body,
    void Function() guard,
  ) async {
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
      exchange = _transport.post(
        MatchingHttpRequest(
          endpoint: endpoint,
          bearerToken: token,
          body: utf8.encode(jsonEncode(body)),
          maxResponseBytes: caseDiscoveryMaxResponseBytes,
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
    if (response.body.length > caseDiscoveryMaxResponseBytes) {
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
    404: {'CASE_NOT_FOUND', 'NOT_FOUND'},
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
