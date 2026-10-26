import assert from 'node:assert/strict';
import { chmod, link, mkdir, mkdtemp, readFile, realpath, rm, stat, symlink, truncate,
  writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test, { type TestContext } from 'node:test';
import { createBackupKey, MAX_BACKUP_PLAINTEXT_BYTES, openBackup, readBackupArchive,
  readBackupKey, sealBackup, writeBackupArchive } from '../src/storage/backup-archive.ts';

const ERROR = { message: 'Backup archive operation failed' };
const KEY = Buffer.alloc(32, 7);
const CONTENT = Buffer.from('{"private":"Fictional observation 🙂","revision":4}');

async function directory(t: TestContext): Promise<string> {
  const root = await realpath(tmpdir());
  const path = await mkdtemp(join(root, 'safeathome-backup-archive-'));
  await chmod(path, 0o700);
  t.after(() => rm(path, { recursive: true, force: true }));
  return path;
}

test('authenticated archive round trips private bytes and empty content without mutating inputs', () => {
  for (const original of [CONTENT, Buffer.alloc(0), Buffer.from([0, 255, 10, 13])]) {
    const content = Buffer.from(original);
    const key = Buffer.from(KEY);
    const archive = sealBackup(content, key);
    assert.equal(archive.length, content.length + 38);
    assert.deepEqual(openBackup(archive, key), original);
    assert.deepEqual(content, original);
    assert.deepEqual(key, KEY);
    if (original.length > 8) assert.equal(archive.includes(original), false);
  }
});

test('each encryption obtains a different nonce and ciphertext for the same key and content', () => {
  const first = sealBackup(CONTENT, KEY);
  const second = sealBackup(CONTENT, KEY);
  assert.notDeepEqual(first.subarray(10, 22), second.subarray(10, 22));
  assert.notDeepEqual(first, second);
  assert.deepEqual(openBackup(second, KEY), CONTENT);
});

test('wrong key, magic, version, nonce, ciphertext and authentication tag all fail closed', () => {
  const archive = sealBackup(CONTENT, KEY);
  assert.throws(() => openBackup(archive, Buffer.alloc(32, 9)), ERROR);
  for (const offset of [0, 8, 9, 10, 21, 22, archive.length - 17, archive.length - 1]) {
    const corrupt = Buffer.from(archive);
    corrupt[offset] ^= 1;
    assert.throws(() => openBackup(corrupt, KEY), ERROR);
  }
});

test('truncation and appended ciphertext cannot be accepted as a complete archive', () => {
  const archive = sealBackup(CONTENT, KEY);
  for (const length of [0, 9, 10, 21, 22, 37, 38, archive.length - 1]) {
    assert.throws(() => openBackup(archive.subarray(0, length), KEY), ERROR);
  }
  assert.throws(() => openBackup(Buffer.concat([archive, Buffer.from([0])]), KEY), ERROR);
});

test('key and buffer types are strict and oversize input fails before encryption or decryption', () => {
  const archive = sealBackup(CONTENT, KEY);
  for (const key of [Buffer.alloc(0), Buffer.alloc(31), Buffer.alloc(33),
    new Uint8Array(32) as unknown as Buffer]) {
    assert.throws(() => sealBackup(CONTENT, key), ERROR);
    assert.throws(() => openBackup(archive, key), ERROR);
  }
  assert.throws(() => sealBackup(new Uint8Array(4) as unknown as Buffer, KEY), ERROR);
  assert.throws(() => openBackup(new Uint8Array(37) as unknown as Buffer, KEY), ERROR);
  const oversized = Buffer.allocUnsafe(MAX_BACKUP_PLAINTEXT_BYTES + 39);
  assert.throws(() => sealBackup(oversized.subarray(0, MAX_BACKUP_PLAINTEXT_BYTES + 1), KEY), ERROR);
  assert.throws(() => sealBackup(oversized, KEY), ERROR);
  assert.throws(() => openBackup(oversized, KEY), ERROR);
});

test('key helper creates a private random raw key and refuses to overwrite it', async t => {
  const root = await directory(t);
  const first = join(root, 'first.key');
  const second = join(root, 'second.key');
  await createBackupKey(first);
  await createBackupKey(second);
  const key = await readBackupKey(first);
  assert.equal(key.length, 32);
  assert.notDeepEqual(key, await readBackupKey(second));
  assert.equal((await stat(first)).mode & 0o7777, 0o600);
  await assert.rejects(createBackupKey(first), ERROR);
  assert.deepEqual(await readBackupKey(first), key);
});

test('archive helpers persist ciphertext with 0600 mode and exclusive creation', async t => {
  const root = await directory(t);
  const path = join(root, 'snapshot.sahbackup');
  const archive = sealBackup(CONTENT, KEY);
  await writeBackupArchive(path, archive);
  assert.equal((await stat(path)).mode & 0o7777, 0o600);
  assert.deepEqual(await readBackupArchive(path), archive);
  assert.deepEqual(openBackup(await readBackupArchive(path), KEY), CONTENT);
  await assert.rejects(writeBackupArchive(path, sealBackup(Buffer.from('different'), KEY)), ERROR);
  assert.deepEqual(await readFile(path), archive);
});

test('archive writes detach caller-owned bytes before the first asynchronous filesystem operation', async t => {
  const root = await directory(t);
  const path = join(root, 'detached.sahbackup');
  const archive = sealBackup(CONTENT, KEY);
  const writing = writeBackupArchive(path, archive);
  archive.fill(0);
  await writing;
  assert.deepEqual(openBackup(await readBackupArchive(path), KEY), CONTENT);
});

test('concurrent exclusive key creation has exactly one winner', async t => {
  const root = await directory(t);
  const path = join(root, 'concurrent.key');
  const results = await Promise.allSettled([createBackupKey(path), createBackupKey(path)]);
  assert.equal(results.filter(result => result.status === 'fulfilled').length, 1);
  assert.equal(results.filter(result => result.status === 'rejected').length, 1);
  assert.equal((await readBackupKey(path)).length, 32);
});

test('helpers reject relative and nonnormalized paths without exposing file locations', async t => {
  const root = await directory(t);
  for (const path of ['relative.key', root + '/./invalid.key', root + '/child/../invalid.key',
    root + '/invalid.key/', root + '/invalid\0.key']) {
    await assert.rejects(createBackupKey(path), ERROR);
    await assert.rejects(readBackupKey(path), ERROR);
    await assert.rejects(writeBackupArchive(path, sealBackup(CONTENT, KEY)), ERROR);
    await assert.rejects(readBackupArchive(path), ERROR);
  }
  await assert.rejects(readBackupKey(join(root, 'PRIVATE-secret-missing.key')), error => {
    assert.ok(error instanceof Error);
    assert.deepEqual(Object.keys(error), []);
    assert.equal(error.message, ERROR.message);
    assert.equal(error.stack?.includes('PRIVATE-secret-missing'), false);
    return true;
  });
});

test('existing directories must be 0700 and are never chmodded by helpers', async t => {
  const root = await directory(t);
  const unsafe = join(root, 'public');
  await mkdir(unsafe, { mode: 0o755 });
  const path = join(unsafe, 'key');
  await assert.rejects(createBackupKey(path), ERROR);
  assert.equal((await stat(unsafe)).mode & 0o7777, 0o755);
  await assert.rejects(readBackupKey(path), ERROR);
  await assert.rejects(writeBackupArchive(join(root, 'missing', 'archive'), sealBackup(CONTENT, KEY)), ERROR);
});

test('read helpers reject permissive, special-mode and incorrectly sized secret files', async t => {
  const root = await directory(t);
  const path = join(root, 'key');
  await writeFile(path, KEY, { mode: 0o600 });
  for (const mode of [0o644, 0o640, 0o660, 0o700, 0o4600]) {
    await chmod(path, mode);
    await assert.rejects(readBackupKey(path), ERROR);
  }
  await chmod(path, 0o600);
  for (const length of [0, 31, 33]) {
    await writeFile(path, Buffer.alloc(length));
    await assert.rejects(readBackupKey(path), ERROR);
  }
  await assert.rejects(readBackupKey(root), ERROR);
});

test('final-component symlinks and hardlinks cannot read or replace another file', async t => {
  const root = await directory(t);
  const key = join(root, 'original.key');
  const alias = join(root, 'alias.key');
  await createBackupKey(key);
  const original = await readBackupKey(key);
  await symlink(key, alias);
  await assert.rejects(readBackupKey(alias), ERROR);
  await assert.rejects(createBackupKey(alias), ERROR);
  assert.deepEqual(await readBackupKey(key), original);
  await rm(alias);
  await link(key, alias);
  await assert.rejects(readBackupKey(alias), ERROR);
  await assert.rejects(readBackupKey(key), ERROR);
});

test('symlink directory components and writable nonsticky ancestors are rejected', async t => {
  const root = await directory(t);
  const real = join(root, 'real');
  const alias = join(root, 'alias');
  await mkdir(real, { mode: 0o700 });
  await createBackupKey(join(real, 'key'));
  await symlink(real, alias);
  await assert.rejects(readBackupKey(join(alias, 'key')), ERROR);
  await assert.rejects(createBackupKey(join(alias, 'new.key')), ERROR);
  await chmod(root, 0o777);
  await assert.rejects(readBackupKey(join(real, 'key')), ERROR);
  await assert.rejects(createBackupKey(join(real, 'new.key')), ERROR);
  await chmod(root, 0o700);
});

test('archive file size is bounded before reading and corrupt envelopes are rejected', async t => {
  const root = await directory(t);
  const path = join(root, 'archive');
  await writeFile(path, Buffer.alloc(38), { mode: 0o600 });
  await assert.rejects(readBackupArchive(path), ERROR);
  await truncate(path, 0);
  await assert.rejects(readBackupArchive(path), ERROR);
  await truncate(path, MAX_BACKUP_PLAINTEXT_BYTES + 39);
  await assert.rejects(readBackupArchive(path), ERROR);
  await assert.rejects(writeBackupArchive(join(root, 'invalid'), Buffer.alloc(37)), ERROR);
});

test('archive read also enforces private permissions and rejects symlink files', async t => {
  const root = await directory(t);
  const path = join(root, 'archive');
  const alias = join(root, 'alias');
  await writeBackupArchive(path, sealBackup(CONTENT, KEY));
  await symlink(path, alias);
  await assert.rejects(readBackupArchive(alias), ERROR);
  await assert.rejects(writeBackupArchive(alias, sealBackup(CONTENT, KEY)), ERROR);
  await chmod(path, 0o644);
  await assert.rejects(readBackupArchive(path), ERROR);
});
