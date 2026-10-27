import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/shared/models/account_plan_name.dart';
import 'package:safe_at_home/shared/models/export_contract_values.dart';

Map<String, Object?> nameState({
  String caseId = 'case-a',
  String? name = 'Cedar house',
  int revision = 1,
  String? mutation = 'mutation-a',
}) => {
  'schemaVersion': '2',
  'caseId': caseId,
  'name': name,
  'nameRevision': revision,
  'lastMutationId': mutation,
};

Map<String, Object?> namedSummary(String id) => {
  'caseId': id,
  'caseRevision': 4,
  'name': 'Cedar house',
  'nameRevision': 1,
  'lastMutationId': 'mutation-a',
};

Map<String, Object?> namedPage(List<String> ids, {String? cursor}) => {
  'schemaVersion': '2',
  'cases': ids.map(namedSummary).toList(),
  'nextAfterCaseId': cursor,
};

void main() {
  test('initial state and explicit reset have distinct durable identities', () {
    final initial = AccountPlanName.initial('case-a');
    expect(initial.name, isNull);
    expect(initial.nameRevision, 0);
    expect(initial.lastMutationId, isNull);
    expect(
      AccountPlanName.fromJson(initial.toJson()).toJson(),
      initial.toJson(),
    );
    final reset = AccountPlanName.fromJson(nameState(name: null));
    expect(reset.name, isNull);
    expect(reset.nameRevision, 1);
    expect(reset.lastMutationId, 'mutation-a');
  });

  test('80 Unicode scalars and supported joiners remain valid', () {
    for (final name in ['😀' * 80, 'Mom’s home', '👩‍👩‍👧‍👦 home']) {
      expect(AccountPlanName.fromJson(nameState(name: name)).name, name);
    }
  });

  for (final invalid in <Object?>[
    '',
    ' ',
    ' Cedar',
    'Cedar ',
    '😀' * 81,
    'a\nb',
    'a\rb',
    'a\tb',
    'a\u007fb',
    'a\u2028b',
    'a\u202eb',
    'a\u2066b',
    '\ud800',
    12,
    false,
  ]) {
    test(
      'strict state rejects noncanonical or unsafe name ${invalid.runtimeType} ${invalid.hashCode}',
      () {
        expect(
          () => AccountPlanName.fromJson({...nameState(), 'name': invalid}),
          throwsFormatException,
        );
      },
    );
  }

  test(
    'state enforces exact schema, identity and revision/mutation coupling',
    () {
      for (final invalid in <Map<String, Object?>>[
        {...nameState(), 'extra': true},
        {...nameState()}..remove('name'),
        {...nameState(), 'schemaVersion': '1'},
        {...nameState(), 'caseId': ' bad-id'},
        {...nameState(), 'caseId': '😀' * 201},
        {...nameState(), 'nameRevision': -1},
        {...nameState(), 'nameRevision': 1.5},
        {...nameState(), 'nameRevision': ExportContractValues.maxInteger + 1},
        {...nameState(), 'nameRevision': 0},
        {...nameState(), 'lastMutationId': null},
        {...nameState(), 'lastMutationId': ''},
        {...nameState(), 'lastMutationId': 'x' * 201},
      ]) {
        expect(() => AccountPlanName.fromJson(invalid), throwsFormatException);
      }
      final max = AccountPlanName.fromJson(
        nameState(revision: ExportContractValues.maxInteger),
      );
      expect(max.nameRevision, ExportContractValues.maxInteger);
    },
  );

  test(
    'save request preserves exact retries and leaves increment capacity',
    () {
      final request = PlanNameSaveRequest(
        caseId: 'case-a',
        expectedNameRevision: ExportContractValues.maxInteger - 1,
        mutationId: 'mutation-a',
        name: null,
      );
      expect(
        PlanNameSaveRequest.fromJson(request.toJson()).toJson(),
        request.toJson(),
      );
      for (final invalid in <Map<String, Object?>>[
        {
          ...request.toJson(),
          'expectedNameRevision': ExportContractValues.maxInteger,
        },
        {...request.toJson(), 'expectedNameRevision': -1},
        {...request.toJson(), 'mutationId': null},
        {...request.toJson(), 'name': 'trim me '},
        {...request.toJson(), 'schemaVersion': '1'},
        {...request.toJson(), 'extra': true},
      ]) {
        expect(
          () => PlanNameSaveRequest.fromJson(invalid),
          throwsFormatException,
        );
      }
    },
  );

  test('named list retains flat metadata and existing summary identity', () {
    final page = NamedCaseListPage.fromJson(
      namedPage(['case-a', 'case-b'], cursor: 'case-b'),
      limit: 2,
    );
    expect(page.nextAfterCaseId, 'case-b');
    expect(page.cases.first.name, 'Cedar house');
    expect(page.cases.first.summary.caseRevision, 4);
    expect(page.cases.first.planName.caseId, 'case-a');
    expect(page.toJson(), namedPage(['case-a', 'case-b'], cursor: 'case-b'));
    expect(() => page.cases.clear(), throwsUnsupportedError);
  });

  test(
    'named list rejects duplicates, bad cursor, oversized pages and extras',
    () {
      for (final invalid in <Map<String, Object?>>[
        namedPage(['case-a', 'case-a']),
        namedPage(['case-b', 'case-a']),
        namedPage(['case-a'], cursor: 'case-a'),
        namedPage(['case-a', 'case-b'], cursor: 'case-a'),
        namedPage(['case-a', 'case-b', 'case-c']),
        {
          ...namedPage(['case-a']),
          'extra': true,
        },
        {
          ...namedPage(['case-a']),
          'schemaVersion': '1',
        },
        {
          ...namedPage(['case-a']),
          'cases': [
            {...namedSummary('case-a'), 'extra': true},
          ],
        },
        {
          ...namedPage(['case-a']),
          'cases': [
            {...namedSummary('case-a'), 'nameRevision': 0},
          ],
        },
      ]) {
        expect(
          () => NamedCaseListPage.fromJson(invalid, limit: 2),
          throwsFormatException,
        );
      }
      expect(
        () => NamedCaseListPage.fromJson(
          namedPage(['case-a']),
          afterCaseId: 'case-a',
        ),
        throwsFormatException,
      );
    },
  );

  test('named list preserves UTF-8 ordering across supplementary scalars', () {
    final page = NamedCaseListPage.fromJson(namedPage(['\ue000', '😀']));
    expect(page.cases.map((item) => item.caseId), ['\ue000', '😀']);
    expect(
      () => NamedCaseListPage.fromJson(namedPage(['😀', '\ue000'])),
      throwsFormatException,
    );
  });
}
