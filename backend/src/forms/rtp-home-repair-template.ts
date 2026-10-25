import { defineVerifiedFormTemplate } from './field-mapping.ts';
export function createRtpHomeRepairFormTemplate() {
  return defineVerifiedFormTemplate({
  "schemaVersion": "1",
  "programId": "rtp-home-repair",
  "formVersion": "sha256:ed9ea6e6fbfc670135bf1dbb4ee94538022664bdb2500f5cbc49a16bdf6a6687",
  "templateSha256": "ed9ea6e6fbfc670135bf1dbb4ee94538022664bdb2500f5cbc49a16bdf6a6687",
  "mappingVersion": "rtp-preparation-worksheet-2026-10-22-v1",
  "publisherRevision": "Safe at Home app-generated preparation worksheet; not an RTP form",
  "sourceUrl": "https://rebuildingtogetherpeninsula.my.salesforce-sites.com/HomeownerApplication",
  "sourcePageUrl": "https://rebuildingtogetherpeninsula.org/",
  "reviewedOn": "2026-10-22",
  "pageCount": 1,
  "fields": [
    {
      "fieldName": "memberFirstName",
      "label": "memberFirstName",
      "pdfType": "Tx",
      "widgets": [
        {
          "page": 1,
          "rect": [
            43.75,
            631.75,
            564.25,
            652.25
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
      "fieldName": "memberLastName",
      "label": "memberLastName",
      "pdfType": "Tx",
      "widgets": [
        {
          "page": 1,
          "rect": [
            43.75,
            567.75,
            564.25,
            588.25
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
      "fieldName": "memberPhone",
      "label": "memberPhone",
      "pdfType": "Tx",
      "widgets": [
        {
          "page": 1,
          "rect": [
            43.75,
            503.75,
            564.25,
            524.25
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
      "fieldName": "memberPreferredSpokenLanguage",
      "label": "memberPreferredSpokenLanguage",
      "pdfType": "Tx",
      "widgets": [
        {
          "page": 1,
          "rect": [
            43.75,
            439.75,
            564.25,
            460.25
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
    }
  ]
});
}
