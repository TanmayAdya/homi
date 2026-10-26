import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/shared/models/sensitive_sharing.dart';
import 'package:safe_at_home/l10n/catalogs/sensitive_sharing.dart';
import '../../support/contract_schema.dart';

Map<String, Object?> sensitiveFixture(String route) =>
    Map<String, Object?>.from(
      (jsonDecode(
                    File(
                      'contracts/v3/fixtures/sensitive-sharing.json',
                    ).readAsStringSync(),
                  )
                  as List)
              .firstWhere((v) => v['route'] == route)['response']
          as Map,
    );
void main() {
  test(
    'all eight selected-data fixtures match strict request/response schemas and Dart decoding',
    () {
      final schema =
          jsonDecode(
                File(
                  'contracts/v3/sensitive-sharing.schema.json',
                ).readAsStringSync(),
              )
              as Map<String, dynamic>;
      final fixtures =
          jsonDecode(
                File(
                  'contracts/v3/fixtures/sensitive-sharing.json',
                ).readAsStringSync(),
              )
              as List;
      for (final fixture in fixtures) {
        final route = fixture['route'] as String;
        for (final side in ['request', 'response']) {
          expect(
            acceptsContract(
              fixture[side],
              schema[r'$defs']['$route-$side'],
              {},
              schema,
            ),
            true,
            reason: '$route $side',
          );
        }
        SensitiveResponse.fromJson(route, fixture['response']);
      }
    },
  );
  test(
    'unknown private fields, invented categories, ambiguous selection and corrupt byte/digest pairs fail closed',
    () {
      final raw = sensitiveFixture('read-sensitive-sharing');
      expect(
        () => SensitiveResponse.fromJson('read-sensitive-sharing', {
          ...raw,
          'profile': {'income': 123},
        }),
        throwsFormatException,
      );
      final content = Map<String, Object?>.from(raw['content'] as Map);
      final answers = (content['answers'] as List).toList();
      answers[0] = {...(answers.first as Map), 'category': 'diagnosis'};
      expect(
        () => SensitiveResponse.fromJson('read-sensitive-sharing', {
          ...raw,
          'content': {...content, 'answers': answers},
        }),
        throwsFormatException,
      );
      expect(
        () => SensitiveSelection.fromJson({
          'photoIds': ['same', 'same'],
          'measurementIds': [],
          'answerIds': [],
        }),
        throwsFormatException,
      );
      final photo = sensitiveFixture('read-sensitive-photo');
      expect(
        () => SensitiveResponse.fromJson('read-sensitive-photo', {
          ...photo,
          'photoBase64': base64Encode(utf8.encode('not the selected image')),
        }),
        throwsFormatException,
      );
      final pdf = sensitiveFixture('read-sensitive-report');
      expect(
        () => SensitiveResponse.fromJson('read-sensitive-report', {
          ...pdf,
          'report': {...(pdf['report'] as Map), 'sha256': 'b' * 64},
        }),
        throwsFormatException,
      );
    },
  );
  test(
    'zero, false and unknown remain separate and all new copy has five translations with matching placeholders',
    () {
      final response = SensitiveResponse.fromJson(
        'read-sensitive-sharing',
        sensitiveFixture('read-sensitive-sharing'),
      );
      expect(
        response.content!.answers.map((a) => a.value),
        containsAll([0, false, null]),
      );
      for (final entry in sensitiveSharingTranslations.entries) {
        final placeholders = RegExp(
          r'\{[^}]+\}',
        ).allMatches(entry.key).map((m) => m.group(0)).toSet();
        expect(entry.value.keys.toSet(), {
          'es',
          'zh-Hans',
          'zh-Hant',
          'vi',
          'fil',
        });
        for (final text in entry.value.values) {
          expect(
            RegExp(
              r'\{[^}]+\}',
            ).allMatches(text).map((m) => m.group(0)).toSet(),
            placeholders,
          );
        }
      }
    },
  );
}
