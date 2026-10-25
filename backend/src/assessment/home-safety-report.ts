import { PDFDocument, rgb } from 'pdf-lib';
import { embedReviewedTextFont } from '../pdf/reviewed-text-font.ts';
import type { EvidenceCatalog } from '../evidence/types.ts';
import type { FindingRoom, HomeSafetyState } from './home-safety.ts';
import { STEADI_CATALOG, safetyRequestHash } from './home-safety.ts';

export const HOME_SAFETY_REPORT_MAX_BYTES = 2 * 1024 * 1024;
export function safetyConcernAddressed(state: HomeSafetyState, link: FindingRoom): boolean {
  const finding = state.case.findings.find(f => f.id === link.findingId);
  const revision = link.questionId === null ? null : state.safety.document.answers.find(a => a.roomId === link.roomId && a.questionId === link.questionId)?.revision;
  const report = state.safety.history.map(e => e.operation).filter(o => o.type === 'set_addressed' && o.findingId === link.findingId).at(-1);
  return finding?.reviewState === 'confirmed' && link.answerRevision === revision && report?.type === 'set_addressed'
    && (finding.evidenceIds.length === 0 || state.evidenceCatalogRevision !== undefined && report.evidenceCatalogRevision === state.evidenceCatalogRevision)
    && report.addressed && report.roomId === link.roomId && report.answerRevision === revision && report.findingFingerprint === safetyRequestHash(finding);
}
export function reportLines(state: HomeSafetyState, catalog: EvidenceCatalog, at: string, includeNotes: boolean, includeEvidenceReferences: boolean): string[] {
  const doc = state.safety.document;
  const lines = ['Safe at Home - room and checklist report', 'Educational record. Not a safety certification, clinical score, application or verified repair report.',
    'Report labels and checklist prompts are in English. Resident text is preserved.', `Case ID: ${state.case.caseId}`, `Case revision: ${state.case.revision}; checklist revision: ${state.safety.revision}; photo catalog revision: ${catalog.catalogRevision}`,
    `Generated at: ${at}`, `Source: ${STEADI_CATALOG.sourceTitle}`, `Catalog: ${doc.catalogVersion}`, STEADI_CATALOG.sourceUrl,
    'Addressed means explicitly reported by the resident. Completing a task does not address a concern.',
    `Optional question notes: ${includeNotes ? 'included' : 'excluded'}; photo references: ${includeEvidenceReferences ? 'included (no images)' : 'excluded'}`];
  for (const room of doc.rooms) {
    const questions = STEADI_CATALOG.questions.filter(q => q.rooms.includes(room.type));
    const roomLinks = doc.findingRooms.filter(l => l.roomId === room.id);
    const active = roomLinks.filter(l => { const f = state.case.findings.find(f => f.id === l.findingId); const a = doc.answers.find(a => a.roomId === room.id && a.questionId === l.questionId);
      return f && !(f.reviewState === 'dismissed' && (l.questionId === null || l.answerRevision === a?.revision)); });
    const possible = questions.filter(q => doc.answers.some(a => a.roomId === room.id && a.questionId === q.id && a.value === q.concernWhen) && !roomLinks.some(l => l.questionId === q.id && state.case.findings.some(f => f.id === l.findingId))).length;
    lines.push('', `ROOM: ${room.name ?? room.type} [${room.id}]`, `Area type: ${room.type}; room status: ${room.archived ? 'archived - retained record; findings and tasks remain active' : 'active'}`, `Questions answered: ${doc.answers.filter(a => a.roomId === room.id && a.value !== 'unanswered').length} of ${questions.length}`,
      `Concerns addressed (resident reported): ${active.filter(l => safetyConcernAddressed(state,l)).length} of ${active.length + possible}`);
    if (questions.length === 0) lines.push('No sourced checklist questions for this area. No safety conclusion is made.');
    for (const q of questions) {
      const a = doc.answers.find(a => a.roomId === room.id && a.questionId === q.id);
      const link = roomLinks.find(l => l.questionId === q.id);
      const annotation = state.safety.history.map(e => e.operation).filter(o => o.type === 'annotate_answer' && o.roomId === room.id && o.questionId === q.id).at(-1);
      const recorded = state.safety.history.filter(e => e.operation.type === 'answer' && e.operation.roomId === room.id && e.operation.questionId === q.id).at(-1);
      lines.push(`${q.id} (${q.section}) - ${q.prompt}`, `Answer: ${a?.value ?? 'unanswered'}; answer revision: ${a?.revision ?? 0}`);
      if (recorded) lines.push(`Answer recorded: ${recorded.recordedAt}; account: ${recorded.recordedBy}`);
      if (link) {
        const finding = state.case.findings.find(f => f.id === link.findingId);
        lines.push(`Finding: ${link.findingId}; review: ${finding?.reviewState ?? 'removed'}; answer review: ${link.answerRevision === a?.revision ? 'current' : 'needs review'}`);
        if (finding) lines.push(`Observation: ${finding.observation}`, `Addressed: ${safetyConcernAddressed(state,link) ? 'resident reported' : 'not currently reported'}`);
      }
      if (annotation?.type === 'annotate_answer') {
        if (includeNotes && annotation.note) lines.push(`Question note${annotation.answerRevision !== (a?.revision ?? 0) ? ' (answer changed - review needed)' : ''}: ${annotation.note}`);
        if (includeEvidenceReferences) for (const ref of annotation.evidence) lines.push(`Photo reference: ${ref.evidenceId}, revision ${ref.expectedEvidenceRevision} (${catalog.evidence.some(e => e.evidenceId === ref.evidenceId && e.evidenceRevision === ref.expectedEvidenceRevision) ? 'current' : 'replaced or removed; review needed'})`);
      }
    }
    for (const link of roomLinks.filter(l => l.questionId === null)) {
      const f = state.case.findings.find(f => f.id === link.findingId);
      lines.push(`Assigned finding: ${link.findingId}; review: ${f?.reviewState ?? 'removed'}`, f?.observation ?? 'Original finding removed; historical room link retained.', `Addressed: ${safetyConcernAddressed(state,link) ? 'resident reported' : 'not currently reported'}`);
    }
  }
  return lines;
}

export async function renderHomeSafetyReport(lines: string[], title = 'Safe at Home - educational room and checklist report'): Promise<{ bytes: Uint8Array; pageCount: number }> {
  const pdf = await PDFDocument.create();
  pdf.setTitle(title);
  const text = await embedReviewedTextFont(pdf, lines);
  const wrapped: string[] = [];
  for (const line of lines) {
    if (!text.supports(line)) throw new Error('REPORT_UNSUPPORTED_TEXT');
    let current = '';
    for (const character of Array.from(line)) {
      if (text.font.widthOfTextAtSize(current + character, 10) > 510) { wrapped.push(current); current = ''; }
      current += character;
    }
    wrapped.push(current);
  }
  const pageCount = Math.max(1, Math.ceil(wrapped.length / 45));
  if (pageCount > 128) throw new Error('REPORT_LIMIT');
  for (let page = 0; page < pageCount; page++) {
    const sheet = pdf.addPage([612,792]);
    wrapped.slice(page*45,(page+1)*45).forEach((line,i) => sheet.drawText(line, {x:48,y:740-i*15,size:10,font:text.font,color:rgb(0.08,0.16,0.2)}));
    sheet.drawText(`Educational record | ${page+1} / ${pageCount}`, {x:48,y:35,size:9,font:text.font});
  }
  const bytes = await pdf.save();
  if (bytes.byteLength > HOME_SAFETY_REPORT_MAX_BYTES) throw new Error('REPORT_LIMIT');
  return {bytes,pageCount};
}
