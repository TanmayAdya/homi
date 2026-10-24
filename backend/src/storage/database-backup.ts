import { parseSavedProgramIntake } from '../programs/intake.ts';
import { parseAssessmentMetadata, parseAssessmentRecord } from '../assessment/metadata.ts';
import { parseAnnotations, annotationsBound } from '../assessment/annotations.ts';
import { createHash } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import type { Pool, PoolClient } from 'pg';
import { parseCaseDraft } from '../cases/validation.ts';
import { evidenceIdentifier, evidenceInstant, parseEvidenceDescriptor, parseEvidenceAsset, parseEvidenceSelections } from '../evidence/validation.ts';
import { parseStoredExportArtifactMetadata as parseExportArtifactMetadata } from '../exports/validation.ts';
import { parseSavedFormAnswers } from '../forms/form-answers.ts';
import { instantMicros } from '../packets.ts';
import { parseRequestHistory } from '../requests/tracking.ts';
import { assertMigrationsCurrent } from './migrate.ts';
import type { CaseSnapshot } from '../types.ts';

export const MAX_DATABASE_BACKUP_BYTES = 128 * 1024 * 1024;
export const MAX_DATABASE_BACKUP_ROWS_PER_TABLE = 10_000;
const S = 'safeathome_private';
const FORMAT = 'safeathome-app-data-v1';
const HASH = /^[a-f0-9]{64}$/;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
const KEY = /^[A-Za-z0-9_-]{8,128}$/;
type Row = Record<string, unknown>;
type ColumnType = 'text' | 'integer' | 'boolean' | 'json' | 'bytes' | 'time';
interface Table { columns: Record<string, ColumnType>; key: string[] }
const TABLES = {
  repository_quota: { columns: { singleton: 'boolean', case_count: 'integer', asset_count: 'integer', artifact_count: 'integer', stored_bytes: 'integer' }, key: ['singleton'] },
  cases: { columns: { case_id: 'text', owner_id: 'text', revision: 'integer', catalog_revision: 'integer', snapshot: 'json' }, key: ['case_id'] },
  matches: { columns: { case_id: 'text', response: 'json' }, key: ['case_id'] },
  packets: { columns: { case_id: 'text', generation_key: 'text', packet_id: 'text', context_fingerprint: 'text', packet: 'json' }, key: ['case_id', 'generation_key'] },
  form_answers: { columns: { case_id: 'text', program_id: 'text', answer_revision: 'integer', record: 'json' }, key: ['case_id', 'program_id'] },
  evidence: { columns: { case_id: 'text', evidence_id: 'text', finding_id: 'text', revision: 'integer', prepared_at: 'text', descriptor: 'json', bytes: 'bytes' }, key: ['case_id', 'evidence_id'] },
  program_intake: { columns:{ case_id:'text', program_id:'text', record:'json' }, key:['case_id','program_id'] },
  assessment_metadata: { columns: { case_id:'text', record:'json' }, key:['case_id'] },
  evidence_annotations: { columns: { case_id:'text', evidence_id:'text', record:'json' }, key:['case_id','evidence_id'] },
  exports: { columns: { artifact_id: 'text', case_id: 'text', generation_key: 'text', bindings: 'json', metadata: 'json', bytes: 'bytes', invalidated: 'boolean', last_checked_at: 'text', expires_at: 'time' }, key: ['artifact_id'] },
  deleted_cases: { columns: { case_hash: 'text', owner_hash: 'text', revision: 'integer', catalog_revision: 'integer' }, key: ['case_hash'] },
  closed_accounts: { columns: { owner_hash: 'text', closed_at: 'time', receipt_hash: 'text', receipt_expires_at: 'time', auth_deleted_at: 'time' }, key: ['owner_hash'] },
  account_deletion_previews: { columns: { owner_hash: 'text', token_hash: 'text', fingerprint: 'text', expires_at: 'time' }, key: ['owner_hash'] },
  auth_deletion_jobs: { columns: { job_id: 'text', owner_hash: 'text', raw_user_id: 'text', completed_at: 'time', next_attempt_at: 'time', lease_token: 'text', lease_until: 'time' }, key: ['job_id'] },
  request_history: { columns: { case_id: 'text', program_id: 'text', request_revision: 'integer', record: 'json' }, key: ['case_id', 'program_id'] },
} as const satisfies Record<string, Table>;
type TableName = keyof typeof TABLES;
const NAMES = Object.keys(TABLES) as TableName[];
type RowCounts = Record<TableName, number>;
interface ManifestEntry { version: string; checksum: string }
interface Archive { format: typeof FORMAT; projectOrigin: string; capturedAt: string; migrations: ManifestEntry[]; tables: Record<TableName, Row[]> }
export interface BackupSummary { capturedAt: string; sourceRows: RowCounts; bytes: number }
export interface BackupDrillReport {
  quarantined: true;
  sourceRows: RowCounts;
  restoredRows: RowCounts;
  cleared: { matches: number; packetPayloads: number; exportPayloads: number; previews: number; receiptCapabilities: number; workerLeases: number };
  storedBytes: number;
}
export class DatabaseBackupError extends Error {
  constructor() { super('Application backup validation or isolated restore failed.'); this.name = 'DatabaseBackupError'; }
}
function check(value: unknown): asserts value { if (!value) throw new DatabaseBackupError(); }
function object(value: unknown): value is Row { return value !== null && typeof value === 'object' && !Array.isArray(value); }
function exact(value: unknown, keys: readonly string[]): value is Row {
  return object(value) && Object.keys(value).length === keys.length && keys.every(key => Object.hasOwn(value, key));
}
function integer(value: unknown, min = 0, max = Number.MAX_SAFE_INTEGER): number {
  check(typeof value === 'string' && /^(0|[1-9][0-9]*)$/.test(value));
  const n = Number(value); check(Number.isSafeInteger(n) && n >= min && n <= max); return n;
}
function origin(value: unknown): asserts value is string {
  check(typeof value === 'string' && value.length <= 2048);
  const parsed = new URL(value);
  check(parsed.protocol === 'https:' && parsed.origin === value && !parsed.username && !parsed.password);
}
function hash(value: string) { return createHash('sha256').update(value).digest('hex'); }
function digest(value: unknown): asserts value is string { check(typeof value === 'string' && HASH.test(value)); }
function identifier(value: unknown): asserts value is string { check(evidenceIdentifier(value)); }
function time(value: unknown): asserts value is string { check(evidenceInstant(value)); }
function unique(rows: Row[], columns: string[], nullable = false) {
  const seen = new Set<string>();
  for (const row of rows) {
    if (nullable && columns.some(column => row[column] === null)) continue;
    const key = JSON.stringify(columns.map(column => row[column])); check(!seen.has(key)); seen.add(key);
  }
}
function bytes(value: unknown, maximum: number): Buffer {
  check(typeof value === 'string' && value.length <= Math.ceil(maximum / 3) * 4
    && value.length % 4 === 0 && !/[^A-Za-z0-9+/=]/.test(value));
  const result = Buffer.from(value, 'base64'); check(result.length >= 8 && result.length <= maximum && result.toString('base64') === value);
  return result;
}
async function manifest(): Promise<ManifestEntry[]> {
  return Promise.all([
    ['001', '001_private_repository.sql'], ['002', '002_retention_deletion.sql'], ['003', '003_request_tracking.sql'], ['004','004_assessment_annotations.sql'], ['005','005_program_intake.sql'],
  ].map(async ([version, filename]) => ({ version,
    checksum: createHash('sha256').update(await readFile(new URL(`../../migrations/${filename}`, import.meta.url))).digest('hex') })));
}
function counts(tables: Archive['tables']): RowCounts {
  return Object.fromEntries(NAMES.map(name => [name, tables[name].length])) as RowCounts;
}

async function parseArchive(plaintext: Buffer, expectedProjectOrigin: string): Promise<Archive> {
  check(Buffer.isBuffer(plaintext) && plaintext.length > 0 && plaintext.length <= MAX_DATABASE_BACKUP_BYTES);
  const raw: unknown = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(plaintext));
  origin(expectedProjectOrigin);
  check(exact(raw, ['format', 'projectOrigin', 'capturedAt', 'migrations', 'tables']) && raw.format === FORMAT
    && raw.projectOrigin === expectedProjectOrigin);
  time(raw.capturedAt);
  const expected = await manifest();
  check(Array.isArray(raw.migrations) && raw.migrations.length === expected.length && raw.migrations.every((entry, index) =>
    exact(entry, ['version', 'checksum']) && entry.version === expected[index].version && entry.checksum === expected[index].checksum));
  check(exact(raw.tables, NAMES));
  const tables = raw.tables as Archive['tables'];
  for (const name of NAMES) {
    const table: Table = TABLES[name]; const rows = tables[name];
    check(Array.isArray(rows) && rows.length <= MAX_DATABASE_BACKUP_ROWS_PER_TABLE);
    for (const row of rows) {
      check(exact(row, Object.keys(table.columns)));
      for (const [column, kind] of Object.entries(table.columns)) {
        const value = row[column];
        if (value === null) continue;
        if (kind === 'integer') integer(value);
        else if (kind === 'boolean') check(typeof value === 'boolean');
        else if (kind === 'json') check(object(value));
        else if (kind === 'time') time(value);
        else check(typeof value === 'string');
      }
    }
    unique(rows, table.key);
  }
  check(tables.repository_quota.length === 1 && tables.repository_quota[0].singleton === true
    && tables.cases.length <= 64 && tables.evidence.length <= 64);
  const cases = new Map<string, Row>();
  for (const row of tables.cases) {
    identifier(row.case_id); identifier(row.owner_id); const rev = integer(row.revision, 1); integer(row.catalog_revision);
    check(object(row.snapshot)); const { revision, ...draft } = row.snapshot;
    const parsed = parseCaseDraft(draft, false, 1);
    check(revision === rev && parsed.caseId === row.case_id); cases.set(row.case_id, row);
  }
  for (const name of ['matches', 'packets', 'form_answers', 'evidence', 'exports', 'request_history', 'assessment_metadata', 'evidence_annotations', 'program_intake'] as const) {
    for (const row of tables[name]) { identifier(row.case_id); check(cases.has(row.case_id)); }
  }
  for (const row of tables.matches) check(object(row.response));
  for (const row of tables.packets) {
    check(typeof row.generation_key === 'string' && KEY.test(row.generation_key)); identifier(row.packet_id);
    digest(row.context_fingerprint); check(row.packet === null || object(row.packet));
  }
  unique(tables.packets, ['packet_id']);
  for (const row of tables.form_answers) {
    identifier(row.program_id); const revision = integer(row.answer_revision, 1);
    const saved = parseSavedFormAnswers(row.record);
    check(saved.caseId === row.case_id && saved.programId === row.program_id && saved.answerRevision === revision
      && saved.caseRevision <= integer(cases.get(String(row.case_id))!.revision, 1));
  }
  let evidenceBytes = 0; let exportBytes = 0; let activeExports = 0;
  for (const row of tables.evidence) {
    identifier(row.evidence_id); identifier(row.finding_id); const revision = integer(row.revision, 1); time(row.prepared_at);
    check((row.descriptor === null) === (row.bytes === null));
    if (row.descriptor === null) continue;
    const body = bytes(row.bytes, 24 * 1024 * 1024);
    const asset = parseEvidenceAsset({ descriptor: row.descriptor, bytes: body });
    check(asset.descriptor.caseId === row.case_id && asset.descriptor.evidenceId === row.evidence_id
      && asset.descriptor.findingId === row.finding_id && asset.descriptor.evidenceRevision === revision
      && asset.descriptor.preparedAt === row.prepared_at);
    const snapshot = cases.get(String(row.case_id))!.snapshot as { findings: { id: string; evidenceIds: string[] }[] };
    check(snapshot.findings.some(finding => finding.id === row.finding_id && finding.evidenceIds.includes(String(row.evidence_id))));
    evidenceBytes += body.length;
  }
  for(const row of tables.program_intake){const saved=parseSavedProgramIntake(row.record);check(saved.caseId===row.case_id&&saved.programId===row.program_id&&saved.caseRevision<=integer(cases.get(String(row.case_id))!.revision,1)&&saved.updatedBy===cases.get(String(row.case_id))!.owner_id);}
  for (const row of tables.assessment_metadata) {
    const record = parseAssessmentRecord(row.record), parent = cases.get(String(row.case_id))!;
    const revision = integer(parent.revision, 1);
    check(record.caseId === row.case_id && record.caseRevision <= revision
      && record.history.every(event => event.recordedBy === parent.owner_id));
    if (record.caseRevision === revision) parseAssessmentMetadata(record.metadata, parent.snapshot as CaseSnapshot);
  }
  for(const row of tables.evidence_annotations){
    const record=parseAnnotations(row.record);check(record.caseId===row.case_id&&record.evidenceId===row.evidence_id);
    if(record.reviewState==='reviewed')check(record.reviewedBy===cases.get(String(row.case_id))!.owner_id&&record.reviewedCaseRevision!<=integer(cases.get(String(row.case_id))!.revision,1));
    const evidence=tables.evidence.find(e=>e.case_id===row.case_id&&e.evidence_id===row.evidence_id);check(evidence);
    if(record.marks.length)check(evidence.descriptor!==null&&annotationsBound(record,parseEvidenceDescriptor(evidence.descriptor)));
  }
  for (const row of tables.exports) {
    identifier(row.artifact_id); check(typeof row.generation_key === 'string' && KEY.test(row.generation_key));
    check(typeof row.invalidated === 'boolean'); time(row.last_checked_at); time(row.expires_at);
    check((row.metadata === null) === (row.bindings === null));
    if (row.metadata === null) { check(row.invalidated === true && row.bytes === null); continue; }
    const metadata = parseExportArtifactMetadata(row.metadata);
    check(metadata.caseId === row.case_id && metadata.artifactId === row.artifact_id
      && instantMicros(metadata.expiresAt) === instantMicros(row.expires_at));
    const binding = row.bindings;
    check(exact(binding, ['userId', 'revision', 'caseFingerprint', 'programId', 'catalogRevision', 'answersFingerprint', 'contextFingerprint', 'selections']));
    identifier(binding.userId); identifier(binding.programId); digest(binding.caseFingerprint); digest(binding.contextFingerprint);
    if (binding.answersFingerprint !== null) digest(binding.answersFingerprint);
    check(binding.userId === cases.get(String(row.case_id))!.owner_id && binding.revision === metadata.caseRevision
      && binding.programId === metadata.programId && binding.catalogRevision === metadata.evidenceCatalogRevision
      && binding.contextFingerprint === metadata.exportContextId);
    const selections = parseEvidenceSelections(binding.selections);
    check(selections.length === metadata.selectedEvidence.length && selections.every((selection, index) =>
      selection.evidenceId === metadata.selectedEvidence[index].evidenceId
      && selection.expectedEvidenceRevision === metadata.selectedEvidence[index].evidenceRevision));
    if (row.invalidated) check(row.bytes === null);
    else {
      const body = bytes(row.bytes, 32 * 1024 * 1024);
      check(body.length === metadata.byteLength && body.subarray(0, 5).toString('ascii') === '%PDF-'
        && createHash('sha256').update(body).digest('hex') === metadata.sha256);
      exportBytes += body.length; activeExports++;
    }
  }
  unique(tables.exports, ['case_id', 'generation_key']);
  const deleted = new Set<string>();
  for (const row of tables.deleted_cases) {
    digest(row.case_hash); digest(row.owner_hash); integer(row.revision, 1); integer(row.catalog_revision); deleted.add(row.case_hash);
  }
  const closed = new Map<string, Row>();
  for (const row of tables.closed_accounts) {
    digest(row.owner_hash); time(row.closed_at); time(row.receipt_expires_at);
    if (row.receipt_hash !== null) digest(row.receipt_hash);
    if (row.auth_deleted_at !== null) time(row.auth_deleted_at);
    closed.set(row.owner_hash, row);
  }
  unique(tables.closed_accounts, ['receipt_hash'], true);
  for (const row of tables.cases) check(!deleted.has(hash(String(row.case_id))) && !closed.has(hash(String(row.owner_id))));
  for (const row of tables.account_deletion_previews) {
    digest(row.owner_hash); digest(row.token_hash); digest(row.fingerprint); time(row.expires_at); check(!closed.has(row.owner_hash));
  }
  unique(tables.account_deletion_previews, ['token_hash']);
  for (const row of tables.auth_deletion_jobs) {
    check(typeof row.job_id === 'string' && UUID.test(row.job_id)); digest(row.owner_hash); check(closed.has(row.owner_hash));
    time(row.next_attempt_at); check((row.lease_token === null) === (row.lease_until === null));
    if (row.lease_token !== null) { check(typeof row.lease_token === 'string' && UUID.test(row.lease_token)); time(row.lease_until); }
    if (row.completed_at === null) { identifier(row.raw_user_id); check(hash(row.raw_user_id) === row.owner_hash && closed.get(row.owner_hash)!.auth_deleted_at === null); }
    else { time(row.completed_at); check(row.raw_user_id === null && row.lease_token === null && closed.get(row.owner_hash)!.auth_deleted_at !== null); }
  }
  unique(tables.auth_deletion_jobs, ['owner_hash']);
  check(tables.auth_deletion_jobs.length === tables.closed_accounts.length);
  const programCounts = new Map<string, number>();
  for (const row of tables.request_history) {
    identifier(row.program_id); const revision = integer(row.request_revision, 1, 50);
    const history = parseRequestHistory(row.record);
    check(history.caseId === row.case_id && history.programId === row.program_id && history.requestRevision === revision
      && history.caseRevision <= integer(cases.get(String(row.case_id))!.revision, 1)
      && Buffer.byteLength(JSON.stringify(row.record)) <= 262144);
    const count = (programCounts.get(history.caseId) ?? 0) + 1; check(count <= 4); programCounts.set(history.caseId, count);
  }
  const quota = tables.repository_quota[0];
  check(integer(quota.case_count, 0, 64) === tables.cases.length && integer(quota.asset_count, 0, 64) === tables.evidence.length
    && integer(quota.artifact_count, 0, 16) === activeExports && integer(quota.stored_bytes, 0, 67108864) === evidenceBytes + exportBytes);
  return raw as unknown as Archive;
}

export async function validateDatabaseBackup(plaintext: Buffer, expectedProjectOrigin: string): Promise<BackupSummary> {
  try { const archive = await parseArchive(plaintext, expectedProjectOrigin);
    return { capturedAt: archive.capturedAt, sourceRows: counts(archive.tables), bytes: plaintext.length };
  } catch { throw new DatabaseBackupError(); }
}

async function assertOperatorSchema(client: PoolClient): Promise<void> {
  await assertMigrationsCurrent(client);
  const relations = await client.query(`SELECT c.relname,c.relkind,c.relrowsecurity,c.relforcerowsecurity,
    has_table_privilege(current_user,c.oid,'SELECT') AS can_select,
    (SELECT rolsuper OR rolbypassrls FROM pg_roles WHERE rolname=current_user) AS bypass,
    EXISTS (SELECT 1 FROM pg_policy p WHERE p.polrelid=c.oid AND p.polname='lifecycle_operator'
      AND p.polpermissive AND p.polcmd='*' AND p.polroles=ARRAY[c.relowner]
      AND pg_has_role(current_user,c.relowner,'USAGE')
      AND pg_get_expr(p.polqual,p.polrelid)='true' AND pg_get_expr(p.polwithcheck,p.polrelid)='true') AS full_policy,
    EXISTS (SELECT 1 FROM pg_policy p WHERE p.polrelid=c.oid AND NOT p.polpermissive
      AND (0=ANY(p.polroles) OR EXISTS (SELECT 1 FROM unnest(p.polroles) role_id WHERE role_id<>0 AND pg_has_role(current_user,role_id,'USAGE')))) AS restrictive
    FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
    WHERE n.nspname='safeathome_private' AND c.relkind NOT IN ('i','I') ORDER BY c.relname`);
  check(relations.rows.length === NAMES.length);
  for (const row of relations.rows) {
    check(NAMES.includes(row.relname) && row.relkind === 'r' && row.relrowsecurity === true && row.relforcerowsecurity === true
      && row.can_select === true && (row.bypass === true || (row.full_policy === true && row.restrictive === false)));
    const columns = await client.query(`SELECT a.attname FROM pg_attribute a JOIN pg_class c ON c.oid=a.attrelid
      JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='safeathome_private' AND c.relname=$1
      AND a.attnum>0 AND NOT a.attisdropped ORDER BY a.attnum`, [row.relname]);
    check(JSON.stringify(columns.rows.map(item => item.attname)) === JSON.stringify(Object.keys(TABLES[row.relname as TableName].columns)));
  }
}
function projection(name: TableName): string {
  const columns: Record<string, ColumnType> = TABLES[name].columns;
  return Object.entries(columns).map(([column, kind]) => kind === 'bytes'
    ? `replace(encode(${column},'base64'),E'\\n','') AS ${column}`
    : kind === 'time' ? `to_char(${column} AT TIME ZONE 'UTC','YYYY-MM-DD"T"HH24:MI:SS.US"Z"') AS ${column}`
      : kind === 'integer' ? `${column}::text AS ${column}` : column).join(',');
}
async function transaction<T>(pool: Pool, write: boolean, action: (client: PoolClient) => Promise<T>, signal?: AbortSignal): Promise<T> {
  signal?.throwIfAborted();
  const client = await pool.connect(); let broken = false;
  try {
    await client.query(write ? 'BEGIN' : 'BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY');
    await client.query("SET LOCAL statement_timeout='10s'; SET LOCAL lock_timeout='3s'; SET LOCAL idle_in_transaction_session_timeout='30s'");
    const result = await action(client); signal?.throwIfAborted(); await client.query('COMMIT'); return result;
  } catch {
    try { await client.query('ROLLBACK'); } catch { broken = true; }
    throw new DatabaseBackupError();
  } finally { client.release(broken); }
}

export async function captureDatabaseBackup(pool: Pool, projectOrigin: string, signal?: AbortSignal): Promise<Buffer> {
  try {
    origin(projectOrigin); const expected = await manifest();
    return await transaction(pool, false, async client => {
      await assertOperatorSchema(client);
      const capturedAt = (await client.query(`SELECT to_char(transaction_timestamp() AT TIME ZONE 'UTC',
        'YYYY-MM-DD"T"HH24:MI:SS.US"Z"') AS captured_at`)).rows[0].captured_at;
      const tables = {} as Archive['tables']; let total = 4096;
      for (const name of NAMES) {
        signal?.throwIfAborted();
        const select = `SELECT ${projection(name)} FROM ${S}.${name}`;
        const size = (await client.query(`SELECT count(*)::text AS count,COALESCE(sum(octet_length(row_to_json(q)::text)),0)::text AS bytes FROM (${select}) q`)).rows[0];
        check(integer(size.count) <= MAX_DATABASE_BACKUP_ROWS_PER_TABLE);
        total += integer(size.bytes); check(total <= MAX_DATABASE_BACKUP_BYTES);
        tables[name] = (await client.query(`${select} LIMIT ${MAX_DATABASE_BACKUP_ROWS_PER_TABLE + 1}`)).rows;
        check(tables[name].length === integer(size.count));
      }
      const encoded = Buffer.from(JSON.stringify({ format: FORMAT, projectOrigin, capturedAt, migrations: expected, tables }));
      await parseArchive(encoded, projectOrigin); return encoded;
    }, signal);
  } catch { throw new DatabaseBackupError(); }
}

export async function restoreDatabaseBackup(pool: Pool, plaintext: Buffer, expectedProjectOrigin: string, signal?: AbortSignal): Promise<BackupDrillReport> {
  try {
    const archive = await parseArchive(plaintext, expectedProjectOrigin);
    return await transaction(pool, true, async client => {
      await assertOperatorSchema(client);
      await client.query(`LOCK TABLE ${NAMES.map(name => `${S}.${name}`).join(',')} IN ACCESS EXCLUSIVE MODE`);
      for (const name of NAMES) {
        signal?.throwIfAborted();
        const rows = (await client.query(`SELECT ${projection(name)} FROM ${S}.${name} LIMIT 2`)).rows;
        if (name === 'repository_quota') check(rows.length === 1 && rows[0].singleton === true
          && ['case_count', 'asset_count', 'artifact_count', 'stored_bytes'].every(key => rows[0][key] === '0'));
        else check(rows.length === 0);
      }
      for (const name of NAMES) {
        if (name === 'repository_quota') continue;
        const columns: Record<string, ColumnType> = TABLES[name].columns;
        const keys = Object.keys(columns);
        for (const row of archive.tables[name]) {
          signal?.throwIfAborted();
          const values = keys.map(key => row[key] === null ? null : columns[key] === 'bytes'
            ? Buffer.from(String(row[key]), 'base64') : columns[key] === 'json' ? JSON.stringify(row[key]) : row[key]);
          await client.query(`INSERT INTO ${S}.${name}(${keys.join(',')}) VALUES(${keys.map((_, i) => `$${i + 1}`).join(',')})`, values);
        }
      }
      const cleared = {
        matches: archive.tables.matches.length,
        packetPayloads: archive.tables.packets.filter(row => row.packet !== null).length,
        exportPayloads: archive.tables.exports.filter(row => row.bytes !== null).length,
        previews: archive.tables.account_deletion_previews.length,
        receiptCapabilities: archive.tables.closed_accounts.filter(row => row.receipt_hash !== null).length,
        workerLeases: archive.tables.auth_deletion_jobs.filter(row => row.lease_token !== null).length,
      };
      await client.query(`DELETE FROM ${S}.matches;
        UPDATE ${S}.packets SET packet=NULL;
        UPDATE ${S}.exports SET metadata=NULL,bindings=NULL,bytes=NULL,invalidated=true;
        UPDATE ${S}.evidence_annotations SET record=jsonb_set(jsonb_set(jsonb_set(jsonb_set(record,'{reviewState}','"needs_review"'::jsonb),'{reviewedCaseRevision}','null'::jsonb),'{reviewedAt}','null'::jsonb),'{reviewedBy}','null'::jsonb);
        DELETE FROM ${S}.account_deletion_previews;
        UPDATE ${S}.closed_accounts SET receipt_hash=NULL,receipt_expires_at=LEAST(receipt_expires_at,clock_timestamp());
        UPDATE ${S}.auth_deletion_jobs SET lease_token=NULL,lease_until=NULL;
        UPDATE ${S}.repository_quota SET case_count=(SELECT count(*) FROM ${S}.cases),
          asset_count=(SELECT count(*) FROM ${S}.evidence),artifact_count=0,
          stored_bytes=(SELECT COALESCE(sum(octet_length(bytes)),0) FROM ${S}.evidence)`);
      const restoredRows = counts(archive.tables); restoredRows.matches = 0; restoredRows.account_deletion_previews = 0;
      const storedBytes = integer((await client.query(`SELECT stored_bytes::text AS bytes FROM ${S}.repository_quota`)).rows[0].bytes);
      return { quarantined: true, sourceRows: counts(archive.tables), restoredRows, cleared, storedBytes };
    }, signal);
  } catch { throw new DatabaseBackupError(); }
}
