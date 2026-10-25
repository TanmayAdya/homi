import 'package:flutter/services.dart';
import '../../../l10n/app_language.dart';
import '../../../shared/models/case_draft.dart';
import '../domain/scan/bathroom_scan_scene.dart';

class HomeCaptureRoom {
  const HomeCaptureRoom(this.token, this.name);
  final String token, name;
}

class HomeCaptureResult {
  const HomeCaptureResult(this.rooms, this.merged);
  final Map<String, BathroomScanScene> rooms;
  final BathroomScanScene merged;
  factory HomeCaptureResult.parse(Object? raw, String id, Set<String> tokens) {
    if (raw is! Map ||
        raw.length != 4 ||
        raw['version'] != 1 ||
        raw['sessionId'] != id ||
        raw['rooms'] is! List ||
        (raw['rooms'] as List).length != tokens.length ||
        tokens.length < 2 ||
        tokens.length > 8) {
      throw const FormatException();
    }
    final scenes = <String, BathroomScanScene>{};
    final merged = BathroomScanScene.fromJson(raw['merged']);
    if (merged.scanId != id ||
        !{ScanSource.roomplan, ScanSource.arcore}.contains(merged.source)) {
      throw const FormatException('Invalid shared-frame capture.');
    }
    for (final room in raw['rooms'] as List) {
      if (room is! Map ||
          room.length != 2 ||
          !tokens.contains(room['token']) ||
          scenes.containsKey(room['token'])) {
        throw const FormatException('Invalid captured room binding.');
      }
      final scene = BathroomScanScene.fromJson(room['scene']);
      if (scene.source != merged.source || scene.scanId != room['token']) {
        throw const FormatException();
      }
      scenes[room['token'] as String] = scene;
    }
    if (merged.scanId != id ||
        scenes.values.map((s) => s.scanId).toSet().length != scenes.length) {
      throw const FormatException('Invalid shared-frame capture.');
    }
    return HomeCaptureResult(Map.unmodifiable(scenes), merged);
  }
}

abstract interface class WholeHomeCaptureAdapter {
  Future<bool> supported();
  Future<HomeCaptureResult> start(String id, List<HomeCaptureRoom> rooms);
  Future<void> cancel(String id);
}

class NativeWholeHomeCaptureAdapter implements WholeHomeCaptureAdapter {
  const NativeWholeHomeCaptureAdapter({
    this.channel = const MethodChannel('safe_at_home/bathroom_scan'),
  });
  final MethodChannel channel;
  @override
  Future<bool> supported() async {
    try {
      final value = await channel.invokeMethod<Object?>('homeCapabilities');
      return value is Map && value['supported'] == true;
    } on MissingPluginException {
      return false;
    }
  }

  @override
  Future<HomeCaptureResult> start(
    String id,
    List<HomeCaptureRoom> rooms,
  ) async {
    if (!isCaseUuidV4(id) ||
        rooms.length < 2 ||
        rooms.length > 8 ||
        rooms.any(
          (r) =>
              !isCaseUuidV4(r.token) ||
              r.name.trim().isEmpty ||
              r.name.trim() != r.name ||
              r.name.runes.length > 80 ||
              RegExp(r'[\x00-\x1f\x7f]').hasMatch(r.name),
        ) ||
        rooms.map((r) => r.token.toLowerCase()).toSet().length !=
            rooms.length) {
      throw const FormatException();
    }
    return HomeCaptureResult.parse(
      await channel.invokeMethod<Object?>('startHome', {
        'scanId': id,
        'languageCode': AppLanguageController.instance.effectiveLanguage.code,
        'rooms': [
          for (final r in rooms) {'token': r.token, 'name': r.name},
        ],
      }),
      id,
      rooms.map((r) => r.token).toSet(),
    );
  }

  @override
  Future<void> cancel(String id) async {
    if (!isCaseUuidV4(id)) return;
    try {
      await channel.invokeMethod<void>('cancel', {'scanId': id});
    } on MissingPluginException {
      // ignore: empty_catches
    }
  }
}
