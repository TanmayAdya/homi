import 'dart:typed_data';

import '../../../shared/models/case_draft.dart';
import '../../../shared/services/local_private_store.dart';
import '../domain/capture/staging_store.dart';
import '../domain/image/image_validator.dart';

class EncryptedStagingStore implements StagingStore {
  EncryptedStagingStore(
    this.store, {
    required String caseId,
    this.deferDeletion = false,
  }) : prefix = 'assessment:$caseId:photo:';

  final LocalPrivateStore store;
  final String prefix;
  final bool deferDeletion;
  static const maxDiscardIntents = 512;
  final Set<StagingKey> _discardIntents = {};
  List<String> get discardIntents => [
    for (final key in _discardIntents) key.value,
  ];

  String _key(StagingKey key) {
    if (!RegExp(r'^[a-f0-9-]{36}$').hasMatch(key.value)) {
      throw const FormatException('Invalid staging key');
    }
    return '$prefix${key.value}';
  }

  @override
  Future<StagedImage> put(
    Uint8List bytes,
    ImageAccepted info, {
    String? capturedAt,
    bool orientationNormalized = false,
  }) async {
    final key = StagingKey(newUuidV4());
    await store.writeBytes(_key(key), bytes);
    return StagedImage(
      key: key,
      format: info.format,
      width: info.width,
      height: info.height,
      byteLength: bytes.length,
      capturedAt: capturedAt,
      orientationNormalized: orientationNormalized,
    );
  }

  @override
  Future<Uint8List?> read(StagingKey key) => store.readBytes(_key(key));

  @override
  Future<bool> discard(StagingKey key) async {
    _key(key);
    if (deferDeletion) {
      if (!_discardIntents.contains(key) &&
          _discardIntents.length >= maxDiscardIntents) {
        return false;
      }
      _discardIntents.add(key);
      return true;
    }
    await store.delete(_key(key));
    return true;
  }

  void restoreDiscardIntents(Object? value) {
    if (value == null) return;
    if (value is! List || value.length > maxDiscardIntents) {
      throw const FormatException('Invalid photo cleanup journal');
    }
    final parsed = <StagingKey>{};
    for (final item in value) {
      if (item is! String) {
        throw const FormatException('Invalid photo cleanup key');
      }
      final key = StagingKey(item);
      _key(key);
      parsed.add(key);
    }
    if ({..._discardIntents, ...parsed}.length > maxDiscardIntents) {
      throw const FormatException('Photo cleanup journal is full');
    }
    _discardIntents.addAll(parsed);
  }

  Future<void> commitDiscardIntents({
    required List<String> persistedIntents,
    required Set<String> retainedKeys,
  }) async {
    if (!deferDeletion) return;
    if (persistedIntents.length > maxDiscardIntents) {
      throw const FormatException('Invalid photo cleanup journal');
    }
    for (final value in persistedIntents) {
      final key = StagingKey(value);
      final logicalKey = _key(key);
      if (retainedKeys.contains(value) || !_discardIntents.contains(key)) {
        continue;
      }
      try {
        await store.delete(logicalKey);
        _discardIntents.remove(key);
      } catch (_) {
        // ignore: empty_catches
      }
    }
  }

  @override
  Future<List<StagingKey>> keys() async => [
    for (final key in await store.keys())
      if (key.startsWith(prefix)) StagingKey(key.substring(prefix.length)),
  ];

  @override
  Future<int> discardAll() async {
    final pending = await keys();
    for (final key in pending) {
      await discard(key);
    }
    return pending.length;
  }
}
