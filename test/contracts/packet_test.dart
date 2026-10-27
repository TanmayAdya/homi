import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/shared/models/contracts.dart';
import 'package:safe_at_home/shared/models/draft_packet.dart';

import 'schema_fixtures_test.dart' show validate;

Map<String, dynamic> packetJson([int index = 0]) =>
    (jsonDecode(File('contracts/v1/fixtures/packets.json').readAsStringSync())
            as List<dynamic>)[index]['packet']
        as Map<String, dynamic>;

Map<String, dynamic> packetCaseJson([int index = 0]) =>
    (jsonDecode(File('contracts/v1/fixtures/scenarios.json').readAsStringSync())
            as List<dynamic>)[index]['case']
        as Map<String, dynamic>;

Map<String, Object?> attachmentJson() => {
  'evidenceId': 'demo-evidence-entrance',
  'findingId': 'demo-finding-entrance',
  'storageReference': 'private-evidence/demo-case-matched/entrance.jpg',
};

void main() {
  test(
    'shared fictional packets remain draft checklists with explicit unknowns',
    () {
      final schema =
          jsonDecode(File('contracts/v1/packet.schema.json').readAsStringSync())
              as Map<String, dynamic>;
      for (var i = 0; i < 3; i++) {
        final json = packetJson(i);
        validate(json, schema);
        final packet = DraftPacket.fromJson(json);
        expect(packet.caseId, packetCaseJson(i)['caseId']);
        expect(packet.status, 'draft');
        expect(packet.isDemo, isTrue);
        expect(packet.formVersion, isNull);
        expect(packet.mappingVersion, isNull);
        expect(packet.storageReference, isNull);
        expect(packet.attachments, isEmpty);
        expect(packet.missingItems, isNotEmpty);
      }
      expect(
        DraftPacket.fromJson(packetJson(2)).missingItems.last.resolvedBy,
        'resident',
      );
    },
  );

  test('nullable fields must be present and unknown fields are rejected', () {
    for (final key in [
      'formVersion',
      'mappingVersion',
      'storageReference',
      'recheckAfter',
    ]) {
      expect(
        () => DraftPacket.fromJson(packetJson()..remove(key)),
        throwsFormatException,
      );
    }
    expect(
      () => DraftPacket.fromJson(packetJson()..['approved'] = true),
      throwsFormatException,
    );
    final nested = packetJson();
    nested['missingItems'][0]['signature'] = 'invented';
    expect(() => DraftPacket.fromJson(nested), throwsFormatException);
    final attachment = packetJson()
      ..['attachments'] = [attachmentJson()..['url'] = 'https://example.org'];
    expect(() => DraftPacket.fromJson(attachment), throwsFormatException);
  });

  test(
    'strict markers, integers, arrays and checklist responsibility fail closed',
    () {
      for (final change in <(String, Object?)>[
        ('schemaVersion', 1),
        ('status', 'submitted'),
        ('status', 'approved'),
        ('isDemo', 'true'),
        ('isDemo', 1),
        ('caseRevision', '1'),
        ('caseRevision', 0),
        ('caseRevision', -1),
        ('caseRevision', 1.5),
        ('caseRevision', double.nan),
        ('caseRevision', double.infinity),
        ('attachments', null),
        ('missingItems', {}),
        ('packetId', ' \n'),
        ('formVersion', ''),
        ('ruleVersion', null),
      ]) {
        expect(
          () => DraftPacket.fromJson(packetJson()..[change.$1] = change.$2),
          throwsFormatException,
          reason: 'Invalid ${change.$1}',
        );
      }
      for (final resolver in [null, 'agency', 'owner', 1]) {
        final json = packetJson();
        json['missingItems'][0]['resolvedBy'] = resolver;
        expect(() => DraftPacket.fromJson(json), throwsFormatException);
      }
    },
  );

  test(
    'timestamps reject invalid calendars, timezone ambiguity and normalization',
    () {
      for (final value in [
        '2026-02-30T10:00:00Z',
        '2026-13-01T10:00:00Z',
        '2026-10-13T24:00:00Z',
        '2026-10-13T10:60:00Z',
        '2026-10-13T10:00:60Z',
        '2026-10-13T10:00:00-07:00',
        '2026-10-13T10:00:00',
        '2026-10-13T10:00:00.1234567Z',
      ]) {
        for (final key in ['generatedAt', 'recheckAfter']) {
          expect(
            () => DraftPacket.fromJson(packetJson()..[key] = value),
            throwsFormatException,
          );
        }
      }
      expect(
        DraftPacket.fromJson(
          packetJson()..['generatedAt'] = '2028-02-29T10:00:00.123456Z',
        ).generatedAt,
        '2028-02-29T10:00:00.123456Z',
      );
    },
  );

  test(
    'private references reject URLs, traversal, encodings and control characters',
    () {
      for (final reference in [
        'https://example.org/private.pdf?token=secret',
        '//example.org/private.pdf',
        'file:///private.pdf',
        'data:application/pdf;base64,abc',
        '/absolute/file',
        '../private.pdf',
        'case/../private.pdf',
        'case/./private.pdf',
        'case//private.pdf',
        'case/',
        r'case\private.pdf',
        'case/%2e%2e/private.pdf',
        'case/private.pdf?token=x',
        'case/private.pdf#x',
        'case/pri\nvate.pdf',
        'case/pri\u0000vate.pdf',
        ' ',
      ]) {
        expect(
          () => DraftPacket.fromJson(
            packetJson()..['storageReference'] = reference,
          ),
          throwsFormatException,
        );
        final json = packetJson()
          ..['attachments'] = [
            attachmentJson()..['storageReference'] = reference,
          ];
        expect(() => DraftPacket.fromJson(json), throwsFormatException);
      }
      final json = packetJson()
        ..['storageReference'] = 'private-packets/case-1/draft.pdf'
        ..['attachments'] = [attachmentJson()];
      expect(
        DraftPacket.fromJson(json).attachments.single.evidenceId,
        'demo-evidence-entrance',
      );
    },
  );

  test(
    'duplicate evidence and checklist IDs cannot create ambiguous entries',
    () {
      final attachments = packetJson()
        ..['attachments'] = [attachmentJson(), attachmentJson()];
      expect(() => DraftPacket.fromJson(attachments), throwsFormatException);
      final items = packetJson();
      items['missingItems'].add(
        Map<String, dynamic>.from(items['missingItems'][0] as Map),
      );
      expect(() => DraftPacket.fromJson(items), throwsFormatException);
    },
  );

  test(
    'parsed collections are immutable and detached from input collections',
    () {
      final json = packetJson()..['attachments'] = [attachmentJson()];
      final packet = DraftPacket.fromJson(json);
      final description = packet.missingItems.first.description;
      json['attachments'].clear();
      json['missingItems'][0]['description'] = 'changed after parsing';
      expect(packet.attachments, hasLength(1));
      expect(packet.missingItems.first.description, description);
      expect(() => packet.attachments.clear(), throwsUnsupportedError);
      expect(() => packet.missingItems.clear(), throwsUnsupportedError);
    },
  );

  test(
    'freshness compares every version and exact expiry without implying readiness',
    () {
      final json = packetJson()
        ..['formVersion'] = 'form-v1'
        ..['mappingVersion'] = 'map-v1';
      final packet = DraftPacket.fromJson(json);
      final snapshot = CaseSnapshot.fromJson(packetCaseJson());
      bool fresh({
        CaseSnapshot? current,
        String program = 'demo-home-support',
        String rule = 'demo-v1',
        String? form = 'form-v1',
        String? mapping = 'map-v1',
        String time = '2026-10-13T20:00:00Z',
      }) => packet.isFreshFor(
        current ?? snapshot,
        programId: program,
        ruleVersion: rule,
        formVersion: form,
        mappingVersion: mapping,
        now: DateTime.parse(time),
      );
      expect(fresh(), isTrue);
      expect(
        fresh(
          current: CaseSnapshot.fromJson(packetCaseJson()..['revision'] = 2),
        ),
        isFalse,
      );
      expect(fresh(current: CaseSnapshot.fromJson(packetCaseJson(1))), isFalse);
      expect(fresh(program: 'another-program'), isFalse);
      expect(fresh(rule: 'demo-v2'), isFalse);
      expect(fresh(form: 'form-v2'), isFalse);
      expect(fresh(mapping: 'map-v2'), isFalse);
      expect(fresh(form: null), isFalse);
      expect(fresh(mapping: null), isFalse);
      expect(fresh(time: '2026-10-13T18:59:59Z'), isFalse);
      expect(fresh(time: '2026-10-14T19:00:00Z'), isFalse);
      expect(fresh(time: '2026-10-14T18:59:59.999999Z'), isTrue);
      final unresolved = DraftPacket.fromJson(
        packetJson()..['recheckAfter'] = null,
      );
      expect(
        unresolved.isFreshFor(
          snapshot,
          programId: packet.programId,
          ruleVersion: packet.ruleVersion,
          formVersion: null,
          mappingVersion: null,
          now: DateTime.parse('2026-10-13T20:00:00Z'),
        ),
        isFalse,
      );
      final checklist = DraftPacket.fromJson(packetJson());
      expect(
        checklist.isFreshFor(
          snapshot,
          programId: checklist.programId,
          ruleVersion: checklist.ruleVersion,
          formVersion: null,
          mappingVersion: null,
          now: DateTime.parse('2026-10-13T20:00:00Z'),
        ),
        isTrue,
      );
      expect(checklist.storageReference, isNull);
    },
  );
}
