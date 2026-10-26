import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../models/contracts.dart';

typedef MatchingTokenProvider = Future<String?> Function();

class MatchingApiClient {
  MatchingApiClient({
    required Uri endpoint,
    required MatchingTokenProvider tokenProvider,
    required MatchingTransport transport,
    this.timeout = const Duration(seconds: 15),
    this.maxResponseBytes = 1024 * 1024,
    bool allowInsecureLoopback = false,
    bool allowAndroidEmulatorLoopback = false,
  }) : _endpoint = _validateEndpoint(
         endpoint,
         allowInsecureLoopback: allowInsecureLoopback,
         allowAndroidEmulatorLoopback: allowAndroidEmulatorLoopback,
       ),
       _tokenProvider = tokenProvider,
       _transport = transport {
    if (timeout <= Duration.zero || timeout > const Duration(seconds: 15)) {
      throw ArgumentError(
        'Matching timeout must be greater than zero and at most 15 seconds.',
      );
    }
    if (maxResponseBytes < 1 || maxResponseBytes > 1024 * 1024) {
      throw ArgumentError(
        'Matching response limit must be between 1 byte and 1 MiB.',
      );
    }
  }

  final Uri _endpoint;
  final MatchingTokenProvider _tokenProvider;
  final MatchingTransport _transport;
  final Duration timeout;
  final int maxResponseBytes;

  Future<MatchResponse> matchCase(
    CaseSnapshot snapshot, {
    required CaseSnapshot Function() currentCase,
  }) async {
    if (snapshot.caseId.runes.length > 200 ||
        !RegExp(r'\S', unicode: true).hasMatch(snapshot.caseId) ||
        snapshot.revision > 9007199254740991) {
      throw const MatchingApiException._(
        'INVALID_REQUEST',
        'The matching request was invalid. Review the case and try again.',
        statusCode: 400,
      );
    }
    final elapsed = Stopwatch()..start();
    final token = await _freshToken();
    _requireCurrent(snapshot, currentCase);
    final remaining = timeout - elapsed.elapsed;
    if (remaining <= Duration.zero) {
      throw const MatchingApiException._(
        'TIMEOUT',
        'The matching request timed out. Try again.',
      );
    }

    MatchingExchange? exchange;
    late MatchingHttpResponse response;
    try {
      exchange = _transport.post(
        MatchingHttpRequest(
          endpoint: _endpoint,
          bearerToken: token,
          body: utf8.encode(
            jsonEncode({
              'schemaVersion': '1',
              'caseId': snapshot.caseId,
              'expectedCaseRevision': snapshot.revision,
            }),
          ),
          maxResponseBytes: maxResponseBytes,
        ),
      );
      response = await exchange.response.timeout(remaining);
    } on TimeoutException {
      throw const MatchingApiException._(
        'TIMEOUT',
        'The matching request timed out. Try again.',
      );
    } on MatchingTransportException catch (error) {
      throw _transportError(error.failure);
    } catch (_) {
      throw const MatchingApiException._(
        'NETWORK_ERROR',
        'Unable to reach the matching service. Try again when connected.',
      );
    } finally {
      exchange?.cancel();
    }
    _requireCurrent(snapshot, currentCase);
    if (response.body.length > maxResponseBytes) {
      throw _transportError(MatchingTransportFailure.responseTooLarge);
    }
    if (response.statusCode >= 300 && response.statusCode < 400) {
      throw _transportError(MatchingTransportFailure.redirectBlocked);
    }
    if (response.contentType?.split(';').first.trim().toLowerCase() !=
        'application/json') {
      throw _unexpectedResponse;
    }

    final Object? json;
    try {
      json = jsonDecode(utf8.decode(response.body));
    } catch (_) {
      throw _unexpectedResponse;
    }
    if (response.statusCode != 200) {
      throw _apiError(
        response.statusCode,
        json,
      ).withRetryAfter(response.retryAfter);
    }

    final MatchResponse result;
    try {
      result = MatchResponse.fromJson(json);
    } catch (_) {
      throw _unexpectedResponse;
    }
    if (result.caseId != snapshot.caseId ||
        result.caseRevision != snapshot.revision) {
      throw const MatchingApiException._(
        'STALE_RESPONSE',
        'The case changed or the response describes another revision. Refresh the matches.',
      );
    }
    return result;
  }

  Future<String> _freshToken() async {
    final String? token;
    try {
      token = await _tokenProvider().timeout(timeout);
    } on TimeoutException {
      throw const MatchingApiException._(
        'TIMEOUT',
        'The matching request timed out. Try again.',
      );
    } catch (_) {
      throw _signInRequired;
    }
    if (token == null || !RegExp(r'^[A-Za-z0-9\-._~+/]+=*$').hasMatch(token)) {
      throw _signInRequired;
    }
    return token;
  }
}

abstract interface class MatchingTransport {
  MatchingExchange post(MatchingHttpRequest request);
}

List<int> _immutableBytes(List<int> bytes) {
  if (bytes.any((byte) => byte < 0 || byte > 255)) {
    throw ArgumentError('HTTP body must contain bytes from 0 through 255.');
  }
  return Uint8List.fromList(bytes).asUnmodifiableView();
}

class MatchingHttpRequest {
  MatchingHttpRequest({
    required this.endpoint,
    required this.bearerToken,
    required List<int> body,
    required this.maxResponseBytes,
    this.accept = 'application/json',
  }) : body = _immutableBytes(body);

  final Uri endpoint;
  final String bearerToken;
  final List<int> body;
  final int maxResponseBytes;
  final String accept;
}

class MatchingHttpResponse {
  MatchingHttpResponse({
    required this.statusCode,
    required this.contentType,
    required List<int> body,
    this.retryAfter,
  }) : body = _immutableBytes(body);

  final String? retryAfter;
  final int statusCode;
  final String? contentType;
  final List<int> body;
}

class MatchingExchange {
  MatchingExchange({required this.response, required void Function() cancel})
    : _cancel = cancel;

  final Future<MatchingHttpResponse> response;
  final void Function() _cancel;
  bool _cancelled = false;

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    _cancel();
  }
}

enum MatchingTransportFailure { network, responseTooLarge, redirectBlocked }

class MatchingTransportException implements Exception {
  const MatchingTransportException(this.failure);
  final MatchingTransportFailure failure;

  @override
  String toString() => 'MatchingTransportException(${failure.name})';
}

class MatchingApiException implements Exception {
  const MatchingApiException._(
    this.code,
    this.message, {
    this.statusCode,
    this.retryAfter,
  });

  factory MatchingApiException.forCode(String code, {int? statusCode}) {
    const messages = {
      'SCAN_MODEL_CONFLICT':
          'The account model changed. Check both copies before replacing either.',
      'SCAN_MODEL_MUTATION_CONFLICT':
          'This model upload identifier was already used. Review the account copy.',
      'SCAN_MODEL_LIMIT':
          'Model storage is full. Existing account and device copies are retained.',
      'SCAN_MODEL_SAVE_UNCERTAIN':
          'The model upload could not be confirmed. Retry the same pending upload.',
      'SHARING_NOT_FOUND':
          'Sharing could not be confirmed. Refresh access before trying again.',
      'SHARING_CONFLICT':
          'Sharing could not be confirmed. Refresh access before trying again.',
      'SHARING_LIMIT':
          'Sharing could not be confirmed. Refresh access before trying again.',
      'SHARING_SAVE_UNCERTAIN':
          'Sharing could not be confirmed. Refresh access before trying again.',
      'PROGRESS_CONFLICT':
          'Program progress changed. Refresh and review your pending change.',
      'TASK_CONFLICT':
          'This task changed. Refresh and review your pending change.',
      'PROGRESS_MUTATION_CONFLICT':
          'This save identifier was already used. Review saved progress before discarding the pending change.',
      'PROGRESS_LIMIT':
          'The tracking limit has been reached. Existing tasks and history are retained.',
      'PROGRESS_SAVE_UNCERTAIN':
          'This save could not be confirmed. Retry the same pending change to avoid duplicates.',
      'RECENT_AUTHENTICATION_REQUIRED':
          'Enter your password again before deleting your account.',
      'ACCOUNT_CLOSED':
          'This account is closed. Use the saved deletion receipt to check completion.',
      'DELETION_NOT_FOUND':
          'This deletion receipt is unavailable. Contact the app operator if confirmation was already sent.',
      'DELETION_EXPIRED':
          'The deletion preview expired. Review a new preview before confirming.',
      'DELETION_CHANGED':
          'Account data changed. Review a new deletion preview before confirming.',
      'DELETION_UNCERTAIN':
          'The deletion outcome is unknown. Check the retained receipt or reload the case before deciding whether to retry.',
      'ASSESSMENT_CONFLICT':
          'The assessment changed. Reload and reconcile your local changes.',
      'ASSESSMENT_MUTATION_CONFLICT':
          'This assessment attempt refers to different changes. Reload before continuing.',
      'ASSESSMENT_HISTORY_LIMIT':
          'This case reached its assessment history limit. Contact the app operator.',
      'ASSESSMENT_UPDATE_REQUIRED':
          'Use the assessment editor to preserve measurements and review history.',
      'ANNOTATION_CONFLICT':
          'The photo markings changed. Reload and review them before saving.',
      'ANNOTATIONS_REQUIRE_V2':
          'This photo has saved markings. Use the current draft export flow.',
      'ANNOTATION_REVIEW_REQUIRED':
          'Review the current photo and its markings before export.',
      'INTAKE_CONFLICT':
          'Program answers changed. Reload and reconcile your answers.',
      'QUESTIONNAIRE_CHANGED':
          'These questions changed. Review the current questionnaire.',
      'INTAKE_SAVE_UNCERTAIN':
          'The save result is uncertain. Keep your local answers and reload before reconciling.',
      'INTAKE_REQUIRES_V2':
          'Use the current draft workflow to include saved program answers.',
      'INVALID_REQUEST':
          'The request was invalid. Review the case and try again.',
      'UNAUTHENTICATED': 'Sign in before continuing.',
      'CASE_NOT_FOUND': 'This case is unavailable to the signed-in user.',
      'PROGRAM_NOT_FOUND':
          'The selected program is unavailable. Refresh the programs.',
      'NOT_FOUND':
          'The endpoint was not found. Check the service configuration.',
      'CASE_REVISION_MISMATCH':
          'The saved case changed. Reload it before continuing.',
      'CASE_ID_UNAVAILABLE':
          'This case identifier is unavailable. Reload the selected case to recover an earlier attempt, or start a new case with a fresh identifier.',
      'CASE_SAVE_UNCERTAIN':
          'The case save outcome is unknown. Reload this same case identifier before deciding whether to save again.',
      'PLAN_NAME_CONFLICT':
          'This plan name changed elsewhere. Compare the saved name with your edit before trying again.',
      'HOME_SAFETY_CONFLICT':
          'This device and the saved checklist differ. Review both before continuing.',
      'HOME_SAFETY_MUTATION_CONFLICT':
          'The saved case changed. Reload it before continuing.',
      'HOME_SAFETY_HISTORY_LIMIT':
          'The checklist history limit has been reached. Existing work is retained.',
      'HOME_SAFETY_SAVE_UNCERTAIN':
          'This step could not finish. Your saved device changes are retained. Check saved state before trying again.',
      'NAME_SAVE_UNCERTAIN':
          'The plan name save could not be confirmed. Keep your edit and check the saved name before retrying.',
      'EVIDENCE_SAVE_UNCERTAIN':
          'The image change outcome is unknown. Reload the case and evidence catalog before changing the image again.',
      'INVALID_IMAGE':
          'The image could not be processed. Choose a supported JPEG or PNG within the image limits.',
      'RATE_LIMITED':
          'Too many requests. Wait before trying this same action again.',
      'UPLOAD_BUSY':
          'Another image is being processed. Wait before trying again.',
      'PACKET_GENERATION_CONFLICT':
          'The case or program changed since this draft was started. Start a new draft.',
      'REQUEST_REVISION_MISMATCH':
          'The request history changed. Reload it before recording another update.',
      'REQUEST_UPDATE_CONFLICT':
          'This update identifier already refers to a different saved report. Read the history before continuing.',
      'REQUEST_HISTORY_FULL':
          'This case has reached its request history limit.',
      'REQUEST_UPDATE_UNCERTAIN':
          'The update outcome is unknown. Read this request history and compare the retained update before deciding whether to retry.',
      'FORM_NOT_AVAILABLE':
          'Reviewed form answers are unavailable for this program.',
      'FORM_CONTEXT_MISMATCH':
          'The form changed. Reload it before saving answers.',
      'FORM_ANSWERS_CONFLICT':
          'The saved answers changed. Reload them before saving.',
      'FORM_ANSWERS_STALE':
          'Review and save the form answers for the current case and form before preparing a draft.',
      'FORM_SAVE_UNCERTAIN':
          'The save outcome is unknown. Reload the case and form answers before saving again.',
      'ARTIFACT_NOT_FOUND': 'The requested private file is unavailable.',
      'EVIDENCE_CONFLICT':
          'The evidence changed. Reload it and review your selection again.',
      'FORM_ANSWER_REVISION_MISMATCH':
          'The saved answers changed. Reload them before preparing a draft.',
      'EXPORT_GENERATION_CONFLICT':
          'This export attempt no longer matches the current case. Review the changes before starting another attempt.',
      'EXPORT_EXPIRED':
          'This draft download has expired. Prepare a new draft from the current case.',
      'EXPORT_REVIEW_REQUIRED':
          'Review the selected evidence before preparing the draft.',
      'EXPORT_BUSY':
          'Another draft is being prepared. Wait and retry this same attempt.',
      'STORAGE_LIMIT_REACHED':
          'Private storage has reached its limit. Contact the app operator before retrying.',
      'PAYLOAD_TOO_LARGE': 'The request was too large.',
      'UNSUPPORTED_MEDIA_TYPE':
          'The service could not read the request format.',
      'METHOD_NOT_ALLOWED': 'The service could not accept this request method.',
      'INTERNAL_ERROR': 'The service could not finish the request. Try again.',
      'SERVICE_UNAVAILABLE':
          'The service is temporarily unavailable. Try again later.',
      'TIMEOUT': 'The request timed out. Retry the same preparation attempt.',
      'NETWORK_ERROR': 'Unable to reach the service. Try again when connected.',
      'RESPONSE_TOO_LARGE': 'The service response was too large. Try again.',
      'REDIRECT_BLOCKED':
          'The service destination changed. Check the service configuration.',
      'STALE_RESPONSE':
          'The case or selected program changed. Refresh before continuing.',
      'UNEXPECTED_RESPONSE':
          'The service returned an unexpected response. Try again.',
    };
    final message = messages[code];
    if (message == null) {
      return const MatchingApiException._(
        'UNEXPECTED_RESPONSE',
        'The service returned an unexpected response. Try again.',
      );
    }
    return MatchingApiException._(code, message, statusCode: statusCode);
  }
  final String code;
  final String message;
  final int? statusCode;

  final Duration? retryAfter;

  MatchingApiException withRetryAfter(String? value) {
    if ((statusCode != 429 && statusCode != 503) ||
        value == null ||
        value.length > 4 ||
        RegExp(r'[1-9][0-9]{0,3}').stringMatch(value) != value) {
      return this;
    }
    final seconds = int.parse(value);
    if (seconds > 3600) return this;
    return MatchingApiException._(
      code,
      message,
      statusCode: statusCode,
      retryAfter: Duration(seconds: seconds),
    );
  }

  @override
  String toString() => 'MatchingApiException($code): $message';
}

const _signInRequired = MatchingApiException._(
  'UNAUTHENTICATED',
  'Sign in before requesting matches.',
  statusCode: 401,
);
const _unexpectedResponse = MatchingApiException._(
  'UNEXPECTED_RESPONSE',
  'The matching service returned an unexpected response. Try again.',
);

MatchingApiException _transportError(
  MatchingTransportFailure failure,
) => switch (failure) {
  MatchingTransportFailure.network => const MatchingApiException._(
    'NETWORK_ERROR',
    'Unable to reach the matching service. Try again when connected.',
  ),
  MatchingTransportFailure.responseTooLarge => const MatchingApiException._(
    'RESPONSE_TOO_LARGE',
    'The matching service response was too large. Try again.',
  ),
  MatchingTransportFailure.redirectBlocked => const MatchingApiException._(
    'REDIRECT_BLOCKED',
    'The matching service destination changed. Check the service configuration.',
  ),
};

void _requireCurrent(
  CaseSnapshot requested,
  CaseSnapshot Function() currentCase,
) {
  final CaseSnapshot current;
  try {
    current = currentCase();
  } catch (_) {
    throw const MatchingApiException._(
      'STALE_RESPONSE',
      'The current case is unavailable. Refresh the matches.',
    );
  }
  if (current.caseId != requested.caseId ||
      current.revision != requested.revision) {
    throw const MatchingApiException._(
      'STALE_RESPONSE',
      'The case changed while matching. Refresh the matches.',
    );
  }
}

MatchingApiException _apiError(int statusCode, Object? json) {
  const codes = {
    400: (
      'INVALID_REQUEST',
      'The matching request was invalid. Review the case and try again.',
    ),
    401: ('UNAUTHENTICATED', 'Sign in before requesting matches.'),
    404: ('CASE_NOT_FOUND', 'This case is unavailable to the signed-in user.'),
    409: (
      'CASE_REVISION_MISMATCH',
      'The saved case changed. Refresh it before matching.',
    ),
    429: (
      'RATE_LIMITED',
      'Too many requests. Wait before trying this same action again.',
    ),
    413: ('PAYLOAD_TOO_LARGE', 'The matching request was too large.'),
    415: (
      'UNSUPPORTED_MEDIA_TYPE',
      'The matching service could not read the request format.',
    ),
    405: (
      'METHOD_NOT_ALLOWED',
      'The matching service could not accept this request method.',
    ),
    500: (
      'INTERNAL_ERROR',
      'The matching service could not finish the request. Try again.',
    ),
    503: (
      'SERVICE_UNAVAILABLE',
      'The matching service is temporarily unavailable. Try again later.',
    ),
  };
  if (json is! Map<String, dynamic> ||
      json.length != 2 ||
      json['schemaVersion'] != '1' ||
      !json.containsKey('error')) {
    return _unexpectedResponse;
  }
  final error = json['error'];
  if (error is! Map<String, dynamic> ||
      error.length != 2 ||
      error['message'] is! String ||
      (error['message'] as String).isEmpty) {
    return _unexpectedResponse;
  }
  final expected = statusCode == 404 && error['code'] == 'NOT_FOUND'
      ? (
          'NOT_FOUND',
          'The matching endpoint was not found. Check the service configuration.',
        )
      : codes[statusCode];
  if (expected == null || error['code'] != expected.$1) {
    return _unexpectedResponse;
  }
  return MatchingApiException._(
    expected.$1,
    expected.$2,
    statusCode: statusCode,
  );
}

Uri _validateEndpoint(
  Uri endpoint, {
  required bool allowInsecureLoopback,
  required bool allowAndroidEmulatorLoopback,
}) {
  final safeShape =
      endpoint.hasAuthority &&
      endpoint.host.isNotEmpty &&
      endpoint.userInfo.isEmpty &&
      !endpoint.hasQuery &&
      !endpoint.hasFragment &&
      endpoint.path == '/v1/match-case' &&
      endpoint.port >= 1 &&
      endpoint.port <= 65535;
  final loopback =
      {'localhost', '127.0.0.1', '::1'}.contains(endpoint.host.toLowerCase()) ||
      (allowAndroidEmulatorLoopback && endpoint.host == '10.0.2.2');
  final safeScheme =
      endpoint.scheme == 'https' ||
      (endpoint.scheme == 'http' && allowInsecureLoopback && loopback);
  if (!safeShape || !safeScheme) {
    throw ArgumentError(
      'Use an HTTPS /v1/match-case endpoint without credentials, query, or fragment. HTTP requires explicit loopback opt-in.',
    );
  }
  return endpoint;
}
