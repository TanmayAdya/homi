import { handleReadFormAnswers, handleSaveFormAnswers, type FormAnswerDependencies } from './form-answers.ts';
import { formAnswerFieldsForProgram, formArtifactKind, type FormAnswerKey } from '../forms/form-answers.ts';
const labels: Record<FormAnswerKey, string> = {
  memberFirstName: 'Given name', memberLastName: 'Family name', memberBirthDate: 'Date of birth (YYYY-MM-DD)',
  memberId: 'Plan member identifier', memberPhone: 'Contact phone', memberPreferredSpokenLanguage: 'Preferred spoken language',
  representativeName: 'Authorized representative name', representativeEmail: 'Authorized representative email',
  representativePhone: 'Authorized representative phone', referralDate: 'Referral date (YYYY-MM-DD)',
  referralSource: 'Referral source', referringOrganizationName: 'Referring organization',
  referringOrganizationPhone: 'Referring organization phone', referrerName: 'Referring individual name',
  referrerTitle: 'Referring individual title', referrerOrganizationName: 'Referring individual organization',
  referrerEmail: 'Referring individual email', referrerPhone: 'Referring individual phone',
};
async function handle(input: { body: unknown; bearerToken: string | null }, deps: FormAnswerDependencies, save: boolean) {
  const raw = input.body;
  const valid = raw !== null && typeof raw === 'object' && !Array.isArray(raw)
    && (raw as Record<string, unknown>).schemaVersion === '2';
  const normalized = valid ? { ...structuredClone(raw as Record<string, unknown>), schemaVersion: '1' } : null;
  const result = await (save ? handleSaveFormAnswers : handleReadFormAnswers)({ ...input, body: normalized }, deps);
  if ('error' in result.body) return result;
  const programId = result.body.context.programId;
  const definitions = formAnswerFieldsForProgram(programId).map(field => ({ key: field.key, label: labels[field.key],
    kind: field.kind, maxLength: field.maxLength }));
  return { ...result, body: { ...result.body, schemaVersion: '2' as const,
    fieldDefinitions: definitions, artifactKind: formArtifactKind(programId) } };
}
export const handleReadFormAnswersV2 = (input: { body: unknown; bearerToken: string | null }, deps: FormAnswerDependencies) => handle(input, deps, false);
export const handleSaveFormAnswersV2 = (input: { body: unknown; bearerToken: string | null }, deps: FormAnswerDependencies) => handle(input, deps, true);
