import { COLLABORATION_ROUTES, executeCollaboration, type CollaborationRoute } from './collaboration.ts';
import { invitationEmailHash } from '../auth/invitation-email.ts';
import { executeSensitive, type SensitiveRoute, type SensitiveRequest } from './sensitive.ts';
import type { ProgramDefinition } from '../types.ts';
import { parseProgressRecord, emptyProgress, programReports } from '../tracking/progress.ts';
import type { Pool, PoolClient, QueryResultRow } from 'pg';
import { createHash } from 'node:crypto';
import { canonicalJson, evidenceIdentifier } from '../evidence/validation.ts';
import { AccountClosedError } from '../lifecycle/types.ts';
import { parseRequestHistory } from '../requests/tracking.ts';
import { check, parseSharingRequest, projectCase, type CaseMembership, type SharingRepository, type SharingRequest, type SharingResult, type SharingRoute } from './contracts.ts';
import type { CaseSnapshot } from '../types.ts';
const S = 'safeathome_private';
const hash = (text: string) => createHash('sha256').update(text).digest('hex');
const time = (value: string | Date) => new Date(value).toISOString();
type LabelView = 'owner' | 'recipient' | undefined;
const labelsOf = (source: { recipientLabel?: unknown; ownerLabel?: unknown }): { recipientLabel?: string; ownerLabel?: string } =>
  Object.fromEntries((['recipientLabel', 'ownerLabel'] as const).filter(key => typeof source[key] === 'string').map(key => [key, source[key]]));
function membership(row: QueryResultRow, now: number, view?: LabelView): CaseMembership {
  const labels = view ? labelsOf(row.definition) : {};
  if (view === 'recipient') delete labels.recipientLabel;
  return { ...membershipFields(row, now), ...labels };
}
function membershipFields(row: QueryResultRow, now: number): CaseMembership {
  return { membershipId: row.membership_id, caseId: row.case_id, grantorId: row.owner_id, recipientId: row.recipient_id,
    role: row.definition.role, scope: row.definition.scope, permissionRevision: Number(row.permission_revision),
    expiresAt: row.expires_at === null ? null : time(row.expires_at), invitationExpiresAt: time(row.invitation_expires_at),
    state: row.revoked ? 'revoked' : (row.expires_at !== null && Date.parse(time(row.expires_at)) <= now)
      || (!row.accepted && Date.parse(time(row.invitation_expires_at)) <= now) ? 'expired' : row.accepted ? 'active' : 'pending' };
}
export class PostgresSharingRepository implements SharingRepository {
  private readonly pool: Pool;
  private readonly registry: () => Promise<ProgramDefinition[]>;
  constructor(pool: Pool, registry: () => Promise<ProgramDefinition[]> = async()=>[]) { this.pool = pool; this.registry=registry; }
  async sensitive(userId: string, route: SensitiveRoute, request: SensitiveRequest): Promise<SharingResult> {
    return this.transaction(userId, client => executeSensitive(client, route, request));
  }
  private async transaction<T>(userId: string, action: (client: PoolClient, now: string) => Promise<T>): Promise<T> {
    check(evidenceIdentifier(userId)); const client = await this.pool.connect(); let broken = false;
    try {
      await client.query('BEGIN');
      await client.query("SET LOCAL lock_timeout='5s'; SET LOCAL statement_timeout='10s'; SET LOCAL idle_in_transaction_session_timeout='10s'");
      await client.query("SELECT set_config('safeathome.user_id',$1,true)", [userId]);
      await client.query(`SELECT singleton FROM ${S}.repository_quota WHERE singleton FOR UPDATE`);
      if ((await client.query(`SELECT 1 FROM ${S}.closed_accounts WHERE owner_hash=$1`, [hash(userId)])).rowCount) throw new AccountClosedError();
      const now = time((await client.query('SELECT clock_timestamp() AS now')).rows[0].now);
      const result = await action(client, now); await client.query('COMMIT'); return result;
    } catch (error) { try { await client.query('ROLLBACK'); } catch { broken = true; } throw error; }
    finally { client.release(broken); }
  }
  async execute(userId: string, route: SharingRoute, raw: SharingRequest, tokenHash?: string, verifiedEmail?: string): Promise<SharingResult> {
    const input = parseSharingRequest(route, raw);
    if (['create-invitation','create-email-invitation','review-invitation','accept-invitation'].includes(route)) check(typeof tokenHash === 'string' && /^[0-9a-f]{64}$/.test(tokenHash));
    const emailInvite = route === 'create-email-invitation';
    if (emailInvite) input.recipientId = input.invitationId;
    const ruleVersions = Object.fromEntries((await this.registry()).map(p=>[p.programId,p.ruleVersion]));
    return this.transaction(userId, async (client, now) => {
      if((COLLABORATION_ROUTES as readonly string[]).includes(route)) return executeCollaboration(client,route as CollaborationRoute,input,ruleVersions);
      if (['review-invitation','accept-invitation','list-shared-cases','read-shared-case','add-shared-note'].includes(route)) {
        const args = JSON.stringify({ ...input, code: undefined, tokenHash });
        let result = (await client.query(`SELECT ${S}.shared_operation($1,$2::jsonb) AS result`, [route, args])).rows[0].result;
        if (result.status === 'not_found' && verifiedEmail && ['review-invitation','accept-invitation'].includes(route)) {
          result = (await client.query(`SELECT ${S}.email_invitation_operation($1,$2::jsonb,$3) AS result`,
            [route, args, invitationEmailHash(verifiedEmail)])).rows[0].result;
        }
        if (result.status !== 'ok') return { status: result.status };
        const view: LabelView = input.includeLabels ? 'recipient' : undefined;
        if (route === 'list-shared-cases') return { status: 'ok', data: { memberships: result.rows.map((r: QueryResultRow) => membership(r, Date.parse(now), view)) } };
        const row = result.row, grant = membership(row, Date.parse(now), route === 'review-invitation' ? view : undefined);
        return { status: 'ok', data: route === 'review-invitation' || route === 'accept-invitation' ? { membership: grant }
          : { membership: grant, projection: row.projection, notes: row.notes.events } };
      }
      const ownerCase = (await client.query(`SELECT snapshot,revision,progress FROM ${S}.cases WHERE case_id=$1 AND owner_id=$2 FOR UPDATE`, [input.caseId, userId])).rows[0];
      if (!ownerCase) return { status: 'not_found' };
      if (input.expectedCaseRevision !== undefined && input.expectedCaseRevision !== Number(ownerCase.revision)) return { status: 'conflict' };
      const legacy = (await client.query(`SELECT record FROM ${S}.request_history WHERE case_id=$1`, [input.caseId])).rows.map(r => parseRequestHistory(r.record));
      const progress = ownerCase.progress === null ? emptyProgress(input.caseId!) : parseProgressRecord(ownerCase.progress);
      const programIds = [...new Set([...progress.programs.map(p => p.programId), ...legacy.map(h => h.programId)])];
      if (route === 'list-sharing' || route === 'list-email-sharing') {
        const rows = (await client.query(`SELECT * FROM ${S}.case_shares WHERE case_id=$1 AND owner_id=$2 ORDER BY membership_id`, [input.caseId, userId])).rows;
        return { status: 'ok', data: { availableProgramIds: programIds, shares: rows.map(row => ({ ...membership(row, Date.parse(now), input.includeLabels ? 'owner' : undefined), projection: row.projection, notes: row.notes.events, audit: row.audit.events,
          ...(route==='list-email-sharing'?{invitedEmail:row.invited_email}:{}),
        })) } };
      }
      const row = input.invitationId ? (await client.query(`SELECT * FROM ${S}.case_shares WHERE membership_id=$1 AND case_id=$2 AND owner_id=$3 FOR UPDATE`, [input.invitationId, input.caseId, userId])).rows[0] : null;
      if (route === 'revoke-sharing') {
        if (!row) return { status: 'not_found' };
        if (row.revoked && Number(row.permission_revision) === input.expectedPermissionRevision! + 1) return { status: 'ok', data: { membership: membership(row, Date.parse(now)) } };
        if (Number(row.permission_revision) !== input.expectedPermissionRevision || row.revoked) return { status: 'conflict' };
        const revoked = (await client.query(`UPDATE ${S}.case_shares SET revoked=true, invitation_hash=NULL,projection=NULL,notes='{"events":[]}',definition=definition-'recipientLabel'-'ownerLabel',
          permission_revision=permission_revision+1,audit=${S}.share_audit(audit,'revoked') WHERE membership_id=$1 RETURNING *`, [input.invitationId])).rows[0];
        return { status: 'ok', data: { membership: membership(revoked, Date.parse(now)) } };
      }
      if (input.expiresAt !== undefined && input.expiresAt !== null && (input.expiresAt <= now || Date.parse(input.expiresAt) > Date.parse(now) + 90 * 86400000)) return { status: 'invalid_request' };
      const scope = input.scope!;
      const histories = scope.programIds.map(programId => ({programId, events: programReports({snapshot: ownerCase.snapshot, record: progress, legacy},programId)}));
      if (!scope.programIds.every(id => programIds.includes(id))) return { status: 'invalid_request' };
      let projection; try { projection = projectCase(ownerCase.snapshot as CaseSnapshot, scope, histories, now); } catch { return { status: 'invalid_request' }; }
      if (route === 'preview-sharing') return { status: 'ok', data: { projection } };
      if (route === 'create-invitation' || emailInvite) {
        if (input.recipientId === userId) return { status: 'invalid_request' };
        const key = hash(canonicalJson(input));
        if (row) return row.creation_key === key ? { status: 'ok', data: { created: false, membership: membership(row, Date.parse(now)) } } : { status: 'conflict' };
        const count = (await client.query(`SELECT count(*) AS n FROM ${S}.case_shares WHERE case_id=$1`, [input.caseId])).rows[0];
        if (Number(count.n) >= 16) return { status: 'quota_exceeded' };
        if (!(await client.query(`SELECT ${S}.share_recipient_has_capacity($1) AS capacity`, [input.recipientId])).rows[0].capacity) return {status:'quota_exceeded'};
        const inserted = (await client.query(`INSERT INTO ${S}.case_shares(membership_id,case_id,owner_id,recipient_id,creation_key,invitation_hash,invitation_expires_at,expires_at,definition,projection,audit,recipient_email_hash,invited_email)
          VALUES($1,$2,$3,$4,$5,$6,LEAST(clock_timestamp()+interval '7 days',COALESCE($7::timestamptz,'infinity'::timestamptz)),$7,$8::jsonb,$9::jsonb,${S}.share_audit('{"events":[]}', 'invited'),$10,$11) RETURNING *`,
        [input.invitationId, input.caseId, userId, input.recipientId, key, tokenHash, input.expiresAt, JSON.stringify({ role: input.role, scope, ...labelsOf(input) }), JSON.stringify(projection), emailInvite ? invitationEmailHash(input.recipientEmail!) : null, emailInvite?input.recipientEmail:null])).rows[0];
        return { status: 'ok', data: { created: true, membership: membership(inserted, Date.parse(now)) } };
      }
      if (route === 'change-sharing') {
        if (!row) return { status: 'not_found' };
        const changeKey = hash(canonicalJson(input));
        if (Number(row.permission_revision) === input.expectedPermissionRevision! + 1 && row.definition.lastChangeKey === changeKey && !row.revoked) return {status:'ok',data:{membership:membership(row,Date.parse(now))}};
        if (Number(row.permission_revision) !== input.expectedPermissionRevision || ['revoked','expired'].includes(membership(row, Date.parse(now)).state)) return { status: 'conflict' };
        if (Number(row.permission_revision) >= 998) return {status:'quota_exceeded'};
        const changed = (await client.query(`UPDATE ${S}.case_shares SET definition=$2::jsonb,projection=$3::jsonb,expires_at=$4,
          permission_revision=permission_revision+1,audit=${S}.share_audit(audit,'changed') WHERE membership_id=$1 RETURNING *`,
        [input.invitationId, JSON.stringify({ role: input.role, scope, lastChangeKey: changeKey, ...labelsOf(row.definition) }), JSON.stringify(projection), input.expiresAt])).rows[0];
        return { status: 'ok', data: { membership: membership(changed, Date.parse(now)) } };
      }
      return { status: 'invalid_request' };
    });
  }
}
