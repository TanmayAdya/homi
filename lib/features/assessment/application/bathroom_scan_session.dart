import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';

import '../../../shared/models/case_draft.dart';
import '../../../shared/services/local_private_store.dart';
import '../domain/scan/bathroom_scan_scene.dart';
import '../domain/home_safety/home_safety.dart';
import '../domain/assessment_location.dart';
import '../domain/scan/scan_suggestions.dart';
import 'bathroom_scan_adapter.dart';
import 'scan_model_sync.dart';
import '../../../shared/services/scan_model_api_client.dart';
import '../domain/scan/bathroom_scan_review.dart';
export '../domain/scan/bathroom_scan_review.dart';

class ScanScopeExpired implements Exception {
  const ScanScopeExpired();
}

class _ScanCaptureAttempt {
  _ScanCaptureAttempt(this.id);
  final String id;
  bool cancelled = false, nativeStarted = false, acceptingResult = false;
}

class BathroomScanSession extends ChangeNotifier {
  BathroomScanSession({
    required this.store,
    required this.caseId,
    required this.isCurrent,
    required this.adapter,
    this.room,
    ScanModelApiClient? syncApi,
    int Function()? caseRevision,
  }) {
    if (syncApi != null && caseRevision != null) {
      synchronization = ScanModelSync(
        api: syncApi,
        store: store,
        caseId: caseId,
        room: room,
        storageKey: key,
        isCurrent: () => !_disposed && isCurrent(),
        caseRevision: caseRevision,
        localReview: () => review,
        applyReview: _save,
      )..addListener(_changed);
    }
  }
  final LocalPrivateStore store;
  final String caseId;
  final bool Function() isCurrent;
  final BathroomScanAdapter adapter;
  final RoomInstance? room;
  ScanModelSync? synchronization;
  AssessmentLocation get location => room?.type ?? AssessmentLocation.bathroom;
  static String storageKey(String caseId, {RoomInstance? room}) => room == null
      ? 'assessment:$caseId:bathroom-scan'
      : 'assessment:$caseId:room-scan:${sha256.convert(utf8.encode(room.id))}';
  String get key => storageKey(caseId, room: room);
  List<ScanDifficulty> get availableDifficulties => ScanDifficulty.values
      .where(
        (d) =>
            location == AssessmentLocation.bathroom ||
            d == ScanDifficulty.enteringBathroom ||
            d == ScanDifficulty.movingAround ||
            location == AssessmentLocation.kitchen &&
                d == ScanDifficulty.sinkUse,
      )
      .toList();
  BathroomScanReview review = BathroomScanReview();
  BathroomScanCapabilities? capabilities;
  bool busy = false, dirty = false, initialized = false, _disposed = false;
  String? notice;
  _ScanCaptureAttempt? _captureAttempt;
  bool get canCancelCapture =>
      _captureAttempt != null && !_captureAttempt!.acceptingResult;

  void guard() {
    if (_disposed || !isCurrent()) throw const ScanScopeExpired();
  }

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  static Future<BathroomScanReview?> readSaved(
    LocalPrivateStore store,
    String caseId, {
    RoomInstance? room,
  }) async {
    final bytes = await store.readBytes(storageKey(caseId, room: room));
    if (bytes == null) return null;
    if (bytes.length > 768 * 1024) {
      throw const FormatException('Private scan exceeds its storage bound.');
    }
    return BathroomScanReview.fromJson(
      jsonDecode(utf8.decode(bytes)),
      caseId,
      room: room,
    );
  }

  Future<void> initialize() async {
    guard();
    final saved = await readSaved(store, caseId, room: room);
    guard();
    if (saved != null) review = saved;
    if (review.pendingScanId != null) {
      notice = review.scene == null
          ? 'The previous scan was interrupted. Start a new scan when ready.'
          : 'The previous scan was interrupted. Your saved model is retained. Start a new scan when ready.';
      await _save(review.copyWith(clearPending: true));
    }
    await synchronization?.initialize();
    await refreshCapabilities();
    initialized = true;
    _changed();
  }

  Future<void> refreshCapabilities() async {
    guard();
    try {
      final result = await adapter.capabilities().timeout(
        const Duration(seconds: 5),
      );
      guard();
      capabilities = result;
    } on ScanScopeExpired {
      rethrow;
    } catch (_) {
      guard();
      capabilities = null;
      notice =
          'Scanner availability could not be checked. You can still use photos and manual measurements.';
    }
    _changed();
  }

  Future<void> _save(BathroomScanReview next) async {
    guard();
    final bytes = Uint8List.fromList(
      utf8.encode(jsonEncode(next.toJson(caseId, room: room))),
    );
    if (bytes.length > 768 * 1024) {
      throw const FormatException('Private scan exceeds its storage bound.');
    }
    review = next;
    dirty = true;
    _changed();
    try {
      await store.writeBytes(key, bytes);
      guard();
      dirty = false;
      _changed();
    } catch (_) {
      if (!_disposed && isCurrent()) {
        notice =
            'The device save failed. Keep this screen open, free device space and retry saving. The model has not been uploaded.';
        _changed();
      }
      rethrow;
    }
  }

  Future<void> _run(Future<void> Function() work) async {
    guard();
    if (!initialized || busy) throw StateError('Finish the current scan step.');
    busy = true;
    _changed();
    try {
      await work();
    } finally {
      busy = false;
      _changed();
    }
  }

  Future<void> checkAccountModel() => _run(() => synchronization!.refresh());
  Future<void> uploadModel({
    bool replaceAccount = false,
    bool removeAccount = false,
  }) => _run(
    () => synchronization!.upload(
      replaceAccount: replaceAccount,
      removeAccount: removeAccount,
    ),
  );
  Future<void> retryModelUpload() => _run(() => synchronization!.retry());
  Future<void> restoreModel() => _run(() => synchronization!.restore());
  Future<void> discardSyncRecovery() =>
      _run(() => synchronization!.discardRecovery());

  Future<void> retrySave() => _run(() => _save(review));

  Future<void> discardUnsaved() => _run(() async {
    final bytes = await store.readBytes(key);
    guard();
    review = bytes == null
        ? BathroomScanReview()
        : BathroomScanReview.fromJson(
            jsonDecode(utf8.decode(bytes)),
            caseId,
            room: room,
          );
    dirty = false;
    _changed();
  });

  Future<void> capture() => _run(() async {
    if (dirty) throw StateError('Save the current model before another scan.');
    final scanId = newUuidV4();
    final previous = review;
    final attempt = _ScanCaptureAttempt(scanId);
    _captureAttempt = attempt;
    notice = null;
    try {
      try {
        await _save(previous.copyWith(pendingScanId: scanId));
      } catch (_) {
        if (attempt.cancelled && !_disposed && isCurrent()) {
          review = previous.copyWith(clearPending: true);
          dirty = true;
          _changed();
        }
        rethrow;
      }
      guard();
      if (attempt.cancelled) {
        await _finishCancelledCapture(attempt, previous);
        return;
      }
      BathroomScanScene result;
      try {
        attempt.nativeStarted = true;
        final captureAdapter = adapter;
        final captureRoom = room;
        result = captureRoom != null && captureAdapter is RoomContextScanAdapter
            ? await (captureAdapter as RoomContextScanAdapter).startForRoom(
                scanId,
                captureRoom,
              )
            : await captureAdapter.start(scanId);
        guard();
        if (result.scanId != scanId) {
          throw const FormatException(
            'Scan response belongs to another capture.',
          );
        }
      } on ScanScopeExpired {
        rethrow;
      } catch (error) {
        guard();
        attempt.acceptingResult = true;
        await _save(previous.copyWith(clearPending: true));
        notice = scanErrorMessage(
          attempt.cancelled ? PlatformException(code: 'scan_cancelled') : error,
          hasSavedModel: previous.scene != null,
        );
        _changed();
        return;
      }
      if (attempt.cancelled) {
        await _finishCancelledCapture(attempt, previous);
        return;
      }
      attempt.acceptingResult = true;
      _changed();
      await _save(BathroomScanReview(scene: result));
      notice =
          'Scan saved on this device. Choose what feels difficult to see possible improvements.';
      _changed();
    } finally {
      if (identical(_captureAttempt, attempt)) _captureAttempt = null;
    }
  });

  Future<void> _finishCancelledCapture(
    _ScanCaptureAttempt attempt,
    BathroomScanReview previous,
  ) async {
    guard();
    attempt.acceptingResult = true;
    await _save(previous.copyWith(clearPending: true));
    notice = scanErrorMessage(
      PlatformException(code: 'scan_cancelled'),
      hasSavedModel: previous.scene != null,
    );
    _changed();
  }

  Future<void> reviewElement(
    String id, {
    required bool confirmed,
    ScanElementKind? label,
  }) => _run(() async {
    final element = review.scene?.elementById(id);
    if (element == null) throw const FormatException('Unknown scan feature.');
    final labels = {...review.labels};
    final reviewed = {...review.reviewed};
    if (label != null) labels[id] = label;
    if (confirmed) {
      reviewed.add(id);
    } else {
      reviewed.remove(id);
    }
    await _save(
      review.copyWith(reviewed: reviewed, labels: labels, dismissed: {}),
    );
  });

  List<ScanSuggestionCandidate> get suggestedImprovements {
    final scene = review.scene;
    if (scene == null) return const [];
    return previewBathroomImprovements(
      scene: scene,
      room: room,
      difficulties: review.difficulties,
      identifiedKinds: review.labels,
    );
  }

  Set<String> get currentReviewedSuggestionIds {
    final scene = review.scene;
    if (scene == null) return const {};
    return {
      for (final suggestion in suggestBathroomImprovements(
        scene: scene,
        room: room,
        reviewedElementIds: review.reviewed,
        difficulties: review.difficulties,
        identifiedKinds: {
          for (final entry in review.labels.entries)
            if (review.reviewed.contains(entry.key)) entry.key: entry.value,
        },
      ))
        suggestion.id,
    };
  }

  Future<ScanSuggestion> confirmImprovement(
    ScanSuggestionCandidate candidate,
  ) async {
    late ScanSuggestion confirmed;
    await _run(() async {
      if (dirty) throw StateError('Save the current review first.');
      final current = suggestedImprovements
          .where((value) => value.id == candidate.id)
          .firstOrNull;
      if (current == null) {
        throw StateError('This suggestion changed. Review it again.');
      }
      final reviewed = {...review.reviewed, ...current.relatedElementIds};
      final result = suggestBathroomImprovements(
        scene: review.scene!,
        room: room,
        reviewedElementIds: reviewed,
        difficulties: review.difficulties,
        identifiedKinds: {
          for (final entry in review.labels.entries)
            if (reviewed.contains(entry.key)) entry.key: entry.value,
        },
      ).where((value) => value.id == current.id).firstOrNull;
      if (result == null) {
        throw StateError('This suggestion needs another review.');
      }
      await _save(review.copyWith(reviewed: reviewed));
      guard();
      confirmed = result;
    });
    return confirmed;
  }

  Future<void> setDifficulty(ScanDifficulty difficulty, bool value) =>
      _run(() async {
        if (!availableDifficulties.contains(difficulty)) {
          throw const FormatException(
            'This difficulty does not apply to this room.',
          );
        }
        final next = {...review.difficulties};
        if (value) {
          next.add(difficulty);
        } else {
          next.remove(difficulty);
        }
        await _save(review.copyWith(difficulties: next, dismissed: {}));
      });

  Future<void> dismiss(String id) => _run(() async {
    if (review.dismissed.length >= 256) {
      throw StateError('Review limit reached.');
    }
    await _save(review.copyWith(dismissed: {...review.dismissed, id}));
  });

  Future<void> undismiss(String id) => _run(
    () => _save(review.copyWith(dismissed: {...review.dismissed}..remove(id))),
  );

  Future<void> clearModel() => _run(() async {
    await _save(BathroomScanReview());
    notice =
        'Device model removed. Observations already added to the assessment can be edited or removed there.';
  });

  Future<void> cancelCapture() async {
    final attempt = _captureAttempt;
    if (attempt == null || attempt.acceptingResult) return;
    attempt.cancelled = true;
    if (attempt.nativeStarted) {
      try {
        await adapter.cancel(attempt.id);
      } catch (_) {
        if (!_disposed && isCurrent()) {
          notice = review.scene == null
              ? 'Cancellation was requested. If the camera stays open, close the native scan. Its result will not be saved.'
              : 'Cancellation was requested. If the camera stays open, close the native scan. Its result will not replace your saved model.';
          _changed();
        }
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    synchronization?.removeListener(_changed);
    synchronization?.dispose();
    unawaited(cancelCapture().catchError((Object _) {}));
    super.dispose();
  }
}

String scanErrorMessage(Object error, {bool hasSavedModel = false}) {
  final code = error is PlatformException ? error.code : 'scan_failed';
  return switch (code) {
    'scan_cancelled' =>
      hasSavedModel
          ? 'Scan cancelled. Your previous model is retained.'
          : 'Scan cancelled. Start a new scan when ready.',
    'scan_interrupted' =>
      hasSavedModel
          ? 'Scanning was interrupted. Your previous model is retained; start a new scan when ready.'
          : 'Scanning was interrupted. Start a new scan when ready.',
    'scan_permission_denied' =>
      'Camera access is off. Enable it in device Settings, or continue with manual assessment.',
    'scan_unavailable' =>
      'Scanning is unavailable on this device. Continue with photos and manual measurements.',
    'scan_busy' => 'Another camera session is active. Close it and try again.',
    'scan_limit' =>
      'This scan reached its limit. Try a shorter room scan with fewer objects.',
    _ =>
      hasSavedModel
          ? 'The scan could not be processed. Your previous model is retained. Try again in good light, or use photos and manual measurements.'
          : 'The scan could not be processed. Try again in good light, or use photos and manual measurements.',
  };
}
