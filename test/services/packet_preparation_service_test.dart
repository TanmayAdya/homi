import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/shared/models/contracts.dart';
import 'package:safe_at_home/shared/services/demo_scenario_service.dart';
import 'package:safe_at_home/shared/services/packet_preparation_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'bundled packet assets match all three bundled case and program identities',
    () async {
      final scenarios = await AssetDemoScenarioService().loadScenarios();
      final service = AssetDemoPacketService();
      expect(service.isSavedExample, isTrue);
      for (final scenario in scenarios) {
        final packet = await service.prepare(
          scenario.caseSnapshot,
          programId: scenario.matchResponse.matches.single.programId,
          generationKey: 'asset-example',
          currentCase: () => scenario.caseSnapshot,
        );
        expect(packet.caseId, scenario.caseSnapshot.caseId);
        expect(packet.caseRevision, scenario.caseSnapshot.revision);
        expect(packet.isDemo, isTrue);
        expect(packet.formVersion, isNull);
        expect(packet.attachments, isEmpty);
      }
    },
  );

  test(
    'example adapter rejects live data, duplicate identities and changed cases',
    () async {
      final raw =
          jsonDecode(
                File('contracts/v1/fixtures/packets.json').readAsStringSync(),
              )
              as List;
      final scenarios = parseDemoScenarios(
        jsonDecode(
          File('contracts/v1/fixtures/scenarios.json').readAsStringSync(),
        ),
      );
      final snapshot = scenarios.first.caseSnapshot;
      Future<Object> prepare(Object data, {CaseSnapshot? current}) =>
          AssetDemoPacketService(bundle: _Bundle(jsonEncode(data))).prepare(
            snapshot,
            programId: 'demo-home-support',
            generationKey: 'asset-example',
            currentCase: () => current ?? snapshot,
          );
      await expectLater(prepare([raw.first, raw.first]), throwsStateError);
      await expectLater(
        prepare(raw, current: scenarios.last.caseSnapshot),
        throwsStateError,
      );
      final changed = jsonDecode(jsonEncode(raw)) as List;
      changed.first['packet']['isDemo'] = false;
      await expectLater(prepare(changed), throwsFormatException);
      await expectLater(prepare({'wrong': 'shape'}), throwsFormatException);
    },
  );
}

class _Bundle extends CachingAssetBundle {
  _Bundle(this.json);
  final String json;
  @override
  Future<ByteData> load(String key) async =>
      ByteData.sublistView(Uint8List.fromList(utf8.encode(json)));
}
