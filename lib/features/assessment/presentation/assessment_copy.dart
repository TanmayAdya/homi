import '../application/assessment_flow.dart';
import '../domain/capture/capture_adapter.dart';
import '../domain/image/image_validator.dart';
import '../domain/measurement/measurement_input.dart';
import '../domain/review/finding_review_state.dart';

abstract final class AssessmentCopy {
  static const String notSavedYet =
      'Not saved yet. This stays on this screen until your case is saved, '
      'and is lost if the app closes.';

  static String areaTitle(AssessmentArea area) => switch (area) {
    AssessmentArea.bathroom => 'Bathroom',
    AssessmentArea.entrance => 'Entrance',
  };

  static String areaExplanation(AssessmentArea area) => switch (area) {
    AssessmentArea.bathroom =>
      'A photo of the route to the tub, shower or toilet you are concerned '
          'about, what you notice, and any measurements you take.',
    AssessmentArea.entrance =>
      'A photo of the approach, doorway or threshold you are concerned '
          'about, what you notice, and any measurements you take.',
  };

  static String viewPrompt(AssessmentArea area, CaptureView view) =>
      switch ((area, view)) {
        (AssessmentArea.bathroom, CaptureView.overview) =>
          'Take a wide photo that shows the route to the fixture you are '
              'concerned about.',
        (AssessmentArea.bathroom, CaptureView.closeUp) =>
          'Take a closer photo of the part that was hard to see.',
        (AssessmentArea.entrance, CaptureView.overview) =>
          'Take a photo that shows the approach and the doorway or threshold '
              'you are concerned about.',
        (AssessmentArea.entrance, CaptureView.closeUp) =>
          'Take a closer photo of the threshold or doorway edge.',
      };

  static String safetyNote(AssessmentArea area) => switch (area) {
    AssessmentArea.bathroom =>
      'Stay on a dry floor. Do not climb, stand in the tub or shower, or move '
          'heavy things to take this photo.',
    AssessmentArea.entrance =>
      'Do not climb or move heavy things to take this photo.',
  };

  static const String privacyCheck =
      'Before you continue, check the photo. Does it show faces, mail, '
      'addresses, medicine labels or rooms you do not want to share? If so, '
      'remove it and take another. Removing hidden photo data does not hide '
      'what is visible in the picture.';

  static const String markAfterSaving =
      'You can mark the area on this photo after it is saved, when its '
      'final orientation is known.';

  static const String noPhotoOption =
      'You can also continue without a photo and describe what you notice.';

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
      'For example: "I notice a raised threshold." Say what is hard to see '
      'or unknown, too.';
  static const String observationRequired =
      'Describe what you notice before continuing.';

  static const String measurementsIntro =
      'Measurements are optional. Leave a field empty if you did not measure '
      'it. Enter 0 only if you measured and found nothing.';

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
      'Confirming means you checked that this description, these photos and '
      'these measurements are right. It is not a safety inspection, a '
      'diagnosis or a decision about any program.';

  static const String anotherViewRequested =
      'You asked for another photo of this finding.';

  static const String noPhotos = 'No photo for this finding.';

  static const String zeroCheck = 'You entered 0. Is that right?';
}
