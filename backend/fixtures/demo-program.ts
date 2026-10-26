import type { EvaluationContext, ProgramDefinition } from '../src/types.ts';

export const demoProgram: ProgramDefinition = {
  programId: 'demo-home-support', programName: 'Example assistance route',
  ruleVersion: 'demo-v1', isDemo: true, availability: 'unverified',
  rulesVerified: false, reviewedOn: null, effectiveFrom: null, effectiveUntil: null,
  recheckAfter: '2026-10-14T19:00:00Z', sources: [], requiredDocuments: [], intake: null,
  criteria: [
    { id: 'city', label: 'City', rule: { kind: 'eq', field: 'city', value: 'Demo City', sourceIds: [], resolvedBy: 'resident' } },
    { id: 'plan', label: 'Health plan', rule: { kind: 'eq', field: 'healthPlan', value: 'Example Plan', sourceIds: [], resolvedBy: 'resident' } },
  ],
};

export const demoContext: EvaluationContext = {
  evaluatedAt: '2026-10-13T19:00:00Z', evaluationDate: '2026-10-13',
};
