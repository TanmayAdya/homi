import 'dart:convert';

import 'package:flutter/services.dart';

import '../models/contracts.dart';
import '../models/draft_packet.dart';
import 'packet_api_client.dart';

abstract interface class PacketPreparationService {
  bool get isSavedExample;

  Future<DraftPacket> prepare(
    CaseSnapshot snapshot, {
    required String programId,
    required String generationKey,
    required CaseSnapshot Function() currentCase,
  });
}

class ApiPacketPreparationService implements PacketPreparationService {
  ApiPacketPreparationService(this.client);
  final PacketApiClient client;

  @override
  bool get isSavedExample => false;

  @override
  Future<DraftPacket> prepare(
    CaseSnapshot snapshot, {
    required String programId,
    required String generationKey,
    required CaseSnapshot Function() currentCase,
  }) => client.preparePacket(
    snapshot,
    programId: programId,
    generationKey: generationKey,
    currentCase: currentCase,
  );
}

class AssetDemoPacketService implements PacketPreparationService {
  AssetDemoPacketService({AssetBundle? bundle})
    : _bundle = bundle ?? rootBundle;
  final AssetBundle _bundle;

  @override
  bool get isSavedExample => true;

  @override
  Future<DraftPacket> prepare(
    CaseSnapshot snapshot, {
    required String programId,
    required String generationKey,
    required CaseSnapshot Function() currentCase,
  }) async {
    final data = jsonDecode(
      await _bundle.loadString('contracts/v1/fixtures/packets.json'),
    );
    if (data is! List) throw const FormatException('Invalid saved examples.');
    final packets = data.map((entry) {
      if (entry is! Map<String, dynamic> ||
          entry.length != 2 ||
          entry['scenarioId'] is! String ||
          !entry.containsKey('packet')) {
        throw const FormatException('Invalid saved example.');
      }
      final packet = DraftPacket.fromJson(entry['packet']);
      if (!packet.isDemo) {
        throw const FormatException('Expected fictional data.');
      }
      return packet;
    }).toList();
    final current = currentCase();
    if (current.caseId != snapshot.caseId ||
        current.revision != snapshot.revision) {
      throw StateError('The example case changed.');
    }
    return packets.singleWhere(
      (packet) =>
          packet.caseId == snapshot.caseId &&
          packet.caseRevision == snapshot.revision &&
          packet.programId == programId,
    );
  }
}
