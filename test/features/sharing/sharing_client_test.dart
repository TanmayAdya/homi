import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/shared/services/sharing_api_client.dart';
import '../../case_discovery_api_client_test.dart'
    show FakeTransport, jsonResponse, apiError, failure, requestJson;
import 'sharing_contract_test.dart' show sharedFixture;

void main() {
  SharingApiClient client(FakeTransport transport, {bool labels = false}) =>
      SharingApiClient(
        baseUri: Uri.parse('https://fictional.example'),
        tokenProvider: () async => 'fictional-token',
        transport: transport,
        includeLabels: labels,
      );
  const id = '11111111-1111-4111-8111-111111111111';
  const fields = {'membershipId': id, 'expectedPermissionRevision': 2};
  test(
    'fixed authenticated v3 transport returns a filtered typed view and cancels its exchange',
    () async {
      final transport = FakeTransport(
        (_) async => jsonResponse(sharedFixture()),
      );
      final result = await client(
        transport,
      ).request('read-shared-case', fields, isCurrent: () => true);
      expect(
        result.projection!.findings.single.observation,
        'Fictional step to review',
      );
      expect(
        transport.requests.single.endpoint.toString(),
        'https://fictional.example/v3/read-shared-case',
      );
      expect(requestJson(transport.requests.single), {
        'schemaVersion': '3',
        ...fields,
      });
      expect(transport.cancellations, 1);
    },
  );
  test(
    'late responses after account/permission invalidation are discarded',
    () async {
      var current = true;
      final gate = Completer<dynamic>();
      final transport = FakeTransport((_) async {
        await gate.future;
        return jsonResponse(sharedFixture());
      });
      final pending = client(
        transport,
      ).request('read-shared-case', fields, isCurrent: () => current);
      await transport.started.future;
      current = false;
      gate.complete();
      await expectLater(pending, throwsA(failure('STALE_RESPONSE')));
      expect(transport.cancellations, 1);
    },
  );
  test(
    'revoked access and stale permission errors stay explicit and never expose server messages',
    () async {
      for (final (status, code) in [
        (404, 'SHARING_NOT_FOUND'),
        (409, 'SHARING_CONFLICT'),
      ]) {
        final transport = FakeTransport((_) async => apiError(code, status));
        await expectLater(
          client(
            transport,
          ).request('read-shared-case', fields, isCurrent: () => true),
          throwsA(failure(code)),
        );
      }
    },
  );
  test(
    'a response tied to a different grant revision cannot populate the view',
    () async {
      final transport = FakeTransport(
        (_) async => jsonResponse(sharedFixture()),
      );
      await expectLater(
        client(transport).request('read-shared-case', {
          ...fields,
          'expectedPermissionRevision': 3,
        }, isCurrent: () => true),
        throwsA(failure('UNEXPECTED_RESPONSE')),
      );
    },
  );
  test('insecure nonlocal origins and unknown operations are rejected', () {
    expect(
      () => SharingApiClient(
        baseUri: Uri.parse('http://example.org'),
        tokenProvider: () async => 'token',
        transport: FakeTransport((_) async => jsonResponse({})),
      ),
      throwsArgumentError,
    );
  });
  group('sharing labels flag', () {
    final fixtures =
        (jsonDecode(
                  File(
                    'contracts/v3/fixtures/sharing-labels.json',
                  ).readAsStringSync(),
                )
                as List)
            .cast<Map<String, Object?>>();
    Map<String, Object?> labelled(String route) =>
        fixtures.firstWhere((f) => f['route'] == route)['response']!
            as Map<String, Object?>;
    Map<String, Object?> legacy(String route) {
      final value = jsonDecode(jsonEncode(labelled(route))) as Map;
      for (final row in [
        ...(value['memberships'] as List? ?? const []),
        ...(value['shares'] as List? ?? const []),
        ?value['membership'],
      ]) {
        (row as Map)
          ..remove('ownerLabel')
          ..remove('recipientLabel');
      }
      return value.cast<String, Object?>();
    }

    const routes = {
      'list-sharing': {'caseId': 'fictional-shared-case'},
      'list-shared-cases': <String, Object?>{},
      'review-invitation': {
        'code': 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      },
    };
    test(
      'off (default): no label key is sent and labelled replies fail',
      () async {
        for (final MapEntry(key: route, value: body) in routes.entries) {
          final sent = FakeTransport((_) async => jsonResponse(legacy(route)));
          final response = await client(
            sent,
          ).request(route, body, isCurrent: () => true);
          expect(requestJson(sent.requests.single), {
            'schemaVersion': '3',
            ...body,
          }, reason: route);
          expect(
            [
              ...response.memberships,
              ...response.shares.map((s) => s.membership),
              ?response.membership,
            ].every((m) => m.ownerLabel == null && m.recipientLabel == null),
            isTrue,
          );
          await expectLater(
            client(
              FakeTransport((_) async => jsonResponse(labelled(route))),
            ).request(route, body, isCurrent: () => true),
            throwsA(failure('UNEXPECTED_RESPONSE')),
            reason: route,
          );
        }
        for (final key in ['recipientLabel', 'ownerLabel', 'includeLabels']) {
          final none = FakeTransport((_) async => throw StateError('sent'));
          expect(
            () => client(none).request('create-invitation', {
              key: 'Fictional',
            }, isCurrent: () => true),
            throwsArgumentError,
          );
          expect(none.requests, isEmpty);
        }
      },
    );
    test('on: list/review opt in and labels parse', () async {
      for (final MapEntry(key: route, value: body) in routes.entries) {
        final sent = FakeTransport((_) async => jsonResponse(labelled(route)));
        final response = await client(
          sent,
          labels: true,
        ).request(route, body, isCurrent: () => true);
        expect(requestJson(sent.requests.single), {
          'schemaVersion': '3',
          ...body,
          'includeLabels': true,
        });
        expect(
          [
            ...response.memberships,
            ...response.shares.map((s) => s.membership),
            ?response.membership,
          ].map((m) => m.ownerLabel),
          everyElement('Fictional Sam'),
        );
      }
    });
  });
}
