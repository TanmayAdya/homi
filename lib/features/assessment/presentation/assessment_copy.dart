import 'package:flutter/material.dart';
import 'package:safe_at_home/l10n/app_localizations.dart';

import '../application/assessment_flow.dart';
import '../domain/assessment_location.dart';
import '../domain/capture/capture_adapter.dart';
import '../domain/image/image_validator.dart';
import '../domain/measurement/measurement_input.dart';
import '../domain/measurement/measurement_fields.dart';
import '../domain/review/finding_review_state.dart';

String localizedAssessmentObservation(
  BuildContext context, {
  required String observation,
  required String room,
}) {
  if (room != 'other') return observation;
  final location = AssessmentLocation.fromObservation(
    AssessmentArea.other,
    observation,
  );
  if (location == null) return observation;
  return '${context.tr(location.title)}: ${location.observationWithoutLocation(observation)}';
}

String assessmentHistoryValue(
  BuildContext context,
  Object? value, {
  String? field,
}) {
  if (value == null) return context.tr('None recorded');
  if (value is List) {
    return value
        .map((v) => assessmentHistoryValue(context, v, field: field))
        .join('; ');
  }
  if (value is Map) {
    const labels = {
      'room': 'Area',
      'observation': 'Observation',
      'measurements': 'Measurements',
      'reviews': 'Review decisions',
      'reviewState': 'Review state',
      'state': 'Review state',
      'note': 'Note',
      'type': 'Measurement type',
      'value': 'Value',
      'unit': 'Unit',
      'method': 'Measurement method',
      'confirmed': 'Checked by you',
      'originalText': 'Original input',
      'originalUnit': 'Original unit',
      'decimalSeparator': 'Decimal mark',
      'source': 'Measurement source',
      'recorder': 'Recorded by',
      'recordedAt': 'Recorded at',
    };
    return value.entries
        .where((e) => !{'id', 'findingId', 'evidenceIds'}.contains(e.key))
        .map((e) {
          final key = e.key.toString();
          final label = labels[key];
          return '${label == null ? key : context.tr(label)}: ${assessmentHistoryValue(context, e.value, field: key)}';
        })
        .join(', ');
  }
  if (value is bool) return context.tr(value ? 'Yes' : 'No');
  if (value is String) {
    final label = switch (field) {
      'type' => measurementFieldSpecFor(value)?.label,
      'room' => const {
        'bathroom': 'Bathroom',
        'entrance': 'Entrance',
        'other': 'Other area',
      }[value],
      'unit' || 'originalUnit' => const {
        'mm': 'millimetres',
        'cm': 'centimetres',
        'm': 'metres',
        'in': 'inches',
        'ft': 'feet',
      }[value],
      'method' || 'source' => const {
        'manual': 'Measured',
        'estimated': 'Your estimate',
        'legacy_unknown': 'Original input unavailable',
      }[value],
      'state' || 'reviewState' => const {
        'confirmed': 'Confirmed by you',
        'needs_review': 'Needs your review',
        'dismissed': 'Dismissed',
      }[value],
      'recorder' => const {
        'self': 'Resident',
        'helper': 'Helper',
        'unknown': 'Unknown',
      }[value],
      'decimalSeparator' => const {
        'point': 'Decimal point',
        'comma': 'Decimal comma',
      }[value],
      _ => null,
    };
    if (label != null) return context.tr(label);
  }
  return value.toString();
}

abstract final class AssessmentCopy {
  static const String notSavedYet =
      'Not saved yet. Lost if the app closes before you save.';

  static String areaTitle(AssessmentArea area) => switch (area) {
    AssessmentArea.bathroom => 'Bathroom',
    AssessmentArea.entrance => 'Entrance',
    AssessmentArea.other => 'Other area',
  };

  static String areaExplanation(AssessmentArea area) => switch (area) {
    AssessmentArea.bathroom => 'Route to the tub, shower or toilet.',
    AssessmentArea.entrance => 'Approach, doorway or threshold.',
    AssessmentArea.other =>
      'Handrails, steps, hallways, bedrooms, kitchens or outdoor paths.',
  };

  static String viewPrompt(AssessmentArea area, CaptureView view) =>
      switch ((area, view)) {
        (AssessmentArea.bathroom, CaptureView.overview) =>
          'Take a wide photo of the route to the tub, shower or toilet.',
        (AssessmentArea.bathroom, CaptureView.closeUp) =>
          'Take a closer photo of the hard-to-see part.',
        (AssessmentArea.entrance, CaptureView.overview) =>
          'Take a photo of the approach and doorway.',
        (AssessmentArea.entrance, CaptureView.closeUp) =>
          'Take a closer photo of the threshold or doorway edge.',
        (AssessmentArea.other, CaptureView.overview) =>
          'Show the stairs or area where getting around is difficult.',
        (AssessmentArea.other, CaptureView.closeUp) =>
          'Show the specific step, rail or obstacle you want help with.',
      };

  static String safetyNote(AssessmentArea area) => switch (area) {
    AssessmentArea.bathroom =>
      'Stay on a dry floor. Don’t climb, stand in the tub or move heavy things.',
    AssessmentArea.entrance => 'Don’t climb or move heavy things.',
    AssessmentArea.other =>
      'Take photos from a stable place. Don’t use stairs or reach for a rail just to test it.',
  };

  static const String privacyCheck =
      'Cover or retake if it shows faces, mail, addresses, medicine labels or '
      'rooms you don’t want to share.';

  static const String privacyDetail =
      'Removing hidden photo data does not hide what is visible in the '
      'picture.';

  static const String markAfterSaving =
      'You can mark the area after the photo is saved.';

  static String? notice(FlowNotice? notice) => switch (notice) {
    null => null,
    CaptureCancelledNotice() =>
      'No photo was taken. You can try again or continue without a photo.',
    PermissionNotice(canAskAgain: true) =>
      'Camera access was not allowed. You can try again or continue without '
          'a photo.',
    PermissionNotice(canAskAgain: false) =>
      'Camera access is turned off for this app. To take photos, allow it in '
          'your phone settings, then tap "I changed the setting". You can also '
          'continue without a photo.',
    CameraUnavailableNotice() =>
      'The camera is not available right now. You can continue without a '
          'photo.',
    PhotoRejectedNotice(:final reason) => rejected(reason),
    CaptureFailedNotice() =>
      'Something went wrong taking the photo. Please try again.',
    PhotoImportFailedNotice(timedOut: true) =>
      'The selected photo took too long to become available. Open it in Photos to download it, then try again. You can choose another photo or continue without one.',
    PhotoImportFailedNotice(timedOut: false) =>
      'The selected photo could not be imported. Try again or choose another photo. You can continue without one.',
    PhotoPreviewUnavailableNotice() =>
      'The photo was captured, but its preview could not be opened. Reopen this finding to retry, or retake or remove the photo.',
    PhotoRemovedNotice() => 'Photo removed.',
    InterruptedCaptureNotice() =>
      'The last photo attempt was interrupted. No unfinished camera or library result was attached. Your earlier photo and measurements are kept. Take or choose the photo again, or continue without a new one.',
    InterruptedPrivacyNotice() =>
      'The photo editor was interrupted before its changes were saved. Unfinished crops and covers were not applied. Review the retained photo and apply the privacy edits again before saving online.',
    PrivatePhotoSaveFailedNotice() =>
      'The private photo checkpoint could not be saved. Keep this screen open and free some device space, then try again. Your previous saved photo is retained.',
    PhotoTargetChangedNotice() =>
      'This finding or photo changed while the photo step was open. The returned photo was not attached. Review the current finding before trying again.',
    PhotoCaptureLimitNotice() =>
      'This assessment has reached its photo-attempt limit. Your saved work is retained. Continue with the existing photos or without a new photo; freeing device space will not reset this limit.',
  };

  static String rejected(ImageRejection reason) => switch (reason) {
    ImageRejection.heif =>
      'This photo is in HEIC format, which cannot be used yet. Take another '
          'photo, or set your camera to save "Most Compatible" (JPEG) photos.',
    ImageRejection.tooManyBytes =>
      'This photo is larger than 8 MB. Take another photo at a lower '
          'resolution.',
    ImageRejection.edgeTooLong || ImageRejection.tooManyPixels =>
      'This photo has too many pixels to use. Take another photo at a lower '
          'resolution.',
    ImageRejection.empty ||
    ImageRejection.unsupportedFormat ||
    ImageRejection.unreadableDimensions ||
    ImageRejection.zeroDimension =>
      'This photo could not be read. Please take another.',
  };

  static const String observationLabel = 'What do you notice?';
  static const String observationHint =
      'For example, “a raised threshold”. Note anything unknown too.';
  static const String observationRequired =
      'Choose a concern or describe what you notice.';

  static List<String> concernChoicesFor(AssessmentArea area) => switch (area) {
    AssessmentArea.bathroom => const [
      'Getting in or out of the tub or shower is hard.',
      'Getting on or off the toilet is hard.',
      'The floor gets slippery.',
      'There is nothing steady to hold on to.',
      'The doorway is hard to get through.',
    ],
    AssessmentArea.entrance => const [
      'The steps are hard to manage.',
      'The handrail is missing or loose.',
      'The threshold is hard to get over.',
      'The lighting is too dim.',
    ],
    AssessmentArea.other => const [
      'Moving around here feels unsafe.',
      'Something on the floor could cause a trip.',
      'The lighting is too dim.',
      'Things are hard to reach.',
    ],
  };

  static const String measurementsIntro =
      'Only add a size if it helps explain this concern. You can continue '
      'without measuring. Leave unknown sizes blank.';

  static String observationHintFor(AssessmentArea area) => switch (area) {
    AssessmentArea.bathroom =>
      'For example, “I need something to hold when getting out of the shower.”',
    AssessmentArea.entrance =>
      'For example, “The front step is difficult to get over with my walker.”',
    AssessmentArea.other =>
      'Name the place and difficulty, for example “The indoor stairs have no handrail.”',
  };

  static String measurementError(LengthParseError error) => switch (error) {
    LengthParseError.empty => 'Enter a number or leave it empty.',
    LengthParseError.notANumber => 'Enter digits only, like 80 or 80.5.',
    LengthParseError.negative => 'Measurements cannot be negative.',
    LengthParseError.unexpectedSeparator =>
      'Use one decimal mark and no thousands separator, like 1500 or 80.5.',
    LengthParseError.tooManyDigits => 'That number is too long. Check it.',
    LengthParseError.tooManyDecimals => 'Use at most 4 decimal places.',
  };

  static const String estimateLabel = 'This is my estimate, not a measurement';

  static String reviewState(FindingReviewState state) => switch (state) {
    FindingReviewState.needsReview => 'Needs your review',
    FindingReviewState.confirmed => 'Confirmed by you',
    FindingReviewState.dismissed => 'Dismissed',
  };

  static const String confirmMeaning =
      'Check this concern and any numbers you entered once, then confirm below. '
      'Estimates stay estimates. This is not a professional inspection or approval.';

  static const String anotherViewRequested =
      'You asked for another photo of this finding.';

  static const String noPhotos = 'No photo for this finding.';

  static const String zeroCheck = 'You entered 0. Is that right?';
}
