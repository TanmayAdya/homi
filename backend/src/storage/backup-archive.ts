import { createCipheriv, createDecipheriv, randomBytes } from 'node:crypto';
import { constants, type Stats } from 'node:fs';
import { lstat, open, type FileHandle } from 'node:fs/promises';
import { dirname, isAbsolute, join, normalize, parse, sep } from 'node:path';

export const MAX_BACKUP_PLAINTEXT_BYTES = 128 * 1024 * 1024;
const MAGIC = Buffer.from('SAHBACKUP', 'ascii');
const VERSION = 1;
const NONCE_BYTES = 12;
const TAG_BYTES = 16;
const HEADER_BYTES = MAGIC.length + 1 + NONCE_BYTES;
const OVERHEAD_BYTES = HEADER_BYTES + TAG_BYTES;
const MAX_ARCHIVE_BYTES = MAX_BACKUP_PLAINTEXT_BYTES + OVERHEAD_BYTES;
const FAILURE = 'Backup archive operation failed';

function fail(): never { throw new Error(FAILURE); }

function validKey(key: Buffer): void {
  if (!Buffer.isBuffer(key) || key.length !== 32) fail();
}

function validEnvelope(archive: Buffer): void {
  if (!Buffer.isBuffer(archive) || archive.length < OVERHEAD_BYTES ||
      archive.length > MAX_ARCHIVE_BYTES ||
      !archive.subarray(0, MAGIC.length).equals(MAGIC) || archive[MAGIC.length] !== VERSION) fail();
}

export function sealBackup(plaintext: Buffer, key: Buffer): Buffer {
  try {
    validKey(key);
    if (!Buffer.isBuffer(plaintext) || plaintext.length > MAX_BACKUP_PLAINTEXT_BYTES) fail();
    const nonce = randomBytes(NONCE_BYTES);
    const header = Buffer.concat([MAGIC, Buffer.from([VERSION]), nonce]);
    const cipher = createCipheriv('aes-256-gcm', key, nonce, { authTagLength: TAG_BYTES });
    cipher.setAAD(header);
    return Buffer.concat([header, cipher.update(plaintext), cipher.final(), cipher.getAuthTag()]);
  } catch { fail(); }
}

export function openBackup(archive: Buffer, key: Buffer): Buffer {
  let provisional: Buffer | undefined;
  try {
    validKey(key);
    validEnvelope(archive);
    const header = archive.subarray(0, HEADER_BYTES);
    const decipher = createDecipheriv('aes-256-gcm', key,
      header.subarray(MAGIC.length + 1), { authTagLength: TAG_BYTES });
    decipher.setAAD(header);
    decipher.setAuthTag(archive.subarray(archive.length - TAG_BYTES));
    provisional = decipher.update(archive.subarray(HEADER_BYTES, archive.length - TAG_BYTES));
    const final = decipher.final();
    return Buffer.concat([provisional, final]);
  } catch { return fail(); }
  finally { provisional?.fill(0); }
}

function userId(): number {
  if (!process.getuid) fail();
  return process.getuid();
}

function safePath(path: string): void {
  if (typeof path !== 'string' || !isAbsolute(path) || normalize(path) !== path ||
      path === parse(path).root || path.includes('\0') || path.endsWith(sep)) fail();
}

async function privateParent(path: string): Promise<Stats> {
  safePath(path);
  const uid = userId();
  const parent = dirname(path);
  const root = parse(parent).root;
  let current = root;
  let result = await lstat(root);
  const parts = parent.slice(root.length).split(sep).filter(Boolean);
  for (let index = -1; index < parts.length; index++) {
    if (index >= 0) {
      current = join(current, parts[index]);
      result = await lstat(current);
    }
    if (!result.isDirectory() || result.isSymbolicLink() ||
        (result.uid !== uid && result.uid !== 0)) fail();
    const writableByOthers = (result.mode & 0o022) !== 0;
    if (writableByOthers && !(result.uid === 0 && (result.mode & 0o1000) !== 0)) fail();
  }
  if (result.uid !== uid || (result.mode & 0o7777) !== 0o700) fail();
  return result;
}

function sameFile(first: Stats, second: Stats): boolean {
  return first.dev === second.dev && first.ino === second.ino;
}

function privateFile(stats: Stats, minimum: number, maximum: number): void {
  if (!stats.isFile() || stats.uid !== userId() || stats.nlink !== 1 ||
      (stats.mode & 0o7777) !== 0o600 || !Number.isSafeInteger(stats.size) ||
      stats.size < minimum || stats.size > maximum) fail();
}

async function closeQuietly(handle: FileHandle | undefined): Promise<void> {
  try { await handle?.close(); } catch {   }
}

async function writePrivate(path: string, bytes: Buffer): Promise<void> {
  let handle: FileHandle | undefined;
  let parentHandle: FileHandle | undefined;
  try {
    const parent = await privateParent(path);
    handle = await open(path, constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL |
      constants.O_NOFOLLOW | constants.O_NONBLOCK, 0o600);
    const created = await handle.stat();
    privateFile(created, 0, 0);
    if (!sameFile(parent, await privateParent(path))) fail();
    await handle.writeFile(bytes);
    await handle.sync();
    const written = await handle.stat();
    privateFile(written, bytes.length, bytes.length);
    if (!sameFile(parent, await privateParent(path)) || !sameFile(written, await lstat(path))) fail();
    parentHandle = await open(dirname(path), constants.O_RDONLY | constants.O_DIRECTORY | constants.O_NOFOLLOW);
    if (!sameFile(parent, await parentHandle.stat())) fail();
    await parentHandle.sync();
    await parentHandle.close();
    parentHandle = undefined;
    await handle.close();
    handle = undefined;
  } catch { fail(); }
  finally {
    await closeQuietly(parentHandle);
    await closeQuietly(handle);
  }
}

async function readPrivate(path: string, minimum: number, maximum: number): Promise<Buffer> {
  let handle: FileHandle | undefined;
  let bytes: Buffer | undefined;
  let succeeded = false;
  try {
    const parent = await privateParent(path);
    const named = await lstat(path);
    privateFile(named, minimum, maximum);
    handle = await open(path, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
    const before = await handle.stat();
    privateFile(before, minimum, maximum);
    if (!sameFile(named, before) || !sameFile(parent, await privateParent(path))) fail();
    bytes = Buffer.alloc(before.size);
    let offset = 0;
    while (offset < bytes.length) {
      const { bytesRead } = await handle.read(bytes, offset, Math.min(65536, bytes.length - offset), offset);
      if (bytesRead === 0) fail();
      offset += bytesRead;
    }
    const extra = Buffer.alloc(1);
    if ((await handle.read(extra, 0, 1, offset)).bytesRead !== 0) fail();
    const after = await handle.stat();
    privateFile(after, minimum, maximum);
    if (!sameFile(before, after) || before.size !== after.size || before.mtimeMs !== after.mtimeMs ||
        before.ctimeMs !== after.ctimeMs || !sameFile(parent, await privateParent(path)) ||
        !sameFile(after, await lstat(path))) fail();
    await handle.close();
    handle = undefined;
    succeeded = true;
    return bytes;
  } catch { return fail(); }
  finally {
    if (!succeeded) bytes?.fill(0);
    await closeQuietly(handle);
  }
}

export { readPrivate as readPrivateBackupFile, writePrivate as writePrivateBackupFile };

export async function createBackupKey(path: string): Promise<void> {
  const key = randomBytes(32);
  try { await writePrivate(path, key); }
  finally { key.fill(0); }
}

export async function readBackupKey(path: string): Promise<Buffer> {
  return readPrivate(path, 32, 32);
}

export async function writeBackupArchive(path: string, archive: Buffer): Promise<void> {
  validEnvelope(archive);
  const owned = Buffer.from(archive);
  try { await writePrivate(path, owned); }
  finally { owned.fill(0); }
}

export async function readBackupArchive(path: string): Promise<Buffer> {
  const archive = await readPrivate(path, OVERHEAD_BYTES, MAX_ARCHIVE_BYTES);
  try { validEnvelope(archive); return archive; }
  catch { archive.fill(0); fail(); }
}
