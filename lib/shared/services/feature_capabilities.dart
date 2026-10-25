import 'dart:async';
import 'dart:convert';

import 'matching_api_client.dart';

class FeatureCheckUnsupported implements Exception {
  const FeatureCheckUnsupported();
}

class FeatureCapabilities {
  const FeatureCapabilities(this.features);
  final Map<String, bool> features;

  static Future<FeatureCapabilities> read({
    required Uri origin,
    required MatchingTransport transport,
    required Future<String?> Function() token,
    required bool Function() isCurrent,
  }) async {
    void guard() {
      if (!isCurrent()) throw MatchingApiException.forCode('STALE_RESPONSE');
    }

    guard();
    final bearer = await token().timeout(const Duration(seconds: 15));
    guard();
    if (bearer == null ||
        bearer.isEmpty ||
        bearer.length > 4096 ||
        !RegExp(r'^[A-Za-z0-9._~+/=-]+$').hasMatch(bearer)) {
      throw MatchingApiException.forCode('UNAUTHENTICATED');
    }
    final exchange = transport.post(
      MatchingHttpRequest(
        endpoint: origin.resolve('/v1/capabilities'),
        bearerToken: bearer,
        body: utf8.encode('{"schemaVersion":"1"}'),
        maxResponseBytes: 4096,
      ),
    );
    try {
      final response = await exchange.response.timeout(
        const Duration(seconds: 15),
      );
      guard();
      if (response.statusCode == 404) throw const FeatureCheckUnsupported();
      if (response.statusCode != 200 ||
          response.body.length > 4096 ||
          response.contentType?.split(';').first.trim().toLowerCase() !=
              'application/json') {
        throw MatchingApiException.forCode('SERVICE_UNAVAILABLE');
      }
      final value = jsonDecode(utf8.decode(response.body));
      const names = {
        'structuredRooms',
        'tracking',
        'scanSync',
        'permissionSharing',
        'sensitiveSharing',
        'simpleInvitations',
      };
      if (value is! Map ||
          value['schemaVersion'] != '1' ||
          value['features'] is! Map) {
        throw MatchingApiException.forCode('UNEXPECTED_RESPONSE');
      }
      final features = value['features'] as Map;
      if (features.length != names.length ||
          !names.every((name) => features[name] is bool)) {
        throw MatchingApiException.forCode('UNEXPECTED_RESPONSE');
      }
      return FeatureCapabilities(
        Map.unmodifiable(features.cast<String, bool>()),
      );
    } finally {
      exchange.cancel();
    }
  }
}
