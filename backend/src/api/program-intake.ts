import { intakeDefinition, parseIntakeAnswers, parseSavedProgramIntake, type IntakeDefinition, type SavedProgramIntake } from '../programs/intake.ts';
import { canonicalJson, evidenceIdentifier, evidenceRevision } from '../evidence/validation.ts';
import type { AuthenticatedUser } from './match-case.ts';
import { AccountClosedError } from '../lifecycle/types.ts';

export interface ProgramIntakeReadInput { userId: string; caseId: string; revision: number; programId: string }
export type ProgramIntakeReadResult = { status: 'found'; saved: SavedProgramIntake | null } | { status: 'not_found' | 'conflict' };
export interface ProgramIntakeSaveInput extends ProgramIntakeReadInput { expectedIntakeRevision: number; intake: SavedProgramIntake }
export type ProgramIntakeSaveResult = { status: 'saved'; saved: SavedProgramIntake; caseRevision: number } | { status: 'not_found' | 'conflict' | 'intake_conflict' };
export interface ProgramIntakeRepository {
  readProgramIntakeIfCurrent(input: ProgramIntakeReadInput): Promise<ProgramIntakeReadResult>;
  saveProgramIntakeIfCurrent(input: ProgramIntakeSaveInput): Promise<ProgramIntakeSaveResult>;
}
export interface ProgramIntakeDependencies { authenticate(token: string): Promise<AuthenticatedUser | null>; cases: ProgramIntakeRepository; now(): Date }
export interface ProgramIntakeResponse { schemaVersion: '2'; caseId: string; caseRevision: number; definition: IntakeDefinition; saved: SavedProgramIntake | null; isCurrent: boolean }
export type ProgramIntakeResult = { status: number; headers: Record<string, string>; body: ProgramIntakeResponse | { schemaVersion: '2'; error: { code: string; message: string } } };
const errors: Record<string, [number, string]> = {
  INVALID_REQUEST: [400, 'Provide only the reviewed program questions and valid answers.'],
  UNAUTHENTICATED: [401, 'Sign in before reviewing program questions.'], ACCOUNT_CLOSED: [409, 'This account is closed.'],
  CASE_NOT_FOUND: [404, 'The requested case is unavailable.'], PROGRAM_NOT_FOUND: [404, 'This preparation route is unavailable.'],
  CASE_REVISION_MISMATCH: [409, 'The case changed. Reload before saving answers.'],
  INTAKE_CONFLICT: [409, 'The saved program answers changed. Reload and reconcile.'],
  QUESTIONNAIRE_CHANGED: [409, 'These questions changed. Review the current questionnaire.'],
  SERVICE_UNAVAILABLE: [503, 'Program preparation is temporarily unavailable.'], INTERNAL_ERROR: [500, 'The program preparation result could not be confirmed.'],
};
function failure(code: string): ProgramIntakeResult { const [status, message] = errors[code]; return { status, headers: { 'Cache-Control': 'no-store' }, body: { schemaVersion: '2', error: { code, message } } }; }
function object(value: unknown, keys: string[]): value is Record<string, unknown> { return value !== null && typeof value === 'object' && !Array.isArray(value) && Object.keys(value).length === keys.length && keys.every(key => Object.hasOwn(value, key)); }
async function handle(input: { body: unknown; bearerToken: string | null }, deps: ProgramIntakeDependencies, save: boolean): Promise<ProgramIntakeResult> {
  try {
    const token = input.bearerToken;
    if (typeof token !== 'string' || token.length > 4096 || !/^[A-Za-z0-9._~+\/-]+=*$/.test(token)) return failure('UNAUTHENTICATED');
    const raw = input.body;
    if (!object(raw, ['schemaVersion', 'caseId', 'expectedCaseRevision', 'programId', ...(save ? ['expectedIntakeRevision', 'expectedQuestionnaireVersion', 'answers'] : [])])
      || raw.schemaVersion !== '2' || !evidenceIdentifier(raw.caseId) || !evidenceIdentifier(raw.programId) || !evidenceRevision(raw.expectedCaseRevision)) return failure('INVALID_REQUEST');
    const body = structuredClone(raw);
    const definition = intakeDefinition(body.programId as string);
    let user: AuthenticatedUser | null;
    try { user = await deps.authenticate(token); } catch (e) { return failure(e instanceof AccountClosedError ? 'ACCOUNT_CLOSED' : 'SERVICE_UNAVAILABLE'); }
    if (user === null) return failure('UNAUTHENTICATED');
    if (!evidenceIdentifier(user.userId)) return failure('INTERNAL_ERROR');
    if (definition === null) return failure('PROGRAM_NOT_FOUND');
    const query = { userId: user.userId, caseId: body.caseId as string, revision: body.expectedCaseRevision as number, programId: body.programId as string };
    const response = (saved: SavedProgramIntake | null, revision: number): ProgramIntakeResult => ({ status: 200, headers: { 'Cache-Control': 'no-store' },
      body: { schemaVersion: '2', caseId: query.caseId, caseRevision: revision, definition, saved,
        isCurrent: saved !== null && saved.caseRevision === revision && saved.questionnaireVersion === definition.questionnaireVersion } });
    if (!save) {
      const result = await deps.cases.readProgramIntakeIfCurrent(query);
      if (result.status !== 'found') return failure(result.status === 'not_found' ? 'CASE_NOT_FOUND' : 'CASE_REVISION_MISMATCH');
      const saved = result.saved === null ? null : parseSavedProgramIntake(result.saved);
      if (saved && (saved.caseId !== query.caseId || saved.programId !== query.programId || saved.caseRevision > query.revision || saved.updatedBy !== user.userId)) return failure('INTERNAL_ERROR');
      return response(saved, query.revision);
    }
    if (!evidenceRevision(body.expectedIntakeRevision, true) || !Number.isSafeInteger(query.revision + 1) || !Number.isSafeInteger(Number(body.expectedIntakeRevision) + 1)) return failure('INVALID_REQUEST');
    if (body.expectedQuestionnaireVersion !== definition.questionnaireVersion) return failure('QUESTIONNAIRE_CHANGED');
    let saved: SavedProgramIntake;
    try {
      saved = parseSavedProgramIntake({ schemaVersion: '2', caseId: query.caseId, caseRevision: query.revision + 1,
        programId: query.programId, questionnaireVersion: definition.questionnaireVersion, intakeRevision: Number(body.expectedIntakeRevision) + 1,
        updatedAt: deps.now().toISOString(), updatedBy: user.userId, answers: parseIntakeAnswers(body.answers, definition) });
    } catch { return failure('INVALID_REQUEST'); }
    const expectedSaved = canonicalJson(saved);
    const result = await deps.cases.saveProgramIntakeIfCurrent({ ...query, expectedIntakeRevision: Number(body.expectedIntakeRevision), intake: structuredClone(saved) });
    if (result.status !== 'saved') return failure(result.status === 'not_found' ? 'CASE_NOT_FOUND' : result.status === 'conflict' ? 'CASE_REVISION_MISMATCH' : 'INTAKE_CONFLICT');
    if (result.caseRevision !== query.revision + 1 || canonicalJson(result.saved) !== expectedSaved) return failure('INTERNAL_ERROR');
    return response(saved, result.caseRevision);
  } catch (e) { return failure(e instanceof AccountClosedError ? 'ACCOUNT_CLOSED' : 'SERVICE_UNAVAILABLE'); }
}
export const handleReadProgramIntake = (input: { body: unknown; bearerToken: string | null }, deps: ProgramIntakeDependencies) => handle(input, deps, false);
export const handleSaveProgramIntake = (input: { body: unknown; bearerToken: string | null }, deps: ProgramIntakeDependencies) => handle(input, deps, true);
