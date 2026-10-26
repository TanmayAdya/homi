import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/shared/services/local_private_store.dart';

class MemorySecrets implements SecretValueStore {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}

class DeleteFailDirectory extends Fake implements Directory {
  DeleteFailDirectory(this.actual);
  final Directory actual;
  bool fail = true;
  @override
  Future<bool> exists() => actual.exists();
  @override
  Future<Directory> delete({bool recursive = false}) async {
    if (fail) {
      fail = false;
      throw const FileSystemException('Fictional filesystem failure');
    }
    await actual.delete(recursive: recursive);
    return actual;
  }
}

void main() {
  late Directory directory;
  late MemorySecrets secrets;
  late LocalPrivateStore store;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('sah-private-test-');
    secrets = MemorySecrets();
    store = LocalPrivateStore(
      directory: directory,
      accountId: 'fictional-owner',
      secrets: secrets,
    );
  });
  tearDown(() async {
    if (await directory.exists()) await directory.delete(recursive: true);
  });
  test(
    'failed ciphertext deletion still removes the key and can be retried',
    () async {
      await store.writeJson('case.saved', {'fictional': true});
      final failing = LocalPrivateStore(
        directory: DeleteFailDirectory(directory),
        accountId: 'fictional-owner',
        secrets: secrets,
      );
      await expectLater(failing.clear(), throwsA(isA<FileSystemException>()));
      expect(secrets.values, isEmpty);
      expect(await directory.exists(), true);
      await failing.clear();
      expect(await directory.exists(), false);
    },
  );
  test('empty fresh account lists no records without creating a key', () async {
    expect(await store.keys(), isEmpty);
    expect(secrets.values, isEmpty);
  });
  test(
    'records and logical identifiers are encrypted and survive reopen',
    () async {
      await store.writeJson('case.fictional', {
        'resident': 'Fictional Test Resident',
        'income': 0,
        'consent': false,
        'unknown': null,
      });
      final file = (await directory.list().toList()).whereType<File>().single;
      expect(file.path, isNot(contains('fictional')));
      expect(
        await file.readAsString(),
        isNot(contains('Fictional Test Resident')),
      );
      final reopened = LocalPrivateStore(
        directory: directory,
        accountId: 'fictional-owner',
        secrets: secrets,
      );
      expect((await reopened.readJson('case.fictional'))!['income'], 0);
      expect((await reopened.readJson('case.fictional'))!['unknown'], isNull);
      expect(await reopened.keys(), ['case.fictional']);
    },
  );
  test('each rewrite has a different nonce and bytes authenticate', () async {
    final bytes = Uint8List.fromList(utf8.encode('private fictional image'));
    await store.writeBytes('photo.one', bytes);
    final file = (await directory.list().toList()).whereType<File>().single;
    final first = await file.readAsString();
    await store.writeBytes('photo.one', bytes);
    expect(await file.readAsString(), isNot(first));
    final value = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    final encoded = base64Decode(value['record'] as String);
    encoded[15] ^= 1;
    value['record'] = base64Encode(encoded);
    await file.writeAsString(jsonEncode(value));
    await expectLater(store.readBytes('photo.one'), throwsFormatException);
  });
  test(
    'swapping encrypted files between record identities is rejected',
    () async {
      await store.writeBytes('one', Uint8List.fromList([1]));
      await store.writeBytes('two', Uint8List.fromList([2]));
      final files = (await directory.list().toList())
          .whereType<File>()
          .toList();
      await files[0].writeAsBytes(await files[1].readAsBytes());
      final results = await Future.wait(
        ['one', 'two'].map((key) async {
          try {
            await store.readBytes(key);
            return true;
          } catch (_) {
            return false;
          }
        }),
      );
      expect(results.where((v) => !v).length, 1);
    },
  );
  test('another account cannot enumerate or decrypt private records', () async {
    await store.writeJson('case.one', {'name': 'fictional'});
    final other = LocalPrivateStore(
      directory: directory,
      accountId: 'other-owner',
      secrets: secrets,
    );
    expect(await other.readJson('case.one'), isNull);
    await expectLater(other.keys(), throwsStateError);
  });
  test(
    'concurrent writes serialize and total/value limits fail before replacement',
    () async {
      final tiny = LocalPrivateStore(
        directory: directory,
        accountId: 'fictional-owner',
        secrets: secrets,
        maxValueBytes: 64,
        maxTotalBytes: 250,
      );
      await Future.wait([
        tiny.writeBytes('one', Uint8List.fromList([1])),
        tiny.writeBytes('one', Uint8List.fromList([2])),
      ]);
      expect(await tiny.readBytes('one'), [2]);
      await expectLater(
        tiny.writeBytes('one', Uint8List(65)),
        throwsStateError,
      );
      expect(await tiny.readBytes('one'), [2]);
      await expectLater(
        tiny.writeBytes('two', Uint8List(64)),
        throwsStateError,
      );
      expect(await tiny.readBytes('one'), [2]);
    },
  );
  test(
    'session expiry closes handles but retains queued edits for the same account',
    () async {
      final writing = store.writeJson('case.saved', {
        'income': 0,
        'unknown': null,
      });
      final closed = store.close();
      await writing;
      await closed;
      await expectLater(store.readJson('case.saved'), throwsStateError);
      expect(secrets.values, isNotEmpty);
      final resumed = LocalPrivateStore(
        directory: directory,
        accountId: 'fictional-owner',
        secrets: secrets,
      );
      expect(await resumed.readJson('case.saved'), {
        'income': 0,
        'unknown': null,
      });
      await store.clear();
      expect(await directory.exists(), false);
      expect(secrets.values, isEmpty);
    },
  );
  test(
    'clear removes ciphertext and key and blocks late queued writes',
    () async {
      await store.writeBytes('one', Uint8List.fromList([1]));
      final clear = store.clear();
      final late = store.writeBytes('two', Uint8List.fromList([2]));
      final blocked = expectLater(late, throwsStateError);
      await clear;
      await blocked;
      await store.clear();
      expect(await directory.exists(), false);
      expect(secrets.values, isEmpty);
    },
  );
}
