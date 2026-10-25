import 'capture/capture_adapter.dart';

enum AssessmentLocation {
  bathroom,
  entrance,
  stairs,
  livingSpaces,
  bedroom,
  kitchen,
  outdoorPaths;

  AssessmentArea get area => switch (this) {
    bathroom => AssessmentArea.bathroom,
    entrance => AssessmentArea.entrance,
    _ => AssessmentArea.other,
  };

  String get title => switch (this) {
    bathroom => 'Bathroom',
    entrance => 'Entrance',
    stairs => 'Stairs',
    livingSpaces => 'Hallways & living spaces',
    bedroom => 'Bedroom',
    kitchen => 'Kitchen',
    outdoorPaths => 'Outdoor paths',
  };

  String observationWithLocation(String text) =>
      area == AssessmentArea.other && text.trim().isNotEmpty
      ? '$title: ${text.trim()}'
      : text;

  String observationWithoutLocation(String text) =>
      area == AssessmentArea.other && text.startsWith('$title: ')
      ? text.substring(title.length + 2)
      : text;

  static AssessmentLocation? fromObservation(
    AssessmentArea area,
    String observation,
  ) => switch (area) {
    AssessmentArea.bathroom => bathroom,
    AssessmentArea.entrance => entrance,
    AssessmentArea.other =>
      values
          .where(
            (location) =>
                location.area == AssessmentArea.other &&
                observation.startsWith('${location.title}: '),
          )
          .firstOrNull,
  };
}
