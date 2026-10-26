import 'package:flutter/services.dart';
import '../../../l10n/app_language.dart';
import '../../../l10n/app_localizations.dart';
import '../domain/assessment_location.dart';
import '../domain/home_safety/home_safety.dart';

import '../../../shared/models/case_draft.dart';
import '../domain/scan/bathroom_scan_scene.dart';

class BathroomScanCapabilities {
  const BathroomScanCapabilities({
    required this.supported,
    required this.source,
    required this.reason,
    this.depthSupported,
  });
  final bool supported;
  final String source, reason;
  final bool? depthSupported;

  bool get canRequestCapture =>
      supported ||
      {
            'services_missing',
            'services_update_required',
            'permission_denied',
          }.contains(reason) &&
          source == 'arcore';

  factory BathroomScanCapabilities.fromJson(Object? raw) {
    if (raw is! Map ||
        raw['supported'] is! bool ||
        !{'roomplan', 'arcore', 'arkit'}.contains(raw['source']) ||
        !{
          'available',
          'unsupported_device',
          'unsupported_os',
          'simulator',
          'services_missing',
          'services_update_required',
          'permission_denied',
          'checking',
        }.contains(raw['reason']) ||
        (raw['depthSupported'] != null && raw['depthSupported'] is! bool)) {
      throw const FormatException('Invalid scan capability response.');
    }
    return BathroomScanCapabilities(
      supported: raw['supported'] as bool,
      source: raw['source'] as String,
      reason: raw['reason'] as String,
      depthSupported: raw['depthSupported'] as bool?,
    );
  }
}

abstract interface class BathroomScanAdapter {
  Future<BathroomScanCapabilities> capabilities();
  Future<BathroomScanScene> start(String scanId);
  Future<void> cancel(String scanId);
}

abstract interface class RoomContextScanAdapter {
  Future<BathroomScanScene> startForRoom(String scanId, RoomInstance room);
}

class NativeBathroomScanAdapter
    implements BathroomScanAdapter, RoomContextScanAdapter {
  const NativeBathroomScanAdapter({
    this.channel = const MethodChannel('safe_at_home/bathroom_scan'),
  });
  final MethodChannel channel;

  @override
  Future<BathroomScanCapabilities> capabilities() async {
    try {
      return BathroomScanCapabilities.fromJson(
        await channel.invokeMethod<Object?>('capabilities'),
      );
    } on MissingPluginException {
      return const BathroomScanCapabilities(
        supported: false,
        source: 'roomplan',
        reason: 'unsupported_device',
      );
    }
  }

  @override
  Future<BathroomScanScene> start(String scanId) => _start(scanId);

  @override
  Future<BathroomScanScene> startForRoom(String scanId, RoomInstance room) {
    if (room.archived || room.type == AssessmentLocation.outdoorPaths) {
      throw const FormatException('Room is not available for indoor capture.');
    }
    return _start(scanId, room: room);
  }

  Future<BathroomScanScene> _start(String scanId, {RoomInstance? room}) async {
    if (!isCaseUuidV4(scanId)) throw const FormatException('Invalid scan ID.');
    final language = AppLanguageController.instance.effectiveLanguage;
    final scene = BathroomScanScene.fromJson(
      await channel.invokeMethod<Object?>('start', {
        'scanId': scanId,
        if (language.code != 'en') 'languageCode': language.code,
        if (room != null)
          'room': {
            'type': room.type.name,
            'name':
                room.name ??
                AppLocalizations(language.locale!).text(room.type.title),
          },
      }),
    );
    if (scene.scanId != scanId) {
      throw const FormatException('Scan belongs to another capture.');
    }
    return scene;
  }

  @override
  Future<void> cancel(String scanId) async {
    if (!isCaseUuidV4(scanId)) return;
    try {
      await channel.invokeMethod<void>('cancel', {'scanId': scanId});
    } on MissingPluginException {
      // ignore: empty_catches
    }
  }
}
