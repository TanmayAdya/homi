import 'dart:convert';
import 'package:flutter/foundation.dart';
import '../../../shared/models/case_draft.dart';
import '../../../shared/models/export_contract_values.dart';
import '../../../shared/models/home_model_sync.dart';
import '../../../shared/services/local_private_store.dart';
import '../../../shared/services/matching_api_client.dart';
import '../../../shared/services/scan_model_api_client.dart';

class HomeModelSync extends ChangeNotifier {
  HomeModelSync({
    required this.api,
    required this.store,
    required this.caseId,
    required this.storageKey,
    required this.isCurrent,
    required this.caseRevision,
    required this.localBundle,
    required this.applyBundle,
  });
  final ScanModelApiClient api;
  final LocalPrivateStore store;
  final String caseId, storageKey;
  final bool Function() isCurrent;
  final int Function() caseRevision;
  final HomeModelBundle? Function() localBundle;
  final Future<void> Function(HomeModelBundle) applyBundle;
  String get _metaKey => '$storageKey:sync';
  String get _pendingKey => '$storageKey:upload';
  int baseRevision = 0;
  Map<String, Object?>? pending;
  HomeModelState? remote;
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

  String? _json(HomeModelBundle? value) {
    try {
      return value?.encode();
    } on FormatException {
      return null;
    }
  }

  bool get differsFromAccount =>
      remote != null && _json(localBundle()) != remote!.bundleJson;
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
          'baseRevision',
        });
        if (meta['version'] != 1 || meta['caseId'] != caseId) {
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
        if (bytes.length > homeSyncMaxBytes) throw const FormatException();
        final value =
            ExportContractValues.object(jsonDecode(utf8.decode(bytes)), {
              'schemaVersion',
              'caseId',
              'expectedCaseRevision',
              'expectedModelRevision',
              'mutationId',
              'bundleJson',
            });
        if (value['schemaVersion'] != '3' ||
            value['caseId'] != caseId ||
            !isCaseUuidV4(value['mutationId'] as String)) {
          throw const FormatException();
        }
        ExportContractValues.integer(value['expectedCaseRevision']);
        ExportContractValues.integer(value['expectedModelRevision'], min: 0);
        if (value['bundleJson'] != null) {
          HomeModelBundle.decode(value['bundleJson'] as String, caseId);
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
      'baseRevision': revision,
    });
    _guard();
    baseRevision = revision;
  }

  Future<void> refresh() async {
    _guard();
    final value = await api.readHome(
      caseId,
      isCurrent: () => !_disposed && isCurrent(),
    );
    _guard();
    remote = value;
    if (!hasRecovery && value.bundleJson == _json(localBundle())) {
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
    final local = localBundle();
    if (!removeAccount && local == null) {
      feedback = 'Review the connected model before saving an account copy.';
      _changed();
      throw StateError('Finish and save the model first.');
    }
    if (accountChanged && !replaceAccount) {
      throw MatchingApiException.forCode('SCAN_MODEL_CONFLICT');
    }
    String? bundleJson;
    if (!removeAccount) {
      try {
        bundleJson = local!.encode();
      } on FormatException {
        feedback =
            'This connected model is too large to sync. Your device copy is retained.';
        _changed();
        rethrow;
      }
    }
    final request = <String, Object?>{
      'schemaVersion': '3',
      'caseId': caseId,
      'expectedCaseRevision': caseRevision(),
      'expectedModelRevision': replaceAccount || removeAccount
          ? remote!.modelRevision
          : baseRevision,
      'mutationId': newUuidV4(),
      'bundleJson': bundleJson,
    };
    final bytes = Uint8List.fromList(utf8.encode(jsonEncode(request)));
    if (bytes.length > homeSyncMaxBytes) throw const FormatException();
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
      final result = await api.saveHome(
        request,
        isCurrent: () => !_disposed && isCurrent(),
      );
      _guard();
      final revision = result.bundleJson == request['bundleJson']
          ? result.modelRevision
          : (request['expectedModelRevision'] as int) + 1;
      await _metadata(revision);
      await store.delete(_pendingKey);
      _guard();
      pending = null;
      remote = result;
      feedback = result.bundleJson == request['bundleJson']
          ? request['bundleJson'] == null
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
    if (hasRecovery || selected?.bundle == null) {
      throw StateError('Review the account model first.');
    }
    final latest = await api.readHome(
      caseId,
      isCurrent: () => !_disposed && isCurrent(),
    );
    _guard();
    if (latest.modelRevision != selected!.modelRevision ||
        latest.bundleJson != selected.bundleJson) {
      remote = latest;
      _changed();
      throw MatchingApiException.forCode('SCAN_MODEL_CONFLICT');
    }
    if (latest.caseRevision != caseRevision()) {
      throw MatchingApiException.forCode('CASE_REVISION_MISMATCH');
    }
    await applyBundle(latest.bundle!);
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
