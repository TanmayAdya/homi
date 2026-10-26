import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as hashing;
import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/shared/models/contracts.dart';
import 'package:safe_at_home/shared/models/draft_export.dart';
import 'package:safe_at_home/shared/models/evidence.dart';
import 'package:safe_at_home/shared/models/form_answers.dart';

import '../support/contract_schema.dart';

const stamp = '2026-10-17T19:00:00.123456Z';
const digest =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
final png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aJxkAAAAASUVORK5CYII=',
);
final pdf = utf8.encode('%PDF-1.7\nFictional draft\n%%EOF');

Map<String, Object?> descriptorJson({
  String id = 'fictional-evidence',
  int revision = 1,
}) => {
  'evidenceId': id,
  'evidenceRevision': revision,
  'caseId': 'fictional-case',
  'findingId': 'fictional-finding',
  'mediaType': 'image/png',
  'byteLength': png.length,
  'sha256': hashing.sha256.convert(png).toString(),
  'width': 1,
  'height': 1,
  'capturedAt': null,
  'preparedAt': stamp,
  'processingVersion': 'evidence-png-v1',
};
Map<String, Object?> catalogJson() => {
  'schemaVersion': '1',
  'caseId': 'fictional-case',
  'caseRevision': 2,
  'catalogRevision': 1,
  'evidence': [descriptorJson()],
};
Map<String, Object?> selectionJson({
  String id = 'fictional-evidence',
  int revision = 1,
}) => {
  'evidenceId': id,
  'expectedEvidenceRevision': revision,
  'reviewedForExport': true,
};
Map<String, Object?> contextJson() => {
  'programId': 'fictional-program',
  'formVersion': 'form-v1',
  'mappingVersion': 'mapping-v1',
  'formContextId': digest,
};
Map<String, Object?> artifactJson() => {
  'schemaVersion': '1',
  'artifactId': 'fictional-artifact',
  'caseId': 'fictional-case',
  'caseRevision': 2,
  ...contextJson(),
  'ruleVersion': 'rule-v1',
  'answerRevision': 0,
  'evidenceCatalogRevision': 1,
  'exportContextId': digest,
  'generatedAt': stamp,
  'expiresAt': '2026-10-17T19:15:00.123456Z',
  'recheckAfter': null,
  'status': 'draft',
  'isDemo': true,
  'mediaType': 'application/pdf',
  'byteLength': pdf.length,
  'sha256': hashing.sha256.convert(pdf).toString(),
  'pageCount': 6,
  'renderingVersion': 'draft-export-v1',
  'selectedEvidence': [
    {
      'evidenceId': 'fictional-evidence',
      'evidenceRevision': 1,
      'findingId': 'fictional-finding',
      'sha256': descriptorJson()['sha256'],
      'reviewedAt': stamp,
      'reviewedBy': 'fictional-reviewer',
    },
  ],
  'missingItems': [
    <String, Object?>{
      'id': 'clinical-review',
      'description': 'Ask a professional to review the clinical questions.',
      'resolvedBy': 'professional',
    },
  ],
  'warnings': [
    'INCOMPLETE_DRAFT',
    'NOT_SUBMITTED',
    'POLICY_CURRENTNESS_UNKNOWN',
  ],
};
CaseSnapshot snapshot({int revision = 2, String review = 'confirmed'}) =>
    CaseSnapshot.fromJson({
      'schemaVersion': '1',
      'caseId': 'fictional-case',
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
      'findings': [
        {
          'id': 'fictional-finding',
          'room': 'entrance',
          'observation': 'Fictional uneven threshold.',
          'reviewState': review,
          'evidenceIds': ['fictional-evidence', 'second-evidence'],
          'measurements': <Object>[],
        },
      ],
    });
EvidenceCatalog catalog() => EvidenceCatalog.fromJson(catalogJson());
FormAnswerContext context() => FormAnswerContext.fromJson(contextJson());
EvidenceSelection selection() => EvidenceSelection.fromJson(selectionJson());
ExportArtifactMetadata artifact() =>
    ExportArtifactMetadata.fromJson(artifactJson());

void main() {
  test(
    'catalog and artifact round trip with immutable detached collections',
    () {
      final input = catalogJson(), metadata = artifactJson();
      final parsed = EvidenceCatalog.fromJson(input),
          exported = ExportArtifactMetadata.fromJson(metadata);
      expect(parsed.toJson(), input);
      expect(exported.toJson(), metadata);
      (input['evidence'] as List).clear();
      (metadata['selectedEvidence'] as List).clear();
      expect(parsed.evidence, hasLength(1));
      expect(exported.selectedEvidence, hasLength(1));
      expect(() => parsed.evidence.clear(), throwsUnsupportedError);
      expect(() => exported.warnings.clear(), throwsUnsupportedError);
      expect(() => exported.missingItems.clear(), throwsUnsupportedError);
      expect(parsed.belongsTo(snapshot()), isTrue);
      expect(parsed.belongsTo(snapshot(revision: 3)), isFalse);
    },
  );
  test('strict objects reject unknown fields and storage identifiers', () {
    for (final field in ['ownerId', 'url', 'storageReference', 'signedUrl']) {
      expect(
        () =>
            EvidenceDescriptor.fromJson(descriptorJson()..[field] = 'private'),
        throwsFormatException,
      );
      expect(
        () => ExportArtifactMetadata.fromJson(
          artifactJson()..[field] = 'private',
        ),
        throwsFormatException,
      );
    }
    expect(
      () => EvidenceCatalog.fromJson(catalogJson()..remove('catalogRevision')),
      throwsFormatException,
    );
    expect(
      () => ExportArtifactMetadata.fromJson(artifactJson()..remove('warnings')),
      throwsFormatException,
    );
  });
  test(
    'identifiers preserve Unicode scalars and reject whitespace controls and surrogates',
    () {
      final unicode = List.filled(200, '😀').join();
      expect(
        EvidenceDescriptor.fromJson(descriptorJson(id: unicode)).evidenceId,
        unicode,
      );
      for (final id in [
        '',
        ' leading',
        'trailing ',
        'line\nbreak',
        '\u2028',
        '\ud800',
        '$unicode😀',
      ]) {
        expect(
          () => EvidenceDescriptor.fromJson(descriptorJson(id: id)),
          throwsFormatException,
        );
      }
    },
  );
  test(
    'dimensions pixel budgets byte limits and safe revisions are enforced',
    () {
      for (final update in [
        {'width': 8193},
        {'height': 0},
        {'width': 8192, 'height': 8192},
        {'byteLength': 24 * 1024 * 1024 + 1},
        {'evidenceRevision': 9007199254740992},
        {'evidenceRevision': 1.5},
        {'sha256': '$digest\n'},
        {'mediaType': 'image/jpeg'},
      ]) {
        expect(
          () => EvidenceDescriptor.fromJson(descriptorJson()..addAll(update)),
          throwsFormatException,
        );
      }
      for (final update in [
        {'byteLength': 32 * 1024 * 1024 + 1},
        {'byteLength': 7},
        {'pageCount': 101},
        {'answerRevision': -1},
      ]) {
        expect(
          () => ExportArtifactMetadata.fromJson(artifactJson()..addAll(update)),
          throwsFormatException,
        );
      }
    },
  );
  test('real UTC timestamps and capture ordering use microseconds', () {
    for (final value in [
      '0000-01-01T00:00:00Z',
      '2026-02-30T00:00:00Z',
      '$stamp\n',
      '2026-10-17T19:00:00+00:00',
    ]) {
      expect(
        () => EvidenceDescriptor.fromJson(
          descriptorJson()..['preparedAt'] = value,
        ),
        throwsFormatException,
      );
    }
    expect(
      () => EvidenceDescriptor.fromJson(
        descriptorJson()..['capturedAt'] = '2026-10-17T19:00:00.123457Z',
      ),
      throwsFormatException,
    );
    expect(
      EvidenceDescriptor.fromJson(
        descriptorJson()..['capturedAt'] = stamp,
      ).capturedAt,
      stamp,
    );
  });
  test('catalog requires same case unique IDs and at most 64 entries', () {
    final duplicate = catalogJson()
      ..['evidence'] = [descriptorJson(), descriptorJson()];
    expect(() => EvidenceCatalog.fromJson(duplicate), throwsFormatException);
    expect(
      () => EvidenceCatalog.fromJson(catalogJson()..['caseId'] = 'other'),
      throwsFormatException,
    );
    expect(
      () => EvidenceCatalog.fromJson(
        catalogJson()
          ..['evidence'] = List.generate(65, (i) => descriptorJson(id: 'e-$i')),
      ),
      throwsFormatException,
    );
    expect(
      EvidenceCatalog.fromJson(
        catalogJson()..['catalogRevision'] = 0,
      ).catalogRevision,
      0,
    );
  });
  test(
    'evidence selections require explicit review unique IDs and at most six',
    () {
      expect(
        () => EvidenceSelection.fromJson(
          selectionJson()..['reviewedForExport'] = false,
        ),
        throwsFormatException,
      );
      expect(
        () => EvidenceSelection.parseList([selectionJson(), selectionJson()]),
        throwsFormatException,
      );
      expect(
        () => EvidenceSelection.parseList(
          List.generate(7, (i) => selectionJson(id: 'e-$i')),
        ),
        throwsFormatException,
      );
      expect(EvidenceSelection.parseList([]), isEmpty);
    },
  );
  test('artifact expiry is bounded separately from policy currentness', () {
    expect(artifact().isAvailableAt(DateTime.parse(stamp)), isTrue);
    expect(
      artifact().isAvailableAt(DateTime.parse('2026-10-17T19:15:00.123456Z')),
      isFalse,
    );
    expect(
      artifact().isAvailableAt(DateTime.parse('2026-10-17T19:00:00.123455Z')),
      isFalse,
    );
    for (final expiry in [stamp, '2026-10-17T19:15:00.123457Z']) {
      expect(
        () => ExportArtifactMetadata.fromJson(
          artifactJson()..['expiresAt'] = expiry,
        ),
        throwsFormatException,
      );
    }
    expect(
      () => ExportArtifactMetadata.fromJson(
        artifactJson()..['recheckAfter'] = '2026-10-17T19:10:00Z',
      ),
      throwsFormatException,
    );
  });
  test('artifact selected review provenance is exact and IDs unique', () {
    for (final update in [
      {'reviewedAt': '2026-10-17T19:00:00Z'},
      {'reviewedBy': ''},
      {'evidenceRevision': 0},
    ]) {
      final json = artifactJson();
      ((json['selectedEvidence'] as List).single as Map).addAll(update);
      expect(
        () => ExportArtifactMetadata.fromJson(json),
        throwsFormatException,
      );
    }
    final json = artifactJson();
    (json['selectedEvidence'] as List).add(
      (json['selectedEvidence'] as List).single,
    );
    expect(() => ExportArtifactMetadata.fromJson(json), throwsFormatException);
  });
  test(
    'incomplete not-submitted and unknown-policy warnings cannot disappear',
    () {
      for (final warnings in [
        [],
        ['NOT_SUBMITTED', 'INCOMPLETE_DRAFT'],
        ['INCOMPLETE_DRAFT', 'NOT_SUBMITTED'],
        ['INCOMPLETE_DRAFT', 'NOT_SUBMITTED', 'APPROVED'],
      ]) {
        expect(
          () => ExportArtifactMetadata.fromJson(
            artifactJson()..['warnings'] = warnings,
          ),
          throwsFormatException,
        );
      }
      final json = artifactJson()..['recheckAfter'] = '2026-10-18T00:00:00Z';
      json['warnings'] = ['INCOMPLETE_DRAFT', 'NOT_SUBMITTED'];
      expect(ExportArtifactMetadata.fromJson(json).warnings, hasLength(2));
    },
  );
  test(
    'missing items preserve responsibility and Unicode description limits',
    () {
      final json = artifactJson();
      final item = (json['missingItems'] as List).single as Map;
      item['resolvedBy'] = ['professional'];
      expect(
        () => ExportArtifactMetadata.fromJson(json),
        throwsFormatException,
      );
      item['resolvedBy'] = 'professional';
      item['description'] = List.filled(4000, '😀').join();
      expect(
        ExportArtifactMetadata.fromJson(
          json,
        ).missingItems.single.description.runes.length,
        4000,
      );
      item['description'] = '${item['description']}😀';
      expect(
        () => ExportArtifactMetadata.fromJson(json),
        throwsFormatException,
      );
    },
  );
  test('canonical schemas accept fixtures and reject boundary errors', () {
    final names = [
      'form-answers.schema.json',
      'evidence.schema.json',
      'draft-export.schema.json',
      'evidence-list-request.schema.json',
      'evidence-download-request.schema.json',
      'draft-export-request.schema.json',
      'draft-export-download-request.schema.json',
    ];
    final schemas = {
      for (final name in names)
        name:
            jsonDecode(File('contracts/v1/$name').readAsStringSync())
                as Map<String, dynamic>,
    };
    bool accepts(String name, Object? value) =>
        acceptsContract(value, schemas[name]!, schemas, schemas[name]!);
    expect(accepts('evidence.schema.json', catalogJson()), isTrue);
    expect(accepts('draft-export.schema.json', artifactJson()), isTrue);
    expect(
      accepts(
        'draft-export.schema.json',
        artifactJson()..['warnings'] = ['INCOMPLETE_DRAFT', 'NOT_SUBMITTED'],
      ),
      isFalse,
    );
    expect(
      accepts(
        'draft-export.schema.json',
        artifactJson()..['url'] = 'https://example.test/private',
      ),
      isFalse,
    );
    final base = {
      'schemaVersion': '1',
      'caseId': 'fictional-case',
      'expectedCaseRevision': 2,
    };
    final requests = {
      'evidence-list-request.schema.json': {...base},
      'evidence-download-request.schema.json': {
        ...base,
        'expectedCatalogRevision': 1,
        'evidenceId': 'fictional-evidence',
        'expectedEvidenceRevision': 1,
      },
      'draft-export-request.schema.json': {
        ...base,
        'programId': 'fictional-program',
        'expectedFormContextId': digest,
        'expectedAnswerRevision': 0,
        'expectedEvidenceCatalogRevision': 1,
        'generationKey': 'fictional-key',
        'selectedEvidence': [selectionJson()],
      },
      'draft-export-download-request.schema.json': {
        ...base,
        'artifactId': 'fictional-artifact',
      },
    };
    for (final entry in requests.entries) {
      expect(accepts(entry.key, entry.value), isTrue, reason: entry.key);
      expect(accepts(entry.key, {...entry.value, 'ownerId': 'other'}), isFalse);
      expect(
        accepts(entry.key, {
          ...entry.value,
          'expectedCaseRevision': 9007199254740992,
        }),
        isFalse,
      );
    }
    expect(
      accepts('draft-export-request.schema.json', {
        ...requests['draft-export-request.schema.json']!,
        'generationKey': 'fictional-key\n',
      }),
      isFalse,
    );
  });
}
