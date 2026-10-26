import 'dart:async';
import 'dart:convert';

import '../models/account_deletion.dart';
import '../models/contracts.dart';
import '../models/export_contract_values.dart';
import 'matching_api_client.dart';

class LifecycleApiClient {
  LifecycleApiClient({
    required Uri apiBaseUrl,
    required MatchingTokenProvider tokenProvider,
    required MatchingTransport transport,
    this.timeout = const Duration(seconds: 15),
    bool allowInsecureLoopback = false,
    bool allowAndroidEmulatorLoopback = false,
  }) : _base = _validateBase(
         apiBaseUrl,
         allowInsecureLoopback,
         allowAndroidEmulatorLoopback,
       ),
       _tokenProvider = tokenProvider,
       _transport = transport {
    if (timeout <= Duration.zero || timeout > const Duration(seconds: 15)) {
      throw ArgumentError('Use a timeout of at most 15 seconds.');
    }
  }
  final Uri _base;
  final MatchingTokenProvider _tokenProvider;
  final MatchingTransport _transport;
  final Duration timeout;

  Future<void> deleteCase(
    CaseSnapshot snapshot, {
    required int expectedCatalogRevision,
    required bool Function() isCurrent,
  }) async {
    ExportContractValues.integer(expectedCatalogRevision, min: 0);
    final json = await _post(
      'delete-case',
      {
        'schemaVersion': '1',
        'caseId': snapshot.caseId,
        'expectedCaseRevision': snapshot.revision,
        'expectedCatalogRevision': expectedCatalogRevision,
        'confirmation': 'DELETE_CASE',
      },
      isCurrent: isCurrent,
      mutating: true,
    );
    try {
      final value = ExportContractValues.object(json, {
        'schemaVersion',
        'caseId',
        'deleted',
      });
      if (value['schemaVersion'] != '1' ||
          value['caseId'] != snapshot.caseId ||
          value['deleted'] != true) {
        throw const FormatException();
      }
    } catch (_) {
      throw _error('DELETION_UNCERTAIN');
    }
  }

  Future<AccountDeletionPreview> prepareAccountDeletion({
    required bool Function() isCurrent,
  }) async {
    final json = await _post('prepare-account-deletion', {
      'schemaVersion': '1',
    }, isCurrent: isCurrent);
    try {
      return AccountDeletionPreview.fromJson(json);
    } catch (_) {
      throw _error('UNEXPECTED_RESPONSE');
    }
  }

  Future<AccountDeletionState> confirmAccountDeletion(
    AccountDeletionPreview preview, {
    required bool Function() isCurrent,
  }) async {
    final json = await _post(
      'confirm-account-deletion',
      {
        'schemaVersion': '1',
        'deletionToken': preview.deletionToken,
        'confirmation': 'DELETE_ACCOUNT',
      },
      isCurrent: isCurrent,
      mutating: true,
    );
    try {
      final result = AccountDeletionState.fromJson(json);
      if (!result.applicationDataDeleted) throw const FormatException();
      return result;
    } catch (_) {
      throw _error('DELETION_UNCERTAIN');
    }
  }

  Future<AccountDeletionState> readAccountDeletionStatus(
    String receiptToken, {
    required bool Function() isCurrent,
  }) async {
    ExportContractValues.digest(receiptToken);
    final json = await _post(
      'account-deletion-status',
      {'schemaVersion': '1'},
      isCurrent: isCurrent,
      receiptToken: receiptToken,
    );
    try {
      return AccountDeletionState.fromJson(json);
    } catch (_) {
      throw _error('UNEXPECTED_RESPONSE');
    }
  }

  Future<Object?> _post(
    String route,
    Map<String, Object?> body, {
    required bool Function() isCurrent,
    bool mutating = false,
    String? receiptToken,
  }) async {
    void guard() {
      try {
        if (!isCurrent()) throw const FormatException();
      } catch (_) {
        throw _error('STALE_RESPONSE');
      }
    }

    guard();
    final clock = Stopwatch()..start();
    String? token;
    MatchingApiException? authFailure;
    try {
      token = receiptToken ?? await _tokenProvider().timeout(timeout);
    } on TimeoutException {
      authFailure = _error('TIMEOUT');
    } catch (_) {
      authFailure = _error('UNAUTHENTICATED', 401);
    }
    guard();
    if (authFailure != null) throw authFailure;
    if (token == null ||
        token.isEmpty ||
        token.length > 4096 ||
        RegExp(r'^[A-Za-z0-9._~+/\-]+=*$').stringMatch(token) != token) {
      throw _error('UNAUTHENTICATED', 401);
    }
    final remaining = timeout - clock.elapsed;
    if (remaining <= Duration.zero) throw _error('TIMEOUT');
    MatchingExchange? exchange;
    var sent = false;
    try {
      guard();
      sent = true;
      exchange = _transport.post(
        MatchingHttpRequest(
          endpoint: _base.resolve('/v1/$route'),
          bearerToken: token,
          body: utf8.encode(jsonEncode(body)),
          maxResponseBytes: 16 * 1024,
        ),
      );
      guard();
      final response = await exchange.response.timeout(remaining);
      guard();
      if (response.body.length > 16 * 1024) throw _error('RESPONSE_TOO_LARGE');
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
      if (response.statusCode != 200 &&
          !(route == 'confirm-account-deletion' &&
              response.statusCode == 202)) {
        throw _apiError(
          response.statusCode,
          json,
        ).withRetryAfter(response.retryAfter);
      }
      if (route == 'confirm-account-deletion') {
        final state = AccountDeletionState.fromJson(json);
        if (state.status !=
            (response.statusCode == 202 ? 'auth_pending' : 'complete')) {
          throw _error('UNEXPECTED_RESPONSE');
        }
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
          : _error('UNEXPECTED_RESPONSE');
      if (mutating &&
          sent &&
          !{
            'STALE_RESPONSE',
            'INVALID_REQUEST',
            'UNAUTHENTICATED',
            'CASE_NOT_FOUND',
            'CASE_REVISION_MISMATCH',
            'EVIDENCE_CONFLICT',
            'RECENT_AUTHENTICATION_REQUIRED',
            'ACCOUNT_CLOSED',
            'DELETION_NOT_FOUND',
            'DELETION_EXPIRED',
            'DELETION_CHANGED',
            'RATE_LIMITED',
            'PAYLOAD_TOO_LARGE',
            'METHOD_NOT_ALLOWED',
            'UNSUPPORTED_MEDIA_TYPE',
            'NOT_FOUND',
          }.contains(mapped.code)) {
        throw _error('DELETION_UNCERTAIN', mapped.statusCode);
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

MatchingApiException _error(String code, [int? status]) =>
    MatchingApiException.forCode(code, statusCode: status);
MatchingApiException _apiError(int status, Object? json) {
  const codes = {
    400: {'INVALID_REQUEST'},
    401: {'UNAUTHENTICATED'},
    403: {'RECENT_AUTHENTICATION_REQUIRED'},
    404: {'CASE_NOT_FOUND', 'DELETION_NOT_FOUND', 'NOT_FOUND'},
    405: {'METHOD_NOT_ALLOWED'},
    409: {
      'CASE_REVISION_MISMATCH',
      'EVIDENCE_CONFLICT',
      'ACCOUNT_CLOSED',
      'DELETION_CHANGED',
    },
    410: {'DELETION_EXPIRED'},
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

Uri _validateBase(Uri base, bool allowLocal, bool allowEmulator) {
  final local =
      {'localhost', '127.0.0.1', '::1'}.contains(base.host.toLowerCase()) ||
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
          (allowLocal && local && base.scheme == 'http'))) {
    throw ArgumentError(
      'Use an HTTPS API origin; HTTP requires explicit loopback opt-in.',
    );
  }
  return base;
}
