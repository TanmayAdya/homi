import type { Pool, PoolClient } from 'pg';
import { CAPACITY_LIMITS } from './capacity-limits.ts';
import { assertMigrationsCurrent } from './migrate.ts';

const TABLES = ['repository_quota', 'cases', 'matches', 'packets', 'form_answers', 'evidence', 'exports',
  'deleted_cases', 'closed_accounts', 'account_deletion_previews', 'auth_deletion_jobs', 'request_history'] as const;
type Table = typeof TABLES[number];
interface Quota { cases: number; evidence: number; activeExports: number; binaryBytes: number }
export interface CapacityReport {
  schemaVersion: '1';
  capturedAt: string;
  mode: 'read_only';
  rows: Record<Table, number>;
  payloads: { liveEvidence: number; evidenceTombstones: number; packetPayloads: number; packetTombstones: number;
    storedPdfPayloads: number; expiredPdfPayloads: number; exportTombstones: number; pendingAuthDeletions: number };
  maxima: { casesPerOwner: number; evidencePerOwner: number; packetsPerCase: number; exportsPerCase: number;
    answerSetsPerCase: number; requestStreamsPerCase: number; requestEventsPerStream: number };
  quota: { consistent: boolean; recorded: Quota; observed: Quota };
  limits: typeof CAPACITY_LIMITS;
  warnings: string[];
  physicalStorage: { databaseBytes: number; privateRelationsBytes: number; relationBytes: Record<Table, number>;
    measurement: 'approximate_physical_postgresql_bytes'; providerBillableUsage: null; providerLimitBytes: null };
}
export class CapacityReportError extends Error {
  constructor() { super('Capacity report failed. Check current migrations and complete operator visibility.'); this.name = 'CapacityReportError'; }
}
function check(value: unknown): asserts value { if (!value) throw new CapacityReportError(); }
function integer(value: unknown): number {
  check(typeof value === 'string' && /^(0|[1-9][0-9]*)$/.test(value));
  const result = Number(value); check(Number.isSafeInteger(result)); return result;
}

export async function assertCompleteOperatorVisibility(client: PoolClient): Promise<void> {
  await assertMigrationsCurrent(client);
  const result = await client.query(`SELECT c.relname,c.relkind,c.relrowsecurity,c.relforcerowsecurity,
    has_table_privilege(current_user,c.oid,'SELECT') AS can_select,
    (SELECT rolsuper OR rolbypassrls FROM pg_roles WHERE rolname=current_user) AS bypass,
    EXISTS (SELECT 1 FROM pg_policy p WHERE p.polrelid=c.oid AND p.polname='lifecycle_operator'
      AND p.polpermissive AND p.polcmd='*' AND p.polroles=ARRAY[c.relowner]
      AND pg_has_role(current_user,c.relowner,'USAGE')
      AND pg_get_expr(p.polqual,p.polrelid)='true' AND pg_get_expr(p.polwithcheck,p.polrelid)='true') AS full_policy,
    EXISTS (SELECT 1 FROM pg_policy p WHERE p.polrelid=c.oid AND NOT p.polpermissive
      AND p.polcmd IN ('*','r')
      AND (0=ANY(p.polroles) OR EXISTS (SELECT 1 FROM unnest(p.polroles) role_id
        WHERE role_id<>0 AND pg_has_role(current_user,role_id,'USAGE')))) AS restrictive
    FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
    WHERE n.nspname='safeathome_private' AND c.relkind NOT IN ('i','I') ORDER BY c.relname`);
  check(result.rows.length === TABLES.length);
  for (const row of result.rows) check(TABLES.includes(row.relname) && row.relkind === 'r'
    && row.relrowsecurity === true && row.relforcerowsecurity === true && row.can_select === true
    && (row.bypass === true || (row.full_policy === true && row.restrictive === false)));
}

export async function readCapacityReport(pool: Pool): Promise<CapacityReport> {
  let client: PoolClient | undefined; let broken = false;
  try {
    client = await pool.connect();
    await client.query('BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY');
    await assertCompleteOperatorVisibility(client);
    const rows = {} as Record<Table, number>, relationBytes = {} as Record<Table, number>;
    for (const table of TABLES) {
      const result = await client.query(`SELECT count(*)::text AS count,
        pg_total_relation_size('safeathome_private.${table}')::text AS bytes FROM safeathome_private.${table}`);
      rows[table] = integer(result.rows[0].count); relationBytes[table] = integer(result.rows[0].bytes);
    }
    const result = await client.query(`SELECT
      to_char(transaction_timestamp() AT TIME ZONE 'UTC','YYYY-MM-DD"T"HH24:MI:SS.US"Z"') AS captured_at,
      pg_database_size(current_database())::text AS database_bytes,
      q.case_count::text,q.asset_count::text,q.artifact_count::text,q.stored_bytes::text,
      (SELECT count(bytes)::text FROM safeathome_private.evidence) AS live_evidence,
      (SELECT count(packet)::text FROM safeathome_private.packets) AS packet_payloads,
      (SELECT count(bytes)::text FROM safeathome_private.exports) AS pdf_payloads,
      (SELECT count(*)::text FROM safeathome_private.exports WHERE bytes IS NOT NULL
        AND expires_at<=transaction_timestamp()) AS expired_pdf_payloads,
      (SELECT count(*)::text FROM safeathome_private.auth_deletion_jobs WHERE completed_at IS NULL) AS pending_auth_deletions,
      ((SELECT COALESCE(sum(octet_length(bytes)),0) FROM safeathome_private.evidence)
        +(SELECT COALESCE(sum(octet_length(bytes)),0) FROM safeathome_private.exports))::text AS binary_bytes,
      (SELECT COALESCE(max(n),0)::text FROM (SELECT count(*) n FROM safeathome_private.cases GROUP BY owner_id) t) AS cases_per_owner,
      (SELECT COALESCE(max(n),0)::text FROM (SELECT count(*) n FROM safeathome_private.evidence e
        JOIN safeathome_private.cases c USING(case_id) GROUP BY c.owner_id) t) AS evidence_per_owner,
      (SELECT COALESCE(max(n),0)::text FROM (SELECT count(*) n FROM safeathome_private.packets GROUP BY case_id) t) AS packets_per_case,
      (SELECT COALESCE(max(n),0)::text FROM (SELECT count(*) n FROM safeathome_private.exports GROUP BY case_id) t) AS exports_per_case,
      (SELECT COALESCE(max(n),0)::text FROM (SELECT count(*) n FROM safeathome_private.form_answers GROUP BY case_id) t) AS answers_per_case,
      (SELECT COALESCE(max(n),0)::text FROM (SELECT count(*) n FROM safeathome_private.request_history GROUP BY case_id) t) AS streams_per_case,
      (SELECT COALESCE(max(request_revision),0)::text FROM safeathome_private.request_history) AS events_per_stream
      FROM safeathome_private.repository_quota q WHERE singleton=true`);
    check(result.rows.length === 1 && rows.repository_quota === 1);
    const row = result.rows[0];
    check(typeof row.captured_at === 'string' && /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{6}Z$/.test(row.captured_at));
    const recorded: Quota = { cases: integer(row.case_count), evidence: integer(row.asset_count),
      activeExports: integer(row.artifact_count), binaryBytes: integer(row.stored_bytes) };
    const observed: Quota = { cases: rows.cases, evidence: rows.evidence,
      activeExports: integer(row.pdf_payloads), binaryBytes: integer(row.binary_bytes) };
    const consistent = (Object.keys(recorded) as (keyof Quota)[]).every(key => recorded[key] === observed[key]);
    const liveEvidence = integer(row.live_evidence), packetPayloads = integer(row.packet_payloads);
    const maxima = { casesPerOwner: integer(row.cases_per_owner), evidencePerOwner: integer(row.evidence_per_owner),
      packetsPerCase: integer(row.packets_per_case), exportsPerCase: integer(row.exports_per_case),
      answerSetsPerCase: integer(row.answers_per_case), requestStreamsPerCase: integer(row.streams_per_case),
      requestEventsPerStream: integer(row.events_per_stream) };
    const warnings: string[] = [];
    if (!consistent) warnings.push('quota_mismatch');
    for (const [key, value] of Object.entries({ ...observed, ...maxima })) {
      const limit = CAPACITY_LIMITS[key as keyof typeof CAPACITY_LIMITS];
      if (limit !== undefined && value >= limit) warnings.push(`${key}_at_or_above_limit`);
      else if (limit !== undefined && value >= Math.ceil(limit * 0.8)) warnings.push(`${key}_near_limit`);
    }
    if (integer(row.expired_pdf_payloads) > 0) warnings.push('expired_pdf_payloads_pending_retention');
    if (integer(row.pending_auth_deletions) > 0) warnings.push('auth_deletions_pending');
    const report: CapacityReport = { schemaVersion: '1', capturedAt: row.captured_at, mode: 'read_only', rows,
      payloads: { liveEvidence, evidenceTombstones: rows.evidence - liveEvidence, packetPayloads,
        packetTombstones: rows.packets - packetPayloads, storedPdfPayloads: observed.activeExports,
        expiredPdfPayloads: integer(row.expired_pdf_payloads), exportTombstones: rows.exports - observed.activeExports,
        pendingAuthDeletions: integer(row.pending_auth_deletions) },
      maxima, quota: { consistent, recorded, observed }, limits: { ...CAPACITY_LIMITS }, warnings,
      physicalStorage: { databaseBytes: integer(row.database_bytes),
        privateRelationsBytes: Object.values(relationBytes).reduce((sum, value) => sum + value, 0), relationBytes,
        measurement: 'approximate_physical_postgresql_bytes', providerBillableUsage: null, providerLimitBytes: null } };
    check(Number.isSafeInteger(report.physicalStorage.privateRelationsBytes));
    await client.query('COMMIT');
    return report;
  } catch {
    if (client) try { await client.query('ROLLBACK'); } catch { broken = true; }
    throw new CapacityReportError();
  } finally { client?.release(broken); }
}
