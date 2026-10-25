import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/shared/models/form_answers.dart';
import 'package:safe_at_home/shared/services/form_answers_api_client.dart';
import 'package:safe_at_home/shared/services/matching_api_client.dart';

import '../contracts/form_answers_test.dart' as f;

MatchingHttpResponse jsonResponse(Object? value, {int status = 200}) =>
    MatchingHttpResponse(
      statusCode: status,
      contentType: 'application/json',
      body: utf8.encode(jsonEncode(value)),
    );

Map<String, Object?> savedResponse() {
  final result = f.responseJson()..['caseRevision'] = 3;
  (result['saved'] as Map)['caseRevision'] = 3;
  return result;
}

FormAnswerContext context() => FormAnswerContext.fromJson(f.contextJson());
Map<String, Object?> caseJson({
  String caseId = 'fictional-case',
  int revision = 3,
}) => {
  'schemaVersion': '1',
  'caseId': caseId,
  'revision': revision,
  'profile': {
    'city': null,
    'county': null,
    'healthPlan': null,
    'tenure': null,
    'ageYears': null,
    'householdSize': null,
    'annualIncomeUsd': null,
    'ownerConsentReported': null,
  },
  'unresolvedFields': <String>[],
  'findings': <Object>[],
};
List<FormAnswerInput> answers() => [FormAnswerInput.fromJson(f.answerJson())];
TypeMatcher<MatchingApiException> failure(String code) =>
    isA<MatchingApiException>().having((e) => e.code, 'code', code);

FormAnswersApiClient clientFor(
  MatchingTransport transport, {
  MatchingTokenProvider? tokenProvider,
  Duration timeout = const Duration(seconds: 15),
  int maxResponseBytes = 1024 * 1024,
  int maxRequestBytes = 16 * 1024,
}) => FormAnswersApiClient(
  readEndpoint: Uri.parse('https://example.org/v1/read-form-answers'),
  saveEndpoint: Uri.parse('https://example.org/v1/save-form-answers'),
  caseEndpoint: Uri.parse('https://example.org/v1/read-case'),
  tokenProvider: tokenProvider ?? () async => 'fictional-token',
  transport: transport,
  timeout: timeout,
  maxResponseBytes: maxResponseBytes,
  maxRequestBytes: maxRequestBytes,
);

Future<FormAnswersResponse> read(FormAnswersApiClient client) =>
    client.readAnswers(
      f.snapshot(),
      programId: 'scfhp-eaa',
      currentCase: f.snapshot,
      currentProgramId: () => 'scfhp-eaa',
      currentContext: () => null,
    );

Future<FormAnswersResponse> save(
  FormAnswersApiClient client, {
  List<FormAnswerInput>? input,
  int expectedAnswerRevision = 0,
}) => client.saveAnswers(
  f.snapshot(),
  context: context(),
  expectedAnswerRevision: expectedAnswerRevision,
  answers: input ?? answers(),
  currentCase: f.snapshot,
  currentProgramId: () => 'scfhp-eaa',
  currentContext: context,
);

void main() {
  test(
    'case reload fetches latest server revision with no guessed revision',
    () async {
      final transport = _Transport(
        (_) async => jsonResponse(caseJson(revision: 9)),
      );
      final result = await clientFor(
        transport,
      ).reloadCase('fictional-case', currentCase: f.snapshot);
      expect(result.revision, 9);
      expect(transport.requests.single.endpoint.path, '/v1/read-case');
      expect(jsonDecode(utf8.decode(transport.requests.single.body)), {
        'schemaVersion': '1',
        'caseId': 'fictional-case',
      });
      expect(transport.cancellations, 1);
    },
  );

  test(
    'lost save recovery reloads case then answers without automatic retry or adoption',
    () async {
      final lostResponse = Completer<MatchingHttpResponse>();
      var remoteRevision = 2;
      final transport = _Transport((request) {
        switch (request.endpoint.path) {
          case '/v1/save-form-answers':
            remoteRevision++;
            return lostResponse.future;
          case '/v1/read-case':
            return Future.value(
              jsonResponse(caseJson(revision: remoteRevision)),
            );
          default:
            return Future.value(jsonResponse(savedResponse()));
        }
      });
      final client = clientFor(
        transport,
        timeout: const Duration(milliseconds: 20),
      );
      var current = f.snapshot();
      await expectLater(
        client.saveAnswers(
          current,
          context: context(),
          expectedAnswerRevision: 0,
          answers: answers(),
          currentCase: () => current,
          currentProgramId: () => 'scfhp-eaa',
          currentContext: context,
        ),
        throwsA(failure('FORM_SAVE_UNCERTAIN')),
      );
      expect(current.revision, 2);
      final reloaded = await client.reloadCase(
        current.caseId,
        currentCase: () => current,
      );
      expect(
        current.revision,
        2,
        reason: 'Reload does not automatically adopt state',
      );
      current = reloaded;
      final recovered = await client.readAnswers(
        current,
        programId: 'scfhp-eaa',
        currentCase: () => current,
        currentProgramId: () => 'scfhp-eaa',
        currentContext: context,
      );
      expect(current.revision, 3);
      expect(recovered.saved!.answerRevision, 1);
      expect(recovered.saved!.answers.single.value, 'Fictional');
      expect(
        transport.requests.where((r) => r.endpoint.path.contains('save-')),
        hasLength(1),
      );
      lostResponse.complete(jsonResponse(savedResponse()));
      await Future<void>.delayed(Duration.zero);
      expect(transport.requests, hasLength(3));
    },
  );

  test(
    'case reload binds selection before and after asynchronous work',
    () async {
      for (final duringToken in [true, false]) {
        var selected = 'fictional-case';
        final transport = _Transport((_) async {
          selected = 'other-case';
          return jsonResponse(caseJson());
        });
        final client = clientFor(
          transport,
          tokenProvider: () async {
            if (duringToken) selected = 'other-case';
            return 'token';
          },
        );
        await expectLater(
          client.reloadCase(
            'fictional-case',
            currentCase: () => f.snapshot(caseId: selected),
          ),
          throwsA(failure('STALE_RESPONSE')),
        );
        expect(transport.requests, hasLength(duringToken ? 0 : 1));
      }
      final transport = _Transport((_) async => jsonResponse(caseJson()));
      await expectLater(
        clientFor(transport).reloadCase(
          'fictional-case',
          currentCase: () => throw StateError('private-case'),
        ),
        throwsA(
          failure('STALE_RESPONSE').having(
            (e) => e.toString(),
            'sanitized',
            isNot(contains('private')),
          ),
        ),
      );
      expect(transport.requests, isEmpty);
    },
  );

  test(
    'case reload cannot replace a newer same-case revision with an older response',
    () async {
      for (final advancesDuringRequest in [false, true]) {
        var current = f.snapshot(revision: advancesDuringRequest ? 2 : 3);
        final transport = _Transport((_) async {
          current = f.snapshot(revision: 3);
          return jsonResponse(caseJson(revision: 2));
        });
        await expectLater(
          clientFor(
            transport,
          ).reloadCase(current.caseId, currentCase: () => current),
          throwsA(failure('STALE_RESPONSE')),
        );
        expect(current.revision, 3);
        expect(transport.requests, hasLength(1));
      }
      var current = f.snapshot();
      final transport = _Transport((_) async {
        current = f.snapshot(revision: 3);
        return jsonResponse(caseJson(revision: 4));
      });
      final result = await clientFor(
        transport,
      ).reloadCase(current.caseId, currentCase: () => current);
      expect(result.revision, 4);
      expect(current.revision, 3, reason: 'Adoption remains caller-owned');
    },
  );

  test(
    'reload rejects invalid identifiers wrong cases unsafe revisions and malformed data',
    () async {
      final transport = _Transport((_) async => jsonResponse(caseJson()));
      for (final id in [
        '',
        ' leading',
        'a\nb',
        '\ud800',
        List.filled(201, '😀').join(),
      ]) {
        await expectLater(
          clientFor(
            transport,
          ).reloadCase(id, currentCase: () => f.snapshot(caseId: id)),
          throwsA(failure('INVALID_REQUEST')),
        );
      }
      expect(transport.requests, isEmpty);
      await expectLater(
        clientFor(
          _Transport((_) async => jsonResponse(caseJson(caseId: 'other'))),
        ).reloadCase('fictional-case', currentCase: f.snapshot),
        throwsA(failure('STALE_RESPONSE')),
      );
      for (final json in [
        caseJson(revision: 9007199254740992),
        caseJson()..['approved'] = true,
        caseJson()..['profile'] = {},
        caseJson()..remove('findings'),
      ]) {
        await expectLater(
          clientFor(
            _Transport((_) async => jsonResponse(json)),
          ).reloadCase('fictional-case', currentCase: f.snapshot),
          throwsA(failure('UNEXPECTED_RESPONSE')),
        );
      }
    },
  );

  test(
    'case reload preserves safe access-denied errors without response details',
    () async {
      final client = clientFor(
        _Transport(
          (_) async => jsonResponse({
            'schemaVersion': '1',
            'error': {'code': 'CASE_NOT_FOUND', 'message': 'private-owner'},
          }, status: 404),
        ),
      );
      await expectLater(
        client.reloadCase('fictional-case', currentCase: f.snapshot),
        throwsA(
          failure(
            'CASE_NOT_FOUND',
          ).having((e) => e.message, 'sanitized', isNot(contains('private'))),
        ),
      );
    },
  );

  test(
    'case reload endpoint must be fixed and share the configured origin',
    () {
      final transport = _Transport((_) async => jsonResponse(caseJson()));
      for (final url in [
        'https://example.org/v1/read-case?token=private',
        'https://other.org/v1/read-case',
        'https://example.org/v1/read-case/',
        'https://example.org/v1/read-form-answers',
      ]) {
        expect(
          () => FormAnswersApiClient(
            readEndpoint: Uri.parse('https://example.org/v1/read-form-answers'),
            saveEndpoint: Uri.parse('https://example.org/v1/save-form-answers'),
            caseEndpoint: Uri.parse(url),
            tokenProvider: () async => 'token',
            transport: transport,
          ),
          throwsArgumentError,
        );
      }
    },
  );

  test(
    'read and save send exact scoped bodies with fresh tokens and no owner metadata',
    () async {
      var tokens = 0;
      final transport = _Transport(
        (request) async => jsonResponse(
          request.endpoint.path.contains('read-')
              ? f.responseJson()
              : savedResponse(),
        ),
      );
      final client = clientFor(
        transport,
        tokenProvider: () async => 'token-${++tokens}',
      );
      final loaded = await read(client);
      expect(loaded.caseRevision, 2);
      final updated = await save(client);
      expect(updated.caseRevision, 3);
      expect(updated.saved!.answerRevision, 1);
      expect(
        f.snapshot().revision,
        2,
        reason: 'The client never adopts server state',
      );
      expect(transport.requests.map((r) => r.bearerToken), [
        'token-1',
        'token-2',
      ]);
      expect(jsonDecode(utf8.decode(transport.requests[0].body)), f.readJson());
      expect(jsonDecode(utf8.decode(transport.requests[1].body)), f.saveJson());
      expect(transport.cancellations, 2);
    },
  );

  test(
    'read discovers a new remote context while returning old answers as stale',
    () async {
      final response = f.responseJson()..['isCurrent'] = false;
      (response['context'] as Map)['mappingVersion'] = 'new-mapping';
      (response['context'] as Map)['formContextId'] = f.digest.replaceAll(
        'a',
        'b',
      );
      final transport = _Transport((_) async => jsonResponse(response));
      final result = await clientFor(transport).readAnswers(
        f.snapshot(),
        programId: 'scfhp-eaa',
        currentCase: f.snapshot,
        currentProgramId: () => 'scfhp-eaa',
        currentContext: context,
      );
      expect(result.isCurrent, isFalse);
      expect(result.context.mappingVersion, 'new-mapping');
      expect(result.saved!.mappingVersion, 'fictional-mapping-version');
    },
  );

  test(
    'empty replacement clears answers and ordered response is not required',
    () async {
      final cleared = savedResponse();
      (cleared['saved'] as Map)['answers'] = <Object>[];
      final result = await save(
        clientFor(_Transport((_) async => jsonResponse(cleared))),
        input: [],
      );
      expect(result.saved!.answers, isEmpty);
      final reordered = savedResponse();
      (reordered['saved'] as Map)['answers'] = [
        f.savedAnswerJson(key: 'memberLastName', value: 'Resident'),
        f.savedAnswerJson(),
      ];
      final submitted = [
        FormAnswerInput.fromJson(f.answerJson()),
        FormAnswerInput.fromJson(
          f.answerJson(key: 'memberLastName', value: 'Resident'),
        ),
      ];
      expect(
        (await save(
          clientFor(_Transport((_) async => jsonResponse(reordered))),
          input: submitted,
        )).saved!.answers,
        hasLength(2),
      );
    },
  );

  test(
    'invalid identifiers revision overflow duplicates and body caps reject before token I/O',
    () async {
      var tokens = 0;
      final transport = _Transport((_) async => jsonResponse(savedResponse()));
      final client = clientFor(
        transport,
        tokenProvider: () async {
          tokens++;
          return 'token';
        },
      );
      for (final id in [
        'bad\nID',
        ' leading',
        List.filled(201, '😀').join(),
        '\ud800',
      ]) {
        await expectLater(
          client.readAnswers(
            f.snapshot(caseId: id),
            programId: 'scfhp-eaa',
            currentCase: () => f.snapshot(caseId: id),
            currentProgramId: () => 'scfhp-eaa',
            currentContext: () => null,
          ),
          throwsA(failure('INVALID_REQUEST')),
        );
      }
      await expectLater(
        save(client, expectedAnswerRevision: 9007199254740991),
        throwsA(failure('INVALID_REQUEST')),
      );
      await expectLater(
        client.saveAnswers(
          f.snapshot(revision: 9007199254740991),
          context: context(),
          expectedAnswerRevision: 0,
          answers: answers(),
          currentCase: () => f.snapshot(revision: 9007199254740991),
          currentProgramId: () => 'scfhp-eaa',
          currentContext: context,
        ),
        throwsA(failure('INVALID_REQUEST')),
      );
      await expectLater(
        save(client, input: [...answers(), ...answers()]),
        throwsA(failure('INVALID_REQUEST')),
      );
      await expectLater(
        save(
          clientFor(
            transport,
            maxRequestBytes: 10,
            tokenProvider: () async {
              tokens++;
              return 'token';
            },
          ),
        ),
        throwsA(failure('PAYLOAD_TOO_LARGE')),
      );
      expect(tokens, 0);
      expect(transport.requests, isEmpty);
    },
  );

  test(
    '200 Unicode scalar request IDs and maximum safe read revision are accepted',
    () async {
      final id = List.filled(200, '😀').join();
      final response = f.responseJson()
        ..['caseId'] = id
        ..['caseRevision'] = 9007199254740991
        ..['saved'] = null
        ..['isCurrent'] = false;
      final requested = f.snapshot(caseId: id, revision: 9007199254740991);
      final result =
          await clientFor(
            _Transport((_) async => jsonResponse(response)),
          ).readAnswers(
            requested,
            programId: 'scfhp-eaa',
            currentCase: () => requested,
            currentProgramId: () => 'scfhp-eaa',
            currentContext: () => null,
          );
      expect(result.caseId, id);
    },
  );

  test(
    'missing unsafe oversized or failed tokens never begin a request',
    () async {
      for (final provider in <MatchingTokenProvider>[
        () async => null,
        () async => '',
        () async => ' ',
        () async => 'token\n',
        () async => 'token\r\nSecret: value',
        () async => List.filled(4097, 'a').join(),
        () async => throw StateError('private-token'),
      ]) {
        final transport = _Transport(
          (_) async => jsonResponse(savedResponse()),
        );
        await expectLater(
          save(clientFor(transport, tokenProvider: provider)),
          throwsA(
            failure('UNAUTHENTICATED').having(
              (e) => e.toString(),
              'sanitized',
              isNot(contains('private')),
            ),
          ),
        );
        expect(transport.requests, isEmpty);
      }
    },
  );

  test(
    'selection is checked before token I/O and after delayed token acquisition',
    () async {
      var tokens = 0;
      final transport = _Transport((_) async => jsonResponse(savedResponse()));
      final client = clientFor(
        transport,
        tokenProvider: () async {
          tokens++;
          return 'token';
        },
      );
      await expectLater(
        client.saveAnswers(
          f.snapshot(),
          context: context(),
          expectedAnswerRevision: 0,
          answers: answers(),
          currentCase: () => f.snapshot(revision: 3),
          currentProgramId: () => 'scfhp-eaa',
          currentContext: context,
        ),
        throwsA(failure('STALE_RESPONSE')),
      );
      expect(tokens, 0);
      for (final kind in ['case', 'program', 'context']) {
        final token = Completer<String?>();
        var current = f.snapshot();
        var program = 'scfhp-eaa';
        var form = context();
        final pending = clientFor(transport, tokenProvider: () => token.future)
            .saveAnswers(
              f.snapshot(),
              context: context(),
              expectedAnswerRevision: 0,
              answers: answers(),
              currentCase: () => current,
              currentProgramId: () => program,
              currentContext: () => form,
            );
        if (kind == 'case') current = f.snapshot(revision: 3);
        if (kind == 'program') program = 'different';
        if (kind == 'context') {
          form = FormAnswerContext.fromJson(
            f.contextJson()..['mappingVersion'] = 'different',
          );
        }
        token.complete('token');
        await expectLater(pending, throwsA(failure('STALE_RESPONSE')));
      }
      expect(transport.requests, isEmpty);
    },
  );

  test(
    'caller list changes during token wait cannot alter the sent replacement',
    () async {
      final token = Completer<String?>();
      final transport = _Transport((_) async => jsonResponse(savedResponse()));
      final input = answers();
      final pending = save(
        clientFor(transport, tokenProvider: () => token.future),
        input: input,
      );
      input.clear();
      token.complete('token');
      expect((await pending).saved!.answers, hasLength(1));
      expect(
        (jsonDecode(utf8.decode(transport.requests.single.body))
            as Map)['answers'],
        hasLength(1),
      );
    },
  );

  test(
    'after-dispatch local changes reject reads and require save recovery',
    () async {
      for (final saving in [false, true]) {
        for (final kind in ['case', 'program', 'context']) {
          var current = f.snapshot();
          var program = 'scfhp-eaa';
          FormAnswerContext? form = saving ? context() : null;
          final transport = _Transport((_) async {
            if (kind == 'case') current = f.snapshot(revision: 3);
            if (kind == 'program') program = 'different';
            if (kind == 'context') {
              form = FormAnswerContext.fromJson(
                f.contextJson()..['mappingVersion'] = 'different',
              );
            }
            return jsonResponse(saving ? savedResponse() : f.responseJson());
          });
          final client = clientFor(transport);
          final pending = saving
              ? client.saveAnswers(
                  f.snapshot(),
                  context: context(),
                  expectedAnswerRevision: 0,
                  answers: answers(),
                  currentCase: () => current,
                  currentProgramId: () => program,
                  currentContext: () => form,
                )
              : client.readAnswers(
                  f.snapshot(),
                  programId: 'scfhp-eaa',
                  currentCase: () => current,
                  currentProgramId: () => program,
                  currentContext: () => form,
                );
          await expectLater(
            pending,
            throwsA(failure(saving ? 'FORM_SAVE_UNCERTAIN' : 'STALE_RESPONSE')),
          );
          expect(transport.requests, hasLength(1));
          expect(transport.cancellations, 1);
        }
      }
    },
  );

  test(
    'token timeout remains undispatched and late completion cannot send',
    () async {
      final token = Completer<String?>();
      final transport = _Transport((_) async => jsonResponse(savedResponse()));
      await expectLater(
        save(
          clientFor(
            transport,
            tokenProvider: () => token.future,
            timeout: const Duration(milliseconds: 20),
          ),
        ),
        throwsA(failure('TIMEOUT')),
      );
      token.complete('late-token');
      await Future<void>.delayed(Duration.zero);
      expect(transport.requests, isEmpty);
    },
  );

  test('save timeout cancels once never retries and requires reload', () async {
    final response = Completer<MatchingHttpResponse>();
    final transport = _Transport((_) => response.future);
    await expectLater(
      save(clientFor(transport, timeout: const Duration(milliseconds: 20))),
      throwsA(
        failure('FORM_SAVE_UNCERTAIN').having(
          (e) => e.message,
          'recovery',
          allOf(contains('Reload'), contains('before saving')),
        ),
      ),
    );
    expect(transport.requests, hasLength(1));
    expect(transport.cancellations, 1);
    response.complete(jsonResponse(savedResponse()));
    await Future<void>.delayed(Duration.zero);
    expect(transport.requests, hasLength(1));
  });

  test('transport cancellation and raw exception details never leak', () async {
    for (final saving in [false, true]) {
      final transport = _Transport(
        (_) async => throw StateError('private-answer-token'),
        cancellationError: StateError('private-cancel'),
      );
      await expectLater(
        saving ? save(clientFor(transport)) : read(clientFor(transport)),
        throwsA(
          failure(saving ? 'FORM_SAVE_UNCERTAIN' : 'NETWORK_ERROR').having(
            (e) => e.toString(),
            'sanitized',
            isNot(contains('private')),
          ),
        ),
      );
      expect(transport.cancellations, 1);
    }
  });

  test(
    'safe known server errors retain codes but save 5xx means uncertain outcome',
    () async {
      for (final pair in <(int, String)>[
        (400, 'INVALID_REQUEST'),
        (401, 'UNAUTHENTICATED'),
        (404, 'CASE_NOT_FOUND'),
        (404, 'PROGRAM_NOT_FOUND'),
        (404, 'FORM_NOT_AVAILABLE'),
        (404, 'NOT_FOUND'),
        (409, 'CASE_REVISION_MISMATCH'),
        (409, 'FORM_CONTEXT_MISMATCH'),
        (409, 'FORM_ANSWERS_CONFLICT'),
        (409, 'FORM_ANSWERS_STALE'),
        (413, 'PAYLOAD_TOO_LARGE'),
        (415, 'UNSUPPORTED_MEDIA_TYPE'),
        (405, 'METHOD_NOT_ALLOWED'),
        (500, 'INTERNAL_ERROR'),
        (503, 'SERVICE_UNAVAILABLE'),
      ]) {
        for (final saving in [false, true]) {
          final transport = _Transport(
            (_) async => jsonResponse({
              'schemaVersion': '1',
              'error': {'code': pair.$2, 'message': 'private-server-data'},
            }, status: pair.$1),
          );
          await expectLater(
            saving ? save(clientFor(transport)) : read(clientFor(transport)),
            throwsA(
              failure(
                saving && pair.$1 >= 500 ? 'FORM_SAVE_UNCERTAIN' : pair.$2,
              ).having(
                (e) => e.message,
                'sanitized',
                isNot(contains('private')),
              ),
            ),
          );
        }
      }
    },
  );

  test(
    'status-code mismatch unknown errors and malformed response bodies fail safely',
    () async {
      final responses = [
        jsonResponse({
          'schemaVersion': '1',
          'error': {'code': 'CASE_NOT_FOUND', 'message': 'x'},
        }, status: 409),
        jsonResponse({
          'schemaVersion': '1',
          'error': {'code': 'PRIVATE_UNKNOWN', 'message': 'x'},
        }, status: 400),
        jsonResponse({
          'schemaVersion': '1',
          'error': {'code': 'INVALID_REQUEST', 'message': 'x', 'private': true},
        }, status: 400),
        MatchingHttpResponse(
          statusCode: 200,
          contentType: 'text/html',
          body: utf8.encode('private-html'),
        ),
        MatchingHttpResponse(
          statusCode: 200,
          contentType: 'application/json',
          body: [0xff],
        ),
        MatchingHttpResponse(
          statusCode: 200,
          contentType: 'application/json',
          body: utf8.encode('{bad'),
        ),
        jsonResponse(f.responseJson()..['unknown'] = true),
      ];
      for (final response in responses) {
        for (final saving in [false, true]) {
          final client = clientFor(_Transport((_) async => response));
          await expectLater(
            saving ? save(client) : read(client),
            throwsA(
              failure(saving ? 'FORM_SAVE_UNCERTAIN' : 'UNEXPECTED_RESPONSE'),
            ),
          );
        }
      }
    },
  );

  test(
    'read rejects wrong case program and revision even when internally coherent',
    () async {
      for (final key in ['caseId', 'caseRevision', 'programId']) {
        final json = f.responseJson();
        final Object value = key == 'caseRevision' ? 3 : 'different';
        if (key == 'programId') {
          (json['context'] as Map)[key] = value;
        } else {
          json[key] = value;
        }
        (json['saved'] as Map)[key] = value;
        await expectLater(
          read(clientFor(_Transport((_) async => jsonResponse(json)))),
          throwsA(failure('STALE_RESPONSE')),
        );
      }
    },
  );

  test(
    'save requires exact incremented revisions matching context and replacement',
    () async {
      final mutations = <void Function(Map<String, Object?>)>[
        (j) {
          j['caseRevision'] = 2;
          (j['saved'] as Map)['caseRevision'] = 2;
        },
        (j) => (j['saved'] as Map)['answerRevision'] = 2,
        (j) {
          (j['context'] as Map)['mappingVersion'] = 'changed';
          (j['saved'] as Map)['mappingVersion'] = 'changed';
        },
        (j) {
          j['saved'] = null;
          j['isCurrent'] = false;
        },
        (j) => (j['saved'] as Map)['answers'] = <Object>[],
        (j) => ((j['saved'] as Map)['answers'] as List).single['value'] =
            'Not submitted',
        (j) => ((j['saved'] as Map)['answers'] as List).single['reviewedAt'] =
            '2026-10-17T19:00:00.123457Z',
        (j) => ((j['saved'] as Map)['answers'] as List).single['reviewedBy'] =
            null,
        (j) => ((j['saved'] as Map)['answers'] as List).single['key'] =
            'signature',
        (j) => j['isCurrent'] = false,
      ];
      for (final mutate in mutations) {
        final json = savedResponse();
        mutate(json);
        await expectLater(
          save(clientFor(_Transport((_) async => jsonResponse(json)))),
          throwsA(failure('FORM_SAVE_UNCERTAIN')),
        );
      }
    },
  );

  test(
    'response caps redirects and transport signals cancel without exposing data',
    () async {
      for (final failureKind in MatchingTransportFailure.values) {
        final transport = _Transport(
          (_) async => throw MatchingTransportException(failureKind),
        );
        await expectLater(
          save(clientFor(transport)),
          throwsA(failure('FORM_SAVE_UNCERTAIN')),
        );
        expect(transport.cancellations, 1);
      }
      for (final saving in [false, true]) {
        final big = clientFor(
          _Transport((_) async => jsonResponse(f.responseJson())),
          maxResponseBytes: 10,
        );
        await expectLater(
          saving ? save(big) : read(big),
          throwsA(
            failure(saving ? 'FORM_SAVE_UNCERTAIN' : 'RESPONSE_TOO_LARGE'),
          ),
        );
        final redirect = clientFor(
          _Transport((_) async => jsonResponse({}, status: 307)),
        );
        await expectLater(
          saving ? save(redirect) : read(redirect),
          throwsA(failure(saving ? 'FORM_SAVE_UNCERTAIN' : 'REDIRECT_BLOCKED')),
        );
      }
    },
  );

  test(
    'endpoint validation permits only fixed same-origin HTTPS or opted-in loopback',
    () {
      final transport = _Transport((_) async => jsonResponse(f.responseJson()));
      FormAnswersApiClient configured(
        String readUrl,
        String saveUrl, {
        bool local = false,
        bool emulator = false,
      }) => FormAnswersApiClient(
        readEndpoint: Uri.parse(readUrl),
        caseEndpoint: Uri.parse(readUrl).replace(path: '/v1/read-case'),
        saveEndpoint: Uri.parse(saveUrl),
        tokenProvider: () async => 'token',
        transport: transport,
        allowInsecureLoopback: local,
        allowAndroidEmulatorLoopback: emulator,
      );
      for (final invalid in [
        'http://example.org/v1/read-form-answers',
        'https://user:secret@example.org/v1/read-form-answers',
        'https://example.org/v1/read-form-answers?token=private',
        'https://example.org/v1/read-form-answers#private',
        'https://example.org/v1/read-form-answers/',
        'https://example.org/v1/save-form-answers',
        'https://example.org:0/v1/read-form-answers',
        '/v1/read-form-answers',
      ]) {
        expect(
          () => configured(invalid, 'https://example.org/v1/save-form-answers'),
          throwsA(
            isA<ArgumentError>().having(
              (e) => e.toString(),
              'sanitized',
              isNot(contains('private')),
            ),
          ),
        );
      }
      expect(
        () => configured(
          'https://example.org/v1/read-form-answers',
          'https://other.org/v1/save-form-answers',
        ),
        throwsArgumentError,
      );
      for (final host in ['localhost', '127.0.0.1', '[::1]']) {
        expect(
          configured(
            'http://$host:9876/v1/read-form-answers',
            'http://$host:9876/v1/save-form-answers',
            local: true,
          ),
          isA<FormAnswersApiClient>(),
        );
      }
      expect(
        () => configured(
          'http://10.0.2.2/v1/read-form-answers',
          'http://10.0.2.2/v1/save-form-answers',
          local: true,
        ),
        throwsArgumentError,
      );
      expect(
        configured(
          'http://10.0.2.2/v1/read-form-answers',
          'http://10.0.2.2/v1/save-form-answers',
          local: true,
          emulator: true,
        ),
        isA<FormAnswersApiClient>(),
      );
    },
  );

  test('timeouts and byte limits cannot exceed transport policy', () {
    final transport = _Transport((_) async => jsonResponse(f.responseJson()));
    for (final timeout in [Duration.zero, const Duration(seconds: 16)]) {
      expect(() => clientFor(transport, timeout: timeout), throwsArgumentError);
    }
    for (final bytes in [0, 1024 * 1024 + 1]) {
      expect(
        () => clientFor(transport, maxResponseBytes: bytes),
        throwsArgumentError,
      );
    }
    for (final bytes in [0, 16 * 1024 + 1]) {
      expect(
        () => clientFor(transport, maxRequestBytes: bytes),
        throwsArgumentError,
      );
    }
  });
}

class _Transport implements MatchingTransport {
  _Transport(this.handler, {this.cancellationError});
  final Future<MatchingHttpResponse> Function(MatchingHttpRequest) handler;
  final Object? cancellationError;
  final requests = <MatchingHttpRequest>[];
  var cancellations = 0;

  @override
  MatchingExchange post(MatchingHttpRequest request) {
    requests.add(request);
    return MatchingExchange(
      response: handler(request),
      cancel: () {
        cancellations++;
        if (cancellationError != null) throw cancellationError!;
      },
    );
  }
}
