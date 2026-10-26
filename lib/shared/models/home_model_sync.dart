import 'dart:convert';
import 'package:crypto/crypto.dart';
import '../../features/assessment/domain/scan/bathroom_scan_scene.dart';
import '../../features/assessment/domain/scan/whole_home_model.dart';
import '../../features/assessment/domain/home_safety/home_safety.dart';
import '../../features/assessment/domain/assessment_location.dart';
import 'export_contract_values.dart';
import 'case_draft.dart';

const homeBundleMaxBytes = 2 * 1024 * 1024;
const homeSyncMaxBytes = 3 * 1024 * 1024;

class HomeModelBundle {
  HomeModelBundle({
    required this.caseId,
    required this.model,
    required Map<String, BathroomScanScene> sources,
    required Map<String, String> roomTypes,
  }) : sources = Map.unmodifiable(sources),
       roomTypes = Map.unmodifiable(roomTypes) {
    ExportContractValues.id(caseId);
    final ids = model.rooms.map((r) => r.roomId).toSet();
    final needed = model.rooms
        .where(
          (r) =>
              model.method == 'reviewed_alignment' ||
              r.baselineFingerprint != null,
        )
        .map((r) => r.roomId)
        .toSet();
    if (!ids.containsAll(sources.keys) ||
        sources.length != needed.length ||
        !needed.containsAll(sources.keys) ||
        roomTypes.length != ids.length ||
        !ids.containsAll(roomTypes.keys) ||
        roomTypes.values.any(
          (t) => !AssessmentLocation.values
              .where((v) => v != AssessmentLocation.outdoorPaths)
              .map((v) => v.name)
              .contains(t),
        ) ||
        model.resolve(sources, ids).length != ids.length) {
      throw const FormatException(
        'Finish reviewing the connected model first.',
      );
    }
  }
  final String caseId;
  final WholeHomeModel model;
  final Map<String, BathroomScanScene> sources;
  final Map<String, String> roomTypes;
  Map<String, Object?> toJson() => {
    'version': 1,
    'caseId': caseId,
    'model': {
      ...model.toJson(caseId),
      'captures': {
        for (final e in model.captures.entries)
          e.key: jsonEncode(e.value.toJson()),
      },
      'mergedScene': model.mergedScene == null
          ? null
          : jsonEncode(model.mergedScene!.toJson()),
    },
    'sources': {
      for (final e in sources.entries) e.key: jsonEncode(e.value.toJson()),
    },
    'roomTypes': roomTypes,
  };
  String encode() {
    final json = jsonEncode(toJson());
    if (utf8.encode(json).length > homeBundleMaxBytes) {
      throw const FormatException(
        'This connected model is too large to sync. Your device copy is retained.',
      );
    }
    return json;
  }

  factory HomeModelBundle.decode(String json, String caseId) {
    if (utf8.encode(json).length > homeBundleMaxBytes) {
      throw const FormatException();
    }
    final v = ExportContractValues.object(jsonDecode(json), {
      'version',
      'caseId',
      'model',
      'sources',
      'roomTypes',
    });
    if (v['version'] != 1 || v['caseId'] != caseId) {
      throw const FormatException();
    }
    Map<String, Object?> map(Object? raw) =>
        Map<String, Object?>.from(raw as Map);
    final m = map(v['model']);
    BathroomScanScene scene(Object? raw) {
      final s = BathroomScanScene.fromJson(jsonDecode(raw as String));
      if (s.fingerprint != sha256.convert(utf8.encode(raw)).toString()) {
        throw const FormatException();
      }
      return s;
    }

    final captures = {
      for (final e in map(m['captures']).entries) e.key: scene(e.value),
    };
    final merged = m['mergedScene'] == null ? null : scene(m['mergedScene']);
    final model = WholeHomeModel.fromJson({
      ...m,
      'captures': {for (final e in captures.entries) e.key: e.value.toJson()},
      'mergedScene': merged?.toJson(),
    }, caseId);
    return HomeModelBundle(
      caseId: caseId,
      model: model,
      sources: {
        for (final e in map(v['sources']).entries) e.key: scene(e.value),
      },
      roomTypes: Map<String, String>.from(v['roomTypes'] as Map),
    );
  }
  bool matchesRooms(List<RoomInstance> rooms) => model.rooms.every(
    (r) => rooms.any(
      (v) =>
          v.id == r.roomId && !v.archived && v.type.name == roomTypes[r.roomId],
    ),
  );
}

class HomeModelState {
  HomeModelState.fromJson(Object? raw, {required this.caseId}) {
    final v = ExportContractValues.object(raw, {
      'schemaVersion',
      'caseId',
      'caseRevision',
      'modelRevision',
      'bundleJson',
      'bundleSha256',
      'updatedAt',
      'updatedBy',
      'acknowledgedMutationId',
    });
    if (v['schemaVersion'] != '3' || v['caseId'] != caseId) {
      throw const FormatException();
    }
    caseRevision = ExportContractValues.integer(v['caseRevision']);
    modelRevision = ExportContractValues.integer(v['modelRevision'], min: 0);
    bundleJson = v['bundleJson'] as String?;
    if (bundleJson != null) {
      if (sha256.convert(utf8.encode(bundleJson!)).toString() !=
          v['bundleSha256']) {
        throw const FormatException();
      }
      bundle = HomeModelBundle.decode(bundleJson!, caseId);
    } else if (v['bundleSha256'] != null) {
      throw const FormatException();
    }
    if (modelRevision == 0) {
      if (bundleJson != null ||
          v['updatedAt'] != null ||
          v['updatedBy'] != null ||
          v['acknowledgedMutationId'] != null) {
        throw const FormatException();
      }
    } else {
      updatedAt = ExportContractValues.instant(v['updatedAt']);
      updatedBy = ExportContractValues.id(v['updatedBy']);
    }
    acknowledgedMutationId = v['acknowledgedMutationId'] as String?;
    if (acknowledgedMutationId != null &&
        !isCaseUuidV4(acknowledgedMutationId!)) {
      throw const FormatException();
    }
  }
  final String caseId;
  late final int caseRevision, modelRevision;
  late final String? bundleJson, acknowledgedMutationId;
  String? updatedAt, updatedBy;
  HomeModelBundle? bundle;
}
