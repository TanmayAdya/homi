import 'dart:async';
import 'dart:convert';
import '../models/assessment.dart';
import '../models/export_contract_values.dart';
import 'matching_api_client.dart';
import 'token_availability.dart';

class AssessmentApiClient {
  AssessmentApiClient({
    required Uri baseUri,
    required MatchingTokenProvider tokenProvider,
    required MatchingTransport transport,
    bool allowInsecureLoopback = false,
    bool allowAndroidEmulatorLoopback = false,
  }) : _client = PrivateV2JsonClient(
         baseUri: baseUri,
         tokenProvider: tokenProvider,
         transport: transport,
         allowedRoutes: const {'read-assessment', 'save-assessment'},
         allowInsecureLoopback: allowInsecureLoopback,
         allowAndroidEmulatorLoopback: allowAndroidEmulatorLoopback,
       );
  final PrivateV2JsonClient _client;
  Future<AssessmentState> readAssessment(
    String caseId, {
    required bool Function() isCurrent,
  }) async {
    ExportContractValues.id(caseId);
    final result = AssessmentState.fromJson(
      await _client.post('read-assessment', {
        'schemaVersion': '2',
        'caseId': caseId,
      }, isCurrent: isCurrent),
    );
    if (result.caseSnapshot.caseId != caseId) {
      throw MatchingApiException.forCode('UNEXPECTED_RESPONSE');
    }
    return result;
  }

  Future<AssessmentState> saveAssessment(
    Map<String, Object?> retainedRequest, {
    required bool Function() isCurrent,
  }) async {
    final captured = Map<String, Object?>.from(
      jsonDecode(jsonEncode(retainedRequest)) as Map,
    );
    final result = AssessmentState.fromJson(
      await _client.post(
        'save-assessment',
        captured,
        isCurrent: isCurrent,
        uncertainCode: 'CASE_SAVE_UNCERTAIN',
      ),
    );
    if (result.caseSnapshot.caseId != captured['caseId'] ||
        result.acknowledgedMutationId != captured['mutationId'] ||
        result.caseSnapshot.revision <=
            ExportContractValues.integer(captured['expectedCaseRevision'])) {
      throw MatchingApiException.forCode('CASE_SAVE_UNCERTAIN');
    }
    return result;
  }
}

class PrivateV2JsonClient {
  PrivateV2JsonClient({
    required Uri baseUri,
    required MatchingTokenProvider tokenProvider,
    required MatchingTransport transport,
    required Set<String> allowedRoutes,
    bool allowInsecureLoopback = false,
    bool allowAndroidEmulatorLoopback = false,
  }) : _base = baseUri,
       _tokens = tokenProvider,
       _transport = transport,
       _routes = Set.unmodifiable(allowedRoutes) {
    final loopback =
        {'localhost', '127.0.0.1', '::1'}.contains(baseUri.host) ||
        (allowAndroidEmulatorLoopback && baseUri.host == '10.0.2.2');
    if (!baseUri.hasAuthority ||
        baseUri.host.isEmpty ||
        baseUri.userInfo.isNotEmpty ||
        baseUri.hasQuery ||
        baseUri.hasFragment ||
        !{'', '/'}.contains(baseUri.path) ||
        baseUri.port < 1 ||
        baseUri.port > 65535 ||
        !(baseUri.scheme == 'https' ||
            allowInsecureLoopback && loopback && baseUri.scheme == 'http')) {
      throw ArgumentError('Use a fixed HTTPS origin.');
    }
  }
  final Uri _base;
  final MatchingTokenProvider _tokens;
  final MatchingTransport _transport;
  final Set<String> _routes;
  Future<Object?> post(
    String route,
    Map<String, Object?> body, {
    required bool Function() isCurrent,
    String? uncertainCode,
    String accept = 'application/json',
    int maxResponseBytes = 280 * 1024,
  }) async {
    void guard() {
      try {
        if (isCurrent()) return;
      } catch (_) {}
      throw MatchingApiException.forCode('STALE_RESPONSE');
    }

    if (!_routes.contains(route)) throw ArgumentError('Unsupported route.');
    final bytes = utf8.encode(jsonEncode(body));
    if (bytes.length > 32 * 1024) {
      throw MatchingApiException.forCode('INVALID_REQUEST');
    }
    final clock = Stopwatch()..start();
    guard();
    String? token;
    try {
      token = await _tokens().timeout(const Duration(seconds: 15));
    } on RetryableTokenUnavailableException {
      guard();
      throw MatchingApiException.forCode('NETWORK_ERROR');
    } catch (_) {
      guard();
      throw MatchingApiException.forCode('UNAUTHENTICATED');
    }
    guard();
    if (token == null ||
        token.isEmpty ||
        token.length > 4096 ||
        RegExp(r'^[A-Za-z0-9\-._~+/]+=*$').stringMatch(token) != token) {
      throw MatchingApiException.forCode('UNAUTHENTICATED');
    }
    final remaining = const Duration(seconds: 15) - clock.elapsed;
    if (remaining <= Duration.zero) {
      throw MatchingApiException.forCode('TIMEOUT');
    }
    MatchingExchange? exchange;
    MatchingHttpResponse? response;
    MatchingApiException? failure;
    try {
      exchange = _transport.post(
        MatchingHttpRequest(
          endpoint: _base.resolve('/v2/$route'),
          bearerToken: token,
          body: bytes,
          maxResponseBytes: maxResponseBytes,
          accept: accept,
        ),
      );
      guard();
      response = await exchange.response.timeout(remaining);
    } on MatchingApiException catch (e) {
      failure = e;
    } on TimeoutException {
      failure = MatchingApiException.forCode(uncertainCode ?? 'TIMEOUT');
    } catch (_) {
      failure = MatchingApiException.forCode(uncertainCode ?? 'NETWORK_ERROR');
    } finally {
      exchange?.response.ignore();
      try {
        exchange?.cancel();
      } catch (_) {}
    }
    guard();
    if (failure != null) throw failure;
    try {
      if (response == null ||
          response.body.length > maxResponseBytes ||
          response.statusCode >= 300 && response.statusCode < 400) {
        throw const FormatException();
      }
      final contentType = response.contentType
          ?.split(';')
          .first
          .trim()
          .toLowerCase();
      if (response.statusCode == 200 && accept != 'application/json') {
        if (contentType != accept) throw const FormatException();
        return List<int>.unmodifiable(response.body);
      }
      if (contentType != 'application/json' ||
          response.body.length > 280 * 1024) {
        throw const FormatException();
      }
      final value = jsonDecode(utf8.decode(response.body));
      if (response.statusCode == 200) return value;
      final v = ExportContractValues.object(value, {'schemaVersion', 'error'}),
          e = ExportContractValues.object(v['error'], {'code', 'message'});
      final codes = <int, Set<String>>{
        400: {'INVALID_REQUEST'},
        401: {'UNAUTHENTICATED'},
        404: {'CASE_NOT_FOUND', 'ARTIFACT_NOT_FOUND', 'PROGRAM_NOT_FOUND'},
        409: {
          'CASE_REVISION_MISMATCH',
          'EVIDENCE_CONFLICT',
          'ASSESSMENT_CONFLICT',
          'INTAKE_CONFLICT',
          'QUESTIONNAIRE_CHANGED',
          'ASSESSMENT_MUTATION_CONFLICT',
          'ANNOTATION_CONFLICT',
          'ACCOUNT_CLOSED',

          'FORM_CONTEXT_MISMATCH',
          'FORM_NOT_AVAILABLE',
          'FORM_ANSWER_REVISION_MISMATCH',
          'FORM_ANSWERS_STALE',
          'EXPORT_GENERATION_CONFLICT',
          'INTAKE_REQUIRES_V2',

          'ANNOTATIONS_REQUIRE_V2',
        },
        410: {'EXPORT_EXPIRED'},
        413: {'PAYLOAD_TOO_LARGE'},
        422: {'ANNOTATION_REVIEW_REQUIRED', 'EXPORT_REVIEW_REQUIRED'},
        429: {'RATE_LIMITED', 'EXPORT_BUSY'},
        503: {'SERVICE_UNAVAILABLE'},
        507: {'ASSESSMENT_HISTORY_LIMIT', 'STORAGE_LIMIT_REACHED'},
      };
      if (!{'1', '2'}.contains(v['schemaVersion']) ||
          e['message'] is! String ||
          !(codes[response.statusCode] ?? {}).contains(e['code'])) {
        throw const FormatException();
      }
      if (uncertainCode != null &&
          response.statusCode >= 500 &&
          response.statusCode != 507) {
        throw MatchingApiException.forCode(uncertainCode);
      }
      throw MatchingApiException.forCode(
        e['code'] as String,
        statusCode: response.statusCode,
      ).withRetryAfter(response.retryAfter);
    } on MatchingApiException {
      rethrow;
    } catch (_) {
      throw MatchingApiException.forCode(
        uncertainCode ?? 'UNEXPECTED_RESPONSE',
      );
    }
  }
}
