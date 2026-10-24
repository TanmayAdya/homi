import type { ProgramDefinition, ResolvedBy } from '../types.ts';
const day = '2026-10-22';
const review = (id: string, label: string, reason: string, resolvedBy: ResolvedBy, sourceIds: string[]) =>
  ({ id, label, rule: { kind: 'manual_review' as const, reason, resolvedBy, sourceIds } });
export function createHpsmEaaResearchProgram(): ProgramDefinition {
  return {
    programId: 'hpsm-eaa', programName: 'HPSM Home Modifications (referral draft)',
    ruleVersion: 'hpsm-referral-preparation-2026-10-22-v1', isDemo: false,
    availability: 'unverified', rulesVerified: false, reviewedOn: day,
    effectiveFrom: null, effectiveUntil: null, recheckAfter: null,
    sources: [
      { id: 'hpsm-cs', url: 'https://www.hpsm.org/provider/calaim-at-hpsm/community-supports-(cs)',
        title: 'HPSM Community Supports provider instructions', reviewedOn: day, effectiveFrom: null, effectiveUntil: null },
      { id: 'hpsm-form', url: 'https://www.hpsm.org/docs/default-source/provider-forms/community-supports-referral-form.pdf?sfvrsn=9b37cc61_20',
        title: 'HPSM six-page Community Supports referral form; EAA on page 4', reviewedOn: day, effectiveFrom: null, effectiveUntil: null },
      { id: 'hpsm-cost-exception', url: 'https://www.hpsm.org/docs/default-source/provider-services/calaim/request-form-for-home-modifications-greater-than-7-500.pdf?sfvrsn=1d1815c3_5',
        title: 'HPSM request for home modifications greater than $7,500', reviewedOn: day, effectiveFrom: null, effectiveUntil: null },
    ],
    criteria: [
      review('enrollment', 'Active plan enrollment and applicable service area', 'Ask HPSM to confirm enrollment, product and service area. A reported plan name is not verified enrollment.', 'program', ['hpsm-cs']),
      review('care-coordination', 'Care manager and willingness to receive services', 'Coordinate with the care manager and obtain actual member agreement. App use does not constitute consent.', 'resident', ['hpsm-cs', 'hpsm-form']),
      review('clinical-need', 'Professional need and home assessment', 'A qualified professional must document the applicable clinical criteria, PT/OT evaluation and professional order. Observed hazards and resident reports do not establish medical necessity.', 'professional', ['hpsm-cs', 'hpsm-form']),
      review('service-scope', 'Requested home modifications and other coverage', 'Have HPSM review the requested scope, other available funding and whether services would duplicate coverage. Missing information remains unresolved.', 'program', ['hpsm-cs', 'hpsm-form']),
      review('cost-exception', 'Cost, prior funding and greater-than-$7,500 exception', 'Amounts above $7,500 require the documented HPSM exception request and plan review; they are not an automatic rejection. Confirm applicable limits and prior payments with HPSM.', 'program', ['hpsm-cost-exception']),
      review('permission', 'Property permission and required acknowledgements', 'Confirm the applicable property permissions and obtain actual documents. A reported answer is not a signed authorization.', 'resident', ['hpsm-form', 'hpsm-cs']),
      review('attestation', 'Referral attestation and professional completion', 'The referring professional must review and complete all applicable attestations, clinical criteria and signatures. These remain blank in the app draft.', 'professional', ['hpsm-form']),
      review('currentness', 'Accepted form, governing policy and current intake', 'Confirm the accepted form and current intake with HPSM. The six-page pinned form is prepared as an inert draft, not transmitted by this app.', 'program', ['hpsm-cs', 'hpsm-form']),
    ],
    requiredDocuments: [
      'Applicable professional order and individualized justification for requested adaptations.',
      'PT/OT evaluation and home assessment as required by HPSM; confirm exceptions with the plan.',
      'Itemized estimates, prior funding history and other coverage information for plan review.',
      'HPSM greater-than-$7,500 exception request when applicable; missing exception review is not a denial.',
      'Required property permissions and actual member/representative agreement.',
      'Referring professional review of clinical criteria, attestation and signature; the app leaves these blank.',
    ],
    intake: 'Preparation only. Use the current HPSM Community Supports instructions and coordinate with the care manager. The app does not send, submit or obtain approval for this draft.',
  };
}

export function createRtpResearchProgram(): ProgramDefinition {
  return {
    programId: 'rtp-home-repair', programName: 'Rebuilding Together Peninsula (preparation worksheet)',
    ruleVersion: 'rtp-preparation-2026-10-22-v1', isDemo: false,
    availability: 'unverified', rulesVerified: false, reviewedOn: day,
    effectiveFrom: null, effectiveUntil: null, recheckAfter: null,
    sources: [{ id: 'rtp-intake', url: 'https://rebuildingtogetherpeninsula.my.salesforce-sites.com/HomeownerApplication',
      title: 'RTP official homeowner online application', reviewedOn: day, effectiveFrom: null, effectiveUntil: null }],
    criteria: [
      review('geography', 'Current geographic service area', 'RTP must confirm the current eligible service area. No geographic boundary is activated from unverified information.', 'program', ['rtp-intake']),
      review('income', 'Current household income rules', 'RTP must verify current income limits, household composition and accepted evidence. This beta does not apply an unverified income threshold.', 'program', ['rtp-intake']),
      review('ownership', 'Ownership, occupancy and other property', 'Review owner occupancy, other property ownership and accepted ownership documents with RTP. Reported answers are preparation facts only.', 'resident', ['rtp-intake']),
      review('residence', 'Residence and intention to remain', 'Review residence documentation and plans to remain in the home for at least two years with RTP; RTP determines the applicable requirement.', 'resident', ['rtp-intake']),
      review('scope', 'Repair scope, suitability and availability', 'RTP reviews the requested repairs, property condition and current project capacity. A photo does not establish an offered service or repair commitment.', 'program', ['rtp-intake']),
      review('application', 'Official application and supporting documentation', 'Complete the official online intake separately. The generated worksheet is an app preparation aid, not an RTP form or submitted application.', 'resident', ['rtp-intake']),
    ],
    requiredDocuments: ['Proof of home ownership requested by RTP.', 'Household income documentation requested by RTP.',
      'Proof of residence and owner occupancy requested by RTP.', 'Repair description and questions for RTP review.',
      'Actual official application, permissions and signatures completed through the accepted RTP process.'],
    intake: 'Open the official homeowner application at https://rebuildingtogetherpeninsula.my.salesforce-sites.com/HomeownerApplication. This app produces a preparation worksheet only. Current income, geography and intake availability remain unverified. Do not upload financial or identity documents to this fictional beta.',
  };
}
