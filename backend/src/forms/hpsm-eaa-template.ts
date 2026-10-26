import { defineVerifiedFormTemplate } from './field-mapping.ts';
export function createHpsmEaaFormTemplate() {
  return defineVerifiedFormTemplate({
  "schemaVersion": "1",
  "programId": "hpsm-eaa",
  "formVersion": "sha256:506b6606e3734a2c352a48a67eed28e250e9c369be10e38b52c699e86abbb0d0",
  "templateSha256": "506b6606e3734a2c352a48a67eed28e250e9c369be10e38b52c699e86abbb0d0",
  "mappingVersion": "hpsm-six-page-administrative-2026-10-22-v1",
  "publisherRevision": "HPSM six-page source; blank, inert preparation derivative; source hash in provenance",
  "sourceUrl": "https://www.hpsm.org/docs/default-source/provider-forms/community-supports-referral-form.pdf?sfvrsn=9b37cc61_20",
  "sourcePageUrl": "https://www.hpsm.org/provider/calaim-at-hpsm/community-supports-(cs)",
  "reviewedOn": "2026-10-22",
  "pageCount": 6,
  "fields": [
    {
      "fieldName": "MembersFirstName",
      "label": "memberFirstName",
      "pdfType": "Tx",
      "widgets": [
        {
          "page": 1,
          "rect": [
            345.545,
            328.5,
            576,
            346.5
          ],
          "exportValue": null
        }
      ],
      "semantic": "identity",
      "required": false,
      "maxLength": 160,
      "binding": {
        "kind": "reviewed_answer",
        "answerKey": "memberFirstName"
      }
    },
    {
      "fieldName": "MembersLastName",
      "label": "memberLastName",
      "pdfType": "Tx",
      "widgets": [
        {
          "page": 1,
          "rect": [
            99,
            328.5,
            274.5,
            346.5
          ],
          "exportValue": null
        }
      ],
      "semantic": "identity",
      "required": false,
      "maxLength": 160,
      "binding": {
        "kind": "reviewed_answer",
        "answerKey": "memberLastName"
      }
    },
    {
      "fieldName": "MemberDOB",
      "label": "memberBirthDate",
      "pdfType": "Tx",
      "widgets": [
        {
          "page": 1,
          "rect": [
            108,
            297,
            202.5,
            315
          ],
          "exportValue": null
        }
      ],
      "semantic": "identity",
      "required": false,
      "maxLength": 10,
      "binding": {
        "kind": "reviewed_answer",
        "answerKey": "memberBirthDate"
      }
    },
    {
      "fieldName": "HPSMID",
      "label": "memberId",
      "pdfType": "Tx",
      "widgets": [
        {
          "page": 1,
          "rect": [
            139.5,
            266.081,
            274.5,
            283.5
          ],
          "exportValue": null
        }
      ],
      "semantic": "identity",
      "required": false,
      "maxLength": 80,
      "binding": {
        "kind": "reviewed_answer",
        "answerKey": "memberId"
      }
    },
    {
      "fieldName": "MemberPhone",
      "label": "memberPhone",
      "pdfType": "Tx",
      "widgets": [
        {
          "page": 1,
          "rect": [
            81,
            139.5,
            274.5,
            157.5
          ],
          "exportValue": null
        }
      ],
      "semantic": "contact",
      "required": false,
      "maxLength": 40,
      "binding": {
        "kind": "reviewed_answer",
        "answerKey": "memberPhone"
      }
    },
    {
      "fieldName": "MembersLanguage",
      "label": "memberPreferredSpokenLanguage",
      "pdfType": "Tx",
      "widgets": [
        {
          "page": 1,
          "rect": [
            382.5,
            265.5,
            576,
            283.5
          ],
          "exportValue": null
        }
      ],
      "semantic": "contact",
      "required": false,
      "maxLength": 80,
      "binding": {
        "kind": "reviewed_answer",
        "answerKey": "memberPreferredSpokenLanguage"
      }
    },
    {
      "fieldName": "ReferralDate",
      "label": "referralDate",
      "pdfType": "Tx",
      "widgets": [
        {
          "page": 1,
          "rect": [
            126,
            418.5,
            306,
            436.5
          ],
          "exportValue": null
        }
      ],
      "semantic": "request_detail",
      "required": false,
      "maxLength": 10,
      "binding": {
        "kind": "reviewed_answer",
        "answerKey": "referralDate"
      }
    },
    {
      "fieldName": "ReferringOrgName",
      "label": "referringOrganizationName",
      "pdfType": "Tx",
      "widgets": [
        {
          "page": 2,
          "rect": [
            171,
            441,
            571.5,
            459
          ],
          "exportValue": null
        }
      ],
      "semantic": "identity",
      "required": false,
      "maxLength": 200,
      "binding": {
        "kind": "reviewed_answer",
        "answerKey": "referringOrganizationName"
      }
    },
    {
      "fieldName": "ReferralEmail",
      "label": "referrerEmail",
      "pdfType": "Tx",
      "widgets": [
        {
          "page": 2,
          "rect": [
            72,
            387,
            279,
            405
          ],
          "exportValue": null
        }
      ],
      "semantic": "contact",
      "required": false,
      "maxLength": 254,
      "binding": {
        "kind": "reviewed_answer",
        "answerKey": "referrerEmail"
      }
    },
    {
      "fieldName": "ReferentPhone",
      "label": "referrerPhone",
      "pdfType": "Tx",
      "widgets": [
        {
          "page": 2,
          "rect": [
            396,
            414,
            571.5,
            432
          ],
          "exportValue": null
        }
      ],
      "semantic": "contact",
      "required": false,
      "maxLength": 40,
      "binding": {
        "kind": "reviewed_answer",
        "answerKey": "referrerPhone"
      }
    },
    {
      "fieldName": "5",
      "label": "EAA referral route only; not clinical eligibility",
      "pdfType": "Btn",
      "widgets": [
        {
          "page": 4,
          "rect": [
            31.25,
            724.25,
            49.75,
            742.75
          ],
          "exportValue": "Yes"
        }
      ],
      "semantic": "routing",
      "required": false,
      "maxLength": null,
      "binding": {
        "kind": "routing",
        "programId": "hpsm-eaa",
        "widgetIndex": 0,
        "value": "Yes"
      }
    }
  ]
});
}
