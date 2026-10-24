import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { test } from 'node:test';
import type { PoolClient } from 'pg';
import { PRIVATE_BYTEA_CHUNK_BYTES as CHUNK, readPrivateBytea } from '../src/storage/private-bytea.ts';

function client(rows: unknown[], inspect?: (sql: string, values: unknown[]) => void) {
  let calls = 0;
  return { pool: { query: async (sql: string, values: unknown[]) => {
    calls++; inspect?.(sql, values); return { rows };
  } } as unknown as Pick<PoolClient, 'query'>, calls: () => calls };
}
function chunks(bytes: Uint8Array) {
  return Array.from({ length: Math.ceil(bytes.length / CHUNK) }, (_, index) => ({ chunk_index: index,
    chunk: bytes.slice(index * CHUNK, Math.min(bytes.length, (index + 1) * CHUNK)) }));
}

test('private bytea chunks preserve arbitrary binary bytes at boundaries with one parameterized query', async () => {
  for (const length of [1, CHUNK - 1, CHUNK, CHUNK + 1, 2 * CHUNK + 71]) {
    const expected = new Uint8Array(length);
    for (let index = 0; index < length; index++) expected[index] = (index * 73 + 19) & 255;
    const input = chunks(expected);
    const fake = client(input, (sql, values) => {
      assert.match(sql, /FROM safeathome_private\.evidence AS payload/);
      assert.match(sql, /payload\.evidence_id=\$2/); assert.match(sql, /octet_length\(payload\.bytes\)=\$3::int/);
      assert.match(sql, /generate_series\(0, \(\$3::int - 1\) \/ \$4::int\)/); assert.match(sql, /ORDER BY chunk_index/);
      assert.deepEqual(values, ["fictional-case';--", "fictional-photo';--", length, CHUNK]);
      assert.equal(sql.includes('fictional-'), false);
    });
    const actual = await readPrivateBytea(fake.pool, 'evidence', "fictional-case';--", "fictional-photo';--", length);
    assert.deepEqual(actual, expected); assert.equal(fake.calls(), 1);
    input[0].chunk[0] ^= 255; assert.equal(actual[0], expected[0]);
    actual[length - 1] ^= 255; assert.equal(input.at(-1)!.chunk.at(-1), length === 1 ? expected[0] ^ 255 : expected.at(-1));
  }
});

test('private bytea supports the exact evidence/PDF limits without increasing chunk size', async () => {
  for (const [source, length] of [['evidence', 24 * CHUNK], ['exports', 32 * CHUNK]] as const) {
    const rows = Array.from({ length: length / CHUNK }, (_, index) => ({ chunk_index: index, chunk: Buffer.alloc(CHUNK, index) }));
    const expectedHash = createHash('sha256'); rows.forEach(row => expectedHash.update(row.chunk));
    const fake = client(rows, sql => { assert.match(sql, new RegExp(`payload\\.${source === 'exports' ? 'artifact_id' : 'evidence_id'}=\\$2`)); });
    const actual = await readPrivateBytea(fake.pool, source, 'fictional-case', 'fictional-file', length);
    assert.equal(actual.length, length); assert.equal(createHash('sha256').update(actual).digest('hex'), expectedHash.digest('hex'));
    assert.equal(fake.calls(), 1);
  }
});

test('invalid metadata sizes and source identities fail before allocating or querying', async () => {
  const fake = client([]);
  for (const value of [0, -1, 1.5, NaN, Infinity, Number.MAX_SAFE_INTEGER, 24 * CHUNK + 1]) {
    await assert.rejects(readPrivateBytea(fake.pool, 'evidence', 'fictional-case', 'fictional-file', value), /binary bounds/);
  }
  await assert.rejects(readPrivateBytea(fake.pool, 'exports', 'fictional-case', 'fictional-file', 32 * CHUNK + 1), /binary bounds/);
  for (const source of ['constructor', '__proto__', 'evidence; DROP TABLE cases']) {
    await assert.rejects(readPrivateBytea(fake.pool, source as 'evidence', 'fictional-case', 'fictional-file', 1), /binary bounds/);
  }
  assert.equal(fake.calls(), 0);
});

test('missing, duplicated, reordered, truncated and oversized private chunks fail closed', async () => {
  const first = { chunk_index: 0, chunk: new Uint8Array(CHUNK) }, final = { chunk_index: 1, chunk: new Uint8Array(3) };
  for (const rows of [[], [first], [first, final, final], [final, first], [first, { ...final, chunk_index: 0 }],
    [first, { ...final, chunk_index: '1' }], [first, { ...final, chunk: null }], [first, { ...final, chunk: '\\x010203' }],
    [first, { ...final, chunk: new Uint8Array(2) }], [first, { ...final, chunk: new Uint8Array(4) }],
    [{ ...first, chunk: new Uint8Array(CHUNK + 1) }, final]]) {
    const fake = client(rows);
    await assert.rejects(readPrivateBytea(fake.pool, 'evidence', 'fictional-case', 'fictional-file', CHUNK + 3));
    assert.equal(fake.calls(), 1);
  }
});

test('database failure is propagated without switching protocols or issuing additional queries', async () => {
  let calls = 0; const failure = new Error('synthetic transaction failure');
  const pool = { query: async () => { calls++; throw failure; } } as unknown as Pick<PoolClient, 'query'>;
  await assert.rejects(readPrivateBytea(pool, 'exports', 'fictional-case', 'fictional-file', 5), error => error === failure);
  assert.equal(calls, 1);
});
