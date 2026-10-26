import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as hashing;
import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

abstract interface class SecretValueStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class DeviceSecretStore implements SecretValueStore {
  DeviceSecretStore()
    : _storage = const FlutterSecureStorage(
        iOptions: IOSOptions(
          accessibility: KeychainAccessibility.unlocked_this_device,
          synchronizable: false,
        ),
      );
  final FlutterSecureStorage _storage;
  @override
  Future<String?> read(String key) => _storage.read(key: key);
  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);
  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

class LocalPrivateStore {
  LocalPrivateStore({
    required this.directory,
    required this.accountId,
    required this.secrets,
    this.maxTotalBytes = 128 * 1024 * 1024,
    this.maxValueBytes = 8 * 1024 * 1024,
  });
  final Directory directory;
  final String accountId;
  final SecretValueStore secrets;
  final int maxTotalBytes, maxValueBytes;
  final _cipher = AesGcm.with256bits();
  Future<void> _tail = Future.value();
  bool _closed = false, _closing = false;
  Future<void>? _clearFuture;
  String get _keyName =>
      'sah.v1.account.${hashing.sha256.convert(utf8.encode(accountId))}';
  String _name(String key) {
    if (!RegExp(r'^[A-Za-z0-9_.:-]{1,512}$').hasMatch(key)) {
      throw const FormatException('Invalid private record key.');
    }
    return hashing.sha256
        .convert(utf8.encode('$accountId\u0000$key'))
        .toString();
  }

  Future<T> _serial<T>(Future<T> Function() work) {
    if (_closing || _closed) {
      return Future.error(StateError('Private storage is closed.'));
    }
    final next = _tail.then((_) {
      if (_closed) throw StateError('Private storage is closed.');
      return work();
    });
    _tail = next.then<void>((_) {}, onError: (Object _, StackTrace stack) {});
    return next;
  }

  Future<SecretKey> _key({bool create = false}) async {
    final existing = await secrets.read(_keyName);
    if (existing != null) {
      final value = base64Decode(existing);
      if (value.length != 32) {
        throw const FormatException('Private storage key unavailable.');
      }
      return SecretKey(value);
    }
    if (!create) throw StateError('Private storage key unavailable.');
    final key = await _cipher.newSecretKey();
    await secrets.write(_keyName, base64Encode(await key.extractBytes()));
    return key;
  }

  List<int> _aad(String key) =>
      utf8.encode('sah.private.v1\u0000$accountId\u0000$key');
  Future<void> writeBytes(String key, Uint8List bytes) {
    final copy = Uint8List.fromList(bytes);
    return _serial(() async {
      final name = _name(key);
      if (copy.length > maxValueBytes) {
        throw StateError('Private record is too large.');
      }
      await directory.create(recursive: true);
      final secret = await _key(create: true);
      final box = await _cipher.encrypt(
        copy,
        secretKey: secret,
        aad: _aad(key),
      );
      final keyBox = await _cipher.encrypt(
        utf8.encode(key),
        secretKey: secret,
        aad: utf8.encode('sah.index.v1\u0000$accountId\u0000$name'),
      );
      final encoded = utf8.encode(
        jsonEncode({
          'v': 1,
          'record': base64Encode(box.concatenation()),
          'key': base64Encode(keyBox.concatenation()),
        }),
      );
      final destination = File('${directory.path}/$name.sah');
      var total = 0;
      await for (final item in directory.list(followLinks: false)) {
        if (item is File && item.path != destination.path) {
          total += await item.length();
        }
      }
      if (total + encoded.length > maxTotalBytes) {
        throw StateError(
          'Private storage is full. Save or remove a draft before continuing.',
        );
      }
      final temporary = File('${destination.path}.tmp');
      await temporary.writeAsBytes(encoded, flush: true);
      await temporary.rename(destination.path);
    });
  }

  Future<Uint8List?> readBytes(String key) => _serial(() async {
    final file = File('${directory.path}/${_name(key)}.sah');
    if (!await file.exists()) return null;
    if (await file.length() > maxValueBytes * 2 + 4096) {
      throw const FormatException('Private record is invalid.');
    }
    try {
      final value =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      if (value['v'] != 1) throw const FormatException();
      final box = SecretBox.fromConcatenation(
        base64Decode(value['record'] as String),
        nonceLength: 12,
        macLength: 16,
      );
      final plain = await _cipher.decrypt(
        box,
        secretKey: await _key(),
        aad: _aad(key),
      );
      if (plain.length > maxValueBytes) throw const FormatException();
      return Uint8List.fromList(plain);
    } catch (_) {
      throw const FormatException('Private record could not be opened.');
    }
  });
  Future<Map<String, Object?>?> readJson(String key) async {
    final value = await readBytes(key);
    if (value == null) return null;
    if (value.length > 256 * 1024) {
      throw const FormatException('Private draft is too large.');
    }
    return Map<String, Object?>.from(jsonDecode(utf8.decode(value)) as Map);
  }

  Future<void> writeJson(String key, Map<String, Object?> value) {
    final bytes = Uint8List.fromList(utf8.encode(jsonEncode(value)));
    if (bytes.length > 256 * 1024) {
      throw const FormatException('Private draft is too large.');
    }
    return writeBytes(key, bytes);
  }

  Future<List<String>> keys() => _serial(() async {
    if (!await directory.exists()) return [];
    final result = <String>[];
    SecretKey? secret;
    await for (final item in directory.list(followLinks: false)) {
      if (item is! File || !item.path.endsWith('.sah')) continue;
      if (await item.length() > maxValueBytes * 2 + 4096) {
        throw const FormatException('Private record is invalid.');
      }
      final name = item.uri.pathSegments.last.replaceFirst('.sah', '');
      final value = jsonDecode(await item.readAsString()) as Map;
      secret ??= await _key();
      final box = SecretBox.fromConcatenation(
        base64Decode(value['key'] as String),
        nonceLength: 12,
        macLength: 16,
      );
      final key = utf8.decode(
        await _cipher.decrypt(
          box,
          secretKey: secret,
          aad: utf8.encode('sah.index.v1\u0000$accountId\u0000$name'),
        ),
      );
      if (_name(key) != name) {
        throw const FormatException('Private index is invalid.');
      }
      result.add(key);
    }
    return result;
  });
  Future<void> delete(String key) => _serial(() async {
    final file = File('${directory.path}/${_name(key)}.sah');
    if (await file.exists()) await file.delete();
  });

  Future<void> close() {
    _closing = true;
    return _tail.then((_) {
      _closed = true;
    });
  }

  Future<void> clear() {
    _closing = true;
    final existing = _clearFuture;
    if (existing != null) return existing;
    final attempt = _tail.then((_) async {
      try {
        if (await directory.exists()) await directory.delete(recursive: true);
      } finally {
        try {
          await secrets.delete(_keyName);
        } finally {
          _closed = true;
        }
      }
    });
    _clearFuture = attempt;
    unawaited(
      attempt.then<void>(
        (_) {},
        onError: (Object _, StackTrace stack) {
          _clearFuture = null;
        },
      ),
    );
    return attempt;
  }

  Future<void> flush() => _tail;
}
