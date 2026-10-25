import 'dart:convert';
import 'package:flutter/foundation.dart';
import '../../../shared/models/case_draft.dart';
import '../../../shared/models/export_contract_values.dart';
import '../../../shared/models/scan_model_sync.dart';
import '../../../shared/services/local_private_store.dart';
import '../../../shared/services/matching_api_client.dart';
import '../../../shared/services/scan_model_api_client.dart';
import '../domain/home_safety/home_safety.dart';
import '../domain/scan/bathroom_scan_review.dart';

class ScanModelSync extends ChangeNotifier {
  ScanModelSync({
    required this.api,
    required this.store,
    required this.caseId,
    required this.storageKey,
    required this.isCurrent,
    required this.caseRevision,
    required this.localReview,
    required this.applyReview,
    this.room,
  });
  final ScanModelApiClient api;
  final LocalPrivateStore store;
  final String caseId, storageKey;
  final RoomInstance? room;
  final bool Function() isCurrent;
  final int Function() caseRevision;
  final BathroomScanReview Function() localReview;
  final Future<void> Function(BathroomScanReview) applyReview;
  String get _metaKey => '$storageKey:sync';
  String get _pendingKey => '$storageKey:upload';
  int baseRevision = 0;
  Map<String, Object?>? pending;
  ScanModelState? remote;
  String? feedback;
  bool corrupt = false, _disposed = false;
  bool get hasRecovery => pending != null || corrupt;
  void _guard() {
    if (_disposed || !isCurrent()) {
      throw MatchingApiException.forCode('STALE_RESPONSE');
    }
  }

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  String? _json(BathroomScanReview value) => value.scene == null
      ? null
      : jsonEncode(
          value.copyWith(clearPending: true).toJson(caseId, room: room),
        );
  bool get differsFromAccount =>
      remote != null && _json(localReview()) != remote!.reviewJson;
  bool get accountChanged =>
      remote != null &&
      remote!.modelRevision != baseRevision &&
      differsFromAccount;

  Future<void> initialize() async {
    _guard();
    try {
      final meta = await store.readJson(_metaKey);
      _guard();
      if (meta != null) {
        ExportContractValues.object(meta, {
          'version',
          'caseId',
          'roomId',
          'baseRevision',
        });
        if (meta['version'] != 1 ||
            meta['caseId'] != caseId ||
            meta['roomId'] != room?.id) {
          throw const FormatException();
        }
        baseRevision = ExportContractValues.integer(
          meta['baseRevision'],
          min: 0,
        );
      }
      final bytes = await store.readBytes(_pendingKey);
      _guard();
      if (bytes != null) {
        if (bytes.length > scanSyncMaxBytes) throw const FormatException();
        final value =
            ExportContractValues.object(jsonDecode(utf8.decode(bytes)), {
              'schemaVersion',
              'caseId',
              'roomId',
              'expectedCaseRevision',
              'expectedModelRevision',
              'mutationId',
              'reviewJson',
            });
        if (value['schemaVersion'] != '3' ||
            value['caseId'] != caseId ||
            value['roomId'] != room?.id ||
            !isCaseUuidV4(value['mutationId'] as String)) {
          throw const FormatException();
        }
        ExportContractValues.integer(value['expectedCaseRevision']);
        ExportContractValues.integer(value['expectedModelRevision'], min: 0);
        if (value['reviewJson'] != null) {
          final review = BathroomScanReview.fromJson(
            jsonDecode(value['reviewJson'] as String),
            caseId,
            room: room,
          );
          if (review.scene == null || review.pendingScanId != null) {
            throw const FormatException();
          }
        }
        pending = value;
        feedback =
            'A model upload is pending. Retry the same upload or review the account copy before discarding it.';
      }
    } catch (_) {
      _guard();
      corrupt = true;
      feedback =
          'Account model recovery could not be read. Your device model is retained. Reset sync recovery before uploading.';
    }
    _changed();
  }

  Future<void> _metadata(int revision) async {
    _guard();
    await store.writeJson(_metaKey, {
      'version': 1,
      'caseId': caseId,
      'roomId': room?.id,
      'baseRevision': revision,
    });
    _guard();
    baseRevision = revision;
  }

  Future<void> refresh() async {
    _guard();
    final value = await api.read(
      caseId,
      room: room,
      isCurrent: () => !_disposed && isCurrent(),
    );
    _guard();
    remote = value;
    if (!hasRecovery && value.reviewJson == _json(localReview())) {
      await _metadata(value.modelRevision);
    }
    feedback = accountChanged
        ? 'The account model differs from this device. Review both copies before replacing either.'
        : null;
    _changed();
  }

  Future<void> upload({
    bool replaceAccount = false,
    bool removeAccount = false,
  }) async {
    _guard();
    if (hasRecovery || remote == null) {
      throw StateError('Review model sync first.');
    }
    final local = localReview();
    if (local.pendingScanId != null || !removeAccount && local.scene == null) {
      throw StateError('Finish and save the model first.');
    }
    if (accountChanged && !replaceAccount) {
      throw MatchingApiException.forCode('SCAN_MODEL_CONFLICT');
    }
    final request = <String, Object?>{
      'schemaVersion': '3',
      'caseId': caseId,
      'roomId': room?.id,
      'expectedCaseRevision': caseRevision(),
      'expectedModelRevision': replaceAccount || removeAccount
          ? remote!.modelRevision
          : baseRevision,
      'mutationId': newUuidV4(),
      'reviewJson': removeAccount ? null : _json(local),
    };
    final bytes = Uint8List.fromList(utf8.encode(jsonEncode(request)));
    if (bytes.length > scanSyncMaxBytes) throw const FormatException();
    await store.writeBytes(_pendingKey, bytes);
    _guard();
    pending = request;
    _changed();
    await retry();
  }

  Future<void> retry() async {
    _guard();
    final request = pending;
    if (corrupt || request == null) {
      throw StateError('No readable pending upload.');
    }
    try {
      final result = await api.save(
        request,
        room: room,
        isCurrent: () => !_disposed && isCurrent(),
      );
      _guard();
      final revision = result.reviewJson == request['reviewJson']
          ? result.modelRevision
          : (request['expectedModelRevision'] as int) + 1;
      await _metadata(revision);
      await store.delete(_pendingKey);
      _guard();
      pending = null;
      remote = result;
      feedback = result.reviewJson == request['reviewJson']
          ? request['reviewJson'] == null
                ? 'Account model removed. The device copy is retained.'
                : 'Model saved to your account. Your device copy is retained.'
          : 'The account model changed after your upload. Your device copy is retained; review both copies.';
    } catch (error) {
      if (!_disposed && isCurrent()) {
        feedback =
            error is MatchingApiException &&
                {
                  'SCAN_MODEL_CONFLICT',
                  'CASE_REVISION_MISMATCH',
                  'SCAN_MODEL_MUTATION_CONFLICT',
                }.contains(error.code)
            ? 'The account or plan changed. Check the account copy and review the pending upload.'
            : 'The model upload could not be confirmed. Your device copy and pending upload are retained.';
      }
      rethrow;
    } finally {
      _changed();
    }
  }

  Future<void> restore() async {
    _guard();
    final selected = remote;
    if (hasRecovery || selected?.review == null) {
      throw StateError('Review the account model first.');
    }
    final latest = await api.read(
      caseId,
      room: room,
      isCurrent: () => !_disposed && isCurrent(),
    );
    _guard();
    if (latest.modelRevision != selected!.modelRevision ||
        latest.reviewJson != selected.reviewJson) {
      remote = latest;
      _changed();
      throw MatchingApiException.forCode('SCAN_MODEL_CONFLICT');
    }
    await applyReview(latest.review!);
    _guard();
    await _metadata(latest.modelRevision);
    remote = latest;
    feedback =
        'Account model restored on this device. Findings already saved in the plan are unchanged.';
    _changed();
  }

  Future<void> discardRecovery() async {
    _guard();
    await store.delete(_pendingKey);
    _guard();
    await _metadata(0);
    pending = null;
    corrupt = false;
    remote = null;
    feedback =
        'Sync recovery cleared. Check the account copy before uploading again.';
    _changed();
  }

  @override
  void dispose() {
    _disposed = true;
    remote = null;
    super.dispose();
  }
}
