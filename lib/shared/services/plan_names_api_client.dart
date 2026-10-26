import 'dart:async';
import 'dart:convert';

import '../models/account_plan_name.dart';
import '../models/case_list.dart';
import '../models/export_contract_values.dart';
import 'matching_api_client.dart';
import 'token_availability.dart';

const planNamesMaxResponseBytes = 64 * 1024;

class PlanNamesApiClient {
  PlanNamesApiClient({
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
      throw ArgumentError(
        'Use a timeout greater than zero and at most 15 seconds.',
      );
    }
  }

  final Uri _base;
  final MatchingTokenProvider _tokens;
  final MatchingTransport _transport;
  final Duration timeout;

  Future<AccountPlanName> readName(
    String caseId, {
    int minimumNameRevision = 0,
    AccountPlanName? Function()? currentName,
    required bool Function() isCurrent,
  }) async {
    try {
      ExportContractValues.id(caseId);
      ExportContractValues.integer(minimumNameRevision, min: 0);
    } catch (_) {
      throw _error('INVALID_REQUEST', 400);
    }
    var highest = minimumNameRevision;
    AccountPlanName? observed;
    void guard() {
      _current(isCurrent);
      try {
        final current = currentName?.call();
        if (current == null) return;
        if (current.caseId != caseId) throw const FormatException();
        if (current.nameRevision >= highest) {
          highest = current.nameRevision;
          observed = current;
        }
      } catch (_) {
        throw _error('STALE_RESPONSE');
      }
    }

    final json = await _post('read-plan-name', {
      'schemaVersion': '2',
      'caseId': caseId,
    }, guard: guard);
    guard();
    late final AccountPlanName result;
    try {
      result = AccountPlanName.fromJson(json);
    } catch (_) {
      throw _error('UNEXPECTED_RESPONSE');
    }
    if (result.caseId != caseId || result.nameRevision < highest) {
      throw _error('STALE_RESPONSE');
    }
    if (observed != null &&
        result.nameRevision == observed!.nameRevision &&
        (result.name != observed!.name ||
            result.lastMutationId != observed!.lastMutationId)) {
      throw _error('UNEXPECTED_RESPONSE');
    }
    return result;
  }

  Future<AccountPlanName> saveName(
    String caseId, {
    required int expectedNameRevision,
    required String mutationId,
    required String? name,
    required bool Function() isCurrent,
  }) async {
    late final PlanNameSaveRequest request;
    try {
      request = PlanNameSaveRequest(
        caseId: caseId,
        expectedNameRevision: expectedNameRevision,
        mutationId: mutationId,
        name: name,
      );
    } catch (_) {
      throw _error('INVALID_REQUEST', 400);
    }
    void guard() => _current(isCurrent);
    final json = await _post(
      'save-plan-name',
      request.toJson(),
      guard: guard,
      saving: true,
    );
    guard();
    try {
      final result = AccountPlanName.fromJson(json);
      if (result.caseId != caseId ||
          result.nameRevision != expectedNameRevision + 1 ||
          result.lastMutationId != mutationId ||
          result.name != name) {
        throw const FormatException();
      }
      return result;
    } catch (_) {
      throw _error('NAME_SAVE_UNCERTAIN');
    }
  }

  Future<NamedCaseListPage> listCases({
    int limit = 20,
    String? afterCaseId,
    required bool Function() isCurrent,
  }) async {
    late final CaseListRequest constraints;
    try {
      constraints = CaseListRequest(limit: limit, afterCaseId: afterCaseId);
    } catch (_) {
      throw _error('INVALID_REQUEST', 400);
    }
    void guard() => _current(isCurrent);
    final json = await _post('list-cases', {
      ...constraints.toJson(),
      'schemaVersion': '2',
    }, guard: guard);
    guard();
    try {
      return NamedCaseListPage.fromJson(
        json,
        limit: limit,
        afterCaseId: afterCaseId,
      );
    } catch (_) {
      throw _error('UNEXPECTED_RESPONSE');
    }
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
          endpoint: _base.resolve('/v2/$route'),
          bearerToken: token,
          body: utf8.encode(jsonEncode(body)),
          maxResponseBytes: planNamesMaxResponseBytes,
        ),
      );
      guard();
      final response = await exchange.response.timeout(remaining);
      guard();
      if (response.body.length > planNamesMaxResponseBytes) {
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
        throw _error('NAME_SAVE_UNCERTAIN', mapped.statusCode);
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
  'PLAN_NAME_CONFLICT',
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
    409: {'PLAN_NAME_CONFLICT', 'ACCOUNT_CLOSED'},
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
    if (!{'1', '2'}.contains(value['schemaVersion']) ||
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
