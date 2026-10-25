import { createHash } from 'node:crypto';
import { SENSITIVE_ROUTES, parseSensitiveRequest, type SensitiveRoute } from '../sharing/sensitive.ts';
import { renderHomeSafetyReport } from '../assessment/home-safety-report.ts';
import type { SharingDependencies } from './sharing.ts';

let rendering = false;
export { SENSITIVE_ROUTES };
export async function handleSensitiveSharing(input: { body: unknown; bearerToken: string | null }, deps: SharingDependencies, route: SensitiveRoute) {
  const fail = (status: number, code: string) => ({ status, body: { schemaVersion: '3', error: { code,
    message: 'Refresh access and review the exact selected information before trying again.' } }, headers: { 'Cache-Control': 'no-store' } });
  if (deps.sensitiveEnabled !== true || !deps.sharing.sensitive) return fail(404, 'SHARING_NOT_FOUND');
  let request; try { request = parseSensitiveRequest(route, input.body); } catch { return fail(400, 'INVALID_REQUEST'); }
  if (!input.bearerToken) return fail(401, 'UNAUTHENTICATED');
  const user = await deps.authenticate(input.bearerToken);
  if (!user) return fail(401, 'UNAUTHENTICATED');
  const result = await deps.sharing.sensitive(user.userId, route, request);
  const errors = { not_found: [404, 'SHARING_NOT_FOUND'], conflict: [409, 'SHARING_CONFLICT'],
    quota_exceeded: [507, 'SHARING_LIMIT'], invalid_request: [400, 'INVALID_REQUEST'] } as const;
  if (result.status !== 'ok') { const [status, code] = errors[result.status]; return fail(status, code); }
  if (route.endsWith('-report')) {
    if (rendering) return fail(503, 'SERVICE_UNAVAILABLE');
    rendering = true;
    try {
      const view = result.data as any;
      const lines = ['Safe at Home - limited shared report', 'Draft. Not submitted. Not a verified repair, clinical assessment or agency decision.',
        'This report contains only explicitly selected measurements and preparation answers. Photo bytes are excluded.',
        `Case: ${view.caseId}; revision: ${view.caseRevision}; permission revision: ${view.permissionRevision}`,
        `Access expires: ${view.expiresAt}`, 'Labels remain in their source language; resident answers are not translated.'];
      for (const m of view.content.measurements) lines.push(`Measurement ${m.id}; finding ${m.findingId}`, `${m.type}: ${m.value} ${m.unit}; method ${m.method}; confirmed ${m.confirmed}`);
      for (const a of view.content.answers) lines.push(`${a.programId}: ${a.label}`, `Category: ${a.category}; answer: ${a.value === null ? 'unknown' : a.value}; reported state: ${a.reviewState}`);
      const pdf = await renderHomeSafetyReport(lines, 'Safe at Home - limited shared report');
      const currentUser = await (deps.reauthenticate ?? deps.authenticate)(input.bearerToken);
      if (!currentUser || currentUser.userId !== user.userId) return fail(401, 'UNAUTHENTICATED');
      const fresh = await deps.sharing.sensitive(user.userId, route, request);
      if (fresh.status !== 'ok' || fresh.data.sourceHash !== view.sourceHash || fresh.data.permissionRevision !== view.permissionRevision) return fail(409, 'SHARING_CONFLICT');
      return { status: 200, body: { schemaVersion: '3', membershipId: request.membershipId, permissionRevision: view.permissionRevision,
        sourceHash: view.sourceHash, report: { pdfBase64: Buffer.from(pdf.bytes).toString('base64'),
          sha256: createHash('sha256').update(pdf.bytes).digest('hex'), pageCount: pdf.pageCount } }, headers: { 'Cache-Control': 'no-store' } };
    } finally { rendering = false; }
  }
  return { status: 200, body: result.data, headers: { 'Cache-Control': 'no-store' } };
}
