import assert from 'node:assert/strict';
import { test } from 'node:test';
import { assertBackupSource, parseBackupArguments } from '../tool/backup.ts';

const project = 'https://abcdefghijklmnopqrst.supabase.co';
const args = ['create', '--key', '/private/keys/recovery.key', '--archive', '/private/archives/copy.sah-backup', '--project', project];

test('backup CLI defaults to help and accepts only explicit create/key/drill actions', () => {
  assert.deepEqual(parseBackupArguments([]), { action: 'help' });
  assert.deepEqual(parseBackupArguments(['--help']), { action: 'help' });
  assert.deepEqual(parseBackupArguments(['key', '--key', '/private/keys/recovery.key']), { action: 'key', key: '/private/keys/recovery.key' });
  assert.equal(parseBackupArguments(args).action, 'create');
  assert.equal(parseBackupArguments(['drill', ...args.slice(1)]).action, 'drill');
  for (const invalid of [['restore', ...args.slice(1)], ['create'], [...args, '--key', '/other.key'],
    [...args, '--database', 'postgres://example'], args.slice(0, -1), ['key', ...args.slice(1)]]) {
    assert.throws(() => parseBackupArguments(invalid));
  }
});

test('backup CLI rejects relative paths, co-located keys, noncanonical paths and unbound projects', () => {
  for (const [index, value] of [[2, 'relative.key'], [2, '/private/keys/../keys/recovery.key'], [2, '/private/keys/key.txt'],
    [4, '/private/keys/copy.sah-backup'], [4, '/private/archives/copy.json'], [4, '/private/archives/\ncopy.sah-backup'],
    [6, `${project}/`], [6, 'https://example.com'], [6, project.replace('https:', 'http:')]] as const) {
    const changed = [...args]; changed[index] = value;
    assert.throws(() => parseBackupArguments(changed));
  }
});

test('operator backup binds the Supabase direct or session-pooler connection to expected project', () => {
  const direct = 'postgresql://postgres:fictional@db.abcdefghijklmnopqrst.supabase.co:5432/postgres';
  const pooler = 'postgresql://postgres.abcdefghijklmnopqrst:fictional@aws-1-us-east-1.pooler.supabase.com:5432/postgres';
  assert.doesNotThrow(() => assertBackupSource(direct, project, project));
  assert.doesNotThrow(() => assertBackupSource(pooler, project, project));
  for (const source of [direct.replace('postgres:', 'safeathome_runtime:'), direct.replace('/postgres', '/other'),
    direct.replace('abcdefghijklmnopqrst', 'aaaaaaaaaaaaaaaaaaaa'), pooler.replace('.com:', '.com.attacker.test:'),
    pooler.replace('postgres.abcdefghijklmnopqrst:', 'postgres.aaaaaaaaaaaaaaaaaaaa:')]) {
    assert.throws(() => assertBackupSource(source, project, project));
  }
  assert.throws(() => assertBackupSource(direct, undefined, project));
  assert.throws(() => assertBackupSource(direct, 'https://aaaaaaaaaaaaaaaaaaaa.supabase.co', project));
});
