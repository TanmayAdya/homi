import 'dart:async';
import 'dart:convert';

import '../models/contracts.dart';
import '../models/form_answers.dart';
import 'matching_api_client.dart';

class FormAnswersApiClient {
  FormAnswersApiClient({
    required Uri readEndpoint,
    required Uri saveEndpoint,
    required Uri caseEndpoint,
    required MatchingTokenProvider tokenProvider,
    required MatchingTransport transport,
    this.timeout = const Duration(seconds: 15),
    this.maxResponseBytes = 1024 * 1024,
    this.maxRequestBytes = 16 * 1024,
    bool allowInsecureLoopback = false,
    bool allowAndroidEmulatorLoopback = false,
  }) : _readEndpoint = _endpoint(
         readEndpoint,
         '/v1/read-form-answers',
         allowInsecureLoopback,
         allowAndroidEmulatorLoopback,
       ),
       _saveEndpoint = _endpoint(
         saveEndpoint,
         '/v1/save-form-answers',
         allowInsecureLoopback,
         allowAndroidEmulatorLoopback,
       ),
       _caseEndpoint = _endpoint(
         caseEndpoint,
         '/v1/read-case',
         allowInsecureLoopback,
         allowAndroidEmulatorLoopback,
       ),
       _tokenProvider = tokenProvider,
       _transport = transport {
    if (timeout <= Duration.zero ||
        timeout > const Duration(seconds: 15) ||
        maxResponseBytes < 1 ||
        maxResponseBytes > 1024 * 1024 ||
        maxRequestBytes < 1 ||
        maxRequestBytes > 16 * 1024) {
      throw ArgumentError('Invalid form-answer timeout or body limits.');
    }
    if (_readEndpoint.origin != _saveEndpoint.origin ||
        _readEndpoint.origin != _caseEndpoint.origin) {
      throw ArgumentError('Form-answer endpoints must use the same origin.');
    }
  }

  final Uri _readEndpoint;
  final Uri _saveEndpoint;
  final Uri _caseEndpoint;
  final MatchingTokenProvider _tokenProvider;
  final MatchingTransport _transport;
  final Duration timeout;
  final int maxResponseBytes;
  final int maxRequestBytes;

  Future<CaseSnapshot> reloadCase(
    String caseId, {
    required CaseSnapshot Function() currentCase,
  }) async {
    if (!_identifier(caseId)) throw _error('INVALID_REQUEST', status: 400);
    var latestKnownRevision = 0;
    void requireCurrent() {
      try {
        final current = currentCase();
        if (current.caseId != caseId ||
            current.revision < 1 ||
            current.revision > 9007199254740991) {
          throw const FormatException('Case selection changed.');
        }
        if (current.revision > latestKnownRevision) {
          latestKnownRevision = current.revision;
        }
      } catch (_) {
        throw _error('STALE_RESPONSE');
      }
    }

    final json = await _post(
      _caseEndpoint,
      {'schemaVersion': '1', 'caseId': caseId},
      isSave: false,
      requireCurrent: requireCurrent,
    );
    requireCurrent();
    final CaseSnapshot result;
    try {
      result = CaseSnapshot.fromJson(json);
      if (!_identifier(result.caseId) || result.revision > 9007199254740991) {
        throw const FormatException(
          'Invalid loaded case identity or revision.',
        );
      }
    } catch (_) {
      throw _error('UNEXPECTED_RESPONSE');
    }
    requireCurrent();
    if (result.caseId != caseId || result.revision < latestKnownRevision) {
      throw _error('STALE_RESPONSE');
    }
    return result;
  }

  Future<FormAnswersResponse> readAnswers(
    CaseSnapshot snapshot, {
    required String programId,
    required CaseSnapshot Function() currentCase,
    required String Function() currentProgramId,
    required FormAnswerContext? Function() currentContext,
  }) async {
    final FormAnswersReadRequest request;
    try {
      request = FormAnswersReadRequest.fromJson({
        'schemaVersion': '1',
        'caseId': snapshot.caseId,
        'expectedCaseRevision': snapshot.revision,
        'programId': programId,
      });
    } catch (_) {
      throw _error('INVALID_REQUEST', status: 400);
    }
    final localContext = _captureContext(currentContext);
    void requireCurrent() => _requireCurrent(
      request.caseId,
      request.expectedCaseRevision,
      programId,
      localContext,
      currentCase,
      currentProgramId,
      currentContext,
    );
    final json = await _post(
      _readEndpoint,
      request.toJson(),
      isSave: false,
      requireCurrent: requireCurrent,
    );
    requireCurrent();
    final response = _response(json, isSave: false);
    if (response.caseId != request.caseId ||
        response.caseRevision != request.expectedCaseRevision ||
        response.context.programId != programId) {
      throw _error('STALE_RESPONSE');
    }
    return response;
  }

  Future<FormAnswersResponse> saveAnswers(
    CaseSnapshot snapshot, {
    required FormAnswerContext context,
    required int expectedAnswerRevision,
    required List<FormAnswerInput> answers,
    required CaseSnapshot Function() currentCase,
    required String Function() currentProgramId,
    required FormAnswerContext? Function() currentContext,
  }) async {
    final FormAnswersSaveRequest request;
    final FormAnswerContext requestedContext;
    try {
      if (snapshot.revision >= 9007199254740991 ||
          expectedAnswerRevision >= 9007199254740991) {
        throw const FormatException('Revision cannot advance.');
      }
      requestedContext = FormAnswerContext.fromJson(context.toJson());
      request = FormAnswersSaveRequest.fromJson({
        'schemaVersion': '1',
        'caseId': snapshot.caseId,
        'expectedCaseRevision': snapshot.revision,
        'programId': requestedContext.programId,
        'expectedFormContextId': requestedContext.formContextId,
        'expectedAnswerRevision': expectedAnswerRevision,
        'answers': answers.map((answer) => answer.toJson()).toList(),
      });
    } catch (_) {
      throw _error('INVALID_REQUEST', status: 400);
    }
    void requireCurrent() => _requireCurrent(
      request.caseId,
      request.expectedCaseRevision,
      requestedContext.programId,
      requestedContext,
      currentCase,
      currentProgramId,
      currentContext,
    );
    final json = await _post(
      _saveEndpoint,
      request.toJson(),
      isSave: true,
      requireCurrent: requireCurrent,
    );
    try {
      requireCurrent();
    } catch (_) {
      throw _error('FORM_SAVE_UNCERTAIN');
    }
    final response = _response(json, isSave: true);
    final saved = response.saved;
    if (response.caseId != request.caseId ||
        response.caseRevision != request.expectedCaseRevision + 1 ||
        !_sameContext(response.context, requestedContext) ||
        !response.isCurrent ||
        saved == null ||
        saved.answerRevision != request.expectedAnswerRevision + 1 ||
        !_sameAnswers(saved.answers, request.answers)) {
      throw _error('FORM_SAVE_UNCERTAIN');
    }
    return response;
  }

  Future<Object?> _post(
    Uri endpoint,
    Map<String, Object?> body, {
    required bool isSave,
    required void Function() requireCurrent,
  }) async {
    final bytes = utf8.encode(jsonEncode(body));
    if (bytes.length > maxRequestBytes) {
      throw _error('PAYLOAD_TOO_LARGE', status: 413);
    }
    requireCurrent();
    final elapsed = Stopwatch()..start();
    final token = await _freshToken();
    requireCurrent();
    final remaining = timeout - elapsed.elapsed;
    if (remaining <= Duration.zero) throw _error('TIMEOUT');

    MatchingExchange? exchange;
    late MatchingHttpResponse response;
    try {
      exchange = _transport.post(
        MatchingHttpRequest(
          endpoint: endpoint,
          bearerToken: token,
          body: bytes,
          maxResponseBytes: maxResponseBytes,
        ),
      );
      response = await exchange.response.timeout(remaining);
    } on TimeoutException {
      throw _error(isSave ? 'FORM_SAVE_UNCERTAIN' : 'TIMEOUT');
    } on MatchingTransportException catch (error) {
      final code = switch (error.failure) {
        MatchingTransportFailure.network => 'NETWORK_ERROR',
        MatchingTransportFailure.responseTooLarge => 'RESPONSE_TOO_LARGE',
        MatchingTransportFailure.redirectBlocked => 'REDIRECT_BLOCKED',
      };
      throw _error(isSave ? 'FORM_SAVE_UNCERTAIN' : code);
    } catch (_) {
      throw _error(isSave ? 'FORM_SAVE_UNCERTAIN' : 'NETWORK_ERROR');
    } finally {
      try {
        exchange?.cancel();
      } catch (_) {
        // ignore: empty_catches
      }
    }
    try {
      requireCurrent();
    } catch (_) {
      throw _error(isSave ? 'FORM_SAVE_UNCERTAIN' : 'STALE_RESPONSE');
    }
    if (response.body.length > maxResponseBytes) {
      throw _error(isSave ? 'FORM_SAVE_UNCERTAIN' : 'RESPONSE_TOO_LARGE');
    }
    if (response.statusCode >= 300 && response.statusCode < 400) {
      throw _error(isSave ? 'FORM_SAVE_UNCERTAIN' : 'REDIRECT_BLOCKED');
    }
    if (response.contentType?.split(';').first.trim().toLowerCase() !=
        'application/json') {
      throw _error(isSave ? 'FORM_SAVE_UNCERTAIN' : 'UNEXPECTED_RESPONSE');
    }
    final Object? json;
    try {
      json = jsonDecode(utf8.decode(response.body));
    } catch (_) {
      throw _error(isSave ? 'FORM_SAVE_UNCERTAIN' : 'UNEXPECTED_RESPONSE');
    }
    if (response.statusCode != 200) {
      final error = _apiError(
        response.statusCode,
        json,
      ).withRetryAfter(response.retryAfter);
      if (isSave &&
          (response.statusCode >= 500 || error.code == 'UNEXPECTED_RESPONSE')) {
        throw _error('FORM_SAVE_UNCERTAIN');
      }
      throw error;
    }
    return json;
  }

  Future<String> _freshToken() async {
    final String? token;
    try {
      token = await _tokenProvider().timeout(timeout);
    } on TimeoutException {
      throw _error('TIMEOUT');
    } catch (_) {
      throw _error('UNAUTHENTICATED', status: 401);
    }
    if (token == null ||
        token.length > 4096 ||
        RegExp(r'^[A-Za-z0-9\-._~+/]+=*$').stringMatch(token) != token) {
      throw _error('UNAUTHENTICATED', status: 401);
    }
    return token;
  }
}

FormAnswersResponse _response(Object? json, {required bool isSave}) {
  try {
    return FormAnswersResponse.fromJson(json);
  } catch (_) {
    throw _error(isSave ? 'FORM_SAVE_UNCERTAIN' : 'UNEXPECTED_RESPONSE');
  }
}

FormAnswerContext? _captureContext(FormAnswerContext? Function() current) {
  try {
    final value = current();
    return value == null ? null : FormAnswerContext.fromJson(value.toJson());
  } catch (_) {
    throw _error('STALE_RESPONSE');
  }
}

void _requireCurrent(
  String caseId,
  int revision,
  String programId,
  FormAnswerContext? expected,
  CaseSnapshot Function() currentCase,
  String Function() currentProgram,
  FormAnswerContext? Function() currentContext,
) {
  try {
    final current = currentCase();
    if (current.caseId != caseId ||
        current.revision != revision ||
        currentProgram() != programId ||
        (expected != null && expected.programId != programId) ||
        !_sameContext(currentContext(), expected)) {
      throw const FormatException('Selection changed.');
    }
  } catch (_) {
    throw _error('STALE_RESPONSE');
  }
}

bool _sameContext(FormAnswerContext? a, FormAnswerContext? b) =>
    a == null || b == null
    ? a == null && b == null
    : a.programId == b.programId &&
          a.formVersion == b.formVersion &&
          a.mappingVersion == b.mappingVersion &&
          a.formContextId == b.formContextId;

bool _sameAnswers(List<SavedFormAnswer> saved, List<FormAnswerInput> sent) {
  if (saved.length != sent.length) return false;
  final byKey = {for (final answer in sent) answer.key: answer};
  return saved.every(
    (answer) =>
        byKey[answer.key]?.value == answer.value &&
        byKey[answer.key]?.reviewState == answer.reviewState,
  );
}

bool _identifier(String value) =>
    value.isNotEmpty &&
    value.trim() == value &&
    value.runes.length <= 200 &&
    !RegExp(r'[\x00-\x1f\x7f-\x9f\u2028\u2029]').hasMatch(value) &&
    !value.runes.any((rune) => rune >= 0xd800 && rune <= 0xdfff);

MatchingApiException _error(String code, {int? status}) =>
    MatchingApiException.forCode(code, statusCode: status);

MatchingApiException _apiError(int status, Object? json) {
  const codes = {
    400: {'INVALID_REQUEST'},
    401: {'UNAUTHENTICATED'},
    404: {
      'CASE_NOT_FOUND',
      'PROGRAM_NOT_FOUND',
      'FORM_NOT_AVAILABLE',
      'NOT_FOUND',
    },
    409: {
      'CASE_REVISION_MISMATCH',
      'FORM_CONTEXT_MISMATCH',
      'FORM_ANSWERS_CONFLICT',
      'FORM_ANSWERS_STALE',
    },
    413: {'PAYLOAD_TOO_LARGE'},
    415: {'UNSUPPORTED_MEDIA_TYPE'},
    405: {'METHOD_NOT_ALLOWED'},
    429: {'RATE_LIMITED'},
    500: {'INTERNAL_ERROR'},
    503: {'SERVICE_UNAVAILABLE'},
  };
  if (json is Map<String, dynamic> &&
      json.length == 2 &&
      json['schemaVersion'] == '1') {
    final error = json['error'];
    if (error is Map<String, dynamic> &&
        error.length == 2 &&
        error['message'] is String &&
        (error['message'] as String).isNotEmpty &&
        codes[status]?.contains(error['code']) == true) {
      return _error(error['code'] as String, status: status);
    }
  }
  return _error('UNEXPECTED_RESPONSE');
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
  final safe =
      endpoint.hasAuthority &&
      endpoint.host.isNotEmpty &&
      endpoint.userInfo.isEmpty &&
      !endpoint.hasQuery &&
      !endpoint.hasFragment &&
      endpoint.path == path &&
      endpoint.port >= 1 &&
      endpoint.port <= 65535 &&
      (endpoint.scheme == 'https' ||
          (endpoint.scheme == 'http' && allowLoopback && local));
  if (!safe) {
    throw ArgumentError(
      'Use fixed HTTPS form-answer endpoints without credentials, '
      'query or fragment. HTTP requires explicit loopback opt-in.',
    );
  }
  return endpoint;
}
