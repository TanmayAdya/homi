import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/shared/services/feature_capabilities.dart';
import 'package:safe_at_home/shared/services/matching_api_client.dart';
import '../app/case_coordinator_test.dart' show FakeTransport;
import 'case_evidence_api_client_test.dart' as http;

void main() {
  test('an older service cannot be mistaken for disabled features', () async {
    await expectLater(
      FeatureCapabilities.read(
        origin: Uri.parse('https://example.org'),
        transport: FakeTransport((_) async => http.apiError('NOT_FOUND', 404)),
        token: () async => 'fictional',
        isCurrent: () => true,
      ),
      throwsA(isA<FeatureCheckUnsupported>()),
    );
  });

  test(
    'capabilities require current account and exact boolean response',
    () async {
      var current = true;
      final transport = FakeTransport(
        (_) async => http.jsonResponse({
          'schemaVersion': '1',
          'features': {
            'structuredRooms': true,
            'tracking': false,
            'scanSync': false,
            'permissionSharing': false,
            'sensitiveSharing': false,
            'simpleInvitations': false,
          },
        }),
      );
      Future<FeatureCapabilities> read() => FeatureCapabilities.read(
        origin: Uri.parse('https://example.org'),
        transport: transport,
        token: () async => 'fictional',
        isCurrent: () => current,
      );
      expect((await read()).features['tracking'], false);
      expect(transport.requests.single.endpoint.path, '/v1/capabilities');
      current = false;
      await expectLater(read(), throwsA(isA<MatchingApiException>()));
      expect(transport.requests.length, 1);
    },
  );
  test(
    'unknown or malformed capability responses never enable routes',
    () async {
      for (final response in [
        {'schemaVersion': '2', 'features': <String, Object?>{}},
        {
          'schemaVersion': '1',
          'features': {'tracking': 'true'},
        },
      ]) {
        await expectLater(
          FeatureCapabilities.read(
            origin: Uri.parse('https://example.org'),
            transport: FakeTransport((_) async => http.jsonResponse(response)),
            token: () async => 'fictional',
            isCurrent: () => true,
          ),
          throwsA(isA<MatchingApiException>()),
        );
      }
    },
  );
}
