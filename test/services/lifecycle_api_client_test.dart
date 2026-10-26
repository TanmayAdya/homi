import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/shared/models/account_deletion.dart';
import 'package:safe_at_home/shared/services/lifecycle_api_client.dart';
import 'package:safe_at_home/shared/services/matching_api_client.dart';

import '../case_discovery_api_client_test.dart'
    show FakeTransport, jsonResponse, apiError, failure, snapshot;

final receipt = 'a' * 64;
Map<String, Object?> previewJson() => {
  'schemaVersion': '1',
  'deletionToken': receipt,
  'expiresAt': '2026-10-22T12:05:00Z',
  'counts': {'cases': 2, 'evidence': 3, 'exports': 1, 'storedBytes': 123},
};
Map<String, Object?> stateJson(String status) => {
  'schemaVersion': '1',
  'status': status,
  'applicationDataDeleted': status != 'awaiting_confirmation',
  'providerIdentityDeleted': status == 'complete',
};
LifecycleApiClient client(
  FakeTransport transport, {
  MatchingTokenProvider? tokenProvider,
  Duration timeout = const Duration(seconds: 15),
}) => LifecycleApiClient(
  apiBaseUrl: Uri.parse('https://fictional.example'),
  tokenProvider: tokenProvider ?? () async => 'fictional-token',
  transport: transport,
  timeout: timeout,
);

void main() {
  test(
    'prepare validates private counts, confirm preserves pending state and does not auto poll',
    () async {
      final transport = FakeTransport(
        (r) async => r.endpoint.path.endsWith('prepare-account-deletion')
            ? jsonResponse(previewJson())
            : jsonResponse(stateJson('auth_pending'), status: 202),
      );
      final api = client(transport);
      final preview = await api.prepareAccountDeletion(isCurrent: () => true);
      expect(preview.counts.cases, 2);
      expect(preview.toString(), isNot(contains(receipt)));
      expect(preview.toJson(), previewJson());
      final result = await api.confirmAccountDeletion(
        preview,
        isCurrent: () => true,
      );
      expect(result.applicationDataDeleted, isTrue);
      expect(result.providerIdentityDeleted, isFalse);
      expect(transport.requests, hasLength(2));
      expect(jsonDecode(utf8.decode(transport.requests.last.body)), {
        'schemaVersion': '1',
        'deletionToken': receipt,
        'confirmation': 'DELETE_ACCOUNT',
      });
      expect(transport.cancellations, 2);
    },
  );

  test(
    'receipt polling works after identity removal without invoking auth',
    () async {
      final transport = FakeTransport(
        (_) async => jsonResponse(stateJson('complete')),
      );
      final api = client(
        transport,
        tokenProvider: () => throw StateError('Deleted identity'),
      );
      final state = await api.readAccountDeletionStatus(
        receipt,
        isCurrent: () => true,
      );
      expect(state.complete, isTrue);
      expect(transport.requests.single.bearerToken, receipt);
      expect(jsonDecode(utf8.decode(transport.requests.single.body)), {
        'schemaVersion': '1',
      });
    },
  );

  test(
    'case deletion includes both revisions and exact confirmation',
    () async {
      final transport = FakeTransport(
        (_) async => jsonResponse({
          'schemaVersion': '1',
          'caseId': 'case-a',
          'deleted': true,
        }),
      );
      await client(transport).deleteCase(
        snapshot(),
        expectedCatalogRevision: 4,
        isCurrent: () => true,
      );
      expect(jsonDecode(utf8.decode(transport.requests.single.body)), {
        'schemaVersion': '1',
        'caseId': 'case-a',
        'expectedCaseRevision': 2,
        'expectedCatalogRevision': 4,
        'confirmation': 'DELETE_CASE',
      });
    },
  );

  test(
    'lost successful confirmation stays uncertain with no automatic second mutation',
    () async {
      final transport = FakeTransport(
        (_) async => throw const MatchingTransportException(
          MatchingTransportFailure.network,
        ),
      );
      await expectLater(
        client(transport).confirmAccountDeletion(
          AccountDeletionPreview.fromJson(previewJson()),
          isCurrent: () => true,
        ),
        throwsA(failure('DELETION_UNCERTAIN')),
      );
      expect(transport.requests, hasLength(1));
      expect(transport.cancellations, 1);
    },
  );

  test(
    'bad deletion receipt is rejected before any transport or authentication',
    () async {
      final transport = FakeTransport(
        (_) async => jsonResponse(stateJson('complete')),
      );
      var tokens = 0;
      final api = client(
        transport,
        tokenProvider: () async {
          tokens++;
          return 'token';
        },
      );
      await expectLater(
        api.readAccountDeletionStatus('invalid', isCurrent: () => true),
        throwsFormatException,
      );
      expect(tokens, 0);
      expect(transport.requests, isEmpty);
    },
  );

  test('account switch while token lookup pending prevents dispatch', () async {
    var current = true;
    final token = Completer<String?>();
    final transport = FakeTransport((_) async => jsonResponse(previewJson()));
    final pending = client(
      transport,
      tokenProvider: () => token.future,
    ).prepareAccountDeletion(isCurrent: () => current);
    current = false;
    token.complete('old-token');
    await expectLater(pending, throwsA(failure('STALE_RESPONSE')));
    expect(transport.requests, isEmpty);
  });

  test(
    'late response after account change cannot publish deletion state',
    () async {
      var current = true;
      final response = Completer<MatchingHttpResponse>();
      final transport = FakeTransport((_) => response.future);
      final pending = client(
        transport,
      ).readAccountDeletionStatus(receipt, isCurrent: () => current);
      await transport.started.future;
      current = false;
      response.complete(jsonResponse(stateJson('complete')));
      await expectLater(pending, throwsA(failure('STALE_RESPONSE')));
      expect(transport.cancellations, 1);
    },
  );

  test(
    'recent authentication and changed preview remain actionable without server text',
    () async {
      for (final pair in [
        ('RECENT_AUTHENTICATION_REQUIRED', 403),
        ('DELETION_CHANGED', 409),
        ('DELETION_EXPIRED', 410),
      ]) {
        final transport = FakeTransport(
          (_) async => apiError(pair.$1, pair.$2),
        );
        try {
          await client(transport).confirmAccountDeletion(
            AccountDeletionPreview.fromJson(previewJson()),
            isCurrent: () => true,
          );
          fail('Expected rejection');
        } on MatchingApiException catch (e) {
          expect(e.code, pair.$1);
          expect(e.toString(), isNot(contains('Private server data')));
        }
      }
    },
  );

  test(
    'inconsistent success status and deletion flags are never accepted',
    () async {
      for (final pair in [
        ('complete', 202),
        ('auth_pending', 200),
        ('awaiting_confirmation', 200),
      ]) {
        final transport = FakeTransport(
          (_) async => jsonResponse(stateJson(pair.$1), status: pair.$2),
        );
        await expectLater(
          client(transport).confirmAccountDeletion(
            AccountDeletionPreview.fromJson(previewJson()),
            isCurrent: () => true,
          ),
          throwsA(failure('DELETION_UNCERTAIN')),
        );
      }
      expect(
        () => AccountDeletionState.fromJson({
          ...stateJson('complete'),
          'providerIdentityDeleted': false,
        }),
        throwsFormatException,
      );
      expect(
        () =>
            AccountDeletionPreview.fromJson({...previewJson(), 'extra': true}),
        throwsFormatException,
      );
    },
  );

  test(
    'rate limits preserve advisory cooldown and remain definitive rejection',
    () async {
      final transport = FakeTransport(
        (_) async => MatchingHttpResponse(
          statusCode: 429,
          contentType: 'application/json',
          retryAfter: '30',
          body: utf8.encode(
            jsonEncode({
              'schemaVersion': '1',
              'error': {'code': 'RATE_LIMITED', 'message': 'private'},
            }),
          ),
        ),
      );
      try {
        await client(transport).confirmAccountDeletion(
          AccountDeletionPreview.fromJson(previewJson()),
          isCurrent: () => true,
        );
        fail('Expected rejection');
      } on MatchingApiException catch (e) {
        expect(e.code, 'RATE_LIMITED');
        expect(e.retryAfter, const Duration(seconds: 30));
      }
    },
  );

  test(
    'timeout cancels transport and preserves uncertain confirmation',
    () async {
      final transport = FakeTransport(
        (_) => Completer<MatchingHttpResponse>().future,
      );
      await expectLater(
        client(
          transport,
          timeout: const Duration(milliseconds: 20),
        ).confirmAccountDeletion(
          AccountDeletionPreview.fromJson(previewJson()),
          isCurrent: () => true,
        ),
        throwsA(failure('DELETION_UNCERTAIN')),
      );
      expect(transport.cancellations, 1);
    },
  );

  test(
    'private tokens cannot be sent to an arbitrary HTTP URL or URL credentials',
    () {
      final transport = FakeTransport((_) async => jsonResponse(previewJson()));
      for (final url in [
        'http://fictional.example',
        'https://user:password@fictional.example',
        'https://fictional.example/path',
        'https://fictional.example?secret=x',
      ]) {
        expect(
          () => LifecycleApiClient(
            apiBaseUrl: Uri.parse(url),
            tokenProvider: () async => 'token',
            transport: transport,
          ),
          throwsArgumentError,
        );
      }
    },
  );
}
