import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/shared/models/case_list.dart';

import 'support/contract_schema.dart';

Map<String, Object?> pageJson(
  List<String> ids, {
  String? next,
  num revision = 1,
}) => {
  'schemaVersion': '1',
  'cases': ids
      .map((id) => <String, Object?>{'caseId': id, 'caseRevision': revision})
      .toList(),
  'nextAfterCaseId': next,
};

void main() {
  test('minimal request and page round trip without resident details', () {
    final request = CaseListRequest();
    expect(request.toJson(), {
      'schemaVersion': '1',
      'limit': 20,
      'afterCaseId': null,
    });
    final json = pageJson(['case-a', 'case-b']);
    final page = CaseListPage.fromJson(json, request: request);
    expect(page.cases.map((value) => value.caseId), ['case-a', 'case-b']);
    expect(page.cases.first.caseRevision, 1);
    expect(page.toJson(), json);
    expect(
      CaseListPage.fromJson(pageJson([]), request: request).cases,
      isEmpty,
    );
  });

  test(
    'request requires exact fields, bounds and strict Unicode scalar identifiers',
    () {
      final invalid = <Object?>[
        null,
        [],
        {},
        {'schemaVersion': '2', 'limit': 20, 'afterCaseId': null},
        {'schemaVersion': '1', 'limit': 20},
        {...CaseListRequest().toJson(), 'ownerId': 'other'},
        for (final value in [
          0,
          21,
          1.1,
          double.nan,
          double.infinity,
          '1',
          true,
          null,
        ])
          {...CaseListRequest().toJson(), 'limit': value},
        for (final id in [
          '',
          ' ',
          ' case-a',
          'case-a ',
          'case-a\n',
          'case\u0000a',
          'case\u0085a',
          'case\u2028a',
          'case\u2029a',
          '\ud800',
          '\udfff',
          List.filled(201, '😀').join(),
          1,
          false,
        ])
          {...CaseListRequest().toJson(), 'afterCaseId': id},
      ];
      for (final value in invalid) {
        expect(() => CaseListRequest.fromJson(value), throwsFormatException);
      }
      expect(
        CaseListRequest(
          limit: 1,
          afterCaseId: List.filled(200, '😀').join(),
        ).limit,
        1,
      );
      expect(
        CaseListRequest(afterCaseId: 'case with spaces').afterCaseId,
        'case with spaces',
      );
    },
  );

  test('summary fields and revisions are exact safe integers', () {
    for (final revision in [0, -1, 1.5, 9007199254740992, '1', null, true]) {
      expect(
        () => CaseSummary.fromJson({'caseId': 'a', 'caseRevision': revision}),
        throwsFormatException,
      );
    }
    for (final value in [
      null,
      [],
      {'caseId': 'a'},
      {'caseId': 'a', 'caseRevision': 1, 'title': 'private'},
    ]) {
      expect(() => CaseSummary.fromJson(value), throwsFormatException);
    }
    expect(
      CaseSummary.fromJson({
        'caseId': 'a',
        'caseRevision': 9007199254740991,
      }).caseRevision,
      9007199254740991,
    );
    expect(
      CaseSummary.fromJson({'caseId': 'a', 'caseRevision': 1.0}).caseRevision,
      1,
    );
  });

  test(
    'strict UTF-8 byte order handles supplementary Unicode unlike UTF-16 order',
    () {
      final request = CaseListRequest(limit: 2);
      expect(
        CaseListPage.fromJson(
          pageJson(['\ue000', '\u{10000}']),
          request: request,
        ).cases,
        hasLength(2),
      );
      expect(
        () => CaseListPage.fromJson(
          pageJson(['\u{10000}', '\ue000']),
          request: request,
        ),
        throwsFormatException,
      );
      expect(
        CaseListPage.fromJson(
          pageJson(['\u{10000}']),
          request: CaseListRequest(afterCaseId: '\ue000'),
        ).cases,
        hasLength(1),
      );
      expect(
        () => CaseListPage.fromJson(
          pageJson(['\ue000']),
          request: CaseListRequest(afterCaseId: '\u{10000}'),
        ),
        throwsFormatException,
      );
    },
  );

  test(
    'duplicate, descending, and pre-cursor rows are never repaired or accepted',
    () {
      for (final ids in [
        ['b', 'a'],
        ['a', 'a'],
        ['a', 'ab', 'aa'],
      ]) {
        expect(
          () =>
              CaseListPage.fromJson(pageJson(ids), request: CaseListRequest()),
          throwsFormatException,
        );
      }
      final duplicate = pageJson(['a', 'a']);
      ((duplicate['cases'] as List).last as Map)['caseRevision'] = 2;
      expect(
        () => CaseListPage.fromJson(duplicate, request: CaseListRequest()),
        throwsFormatException,
      );
      for (final id in ['a', 'b']) {
        expect(
          () => CaseListPage.fromJson(
            pageJson([id]),
            request: CaseListRequest(afterCaseId: 'b'),
          ),
          throwsFormatException,
        );
      }
    },
  );

  test('page and continuation cursor must correspond to the request', () {
    final request = CaseListRequest(limit: 2, afterCaseId: 'a');
    for (final value in [
      pageJson(['b', 'c', 'd']),
      pageJson([], next: 'b'),
      pageJson(['b'], next: 'b'),
      pageJson(['b', 'c'], next: 'b'),
      pageJson(['b', 'c'], next: 'd'),
    ]) {
      expect(
        () => CaseListPage.fromJson(value, request: request),
        throwsFormatException,
      );
    }
    expect(
      CaseListPage.fromJson(
        pageJson(['b', 'c'], next: 'c'),
        request: request,
      ).nextAfterCaseId,
      'c',
    );
    expect(
      CaseListPage.fromJson(
        pageJson(['b', 'c']),
        request: request,
      ).nextAfterCaseId,
      isNull,
    );
  });

  test('page schema version, shape and primitive types are strict', () {
    for (final value in [
      null,
      [],
      {},
      {...pageJson([]), 'schemaVersion': '2'},
      {...pageJson([]), 'ownerId': 'private'},
      {...pageJson([])}..remove('nextAfterCaseId'),
      {...pageJson([]), 'cases': {}},
      {...pageJson([]), 'nextAfterCaseId': false},
    ]) {
      expect(
        () => CaseListPage.fromJson(value, request: CaseListRequest()),
        throwsFormatException,
      );
    }
  });

  test('input and serialized output cannot mutate retained page metadata', () {
    final input = pageJson(['a']);
    final page = CaseListPage.fromJson(input, request: CaseListRequest());
    ((input['cases'] as List).first as Map)['caseId'] = 'changed';
    (input['cases'] as List).clear();
    expect(page.cases.single.caseId, 'a');
    expect(() => page.cases.clear(), throwsUnsupportedError);
    final output = page.toJson();
    ((output['cases'] as List).first as Map)['caseRevision'] = 9;
    expect(page.cases.single.caseRevision, 1);
  });

  test(
    'request/response schemas enforce their structural subset and private shape',
    () {
      final schemas = <String, Map<String, dynamic>>{
        for (final name in [
          'case-list-request.schema.json',
          'case-list.schema.json',
        ])
          name:
              jsonDecode(File('contracts/v1/$name').readAsStringSync())
                  as Map<String, dynamic>,
      };
      bool accepts(String name, Object? value) =>
          acceptsContract(value, schemas[name], schemas, schemas[name]!);
      expect(
        accepts(
          'case-list-request.schema.json',
          CaseListRequest(limit: 1, afterCaseId: '😀').toJson(),
        ),
        isTrue,
      );
      for (final limit in [0, 21, 1.5, '1']) {
        expect(
          accepts('case-list-request.schema.json', {
            ...CaseListRequest().toJson(),
            'limit': limit,
          }),
          isFalse,
        );
      }
      for (final id in [' a', 'a\n', '\ud800', List.filled(201, '😀').join()]) {
        expect(
          accepts('case-list-request.schema.json', {
            ...CaseListRequest().toJson(),
            'afterCaseId': id,
          }),
          isFalse,
        );
      }
      expect(accepts('case-list.schema.json', pageJson(['a', '😀'])), isTrue);
      expect(
        accepts('case-list.schema.json', pageJson([], next: 'a')),
        isFalse,
      );
      expect(
        accepts('case-list.schema.json', {...pageJson([]), 'profile': {}}),
        isFalse,
      );
      expect(
        accepts(
          'case-list.schema.json',
          pageJson(['a'], revision: 9007199254740992),
        ),
        isFalse,
      );
    },
  );
}
