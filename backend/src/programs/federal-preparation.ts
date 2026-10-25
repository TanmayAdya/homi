import type { ProgramDefinition, ResolvedBy, Source } from '../types.ts';

const reviewedOn = '2026-10-26';

function source(id: string, url: string, title: string): Source {
  return { id, url, title, reviewedOn, effectiveFrom: null, effectiveUntil: null };
}

function review(id: string, label: string, reason: string, resolvedBy: ResolvedBy, sourceIds: string[]) {
  return { id, label, rule: { kind: 'manual_review' as const, reason, resolvedBy, sourceIds } };
}

function preparation(program: Omit<ProgramDefinition,
  'isDemo' | 'availability' | 'rulesVerified' | 'reviewedOn' | 'effectiveFrom' | 'effectiveUntil' | 'recheckAfter'>): ProgramDefinition {
  return { ...program, isDemo: false, availability: 'unverified', rulesVerified: false,
    reviewedOn, effectiveFrom: null, effectiveUntil: null, recheckAfter: null };
}

export function createUsdaSection504PreparationProgram(): ProgramDefinition {
  return preparation({
    programId: 'usda-section-504',
    programName: 'USDA Section 504 Home Repair (preparation checklist)',
    ruleVersion: 'usda-504-preparation-2026-10-26-v1',
    sources: [
      source('usda-504-overview', 'https://www.rd.usda.gov/programs-services/single-family-housing-programs/single-family-housing-repair-loans-grants',
        'USDA Section 504 national overview and state-specific application resources'),
      source('usda-504-fact-sheet', 'https://www.rd.usda.gov/media/file/download/rhs-fs-sfh-504-repair-loan-grant.pdf',
        'USDA Section 504 fact sheet, revised September 2026; income wording differs from current regulation'),
      source('usda-504-eligibility', 'https://www.ecfr.gov/current/title-7/subtitle-B/chapter-XXXV/part-3550/subpart-C/section-3550.103',
        '7 CFR 3550.103, current through October 22, 2026 when reviewed; adjusted-income and applicant requirements'),
      source('usda-504-application', 'https://www.ecfr.gov/current/title-7/subtitle-B/chapter-XXXV/part-3550/subpart-C/section-3550.104',
        '7 CFR 3550.104, written application and agency review'),
      source('usda-504-intake-form', 'https://forms.sc.egov.usda.gov/efcommon/eFileServices/eForms/RD3550-35.PDF',
        'RD 3550-35, revision 03-24, OMB expiration November 30, 2026; older income wording; no app field mapping'),
      source('usda-504-checklist', 'https://www.rd.usda.gov/media/file/download/rd-sfh-attachment12e.pdf',
        'HB-1-3550 Attachment 12-E, revised March 8, 2024; applicable application documents'),
    ],
    criteria: [
      review('rural-property', 'Exact property location and rural-area eligibility',
        'Ask USDA to check the property address. A state, county name or ZIP alone does not establish an eligible rural property.',
        'program', ['usda-504-overview']),
      review('ownership-occupancy', 'Ownership, occupancy and property arrangements',
        'Supply ownership and occupancy evidence for USDA review. A reported owner or renter answer does not resolve permitted title or property arrangements.',
        'resident', ['usda-504-eligibility', 'usda-504-checklist']),
      review('income-policy-conflict', 'Adjusted income, household basis and conflicting policy sources',
        'The September 2026 fact sheet and national overview describe loans for low- and very-low-income homeowners, while current 7 CFR 3550.103(c) states the very-low-income limit. Ask USDA to resolve the applicable policy, county limit and adjusted household income; the app applies neither conflicting threshold.',
        'program', ['usda-504-overview', 'usda-504-fact-sheet', 'usda-504-eligibility']),
      review('credit-resources-repayment', 'Other credit, personal resources and repayment assessment',
        'USDA must assess other financing, assets and repayment ability, including any appropriate loan, grant or combination. Missing credit or benefit history is not zero, and the app does not determine financing terms.',
        'program', ['usda-504-eligibility', 'usda-504-overview']),
      review('grant-age-alternative', 'Grant age requirement and loan alternative',
        'USDA lists age 62 or older for grants. Confirm age evidence and applicable assistance type with USDA; being younger does not by itself reject a possible loan route.',
        'resident', ['usda-504-eligibility', 'usda-504-overview']),
      review('repair-scope', 'Requested work and permitted funding purpose',
        'Have USDA review repair scope, property requirements and the loan or grant purpose. A recorded hazard or scan does not establish approval.',
        'program', ['usda-504-overview']),
      review('applicant-requirements', 'Other applicant requirements and applicable alternatives',
        'USDA must review qualifying status, legal capacity or an empowered guardian or conservator, and other applicable requirements. The app does not infer these facts from the resident profile.',
        'program', ['usda-504-eligibility']),
      review('local-intake-currentness', 'State requirements, accepted forms and funding',
        'Confirm state-specific requirements, local funding and current forms with USDA. Optional informal prequalification is not a prerequisite. This checklist is app-generated and is not an official application.',
        'program', ['usda-504-overview', 'usda-504-intake-form', 'usda-504-application']),
    ],
    requiredDocuments: [
      'Ask the local USDA office which current application forms and state-specific items apply; RD 3550-35 prequalification intake is optional, not the completed application.',
      'Applicable identity, age, income and asset records; signed adult release and employment/asset certification forms are supplied by the actual people, not generated consent.',
      'Ownership, tax, insurance and mortgage records as applicable; ask USDA about acceptable alternatives.',
      'Itemized repair bids, contractor credentials where required and reviewed property photographs, following the official Attachment 12-E checklist.',
      'Provide sensitive supporting records directly through the USDA-approved process. This preparation checklist does not collect taxpayer IDs, supply signatures or submit documents.',
    ],
    intake: 'Preparation and official referral only. Open the USDA national Section 504 page, select the property state and contact the local Rural Development office or home-loan specialist. Confirm current written application instructions and funding. This app does not transmit an application, promise funding or generate the official USDA forms.',
  });
}

export function createVaHisaPreparationProgram(): ProgramDefinition {
  return preparation({
    programId: 'va-hisa',
    programName: 'VA HISA Home Improvements (preparation checklist)',
    ruleVersion: 'va-hisa-preparation-2026-10-26-v1',
    sources: [
      source('va-hisa-overview', 'https://prosthetics.va.gov/psas/hisa2.asp',
        'VA Prosthetic and Sensory Aids Service HISA scope, package and lifetime categories'),
      source('va-hisa-directive', 'https://www.va.gov/VHAPUbLICAtIons/ViewPublication.asp?pub_ID=5739',
        'VHA Directive 1173.14(2), December 26, 2017, amended November 16, 2025; eligibility alternatives and responsibilities'),
      source('va-hisa-form-page', 'https://www.va.gov/forms/10-0103/',
        'VA Form 10-0103 landing page labels revision February 2025; linked PDF prints March 2025'),
      source('va-hisa-form-pdf', 'https://www.va.gov/vaforms/medical/pdf/10-0103-fill.pdf',
        'VA Form 10-0103, printed MAR 2025, OMB expiration June 30, 2027; accepted revision unresolved, no app field mapping'),
    ],
    criteria: [
      review('beneficiary-alternatives', 'Veteran or qualifying servicemember eligibility',
        'VA must verify eligibility for medical services or the qualifying permanent-disability medical-discharge alternative for a servicemember receiving relevant care. No service-connected rating in this profile is not a rejection of all alternatives.',
        'program', ['va-hisa-directive']),
      review('clinical-prescription', 'VA prescription and medical justification',
        'A VA physician must write or approve the prescription and clinical justification. Scans, photographs and resident reports do not establish a diagnosis or medical necessity.',
        'professional', ['va-hisa-overview', 'va-hisa-directive']),
      review('primary-residence-scope', 'Primary residence, permitted work and alternative equipment routes',
        'Have VA review the proposed adaptation and residence. A HISA scope exclusion may have another VA equipment route; it does not establish that no assistance exists.',
        'program', ['va-hisa-overview', 'va-hisa-directive']),
      review('benefit-category-prior-use', 'Lifetime category and actual remaining benefit',
        'Local VA Prosthetics must verify the applicable lifetime category and prior use. Do not add disability percentages, assume missing history means zero, or treat a published maximum as the amount available.',
        'program', ['va-hisa-overview']),
      review('property-permission', 'Required property-owner authorization',
        'For renters, obtain the signed and notarized owner authorization required by VA. A reported permission answer is not that document, and missing paperwork is not refusal.',
        'resident', ['va-hisa-overview']),
      review('estimate-and-evidence', 'Estimate, photograph and completed package',
        'Obtain an itemized estimate and color photograph of the unimproved area; confirm other package details with VA. The current directive does not require three bids. An inspection may be needed.',
        'resident', ['va-hisa-overview', 'va-hisa-directive']),
      review('overlapping-benefits', 'Related housing benefits and duplicate work',
        'Ask VA to review other housing benefits and duplicate work. Separate HISA and other housing projects may be concurrent; the app does not infer duplicate funding or categorical exclusion.',
        'program', ['va-hisa-directive']),
      review('form-intake-currentness', 'Accepted form revision and local submission instructions',
        'The form page labels February 2025, while its linked PDF prints MAR 2025. Confirm the accepted revision and local instructions with VA. Actual signatures and submission remain with the applicant and VA; this is an app-generated checklist.',
        'program', ['va-hisa-form-page', 'va-hisa-form-pdf']),
    ],
    requiredDocuments: [
      'VA-written or approved prescription describing the project, alternatives, diagnosis and clinical justification; the app does not author professional determinations.',
      'Current accepted VA Form 10-0103, reviewed and signed by the actual applicant; confirm the February/March 2025 revision discrepancy with VA.',
      'Signed and notarized property-owner authorization when renting, as required by VA.',
      'Itemized estimate for labor, materials, permits and inspections, plus a color photograph of the unimproved area; confirm inspection and local package requirements.',
      'Confirm prior benefits and sensitive records directly with VA. This checklist does not collect SSNs, supply signatures or establish the remaining lifetime allowance.',
    ],
    intake: 'Preparation and official referral only. Contact the local VA Prosthetic and Sensory Aids Service using the facility locator linked from the official HISA page. VA Form 10-0103 directs submission to the VA health-care facility where the veteran receives care. Its paperwork-feedback email is not an application destination. The app does not submit or approve requests or generate the official form.',
  });
}

export function createFederalPreparationPrograms(): ProgramDefinition[] {
  return [createUsdaSection504PreparationProgram(), createVaHisaPreparationProgram()];
}
