import 'package:flutter/material.dart';

import '../domain/assessment_location.dart';
import '../domain/capture/capture_adapter.dart';
import 'assessment_copy.dart';

extension AssessmentLocationGuide on AssessmentLocation {
  String get description => switch (this) {
    AssessmentLocation.bathroom =>
      'Getting into the shower or using the toilet',
    AssessmentLocation.entrance => 'Doorways, thresholds and the way inside',
    AssessmentLocation.stairs => 'Steps, landings and handrails',
    AssessmentLocation.livingSpaces =>
      'Moving between rooms and around furniture',
    AssessmentLocation.bedroom => 'Getting to the bed and moving around it',
    AssessmentLocation.kitchen => 'Reaching and moving around work areas',
    AssessmentLocation.outdoorPaths =>
      'Walkways, gates and the route to the home',
  };

  IconData get icon => switch (this) {
    AssessmentLocation.bathroom => Icons.bathtub_outlined,
    AssessmentLocation.entrance => Icons.door_front_door_outlined,
    AssessmentLocation.stairs => Icons.stairs_outlined,
    AssessmentLocation.livingSpaces => Icons.weekend_outlined,
    AssessmentLocation.bedroom => Icons.bed_outlined,
    AssessmentLocation.kitchen => Icons.kitchen_outlined,
    AssessmentLocation.outdoorPaths => Icons.nature_people_outlined,
  };

  String photoPrompt(CaptureView view) {
    if (area != AssessmentArea.other) {
      return AssessmentCopy.viewPrompt(area, view);
    }
    if (view == CaptureView.closeUp) {
      return 'Show the part of this area you would like help with.';
    }
    return switch (this) {
      AssessmentLocation.stairs =>
        'From a safe, stable place, show the steps, landing and any handrails.',
      AssessmentLocation.livingSpaces =>
        'Show the route between rooms or the space around furniture.',
      AssessmentLocation.bedroom =>
        'Show the path to the bed or the space where moving is difficult.',
      AssessmentLocation.kitchen =>
        'Show the work area or item that is difficult to reach or use.',
      AssessmentLocation.outdoorPaths =>
        'Show the path or gate where getting to the home is difficult.',
      _ => AssessmentCopy.viewPrompt(area, view),
    };
  }

  String get observationExample => switch (this) {
    AssessmentLocation.bathroom ||
    AssessmentLocation.entrance => AssessmentCopy.observationHintFor(area),
    AssessmentLocation.stairs =>
      'For example, “I need a handrail on the stairs to the bedroom.”',
    AssessmentLocation.livingSpaces =>
      'For example, “My walker catches on the rug between the rooms.”',
    AssessmentLocation.bedroom =>
      'For example, “I have trouble getting from the bed to the doorway.”',
    AssessmentLocation.kitchen =>
      'For example, “The cupboard I use every day is difficult to reach.”',
    AssessmentLocation.outdoorPaths =>
      'For example, “The path from the gate is uneven and hard to use.”',
  };

  String get safetyNote => switch (this) {
    AssessmentLocation.bathroom ||
    AssessmentLocation.entrance => AssessmentCopy.safetyNote(area),
    AssessmentLocation.stairs =>
      'Take photos from a stable place. Don’t use stairs or lean on a rail just to test it.',
    _ =>
      'Stay in a comfortable, stable place. Don’t climb, overreach or move heavy things for a photo.',
  };
}
