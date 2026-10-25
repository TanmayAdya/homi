import { createFormAnswerContext, createSavedFormAnswers, type FormAnswerInput } from '../src/forms/form-answers.ts';
import type { VerifiedFormTemplate } from '../src/forms/field-mapping.ts';
import type { CaseSnapshot } from '../src/types.ts';

export function fictionalReviewedAnswers(snapshot: CaseSnapshot, template: VerifiedFormTemplate, updatedAt: string) {
  const values: Record<FormAnswerInput['key'], string> = {
    memberFirstName: 'Alex', memberLastName: 'Example', memberBirthDate: '1956-02-29',
    memberId: 'FICTIONAL-001', memberPhone: '408-555-0101', memberPreferredSpokenLanguage: 'English',
    representativeName: 'Taylor Example', representativeEmail: 'taylor@example.org', representativePhone: '408-555-0102',
    referralDate: '2026-10-17', referralSource: 'Fictional student demonstration',
    referringOrganizationName: 'Example Organization', referringOrganizationPhone: '408-555-0103',
    referrerName: 'Sam Example', referrerTitle: 'Example role', referrerOrganizationName: 'Example Organization',
    referrerEmail: 'sam@example.org', referrerPhone: '408-555-0104',
  };
  return createSavedFormAnswers({ snapshot, context: createFormAnswerContext(template), answerRevision: 1,
    updatedAt, updatedBy: 'fictional-preparer', answers: Object.entries(values).map(([key, value]) => ({
      key: key as FormAnswerInput['key'], value, reviewState: 'reviewed',
    })) });
}
