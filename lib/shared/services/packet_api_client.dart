import 'dart:async';
import 'dart:convert';

import '../models/contracts.dart';
import '../models/draft_packet.dart';
import 'matching_api_client.dart';

class PacketApiClient {
  PacketApiClient({
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
        'Packet timeout must be greater than zero and at most 15 seconds.',
      );
    }
    if (maxResponseBytes < 1 || maxResponseBytes > 1024 * 1024) {
      throw ArgumentError(
        'Packet response limit must be between 1 byte and 1 MiB.',
      );
    }
  }

  final Uri _endpoint;
  final MatchingTokenProvider _tokenProvider;
  final MatchingTransport _transport;
  final Duration timeout;
  final int maxResponseBytes;

  Future<DraftPacket> preparePacket(
    CaseSnapshot snapshot, {
    required String programId,
    required String generationKey,
    required CaseSnapshot Function() currentCase,
    String Function()? currentProgramId,
  }) async {
    if (!_validId(snapshot.caseId) ||
        !_validId(programId) ||
        snapshot.revision < 1 ||
        snapshot.revision > 9007199254740991 ||
        generationKey.length < 8 ||
        generationKey.length > 128 ||
        RegExp(r'[^A-Za-z0-9_-]').hasMatch(generationKey)) {
      throw MatchingApiException.forCode('INVALID_REQUEST', statusCode: 400);
    }
    final elapsed = Stopwatch()..start();
    final token = await _freshToken();
    _requireCurrent(snapshot, programId, currentCase, currentProgramId);
    final remaining = timeout - elapsed.elapsed;
    if (remaining <= Duration.zero) {
      throw MatchingApiException.forCode('TIMEOUT');
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
              'programId': programId,
              'generationKey': generationKey,
            }),
          ),
          maxResponseBytes: maxResponseBytes,
        ),
      );
      response = await exchange.response.timeout(remaining);
    } on TimeoutException {
      throw MatchingApiException.forCode('TIMEOUT');
    } on MatchingTransportException catch (error) {
      throw _transportError(error.failure);
    } catch (_) {
      throw MatchingApiException.forCode('NETWORK_ERROR');
    } finally {
      try {
        exchange?.cancel();
      } catch (_) {
        // ignore: empty_catches
      }
    }
    _requireCurrent(snapshot, programId, currentCase, currentProgramId);
    if (response.body.length > maxResponseBytes) {
      throw MatchingApiException.forCode('RESPONSE_TOO_LARGE');
    }
    if (response.statusCode >= 300 && response.statusCode < 400) {
      throw MatchingApiException.forCode('REDIRECT_BLOCKED');
    }
    if (response.contentType?.split(';').first.trim().toLowerCase() !=
        'application/json') {
      throw MatchingApiException.forCode('UNEXPECTED_RESPONSE');
    }
    final Object? json;
    try {
      json = jsonDecode(utf8.decode(response.body));
    } catch (_) {
      throw MatchingApiException.forCode('UNEXPECTED_RESPONSE');
    }
    if (response.statusCode != 200) throw _apiError(response.statusCode, json);
    final DraftPacket packet;
    try {
      packet = DraftPacket.fromJson(json);
    } catch (_) {
      throw MatchingApiException.forCode('UNEXPECTED_RESPONSE');
    }
    if (packet.caseId != snapshot.caseId ||
        packet.caseRevision != snapshot.revision ||
        packet.programId != programId) {
      throw MatchingApiException.forCode('STALE_RESPONSE');
    }
    final findings = {
      for (final finding in snapshot.findings) finding.id: finding,
    };
    for (final attachment in packet.attachments) {
      final finding = findings[attachment.findingId];
      if (finding == null ||
          finding.reviewState != 'confirmed' ||
          !finding.evidenceIds.contains(attachment.evidenceId)) {
        throw MatchingApiException.forCode('UNEXPECTED_RESPONSE');
      }
    }
    return packet;
  }

  Future<String> _freshToken() async {
    final String? token;
    try {
      token = await _tokenProvider().timeout(timeout);
    } on TimeoutException {
      throw MatchingApiException.forCode('TIMEOUT');
    } catch (_) {
      throw MatchingApiException.forCode('UNAUTHENTICATED', statusCode: 401);
    }
    if (token == null || !RegExp(r'^[A-Za-z0-9\-._~+/]+=*$').hasMatch(token)) {
      throw MatchingApiException.forCode('UNAUTHENTICATED', statusCode: 401);
    }
    return token;
  }
}

bool _validId(String value) {
  if (value.runes.length > 200 || value.trim().isEmpty) return false;
  final units = value.codeUnits;
  for (var i = 0; i < units.length; i++) {
    final unit = units[i];
    if (unit >= 0xd800 && unit <= 0xdbff) {
      if (++i == units.length || units[i] < 0xdc00 || units[i] > 0xdfff) {
        return false;
      }
    } else if (unit >= 0xdc00 && unit <= 0xdfff) {
      return false;
    }
  }
  return true;
}

void _requireCurrent(
  CaseSnapshot requested,
  String programId,
  CaseSnapshot Function() currentCase,
  String Function()? currentProgramId,
) {
  try {
    final current = currentCase();
    if (current.caseId == requested.caseId &&
        current.revision == requested.revision &&
        (currentProgramId == null || currentProgramId() == programId)) {
      return;
    }
  } catch (_) {
    // ignore: empty_catches
  }
  throw MatchingApiException.forCode('STALE_RESPONSE');
}

MatchingApiException _transportError(MatchingTransportFailure failure) =>
    MatchingApiException.forCode(switch (failure) {
      MatchingTransportFailure.network => 'NETWORK_ERROR',
      MatchingTransportFailure.responseTooLarge => 'RESPONSE_TOO_LARGE',
      MatchingTransportFailure.redirectBlocked => 'REDIRECT_BLOCKED',
    });

MatchingApiException _apiError(int status, Object? json) {
  const codes = {
    400: {'INVALID_REQUEST'},
    401: {'UNAUTHENTICATED'},
    404: {'CASE_NOT_FOUND', 'PROGRAM_NOT_FOUND', 'NOT_FOUND'},
    409: {
      'CASE_REVISION_MISMATCH',
      'PACKET_GENERATION_CONFLICT',
      'FORM_ANSWERS_STALE',
    },
    413: {'PAYLOAD_TOO_LARGE'},
    415: {'UNSUPPORTED_MEDIA_TYPE'},
    405: {'METHOD_NOT_ALLOWED'},
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
      return MatchingApiException.forCode(
        error['code'] as String,
        statusCode: status,
      );
    }
  }
  return MatchingApiException.forCode('UNEXPECTED_RESPONSE');
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
      endpoint.path == '/v1/prepare-packet' &&
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
      'Use an HTTPS /v1/prepare-packet endpoint without credentials, query, or fragment. HTTP requires explicit loopback opt-in.',
    );
  }
  return endpoint;
}
