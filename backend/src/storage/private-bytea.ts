import type { PoolClient } from 'pg';

export const PRIVATE_BYTEA_CHUNK_BYTES = 1024 * 1024;
const sources = {
  evidence: { column: 'evidence_id', maximum: 24 * 1024 * 1024 },
  exports: { column: 'artifact_id', maximum: 32 * 1024 * 1024 },
} as const;
type Source = keyof typeof sources;

export async function readPrivateBytea(client: Pick<PoolClient, 'query'>, source: Source,
  caseId: string, identity: string, expectedBytes: number): Promise<Uint8Array> {
  if (!Object.hasOwn(sources, source) || !Number.isSafeInteger(expectedBytes)
    || expectedBytes < 1 || expectedBytes > sources[source].maximum) throw new Error('Invalid private binary bounds.');
  const count = Math.ceil(expectedBytes / PRIVATE_BYTEA_CHUNK_BYTES);
  const result = await client.query<{ chunk_index: unknown; chunk: unknown }>(`
    SELECT chunk_index, substring(payload.bytes FROM chunk_index * $4::int + 1 FOR $4::int) AS chunk
    FROM safeathome_private.${source} AS payload
    CROSS JOIN generate_series(0, ($3::int - 1) / $4::int) AS chunk_index
    WHERE payload.case_id=$1 AND payload.${sources[source].column}=$2
      AND octet_length(payload.bytes)=$3::int
    ORDER BY chunk_index`, [caseId, identity, expectedBytes, PRIVATE_BYTEA_CHUNK_BYTES]);
  if (result.rows.length !== count) throw new Error('Incomplete private binary payload.');
  const bytes = new Uint8Array(expectedBytes);
  for (let index = 0; index < count; index++) {
    const row = result.rows[index], expectedChunk = Math.min(PRIVATE_BYTEA_CHUNK_BYTES, expectedBytes - index * PRIVATE_BYTEA_CHUNK_BYTES);
    if (row.chunk_index !== index || !(row.chunk instanceof Uint8Array) || row.chunk.byteLength !== expectedChunk) {
      throw new Error('Invalid private binary chunk.');
    }
    bytes.set(row.chunk, index * PRIVATE_BYTEA_CHUNK_BYTES);
  }
  return bytes;
}
