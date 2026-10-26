import 'dart:async';
import 'dart:convert';
import '../models/sensitive_sharing.dart';
import '../models/sharing.dart';
import '../models/export_contract_values.dart';
import 'matching_api_client.dart';
import 'token_availability.dart';

const sharingMaxResponseBytes = 2 * 1024 * 1024;

class SharingApiClient {
  SharingApiClient({
    required Uri baseUri,
    required MatchingTokenProvider tokenProvider,
    required MatchingTransport transport,
    this.timeout = const Duration(seconds: 15),
    this.includeLabels = false,
    bool allowInsecureLoopback = false,
  }) : _base = _validateBase(baseUri, allowInsecureLoopback, false),
       _tokens = tokenProvider,
       _transport = transport {
    if (timeout <= Duration.zero || timeout > const Duration(seconds: 15)) {
      throw ArgumentError('Invalid timeout.');
    }
  }
  final Uri _base;
  final MatchingTokenProvider _tokens;
  final MatchingTransport _transport;
  final Duration timeout;

  final bool includeLabels;
  Future<SharingResponse> request(
    String route,
    Map<String, Object?> fields, {
    required bool Function() isCurrent,
  }) async {
    const reads = {
      'read-collaboration',
      'preview-sharing',
      'list-sharing',
      'list-email-sharing',
      'review-invitation',
      'list-shared-cases',
      'read-shared-case',
    };
    const writes = {
      'configure-collaboration',
      'update-shared-task',
      'propose-shared-status',
      'review-shared-status',
      'create-invitation',
      'create-email-invitation',
      'change-sharing',
      'revoke-sharing',
      'accept-invitation',
      'add-shared-note',
    };
    if (!reads.contains(route) && !writes.contains(route)) {
      throw ArgumentError('Invalid sharing operation.');
    }
    const labelFields = {'includeLabels', 'recipientLabel', 'ownerLabel'};
    if (fields.keys.any(labelFields.contains) &&
        (!includeLabels || fields.containsKey('includeLabels'))) {
      throw ArgumentError('Sharing labels are not enabled.');
    }
    const labelled = {
      'list-sharing',
      'list-email-sharing',
      'list-shared-cases',
      'review-invitation',
    };
    final json = await _post(
      route,
      {
        'schemaVersion': '3',
        ...fields,
        if (includeLabels && labelled.contains(route)) 'includeLabels': true,
      },
      guard: () => _current(isCurrent),
      saving: writes.contains(route),
    );
    try {
      final response = SharingResponse.fromJson(json, route);
      final work = response.collaboration;
      if (work != null) {
        if (work.membershipId != fields['membershipId'] ||
            work.permissionRevision !=
                (fields['expectedPermissionRevision'] as int) +
                    (route == 'configure-collaboration' ? 1 : 0) ||
            (writes.contains(route) &&
                work.acknowledgement != fields['mutationId'])) {
          throw const FormatException();
        }
      }
      final grant = response.membership;
      if (!includeLabels &&
          [
            ?grant,
            ...response.memberships,
            ...response.shares.map((s) => s.membership),
          ].any((m) => m.ownerLabel != null || m.recipientLabel != null)) {
        throw const FormatException();
      }
      if (grant != null &&
          ((fields['membershipId'] != null &&
                  grant.id != fields['membershipId']) ||
              (fields['invitationId'] != null &&
                  grant.id != fields['invitationId']) ||
              (fields['caseId'] != null && grant.caseId != fields['caseId']))) {
        throw const FormatException();
      }
      if (response.projection != null &&
          fields['caseId'] != null &&
          response.projection!.caseId != fields['caseId']) {
        throw const FormatException();
      }
      if (grant != null && fields['expectedPermissionRevision'] is int) {
        final expected = fields['expectedPermissionRevision'] as int;
        final changes = {
          'change-sharing',
          'revoke-sharing',
          'accept-invitation',
        }.contains(route);
        if (grant.revision != expected + (changes ? 1 : 0)) {
          throw const FormatException();
        }
      }
      return response;
    } catch (_) {
      throw _error(
        writes.contains(route)
            ? 'SHARING_SAVE_UNCERTAIN'
            : 'UNEXPECTED_RESPONSE',
      );
    }
  }

  Future<SensitiveResponse> sensitive(
    String route,
    Map<String, Object?> fields, {
    required bool Function() isCurrent,
    required String expectedCaseId,
  }) async {
    if (!sensitiveSharingRoutes.contains(route)) {
      throw ArgumentError('Unknown selected-data route.');
    }
    void guard() => _current(isCurrent);
    guard();
    final json = await _post(
      route,
      {'schemaVersion': '3', ...fields},
      guard: guard,
      saving: route == 'publish-sensitive-sharing',
      maxBytes: route.endsWith('-photo')
          ? 12 * 1024 * 1024
          : route.endsWith('-report')
          ? 3 * 1024 * 1024
          : sharingMaxResponseBytes,
    );
    guard();
    try {
      final r = SensitiveResponse.fromJson(route, json);
      if (r.membershipId != fields['membershipId'] ||
          r.permissionRevision !=
              (fields['expectedPermissionRevision'] as int) +
                  (route == 'publish-sensitive-sharing' ? 1 : 0) ||
          r.caseId != null && r.caseId != expectedCaseId ||
          r.sourceHash != null &&
              (fields['sourceHash'] ?? fields['previewHash']) != null &&
              r.sourceHash != (fields['sourceHash'] ?? fields['previewHash']) ||
          r.descriptor != null &&
              (r.descriptor!.caseId != expectedCaseId ||
                  r.descriptor!.evidenceId != fields['evidenceId'] ||
                  r.descriptor!.evidenceRevision !=
                      fields['expectedEvidenceRevision']) ||
          route == 'publish-sensitive-sharing' &&
              r.acknowledgement != fields['mutationId']) {
        throw const FormatException();
      }
      if (fields['expectedCaseRevision'] != null &&
              r.caseRevision != null &&
              r.caseRevision != fields['expectedCaseRevision'] ||
          fields['expectedCatalogRevision'] != null &&
              r.catalogRevision != null &&
              r.catalogRevision != fields['expectedCatalogRevision']) {
        throw const FormatException();
      }
      return r;
    } catch (_) {
      throw _error(
        route == 'publish-sensitive-sharing'
            ? 'SHARING_SAVE_UNCERTAIN'
            : 'UNEXPECTED_RESPONSE',
      );
    }
  }

  Future<Object?> _post(
    String route,
    Map<String, Object?> body, {
    required void Function() guard,
    bool saving = false,
    int maxBytes = sharingMaxResponseBytes,
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
        throw _error('SHARING_SAVE_UNCERTAIN', mapped.statusCode);
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
  'SHARING_CONFLICT',
  'SHARING_NOT_FOUND',
  'SHARING_LIMIT',
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
    404: {'SHARING_NOT_FOUND', 'NOT_FOUND'},
    405: {'METHOD_NOT_ALLOWED'},
    409: {'SHARING_CONFLICT', 'ACCOUNT_CLOSED'},
    507: {'SHARING_LIMIT'},
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
