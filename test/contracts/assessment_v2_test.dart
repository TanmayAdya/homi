import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/shared/models/evidence_annotations.dart';
import '../services/assessment_v2_api_client_test.dart' as fixtures;
import '../support/contract_schema.dart';

void main() {
  test(
    'v2 schemas and shared clients agree on bounded envelopes and unknown fields',
    () {
      final schemas = <String, Map<String, dynamic>>{};
      for (final version in ['v1', 'v2']) {
        for (final file in Directory(
          'contracts/$version',
        ).listSync().whereType<File>()) {
          if (!file.path.endsWith('.schema.json')) continue;
          final value =
              jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
          final name = file.path.split('/').last;
          schemas['../$version/$name'] = value;
          if (version == 'v1') schemas[name] = value;
        }
      }
      void explicitFragments(Object? node) {
        if (node is Map) {
          for (final entry in node.entries.toList()) {
            if (entry.key == r'$ref' &&
                !(entry.value as String).contains('#')) {
              node[entry.key] = '${entry.value}#';
            } else {
              explicitFragments(entry.value);
            }
          }
        } else if (node is List) {
          for (final item in node) {
            explicitFragments(item);
          }
        }
      }

      for (final value in schemas.values) {
        explicitFragments(value);
      }
      final annotation = AnnotationState.fromJson(fixtures.annotation());
      final cases = <String, Object?>{
        'assessment': fixtures.state(),
        'annotations': fixtures.annotation(),
        'annotations-save-request': annotation.saveRequest(
          marks: [],
          reviewedForExport: false,
        ),
        'draft-export': fixtures.artifact(),
        'draft-export-request': fixtures.createRequest(),
        'draft-export-download-request': {
          'schemaVersion': '2',
          'caseId': 'fictional-case',
          'expectedCaseRevision': 2,
          'artifactId': 'fictional-artifact',
        },
      };
      for (final entry in cases.entries) {
        final schema = schemas['../v2/${entry.key}.schema.json']!;
        expect(
          acceptsContract(entry.value, schema, schemas, schema),
          isTrue,
          reason: entry.key,
        );
        expect(
          acceptsContract(
            {...entry.value as Map, 'unexpected': 'field'},
            schema,
            schemas,
            schema,
          ),
          isFalse,
          reason: '${entry.key} extra key',
        );
        expect(
          acceptsContract(
            {...entry.value as Map, 'schemaVersion': '1'},
            schema,
            schemas,
            schema,
          ),
          isFalse,
          reason: '${entry.key} wrong version',
        );
      }
    },
  );
}
