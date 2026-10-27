import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/shared/models/case_draft.dart';
import 'package:safe_at_home/shared/models/contracts.dart';
import 'package:safe_at_home/shared/models/evidence_mutation.dart';

import '../support/contract_schema.dart';
import 'draft_export_test.dart' as f;

const caseUuid = 'ec57928e-1456-4b38-8467-e4026ac074a2';
Map<String, Object?> draftJson({String caseId = caseUuid}) =>
    f.snapshot().toJson()
      ..remove('revision')
      ..['caseId'] = caseId;
CaseDraft draft({String caseId = caseUuid}) =>
    CaseDraft.fromJson(draftJson(caseId: caseId));
Map<String, Object?> uploadJson({
  int catalogRevision = 2,
  int evidenceRevision = 2,
}) => {
  'schemaVersion': '1',
  'caseId': 'fictional-case',
  'caseRevision': 2,
  'catalogRevision': catalogRevision,
  'evidence': f.descriptorJson(revision: evidenceRevision),
};
Map<String, Object?> deleteJson() => {
  'schemaVersion': '1',
  'caseId': 'fictional-case',
  'caseRevision': 2,
  'catalogRevision': 2,
  'evidenceId': 'fictional-evidence',
  'evidenceRevision': 2,
  'deleted': true,
};

void main() {
  test(
    'snapshot serialization preserves null, false, zero and negative income',
    () {
      final input = f.snapshot().toJson();
      (input['profile'] as Map).addAll(<String, Object?>{
        'ageYears': 0,
        'householdSize': 1,
        'annualIncomeUsd': -5.5,
        'ownerConsentReported': false,
      });
      (input['findings'] as List).first['measurements'] = [
        {
          'type': 'threshold height',
          'value': 0,
          'unit': 'mm',
          'method': 'manual',
          'confirmed': false,
        },
      ];
      final value = parseWritableCase(input);
      expect(value.toJson(), input);
      expect(value.profile.city, isNull);
      expect(value.profile.ownerConsentReported, isFalse);
      expect(value.profile.ageYears, 0);
      expect(value.profile.annualIncomeUsd, -5.5);
      expect(value.findings.single.measurements.single.value, 0);
    },
  );
  test(
    'draft collections are immutable and serialize detached replacements',
    () {
      final input = draftJson();
      final value = CaseDraft.fromJson(input);
      (input['findings'] as List).clear();
      expect(value.findings, hasLength(1));
      expect(() => value.findings.clear(), throwsUnsupportedError);
      expect(
        () => value.findings.single.evidenceIds.clear(),
        throwsUnsupportedError,
      );
      final output = value.toJson();
      (output['findings'] as List).clear();
      expect(value.findings, hasLength(1));
      expect(value.toJson().containsKey('revision'), isFalse);
    },
  );
  test('protected keys and incomplete replacements fail closed', () {
    for (final key in ['ownerId', 'revision', 'updatedAt']) {
      expect(
        () => CaseDraft.fromJson(draftJson()..[key] = 'caller'),
        throwsFormatException,
      );
    }
    expect(
      () => CaseDraft.fromJson(draftJson()..remove('findings')),
      throwsFormatException,
    );
    expect(
      () => CaseDraft.fromJson(draftJson()..['schemaVersion'] = '2'),
      throwsFormatException,
    );
  });
  test(
    'secure UUID generation fixes version and variant, create validates exact form',
    () {
      final ids = List.generate(100, (_) => newUuidV4());
      expect(ids.toSet(), hasLength(100));
      expect(ids.every(isCaseUuidV4), isTrue);
      expect(draft().toCreateRequest()['caseId'], caseUuid);
      for (final id in [
        'fictional-case',
        caseUuid.toUpperCase(),
        '$caseUuid\n',
        caseUuid.replaceFirst('-4', '-5'),
      ]) {
        expect(
          () => draft(caseId: id).toCreateRequest(),
          throwsFormatException,
        );
      }
      expect(
        draft(
          caseId: 'fictional-case',
        ).toSaveRequest(2)['expectedCaseRevision'],
        2,
      );
    },
  );
  test(
    'safe revisions and profile integers cannot overflow or normalize text',
    () {
      expect(
        () => draft().toSaveRequest(9007199254740991),
        throwsFormatException,
      );
      for (final key in ['ageYears', 'householdSize']) {
        final input = draftJson();
        (input['profile'] as Map)[key] = 9007199254740992;
        expect(() => CaseDraft.fromJson(input), throwsFormatException);
      }
      final input = draftJson();
      (input['profile'] as Map)['city'] = '  Fictional City  ';
      expect(CaseDraft.fromJson(input).profile.city, '  Fictional City  ');
    },
  );
  test(
    'blank, NUL and lone-surrogate facts fail; Unicode scalar IDs stay intact',
    () {
      for (final value in ['   ', '\n', '\ud800', 'Town\u0000name']) {
        final input = draftJson();
        (input['profile'] as Map)['city'] = value;
        expect(() => CaseDraft.fromJson(input), throwsFormatException);
      }
      final observation = draftJson();
      ((observation['findings'] as List).first as Map)['observation'] =
          'Step\u0000edge';
      expect(() => CaseDraft.fromJson(observation), throwsFormatException);
      final unicode = List.filled(200, '🏠').join();
      expect(draft(caseId: unicode).caseId, unicode);
      expect(() => draft(caseId: '${unicode}x'), throwsFormatException);
      for (final id in [' id', 'id\n', '\udfff']) {
        expect(() => draft(caseId: id), throwsFormatException);
      }
    },
  );
  test('duplicate IDs and references are rejected at the saved boundary', () {
    final input = draftJson();
    final findings = input['findings'] as List;
    findings.add(Map<String, Object?>.from(findings.first as Map));
    expect(() => CaseDraft.fromJson(input), throwsFormatException);
    final other = draftJson();
    ((other['findings'] as List).first['evidenceIds'] as List).add(
      'fictional-evidence',
    );
    expect(() => CaseDraft.fromJson(other), throwsFormatException);
    final shared = draftJson();
    final sharedFindings = shared['findings'] as List;
    sharedFindings.add(<String, Object?>{
      ...Map<String, Object?>.from(sharedFindings.first as Map),
      'id': 'another-finding',
    });
    expect(() => CaseDraft.fromJson(shared), throwsFormatException);
  });
  test(
    'unresolved field IDs and measurement types follow strict identifier bounds',
    () {
      for (final value in [' leading', 'line\nbreak', 'x' * 201, '\ud800']) {
        final unresolved = draftJson()..['unresolvedFields'] = [value];
        expect(() => CaseDraft.fromJson(unresolved), throwsFormatException);
        final measured = draftJson();
        (measured['findings'] as List).first['measurements'] = [
          <String, Object?>{
            'type': value,
            'value': 1,
            'unit': 'mm',
            'method': 'manual',
            'confirmed': false,
          },
        ];
        expect(() => CaseDraft.fromJson(measured), throwsFormatException);
      }
    },
  );
  test('UTF8 full snapshot bound includes the assigned next revision', () {
    final input = draftJson();
    final profile = input['profile'] as Map;
    profile['city'] = 'x';
    final base = utf8.encode(jsonEncode({...input, 'revision': 9})).length;
    profile['city'] = 'x' * (maxSavedCaseBytes - base + 1);
    final value = CaseDraft.fromJson(input);
    expect(
      utf8.encode(jsonEncode(value.atRevision(9).toJson())),
      hasLength(maxSavedCaseBytes),
    );
    expect(
      () => value.toSaveRequest(9),
      throwsFormatException,
      reason: 'Revision 10 costs another byte',
    );
    profile['city'] = 'é' * (maxSavedCaseBytes ~/ 2);
    expect(() => CaseDraft.fromJson(input), throwsFormatException);
  });
  test(
    'current snapshot permits only bounded revision-digit growth headroom',
    () {
      final input = draftJson(caseId: 'fictional-case');
      final profile = input['profile'] as Map;
      profile['city'] = 'x';
      final base = utf8.encode(jsonEncode({...input, 'revision': 1})).length;
      profile['city'] = 'x' * (maxSavedCaseBytes - base + 1);
      final saved = {...input, 'revision': 9007199254740991};
      expect(utf8.encode(jsonEncode(saved)), hasLength(maxSavedCaseBytes + 15));
      expect(parseCurrentCase(saved).revision, 9007199254740991);
      expect(() => parseWritableCase(saved), throwsFormatException);
      expect(
        CaseDraft.fromSnapshot(parseCurrentCase(saved)).caseId,
        'fictional-case',
      );
      profile['city'] = '${profile['city']}x';
      expect(
        () => parseCurrentCase({...input, 'revision': 9007199254740991}),
        throwsFormatException,
      );
    },
  );
  test('upload receipt is strict, bound to case and immutable', () {
    final input = uploadJson();
    final value = EvidenceUploadResponse.fromJson(input);
    expect(value.toJson(), input);
    (input['evidence'] as Map)['findingId'] = 'changed';
    expect(value.evidence.findingId, 'fictional-finding');
    for (final key in ['ownerId', 'url', 'storageReference']) {
      expect(
        () => EvidenceUploadResponse.fromJson(uploadJson()..[key] = 'private'),
        throwsFormatException,
      );
    }
    final mismatch = uploadJson();
    (mismatch['evidence'] as Map)['caseId'] = 'other';
    expect(
      () => EvidenceUploadResponse.fromJson(mismatch),
      throwsFormatException,
    );
    expect(
      () => EvidenceUploadResponse.fromJson(uploadJson(catalogRevision: 0)),
      throwsFormatException,
    );
  });
  test('delete receipt requires literal true and safe positive revisions', () {
    final value = EvidenceDeleteResponse.fromJson(deleteJson());
    expect(value.toJson(), deleteJson());
    expect(value.deleted, isTrue);
    for (final patch in [
      <String, Object?>{'deleted': false},
      {'deleted': 'true'},
      {'evidenceRevision': 0},
      {'catalogRevision': 9007199254740992},
      {'storageReference': 'path'},
    ]) {
      expect(
        () => EvidenceDeleteResponse.fromJson({...deleteJson(), ...patch}),
        throwsFormatException,
      );
    }
  });
  test(
    'canonical schemas agree with valid requests and malformed boundaries',
    () {
      final schemas = <String, Map<String, dynamic>>{};
      for (final file
          in Directory('contracts/v1').listSync().whereType<File>().where(
            (f) => f.path.endsWith('.schema.json'),
          )) {
        schemas[file.uri.pathSegments.last] =
            jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      }
      bool accepts(String name, Object? value) =>
          acceptsContract(value, schemas[name]!, schemas, schemas[name]!);
      final create = draft().toCreateRequest();
      final save = draft(caseId: 'fictional-case').toSaveRequest(2);
      final upload = <String, Object?>{
        'schemaVersion': '1',
        'caseId': 'fictional-case',
        'expectedCaseRevision': 2,
        'expectedCatalogRevision': 1,
        'evidenceId': 'fictional-evidence',
        'expectedEvidenceRevision': 1,
        'findingId': 'fictional-finding',
        'capturedAt': null,
        'imageBase64': base64Encode(f.png),
      };
      final deletion = Map<String, Object?>.from(upload)
        ..remove('findingId')
        ..remove('capturedAt')
        ..remove('imageBase64');
      final samples = {
        'case-create-request.schema.json': create,
        'case-save-request.schema.json': save,
        'evidence-upload-request.schema.json': upload,
        'evidence-delete-request.schema.json': deletion,
        'evidence-upload-response.schema.json': uploadJson(),
        'evidence-delete-response.schema.json': deleteJson(),
      };
      for (final entry in samples.entries) {
        expect(accepts(entry.key, entry.value), isTrue, reason: entry.key);
        expect(
          accepts(entry.key, {...entry.value, 'ownerId': 'forged'}),
          isFalse,
          reason: entry.key,
        );
      }
      expect(
        accepts('case-create-request.schema.json', {
          ...create,
          'caseId': 'not-uuid',
        }),
        isFalse,
      );
      expect(
        accepts('case-save-request.schema.json', {
          ...save,
          'expectedCaseRevision': 9007199254740991,
        }),
        isFalse,
      );
      for (final invalid in ['aGVsbG8=\n', 'aGVsbG9=', 'not image?!', '']) {
        expect(
          accepts('evidence-upload-request.schema.json', {
            ...upload,
            'imageBase64': invalid,
          }),
          isFalse,
        );
      }
      final blank = draftJson();
      (blank['profile'] as Map)['city'] = ' ';
      expect(accepts('case-create-request.schema.json', blank), isFalse);
      final unicode = draftJson();
      (unicode['profile'] as Map)['city'] = '🏠 Town';
      expect(accepts('case-create-request.schema.json', unicode), isTrue);
      expect(
        CaseSnapshot.fromJson(f.snapshot().toJson()).toJson(),
        f.snapshot().toJson(),
      );
    },
  );
}
