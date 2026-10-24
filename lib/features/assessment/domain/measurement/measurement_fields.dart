final class MeasurementFieldSpec {
  const MeasurementFieldSpec({
    required this.type,
    required this.label,
    required this.definition,
    required this.howToMeasure,
    required this.zeroIsPlausible,
  });

  final String type;

  final String label;

  final String definition;

  final String howToMeasure;

  final bool zeroIsPlausible;
}

const List<MeasurementFieldSpec> proposedMeasurementFields = [
  MeasurementFieldSpec(
    type: 'clearOpening',
    label: 'Clear opening width',
    definition:
        'The usable width a person can pass through with the door '
        'open as far as it goes. This is often smaller than the size '
        'printed on or sold with the door.',
    howToMeasure:
        'Open the door fully. Measure straight across from the face '
        'of the open door to the doorstop on the opposite side of the frame, '
        'at the narrowest point.',
    zeroIsPlausible: false,
  ),
  MeasurementFieldSpec(
    type: 'thresholdHeight',
    label: 'Threshold height',
    definition:
        'How far the top of the threshold rises above the floor on '
        'the side a person approaches from. Enter 0 if it is flush.',
    howToMeasure:
        'Stand a ruler on the floor beside the threshold and read '
        'the height at its highest point. If the floors on each side differ, '
        'describe that in the observation.',
    zeroIsPlausible: true,
  ),
  MeasurementFieldSpec(
    type: 'curbHeight',
    label: 'Shower or tub edge height',
    definition:
        'The height of the edge a person steps over to get into the '
        'shower or tub, measured from the bathroom floor. Enter 0 if there '
        'is no edge.',
    howToMeasure:
        'Measure from the bathroom floor outside the shower or tub '
        'to the top of the edge. Do not stand in a wet area to measure.',
    zeroIsPlausible: true,
  ),
];

MeasurementFieldSpec? measurementFieldSpecFor(String type) {
  for (final MeasurementFieldSpec spec in proposedMeasurementFields) {
    if (spec.type == type) return spec;
  }
  return null;
}

bool needsZeroReviewPrompt({
  required String type,
  required double millimetres,
}) {
  if (millimetres != 0) return false;
  final MeasurementFieldSpec? spec = measurementFieldSpecFor(type);
  return spec == null || !spec.zeroIsPlausible;
}
