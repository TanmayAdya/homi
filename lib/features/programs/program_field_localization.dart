import 'package:flutter/widgets.dart';
import 'package:safe_at_home/l10n/app_localizations.dart';
import '../../shared/models/program_intake.dart';
import '../../shared/models/form_answers.dart';

const _intakeVersions = <String, String>{
  'scfhp-eaa':
      'a435cbfede8e433831b80d2808b5aa611eb796553ab596ce20d089530e04c1a5',
  'hpsm-eaa':
      '4059c929ea12ef5ae544ccbf65df00360c8ee15ffb72ff5d66cbf977f4417e37',
  'rtp-home-repair':
      'b65e4a71378a4eff16968fe695a90dbb4eb2e5f4396e35c4889a253f25f62f72',
};
const _intakeKeys = <String, List<String>>{
  'scfhp-eaa': [
    "activeMembershipReported",
    "willingServicesReported",
    "professionalEvaluationReported",
    "professionalOrderReported",
    "otherFundingReported",
    "estimatedCostUsd",
    "priorEaaPaidUsd",
  ],
  'hpsm-eaa': [
    "activeMembershipReported",
    "willingServicesReported",
    "professionalEvaluationReported",
    "professionalOrderReported",
    "otherFundingReported",
    "estimatedCostUsd",
    "priorEaaPaidUsd",
    "careManagerEngagedReported",
  ],
  'rtp-home-repair': [
    "ownerOccupiedReported",
    "otherPropertyReported",
    "intendRemainTwoYearsReported",
    "incomeDocumentsReady",
    "ownershipDocumentsReady",
    "residenceDocumentsReady",
    "repairRequest",
  ],
};
const _questions = <String, (String, String, int?, String)>{
  "activeMembershipReported": (
    "Do you believe your membership is currently active?",
    "boolean",
    null,
    "The health plan must verify enrollment and applicable coverage.",
  ),
  "willingServicesReported": (
    "Are you interested in receiving home adaptation services?",
    "boolean",
    null,
    "Interest is not a signed consent or authorization.",
  ),
  "professionalEvaluationReported": (
    "Do you have a professional home or therapy evaluation?",
    "boolean",
    null,
    "Record whether a document is available. The app does not evaluate medical necessity.",
  ),
  "professionalOrderReported": (
    "Do you have a professional order for the requested work?",
    "boolean",
    null,
    "The responsible professional and health plan determine whether the order is sufficient.",
  ),
  "otherFundingReported": (
    "Is another source paying for the same requested work?",
    "boolean",
    null,
    "The plan reviews overlapping services and other coverage.",
  ),
  "estimatedCostUsd": (
    "Estimated project cost, if known",
    "money",
    null,
    "US dollars, up to two decimal places. Unknown is different from zero. A reported amount does not establish funding eligibility.",
  ),
  "priorEaaPaidUsd": (
    "Prior EAA payments, if known",
    "money",
    null,
    "US dollars, up to two decimal places. Unknown is different from zero. A reported amount does not establish funding eligibility.",
  ),
  "careManagerEngagedReported": (
    "Are you working with a care manager?",
    "boolean",
    null,
    "HPSM must confirm its current care-management and referral requirements.",
  ),
  "ownerOccupiedReported": (
    "Do you own and live in the home?",
    "boolean",
    null,
    "RTP must verify ownership, residence and its current service area.",
  ),
  "otherPropertyReported": (
    "Do you own other real estate?",
    "boolean",
    null,
    "RTP must confirm whether and how this affects the currently accepted application.",
  ),
  "intendRemainTwoYearsReported": (
    "Do you intend to remain in this home for at least two years?",
    "boolean",
    null,
    "This prepares a discussion with RTP; the app has not verified the current annual eligibility rules.",
  ),
  "incomeDocumentsReady": (
    "Are household income documents ready?",
    "boolean",
    null,
    "Follow RTP instructions for adults in the household. Do not upload bank statements or tax records to this app.",
  ),
  "ownershipDocumentsReady": (
    "Is proof of ownership ready?",
    "boolean",
    null,
    "Submit supporting documents through RTP’s official intake process.",
  ),
  "residenceDocumentsReady": (
    "Is proof of residence ready?",
    "boolean",
    null,
    "Follow official instructions and obscure unnecessary account or Social Security numbers.",
  ),
  "repairRequest": (
    "What repairs would you like RTP to consider?",
    "text",
    600,
    "Describe observed issues and requested help. Avoid account numbers, diagnoses or unsupported structural claims.",
  ),
};

bool _knownIntake(IntakeDefinition definition, IntakeQuestion question) {
  final keys = _intakeKeys[definition.programId];
  if (_intakeVersions[definition.programId] !=
          definition.questionnaireVersion ||
      keys == null ||
      definition.questions.length != keys.length ||
      !definition.questions.any((q) => identical(q, question))) {
    return false;
  }
  for (var i = 0; i < keys.length; i++) {
    final q = definition.questions[i], expected = _questions[keys[i]]!;
    if (q.key != keys[i] ||
        q.label != expected.$1 ||
        q.kind != expected.$2 ||
        q.maxLength != expected.$3 ||
        q.description != expected.$4) {
      return false;
    }
  }
  return true;
}

String programQuestionLabel(
  BuildContext context,
  IntakeDefinition definition,
  IntakeQuestion question,
) => _knownIntake(definition, question)
    ? context.tr(question.label)
    : question.label;

String programQuestionDescription(
  BuildContext context,
  IntakeDefinition definition,
  IntakeQuestion question,
) => _knownIntake(definition, question)
    ? context.tr(question.description)
    : question.description;

const _formFields = <String, (String, String, int)>{
  "memberFirstName": ("Given name", "text", 160),
  "memberLastName": ("Family name", "text", 160),
  "memberBirthDate": ("Date of birth (YYYY-MM-DD)", "date", 10),
  "memberId": ("Plan member identifier", "text", 80),
  "memberPhone": ("Contact phone", "text", 40),
  "memberPreferredSpokenLanguage": ("Preferred spoken language", "text", 80),
  "representativeName": ("Authorized representative name", "text", 160),
  "representativeEmail": ("Authorized representative email", "email", 254),
  "representativePhone": ("Authorized representative phone", "text", 40),
  "referralDate": ("Referral date (YYYY-MM-DD)", "date", 10),
  "referralSource": ("Referral source", "text", 200),
  "referringOrganizationName": ("Referring organization", "text", 200),
  "referringOrganizationPhone": ("Referring organization phone", "text", 40),
  "referrerName": ("Referring individual name", "text", 160),
  "referrerTitle": ("Referring individual title", "text", 100),
  "referrerOrganizationName": (
    "Referring individual organization",
    "text",
    200,
  ),
  "referrerEmail": ("Referring individual email", "email", 254),
  "referrerPhone": ("Referring individual phone", "text", 40),
};

const _formKeys = <String, List<String>>{
  'hpsm-eaa': [
    'memberFirstName',
    'memberLastName',
    'memberBirthDate',
    'memberId',
    'memberPhone',
    'memberPreferredSpokenLanguage',
    'referralDate',
    'referringOrganizationName',
    'referrerEmail',
    'referrerPhone',
  ],
  'rtp-home-repair': [
    'memberFirstName',
    'memberLastName',
    'memberPhone',
    'memberPreferredSpokenLanguage',
  ],
};

String administrativeFieldLabel(
  BuildContext context,
  String programId,
  FormAnswerFieldDefinition field,
) {
  final expected = _formFields[field.key];
  final knownRoute =
      programId == 'scfhp-eaa' ||
      (_formKeys[programId]?.contains(field.key) ?? false);
  return knownRoute &&
          expected != null &&
          field.label == expected.$1 &&
          field.kind == expected.$2 &&
          field.maxLength == expected.$3
      ? context.tr(field.label)
      : field.label;
}
