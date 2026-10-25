import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { before, beforeEach, after, test } from 'node:test';
import type { Pool } from 'pg';
import { PDFDocument } from 'pdf-lib';
import { TestPostgres } from './harness.ts';
import { applyMigrations } from '../../src/storage/migrate.ts';
import { captureDatabaseBackup, restoreDatabaseBackup } from '../../src/storage/database-backup.ts';
import { seedSensitive, OWNER, HELPER, VIEWER, OTHER } from '../support/sensitive-fixture.ts';
import { parseSensitiveRequest, sensitiveId, type SensitiveRoute, type SensitiveRequest } from '../../src/sharing/sensitive.ts';
import { handleSharing } from '../../src/api/sharing.ts';
import { paintedText } from '../../tool/pdf-verification-text.ts';
import { PostgresSharingRepository } from '../../src/sharing/postgres-sharing-repository.ts';
import { setTimeout as delay } from 'node:timers/promises';
let cluster: TestPostgres, admin: Pool, runtime: Pool;
before(async () => { cluster = await TestPostgres.start(); admin = cluster.pool(); await applyMigrations(admin);
  await admin.query('CREATE ROLE sensitive_runtime LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS IN ROLE safeathome_app'); runtime = cluster.pool('sensitive_runtime'); });
after(async () => { await cluster?.close(); });
beforeEach(async () => {
  await admin.query('TRUNCATE safeathome_private.cases CASCADE; UPDATE safeathome_private.repository_quota SET case_count=0,asset_count=0,artifact_count=0,stored_bytes=0');
});
const base = (s: Awaited<ReturnType<typeof seedSensitive>>, revision = 2) => ({ schemaVersion: '3' as const, membershipId: s.membershipId, expectedPermissionRevision: revision });
const ok = (r: any): any => { assert.equal(r.status, 'ok', JSON.stringify(r)); return r.data; };
async function preview(s: Awaited<ReturnType<typeof seedSensitive>>, pdf = false) {
  const options = ok(await s.shares.sensitive(OWNER, 'list-sensitive-options', base(s)));
  const fields = { ...base(s), expectedCaseRevision: options.caseRevision, expectedCatalogRevision: options.catalogRevision,
    selection: { photoIds: options.content.photos.map((p: any) => p.evidenceId), measurementIds: options.content.measurements.map((m: any) => m.id),
      answerIds: options.content.answers.filter((a: any) => a.category !== 'private').map((a: any) => a.id) },
    allowPdf: pdf, expiresAt: new Date(Date.now() + 86400000).toISOString() };
  return { fields, data: ok(await s.shares.sensitive(OWNER, 'preview-sensitive-sharing', fields)) };
}
async function publish(s: Awaited<ReturnType<typeof seedSensitive>>, pdf = false) {
  const p = await preview(s, pdf), request = { ...p.fields, mutationId: randomUUID(), previewHash: p.data.sourceHash };
  return { ...p, request, saved: ok(await s.shares.sensitive(OWNER, 'publish-sensitive-sharing', request)) };
}
test('explicit selection preserves false/zero/unknown, independent PDF opt-in and exact photo bytes; private owner records remain RLS protected', async () => {
  const s = await seedSensitive(runtime);
  assert.equal((await s.shares.sensitive(HELPER, 'read-sensitive-sharing', base(s))).status, 'not_found');
  const p = await publish(s);
  assert.equal(p.saved.permissionRevision, 3);
  assert.equal(p.data.content.measurements[0].id, sensitiveId('measurement', 'fictional-finding', 'clear_width'));
  const read = ok(await s.shares.sensitive(HELPER, 'read-sensitive-sharing', base(s, 3)));
  assert.deepEqual(read.content.answers.map((a: any) => a.value).sort(), [0, false, null].sort());
  assert.ok(!JSON.stringify(read).includes('willingServicesReported'));
  const photo = ok(await s.shares.sensitive(HELPER, 'read-sensitive-photo', { ...base(s, 3), sourceHash: read.sourceHash,
    evidenceId: 'fictional-photo-a', expectedEvidenceRevision: 1 }));
  assert.deepEqual(Buffer.from(photo.photoBase64, 'base64'), Buffer.from(s.photo.image.bytes));
  assert.equal((await s.shares.sensitive(HELPER, 'read-sensitive-report', { ...base(s, 3), sourceHash: read.sourceHash })).status, 'not_found');
  const client = await runtime.connect();
  try { await client.query('BEGIN'); await client.query("SELECT set_config('safeathome.user_id',$1,true)", [HELPER]);
    for (const table of ['cases', 'evidence', 'program_intake', 'share_sensitive']) assert.equal((await client.query(`SELECT 1 FROM safeathome_private.${table}`)).rowCount, 0);
  } finally { await client.query('ROLLBACK'); client.release(); }
});
test('viewer/unrelated/helper cannot configure, forwarded IDs fail, malformed scopes fail before mutation and exact save retry increments once', async () => {
  const s = await seedSensitive(runtime), viewer = await seedSensitive(runtime, VIEWER, 'viewer'), p = await preview(s);
  for (const actor of [HELPER, VIEWER, OTHER]) assert.equal((await s.shares.sensitive(actor, 'list-sensitive-options', base(s))).status, 'not_found');
  assert.equal((await viewer.shares.sensitive(OWNER, 'list-sensitive-options', base(viewer))).status, 'not_found');
  const request = { ...p.fields, mutationId: randomUUID(), previewHash: p.data.sourceHash };
  assert.equal((await s.shares.sensitive(HELPER, 'publish-sensitive-sharing', request)).status, 'not_found');
  assert.equal((await s.shares.sensitive(OWNER, 'publish-sensitive-sharing', { ...request, previewHash: 'a'.repeat(64) })).status, 'conflict');
  const first = ok(await s.shares.sensitive(OWNER, 'publish-sensitive-sharing', request));
  assert.deepEqual(ok(await s.shares.sensitive(OWNER, 'publish-sensitive-sharing', request)), first);
  assert.equal((await s.shares.sensitive(OWNER, 'publish-sensitive-sharing', { ...request, allowPdf: true })).status, 'conflict');
  assert.throws(() => parseSensitiveRequest('preview-sensitive-sharing', { ...p.fields, selection: { ...p.fields.selection, allPhotos: true } }));
  assert.throws(() => parseSensitiveRequest('preview-sensitive-sharing', { ...p.fields, selection: { ...p.fields.selection, photoIds: ['same', 'same'] } }));
  assert.equal((await s.shares.sensitive(OTHER, 'read-sensitive-sharing', base(s, 3))).status, 'not_found');
});
test('replacement and revocation deny bytes; changed source bindings never substitute new content', async () => {
  const s = await seedSensitive(runtime), p = await publish(s);
  await s.cases.saveEvidenceIfCurrent({ ...s.photo, revision: 2, expectedCatalogRevision: 1, expectedEvidenceRevision: 1 });
  assert.equal((await s.shares.sensitive(HELPER, 'read-sensitive-sharing', base(s, 3))).status, 'conflict');
  assert.equal((await s.shares.sensitive(HELPER, 'read-sensitive-photo', { ...base(s, 3), sourceHash: p.saved.sourceHash, evidenceId: 'fictional-photo-a', expectedEvidenceRevision: 1 })).status, 'conflict');
  await s.shares.execute(OWNER, 'revoke-sharing', { schemaVersion: '3', caseId: s.caseId, invitationId: s.membershipId, expectedPermissionRevision: 3 });
  assert.equal((await admin.query('SELECT 1 FROM safeathome_private.share_sensitive WHERE membership_id=$1', [s.membershipId])).rowCount, 0);
  assert.equal((await s.shares.sensitive(HELPER, 'read-sensitive-sharing', base(s, 3))).status, 'not_found');
});
test('filtered report is generated from selected fields only and rechecks current authentication and authorization after rendering', async () => {
  const s = await seedSensitive(runtime), p = await publish(s, true);
  const deps = { sharing: s.shares, sensitiveEnabled: true, authenticate: async () => ({ userId: HELPER }) };
  const body = { ...base(s, 3), sourceHash: p.saved.sourceHash };
  const result = await handleSharing({ body, bearerToken: 'fictional-helper' }, deps, 'read-sensitive-report');
  assert.equal(result.status, 200);
  const pdf = (result.body as any).report;
  const document = await PDFDocument.load(Buffer.from(pdf.pdfBase64, 'base64'));
  assert.equal(document.getPageCount(), pdf.pageCount);
  const text = document.getPages().flatMap((_, i) => paintedText(document, i)).join(' ').replace(/\s+/g, ' ');
  assert.ok(text.includes('clear_width: 750 mm'));
  assert.ok(text.includes('answer: 0') && text.includes('answer: false') && text.includes('answer: unknown'));
  assert.ok(!text.includes('willingServicesReported') && !text.includes('willing to receive'));
  assert.equal(document.getForm().getFields().length, 0);
  const expired = await handleSharing({ body, bearerToken: 'fictional-helper' }, { ...deps, reauthenticate: async () => null }, 'read-sensitive-report');
  assert.equal(expired.status, 401); assert.ok(!JSON.stringify(expired.body).includes('pdfBase64'));
  const revoked = await handleSharing({ body, bearerToken: 'fictional-helper' }, { ...deps, reauthenticate: async () => {
    await s.shares.execute(OWNER, 'revoke-sharing', { schemaVersion: '3', caseId: s.caseId, invitationId: s.membershipId, expectedPermissionRevision: 3 });
    return { userId: HELPER };
  } }, 'read-sensitive-report');
  assert.equal(revoked.status, 409); assert.ok(!JSON.stringify(revoked.body).includes('pdfBase64'));
});
test('expiry is finite; queued photo, PDF and data reads deny a revocation committed first', async () => {
  const s = await seedSensitive(runtime), p = await publish(s, true);
  const blocked = new PostgresSharingRepository(cluster.pool('sensitive_runtime', 'sensitive-waiting-reader'));
  const lock = await admin.connect();
  let reads: Promise<any[]> | undefined;
  try {
    await lock.query('BEGIN');
    await lock.query('SELECT 1 FROM safeathome_private.repository_quota FOR UPDATE');
    reads = Promise.all([
      blocked.sensitive(HELPER, 'read-sensitive-sharing', base(s, 3)),
      blocked.sensitive(HELPER, 'read-sensitive-photo', { ...base(s, 3), sourceHash: p.saved.sourceHash, evidenceId: 'fictional-photo-a', expectedEvidenceRevision: 1 }),
      blocked.sensitive(HELPER, 'read-sensitive-report', { ...base(s, 3), sourceHash: p.saved.sourceHash }),
    ]);
    const deadline = Date.now() + 3000;
    while (!(await admin.query("SELECT 1 FROM pg_stat_activity WHERE application_name='sensitive-waiting-reader' AND wait_event_type='Lock'")).rowCount) {
      assert.ok(Date.now() < deadline, 'recipient query must reach the held lock'); await delay(10);
    }
    await lock.query('UPDATE safeathome_private.case_shares SET revoked=true,projection=NULL,permission_revision=permission_revision+1 WHERE membership_id=$1', [s.membershipId]);
    await lock.query('COMMIT');
    for (const result of await reads) assert.equal(result.status, 'not_found');
  } finally { await lock.query('ROLLBACK'); lock.release(); await reads; }
  const expiry = await seedSensitive(runtime), e = await preview(expiry);
  for (const expiresAt of [new Date(Date.now() - 1000).toISOString(), new Date(Date.now() + 31 * 86400000).toISOString()]) {
    assert.equal((await expiry.shares.sensitive(OWNER, 'preview-sensitive-sharing', { ...e.fields, expiresAt })).status, 'invalid_request');
  }
  await publish(expiry);
  await admin.query("UPDATE safeathome_private.share_sensitive SET record=jsonb_set(record,'{expiresAt}',to_jsonb(to_char(clock_timestamp()-interval '1 second','YYYY-MM-DD\"T\"HH24:MI:SS.MS\"Z\"'))) WHERE membership_id=$1", [expiry.membershipId]);
  assert.equal((await expiry.shares.sensitive(HELPER, 'read-sensitive-sharing', base(expiry, 3))).status, 'not_found');
});
test('empty explicit publication removes content; parent permission/role changes erase the independent capability', async () => {
  const s = await seedSensitive(runtime); await publish(s, true);
  const options = ok(await s.shares.sensitive(OWNER, 'list-sensitive-options', base(s, 3)));
  const fields = { ...base(s, 3), expectedCaseRevision: options.caseRevision, expectedCatalogRevision: options.catalogRevision,
    selection: { photoIds: [], measurementIds: [], answerIds: [] }, allowPdf: false, expiresAt: new Date(Date.now() + 86400000).toISOString() };
  const previewed = ok(await s.shares.sensitive(OWNER, 'preview-sensitive-sharing', fields));
  ok(await s.shares.sensitive(OWNER, 'publish-sensitive-sharing', { ...fields, previewHash: previewed.sourceHash, mutationId: randomUUID() }));
  const empty = ok(await s.shares.sensitive(HELPER, 'read-sensitive-sharing', base(s, 4)));
  assert.deepEqual(empty.content, { photos: [], measurements: [], answers: [] });
  assert.equal((await s.shares.sensitive(HELPER, 'read-sensitive-photo', { ...base(s, 4), sourceHash: empty.sourceHash, evidenceId: 'fictional-photo-a', expectedEvidenceRevision: 1 })).status, 'not_found');
  assert.equal((await s.shares.sensitive(HELPER, 'read-sensitive-report', { ...base(s, 4), sourceHash: empty.sourceHash })).status, 'not_found');
  ok(await s.shares.execute(OWNER, 'change-sharing', { schemaVersion: '3', caseId: s.caseId, expectedCaseRevision: 2,
    invitationId: s.membershipId, expectedPermissionRevision: 4, role: 'viewer', scope: { findingIds: ['fictional-finding'], programIds: [], allowHelperNotes: false }, expiresAt: null }));
  assert.equal((await admin.query('SELECT 1 FROM safeathome_private.share_sensitive WHERE membership_id=$1', [s.membershipId])).rowCount, 0);
  assert.equal((await s.shares.sensitive(HELPER, 'read-sensitive-sharing', base(s, 5))).status, 'not_found');
});
test('backup is validated, quarantine wipes sensitive capabilities and case deletion cascades selected records', async () => {
  const s = await seedSensitive(runtime); await publish(s, true);
  const origin = 'https://fictional-sensitive.supabase.co', archive = await captureDatabaseBackup(admin, origin);
  const target = await TestPostgres.start();
  try { const db = target.pool(); await applyMigrations(db); await restoreDatabaseBackup(db, archive, origin);
    assert.equal((await db.query('SELECT 1 FROM safeathome_private.share_sensitive')).rowCount, 0);
  } finally { await target.close(); }
  assert.equal((await s.cases.deleteCaseIfCurrent({ userId: OWNER, caseId: s.caseId, revision: 2, expectedCatalogRevision: 1 })).status, 'deleted');
  assert.equal((await admin.query('SELECT 1 FROM safeathome_private.share_sensitive WHERE membership_id=$1', [s.membershipId])).rowCount, 0);
});
