import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/features/assessment/application/encrypted_staging_store.dart';
import 'package:safe_at_home/features/assessment/domain/capture/staging_store.dart';
import 'package:safe_at_home/features/assessment/domain/image/image_validator.dart';
import 'package:safe_at_home/shared/services/local_private_store.dart';
import '../../../app/local_private_store_test.dart' show MemorySecrets;

void main() {
  late Directory directory;
  late EncryptedStagingStore staging;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('sah-discard-intent-');
    staging = EncryptedStagingStore(
      LocalPrivateStore(
        directory: directory,
        accountId: 'fictional-resident',
        secrets: MemorySecrets(),
      ),
      caseId: 'fictional-case',
      deferDeletion: true,
    );
  });
  tearDown(() => directory.delete(recursive: true));
  Future<StagedImage> photo() => staging.put(
    Uint8List.fromList([1, 2, 3]),
    const ImageAccepted(
      format: SupportedImageFormat.png,
      width: 1,
      height: 1,
      byteLength: 3,
    ),
  );
  test(
    'an earlier persisted snapshot cannot delete a later queued discard',
    () async {
      final old = await photo();
      final newer = await photo();
      await staging.discard(old.key);
      final before = staging.discardIntents;
      await staging.discard(newer.key);
      await staging.commitDiscardIntents(
        persistedIntents: before,
        retainedKeys: {},
      );
      expect(await staging.read(old.key), isNull);
      expect(await staging.read(newer.key), isNotNull);
      expect(staging.discardIntents, [newer.key.value]);
    },
  );
  test(
    'retained index and upload references override persisted discard requests',
    () async {
      final original = await photo();
      await staging.discard(original.key);
      await staging.commitDiscardIntents(
        persistedIntents: staging.discardIntents,
        retainedKeys: {original.key.value},
      );
      expect(await staging.read(original.key), isNotNull);
      expect(staging.discardIntents, [original.key.value]);
    },
  );
  test(
    'cleanup journal is bounded and cannot name arbitrary private records',
    () {
      expect(
        () => staging.restoreDiscardIntents(['case.other']),
        throwsFormatException,
      );
      expect(
        () => staging.restoreDiscardIntents(['../another-photo']),
        throwsFormatException,
      );
      expect(() => staging.restoreDiscardIntents([12]), throwsFormatException);
      expect(
        () => staging.restoreDiscardIntents(
          List.filled(
            EncryptedStagingStore.maxDiscardIntents + 1,
            '00000000-0000-0000-0000-000000000000',
          ),
        ),
        throwsFormatException,
      );
      expect(staging.discardIntents, isEmpty);
    },
  );
}
