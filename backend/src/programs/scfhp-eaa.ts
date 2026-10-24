import type { ProgramDefinition, ResolvedBy, Source } from '../types.ts';

export const SCFHP_EAA_SOURCES: Source[] = [
  {
    id: 'scfhp-members',
    url: 'https://www.scfhp.com/healthcare-plans/medi-cal/programs/community-supports/',
    title: 'SCFHP member Community Supports page — EAA and access sections',
    reviewedOn: '2026-10-17', effectiveFrom: null, effectiveUntil: null,
  },
  {
    id: 'scfhp-providers',
    url: 'https://www.scfhp.com/for-providers/communitysupports-cs-healthhomes-hhp/',
    title: 'SCFHP provider Community Supports page — EAA and referral FAQs',
    reviewedOn: '2026-10-17', effectiveFrom: null, effectiveUntil: null,
  },
  {
    id: 'scfhp-guide-2026',
    url: 'https://res.cloudinary.com/dpmykpsih/image/upload/santa-clara-site-299/media/c633fdb6655e4c9eb679b8365b01afed/41559-community-support-provider-user-guide-final.pdf',
    title: 'SCFHP January 2026 Provider User Guide — EAA, printed pages 69–72',
    reviewedOn: '2026-10-17', effectiveFrom: null, effectiveUntil: null,
  },
  {
    id: 'scfhp-form-41567',
    url: 'https://res.cloudinary.com/dpmykpsih/image/upload/santa-clara-site-299/media/220648f9db4244ab883beee4ece8e702/41567-community-supports-referral-form-asthma-remediation-and-home-modifications-final.pdf',
    title: 'SCFHP referral form 41567 — EAA questions, consent and supporting records',
    reviewedOn: '2026-10-17', effectiveFrom: null, effectiveUntil: null,
  },
  {
    id: 'scfhp-supporting-documents',
    url: 'https://res.cloudinary.com/dpmykpsih/image/upload/santa-clara-site-299/media/6613ae64fd864cfc8a6d90288adbb010/40909-examples-of-referral-supporting-documentation.pdf',
    title: 'SCFHP supporting-document examples 40909 — EAA, page 3; conditional records',
    reviewedOn: '2026-10-17', effectiveFrom: null, effectiveUntil: null,
  },
  {
    id: 'dhcs-guide-2025',
    url: 'https://www.dhcs.ca.gov/file/dhcs-community-supports-policy-guide-pdf/',
    title: 'DHCS April 2025 Community Supports Policy Guide Volume 1 — EAA, printed pages 28–31',
    reviewedOn: '2026-10-17', effectiveFrom: null, effectiveUntil: null,
  },
  {
    id: 'dhcs-policy-resources',
    url: 'https://www.dhcs.ca.gov/calaim-transforming-medi-cal/enhanced-care-management-and-community-supports/resources-ecm-resources/',
    title: 'DHCS policy resources — April 2025 Volume 1 and separately labeled proposed 2026 updates',
    reviewedOn: '2026-10-17', effectiveFrom: null, effectiveUntil: null,
  },
  {
    id: 'dhcs-proposed-2026',
    url: 'https://www.dhcs.ca.gov/file/summary-of-changes-july-2026-community-supports-policy-guide-vol-1/',
    title: 'DHCS proposed July 2026 Volume 1 changes — EAA, printed pages 15–17; adoption unverified',
    reviewedOn: '2026-10-17', effectiveFrom: null, effectiveUntil: null,
  },
  {
    id: 'dhcs-elections-2026',
    url: 'https://www.dhcs.ca.gov/file/community-supports-elections-by-mcp-and-county-pdf/',
    title: 'DHCS Community Supports elections July 1, 2026 — Santa Clara/SCFHP EAA, page 4; dated June 30',
    reviewedOn: '2026-10-17', effectiveFrom: null, effectiveUntil: null,
  },
];

function review(id: string, label: string, reason: string, resolvedBy: ResolvedBy, sourceIds: string[]) {
  return { id, label, rule: { kind: 'manual_review' as const, reason, resolvedBy, sourceIds } };
}

export function createScfhpEaaResearchProgram(): ProgramDefinition {
  return {
    programId: 'scfhp-eaa',
    programName: 'SCFHP Environmental Accessibility Adaptations (referral draft)',
    ruleVersion: 'referral-draft-2026-10-17-v2',
    isDemo: false, availability: 'unverified', rulesVerified: false,
    reviewedOn: '2026-10-17', effectiveFrom: null, effectiveUntil: null, recheckAfter: null,
    sources: structuredClone(SCFHP_EAA_SOURCES),
    criteria: [
      review('enrollment', 'Plan product, active enrollment and service area',
        'SCFHP publishes this route for Medi-Cal and DualConnect members, and DHCS lists EAA for SCFHP in Santa Clara County. Ask the plan to verify this person’s product, active enrollment and applicable service area; a typed plan name or county does not establish them.',
        'program', ['scfhp-members', 'scfhp-providers', 'dhcs-elections-2026']),
      review('clinical-need', 'Clinical need and institutionalization risk',
        'A qualified professional must document the clinical need and relevant care setting. Home observations do not establish these determinations.',
        'professional', ['scfhp-guide-2026', 'scfhp-form-41567']),
      review('service-scope', 'Requested adaptation and permitted scope',
        'Have the plan review the requested adaptation, its medical or remedial purpose and any applicable scope exception. An observed hazard alone does not establish a covered service.',
        'program', ['scfhp-guide-2026', 'dhcs-guide-2025']),
      review('alternative-coverage', 'Other coverage and duplicate services',
        'Ask the plan whether an available Medi-Cal or Medicare benefit can achieve the same goals, and whether other funded services would duplicate this request. Do not assume an alternative is available or sufficient.',
        'program', ['scfhp-guide-2026', 'dhcs-guide-2025']),
      review('assessment', 'Assessment and supporting evaluation',
        'Coordinate the required professional order and individualized justification, home suitability review and any applicable PT/OT evaluation. The plan must confirm whether approval without a therapy evaluation applies; missing paperwork alone does not establish ineligibility.',
        'professional', ['scfhp-guide-2026', 'scfhp-form-41567', 'dhcs-guide-2025', 'scfhp-supporting-documents']),
      review('property-permission', 'Property acknowledgements',
        'With the plan’s guidance, obtain the owner’s written permission and applicable property acknowledgements for installed work in a home the member does not own. Reported permission is not signed documentation; missing paperwork does not establish refusal.',
        'resident', ['scfhp-guide-2026', 'scfhp-form-41567', 'dhcs-guide-2025']),
      review('cost-and-prior-use', 'Cost limit and applicable exceptions',
        'The DHCS and SCFHP guides state a $7,500 lifetime limit with exceptions; the referral form says per authorization. Ask the plan to confirm the applicable limit and exception interpretation. Do not infer a renewed allowance or reject an unresolved exception.',
        'program', ['scfhp-guide-2026', 'scfhp-form-41567', 'dhcs-guide-2025']),
      review('prior-use', 'Prior EAA use and remaining funding',
        'Ask the plan to verify prior EAA payments and the funding history relevant to this request. Missing history is not zero prior use, and the app cannot calculate a remaining allowance from the current profile.',
        'program', ['scfhp-guide-2026', 'dhcs-guide-2025']),
      review('consent', 'Consent to services and data sharing',
        'Obtain the member’s actual consent through the appropriate process. No answer is inferred from use of this app or reported owner permission.',
        'resident', ['scfhp-form-41567']),
      review('policy-currentness', 'Applicable policy and current intake',
        'Confirm the governing policy, accepted form and current intake with the plan. DHCS still labels the July 2026 Volume 1 changes proposed; this review does not establish adoption, a complete effective period or open capacity.',
        'program', ['dhcs-policy-resources', 'dhcs-proposed-2026', 'scfhp-providers']),
    ],
    requiredDocuments: [
      'Professional order and individualized equipment/service justification; confirm the appropriate author and supporting equipment information.',
      'Relevant discharge and support-agency records, if available and applicable; their absence does not establish refusal or ineligibility.',
      'Home suitability documentation and PT/OT evaluation when required; the plan determines whether an evaluation exception applies.',
      'Itemized estimates in the form’s four cost categories, with two provider bids where possible; confirm scope and any cost exception with the plan.',
      'Owner permission and property acknowledgements for applicable installed work; obtain actual documents rather than inferring them from reported permission.',
      'Actual member/representative consent and the referring person’s reviewed attestation and signature; the app does not supply these.',
    ],
    intake: 'Informational only: SCFHP publishes its Provider Portal and fax 1-408-874-1985 for referrals. Members can ask Medi-Cal Customer Service at 1-800-260-2055 or DualConnect at 1-877-723-4795. Confirm current instructions and applicable documents with the plan; this app does not submit referrals or promise approval.',
  };
}
