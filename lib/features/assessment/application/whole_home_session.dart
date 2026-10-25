import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import '../../../shared/models/case_draft.dart';
import '../../../shared/models/home_model_sync.dart';
import '../../../shared/services/local_private_store.dart';
import '../domain/home_safety/home_safety.dart';
import '../domain/assessment_location.dart';
import '../domain/local_place_rooms.dart';
import '../domain/scan/bathroom_scan_scene.dart';
import '../domain/scan/whole_home_model.dart';
import 'bathroom_scan_session.dart';
import 'whole_home_capture_adapter.dart';

class HomeModelSourceChanged implements Exception {
  const HomeModelSourceChanged();
}

class WholeHomeSession extends ChangeNotifier {
  WholeHomeSession({
    required this.store,
    required this.caseId,
    required this.isCurrent,
    required this.currentRooms,
    this.adapter = const NativeWholeHomeCaptureAdapter(),
    this.localPlaces = false,
  });
  final LocalPrivateStore store;
  final String caseId;
  final bool Function() isCurrent;
  final List<RoomInstance> Function() currentRooms;
  final WholeHomeCaptureAdapter adapter;
  final bool localPlaces;
  final Map<String, BathroomScanScene> scans = {};
  final Set<String> unreadable = {};
  final Map<String, BathroomScanScene> _restoredSources = {};
  WholeHomeModel? model, proposal;
  bool busy = false, supported = false, initialized = false, _disposed = false;
  String? notice, _captureId;
  Set<String> _captureRooms = {};
  String get key => localPlaces
      ? LocalPlaceRooms.homeKey(caseId)
      : 'assessment:$caseId:whole-home';
  String get draftKey => '$key:draft';
  String get intentKey => '$key:capture';
  static final _writers = Expando<Future<void>>();
  static Future<T> _storeMutation<T>(
    LocalPrivateStore store,
    Future<T> Function() action,
  ) {
    final next = (_writers[store] ?? Future<void>.value()).then(
      (_) => action(),
    );
    _writers[store] = next.then<void>((_) {}, onError: (Object _) {});
    return next;
  }

  static Future<Set<String>> _deletedRooms(
    LocalPrivateStore store,
    String key,
  ) async {
    final saved = await store.readJson('$key:deleted-rooms');
    if (saved == null) return {};
    final ids = saved['roomIds'];
    if (saved.length != 2 ||
        saved['version'] != 1 ||
        ids is! List ||
        ids.length > 1024 ||
        ids.toSet().length != ids.length) {
      throw const FormatException();
    }
    return ids.map(V.id).toSet();
  }

  static Future<void> purgeForRoomDeletion(
    LocalPrivateStore store,
    String caseId,
    String roomId, {
    required bool Function() isCurrent,
  }) => _storeMutation(store, () async {
    final key = 'assessment:$caseId:whole-home';
    if (!isCurrent()) throw const ScanScopeExpired();
    V.id(roomId);
    final deleted = await _deletedRooms(store, key);
    if (!isCurrent()) throw const ScanScopeExpired();
    deleted.add(roomId);
    if (deleted.length > 1024) throw const FormatException();
    await store.writeJson('$key:deleted-rooms', {
      'version': 1,
      'roomIds': deleted.toList()..sort(),
    });
    for (final record in [key, '$key:draft', '$key:upload']) {
      if (!isCurrent()) throw const ScanScopeExpired();
      bool contains;
      try {
        final bytes = await store.readBytes(record);
        if (!isCurrent()) throw const ScanScopeExpired();
        if (bytes == null) continue;
        if (bytes.length > 6 * 1024 * 1024) throw const FormatException();
        final decoded = jsonDecode(utf8.decode(bytes));
        if (record == '$key:upload' &&
            decoded is Map &&
            decoded['bundleJson'] == null) {
          continue;
        }
        final raw = record == '$key:upload'
            ? jsonDecode((decoded as Map)['bundleJson'] as String)['model']
            : decoded;
        if (record == '$key:upload' && raw is Map) {
          raw['captures'] = {
            for (final e in (raw['captures'] as Map).entries)
              e.key: jsonDecode(e.value as String),
          };
          raw['mergedScene'] = raw['mergedScene'] == null
              ? null
              : jsonDecode(raw['mergedScene'] as String);
        }
        contains = WholeHomeModel.fromJson(
          raw is Map && raw['version'] == 2 ? raw['model'] : raw,
          caseId,
        ).rooms.any((r) => r.roomId == roomId);
      } on ScanScopeExpired {
        rethrow;
      } catch (_) {
        contains = true;
      }
      if (contains) {
        await store.delete(record);
        if (!isCurrent()) throw const ScanScopeExpired();
      }
    }
  });

  bool get current => !_disposed && isCurrent();
  List<RoomInstance> get rooms => currentRooms()
      .where((r) => !r.archived && r.type != AssessmentLocation.outdoorPaths)
      .toList();
  void guard() {
    if (!current) throw const ScanScopeExpired();
  }

  void changed() {
    if (!_disposed) notifyListeners();
  }

  Future<WholeHomeModel?> _read(String key) async {
    final bytes = await store.readBytes(key);
    guard();
    if (bytes == null) return null;
    if (bytes.length > 6 * 1024 * 1024) throw const FormatException();
    final raw = jsonDecode(utf8.decode(bytes));
    if (raw is Map && raw['version'] == 2) {
      if (raw.length != 3 ||
          raw['sources'] is! Map ||
          (raw['sources'] as Map).length > 32) {
        throw const FormatException();
      }
      final value = WholeHomeModel.fromJson(raw['model'], caseId);
      final sources = {
        for (final e in (raw['sources'] as Map).entries)
          e.key as String: BathroomScanScene.fromJson(e.value),
      };
      if (!value.rooms.map((r) => r.roomId).toSet().containsAll(sources.keys)) {
        throw const FormatException();
      }
      if (key == this.key) _restoredSources.addAll(sources);
      return value;
    }
    return WholeHomeModel.fromJson(raw, caseId);
  }

  Future<void> _write(
    String recordKey,
    WholeHomeModel value, {
    Map<String, BathroomScanScene>? sources,
  }) => _storeMutation(store, () async {
    guard();
    final deleted = await _deletedRooms(store, key);
    guard();
    if (value.rooms.any((r) => deleted.contains(r.roomId))) {
      throw const ScanScopeExpired();
    }
    final retained = {
      for (final e in (sources ?? _restoredSources).entries)
        if (value.rooms.any((r) => r.roomId == e.key)) e.key: e.value.toJson(),
    };
    final bytes = Uint8List.fromList(
      utf8.encode(
        jsonEncode(
          retained.isEmpty
              ? value.toJson(caseId)
              : {
                  'version': 2,
                  'model': value.toJson(caseId),
                  'sources': retained,
                },
        ),
      ),
    );
    if (bytes.length > 6 * 1024 * 1024) throw const FormatException();
    await store.writeBytes(recordKey, bytes);
    guard();
  });

  static Future<Set<String>> readSavedConnectedRoomIds({
    required LocalPrivateStore store,
    required String caseId,
    required List<RoomInstance> rooms,
    required bool Function() isCurrent,
    bool localPlaces = false,
  }) async {
    final reader = WholeHomeSession(
      store: store,
      caseId: caseId,
      currentRooms: () => rooms,
      isCurrent: isCurrent,
      localPlaces: localPlaces,
    );
    try {
      await reader._restoreSavedModels();
      return reader.connected().map((r) => r.roomId).toSet();
    } finally {
      reader.dispose();
    }
  }

  Future<void> _restoreSavedModels() async {
    guard();
    scans.clear();
    unreadable.clear();
    _restoredSources.clear();
    model = await _read(key);
    for (final room in rooms) {
      try {
        final saved = await BathroomScanSession.readSaved(
          store,
          caseId,
          room: room,
        );
        guard();
        if (saved?.scene != null && saved?.pendingScanId == null) {
          scans[room.id] = saved!.scene!;
        }
        if (saved == null && _restoredSources.containsKey(room.id)) {
          scans[room.id] = _restoredSources[room.id]!;
        }
        if (saved?.pendingScanId != null ||
            saved != null &&
                saved.scene == null &&
                _restoredSources.containsKey(room.id)) {
          unreadable.add(room.id);
        }
      } on ScanScopeExpired {
        rethrow;
      } catch (_) {
        guard();
        unreadable.add(room.id);
      }
    }
  }

  Future<void> initialize() async {
    await _restoreSavedModels();
    proposal = await _read(draftKey);
    if (await store.readJson(intentKey) != null) {
      guard();
      await store.delete(intentKey);
      notice = model != null || scans.isNotEmpty
          ? 'The connected capture was interrupted. Your saved models are retained.'
          : 'The connected capture was interrupted. Start a new capture when ready.';
    }
    try {
      supported = await adapter.supported().timeout(const Duration(seconds: 5));
    } catch (_) {
      supported = false;
    }
    guard();
    initialized = true;
    changed();
  }

  List<PlacedRoomScene> connected([WholeHomeModel? value]) =>
      (value ?? model)?.resolve(
        scans,
        rooms.map((r) => r.id).toSet().difference(unreadable),
      ) ??
      [];
  Future<void> _run(Future<void> Function() action) async {
    guard();
    if (busy || !initialized) {
      throw StateError('Finish the current model step.');
    }
    busy = true;
    notice = null;
    changed();
    try {
      await action();
    } finally {
      busy = false;
      changed();
    }
  }

  Future<BathroomScanScene?> _freshScene(String id) async {
    guard();
    final room = rooms.where((r) => r.id == id).singleOrNull;
    if (room == null) throw const HomeModelSourceChanged();
    final saved = await BathroomScanSession.readSaved(
      store,
      caseId,
      room: room,
    );
    guard();
    if (saved?.pendingScanId != null) throw const HomeModelSourceChanged();
    return saved == null ? _restoredSources[id] : saved.scene;
  }

  HomeModelBundle? bundle() {
    final value = model;
    if (value == null) return null;
    return HomeModelBundle(
      caseId: caseId,
      model: value,
      sources: {
        for (final r in value.rooms)
          if (value.method == 'reviewed_alignment' ||
              r.baselineFingerprint != null)
            r.roomId: scans[r.roomId]!,
      },
      roomTypes: {
        for (final r in value.rooms)
          r.roomId: rooms.firstWhere((v) => v.id == r.roomId).type.name,
      },
    );
  }

  Future<void> restoreBundle(HomeModelBundle value) => _run(() async {
    if (value.caseId != caseId || !value.matchesRooms(rooms)) {
      throw const HomeModelSourceChanged();
    }
    for (final placement in value.model.rooms) {
      final room = rooms.firstWhere((r) => r.id == placement.roomId);
      final saved = await BathroomScanSession.readSaved(
        store,
        caseId,
        room: room,
      );
      guard();
      final expected = value.sources[room.id]?.fingerprint;
      if (saved != null &&
          (saved.pendingScanId != null ||
              saved.scene?.fingerprint != expected)) {
        throw const HomeModelSourceChanged();
      }
    }
    await _write(key, value.model, sources: value.sources);
    _restoredSources
      ..clear()
      ..addAll(value.sources);
    scans.addAll(value.sources);
    unreadable.clear();
    model = value.model;
    changed();
  });

  Future<void> setReference(String id) => _run(() async {
    if (!rooms.any((r) => r.id == id) || !scans.containsKey(id)) {
      throw const FormatException();
    }
    final fresh = await _freshScene(id);
    if (fresh == null) throw const HomeModelSourceChanged();
    scans[id] = fresh;
    final next = WholeHomeModel(
      referenceRoomId: id,
      method: 'reviewed_alignment',
      rooms: [
        HomeRoomPlacement(
          roomId: id,
          fingerprint: scans[id]!.fingerprint,
          pose: RoomPose(),
          reviewed: true,
        ),
        if (model?.method == 'reviewed_alignment' &&
            model?.referenceRoomId == id)
          ...model!.rooms.where((r) => r.roomId != id),
      ],
    );
    await _write(key, next);
    model = next;
  });
  Future<void> place(
    String id,
    String parentId,
    RoomPose pose, {
    String? expectedFingerprint,
    String? expectedParentFingerprint,
  }) => _run(() async {
    final old = model;
    if (old == null ||
        old.method != 'reviewed_alignment' ||
        id == old.referenceRoomId ||
        !rooms.any((r) => r.id == id) ||
        !scans.containsKey(id) ||
        !connected().any((r) => r.roomId == parentId)) {
      throw const FormatException();
    }
    if ((await _freshScene(id))?.fingerprint != scans[id]!.fingerprint ||
        (await _freshScene(parentId))?.fingerprint !=
            old.room(parentId).fingerprint ||
        expectedFingerprint != null &&
            expectedFingerprint != scans[id]!.fingerprint ||
        expectedParentFingerprint != null &&
            expectedParentFingerprint != old.room(parentId).fingerprint) {
      throw const HomeModelSourceChanged();
    }
    final next = WholeHomeModel(
      referenceRoomId: old.referenceRoomId,
      method: old.method,
      rooms: [
        for (final r in old.rooms)
          if (r.roomId != id) r,
        HomeRoomPlacement(
          roomId: id,
          fingerprint: scans[id]!.fingerprint,
          parentId: parentId,
          parentFingerprint: old.room(parentId).fingerprint,
          pose: pose,
          reviewed: true,
        ),
      ],
    );
    next.resolve(scans, rooms.map((r) => r.id).toSet());
    await _write(key, next);
    model = next;
  });
  Future<void> remove(String id) => _run(() async {
    final old = model!;
    if (id == old.referenceRoomId) throw const FormatException();
    final removed = {id};
    for (var i = 0; i < old.rooms.length; i++) {
      removed.addAll(
        old.rooms
            .where((r) => removed.contains(r.parentId))
            .map((r) => r.roomId),
      );
    }
    final next = WholeHomeModel(
      referenceRoomId: old.referenceRoomId,
      method: old.method,
      rooms: old.rooms.where((r) => !removed.contains(r.roomId)).toList(),
    );
    await _write(key, next);
    model = next;
  });
  Future<void> capture(
    List<String> selected,
    Map<String, String> names,
  ) => _run(() async {
    if (!supported ||
        selected.length < 2 ||
        selected.length > 8 ||
        selected.toSet().length != selected.length ||
        selected.any((id) => !rooms.any((r) => r.id == id))) {
      throw const FormatException();
    }
    final id = newUuidV4();
    _captureId = id;
    _captureRooms = selected.toSet();
    final tokens = {for (final room in selected) room: newUuidV4()};
    try {
      await store.writeJson(intentKey, {'version': 1, 'captureId': id});
      guard();
      if (_captureId != id) throw const ScanScopeExpired();
      final result = await adapter.start(id, [
        for (final r in selected) HomeCaptureRoom(tokens[r]!, names[r]!),
      ]);
      guard();
      if (_captureId != id) throw const ScanScopeExpired();
      final captures = {for (final r in selected) r: result.rooms[tokens[r]]!};
      final root = selected.first;
      final next = WholeHomeModel(
        referenceRoomId: root,
        method: result.merged.source == ScanSource.arcore
            ? 'arcore_shared_frame'
            : 'roomplan_shared_frame',
        captures: captures,
        mergedScene: result.merged,
        rooms: [
          for (final r in selected)
            HomeRoomPlacement(
              roomId: r,
              fingerprint: captures[r]!.fingerprint,
              parentId: r == root ? null : root,
              parentFingerprint: r == root ? null : captures[root]!.fingerprint,
              baselineFingerprint: scans[r]?.fingerprint,
              pose: RoomPose(),
              reviewed: false,
            ),
        ],
      );
      await _write(draftKey, next);
      proposal = next;
    } finally {
      if (_captureId == id) _captureId = null;
      _captureRooms = {};
      if (current) await store.delete(intentKey);
    }
  });
  Future<void> acceptCapture() => _run(() async {
    final p = proposal!;
    for (final room in p.rooms) {
      if ((await _freshScene(room.roomId))?.fingerprint !=
          room.baselineFingerprint) {
        throw const HomeModelSourceChanged();
      }
    }
    final next = WholeHomeModel(
      referenceRoomId: p.referenceRoomId,
      method: p.method,
      captures: p.captures,
      mergedScene: p.mergedScene,
      rooms: [
        for (final r in p.rooms)
          HomeRoomPlacement(
            roomId: r.roomId,
            fingerprint: r.fingerprint,
            parentId: r.parentId,
            parentFingerprint: r.parentFingerprint,
            baselineFingerprint: r.baselineFingerprint,
            pose: r.pose,
            reviewed: true,
          ),
      ],
    );
    if (next.resolve(scans, rooms.map((r) => r.id).toSet()).length !=
        next.rooms.length) {
      throw const FormatException('A source room changed. Capture again.');
    }
    await _write(key, next);
    model = next;
    await store.delete(draftKey);
    guard();
    proposal = null;
  });
  Future<void> discardCapture() => _run(() async {
    await store.delete(draftKey);
    guard();
    proposal = null;
  });
  Future<void> cancelCapture() async {
    final id = _captureId;
    if (id != null) {
      _captureId = null;
      await adapter.cancel(id);
    }
  }

  Future<void> cancelIfScopeChanged() async {
    if (!current || _captureRooms.any((id) => !rooms.any((r) => r.id == id))) {
      await cancelCapture();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(cancelCapture().catchError((Object _) {}));
    super.dispose();
  }
}
