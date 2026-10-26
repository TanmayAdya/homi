import '../domain/capture/capture_adapter.dart';
import '../domain/measurement/length_unit.dart';
import '../domain/measurement/measurement_input.dart';
import 'assessment_controller.dart';

List<String> addFictionalBathroomScenario(AssessmentController controller) {
  final String tubEdge = controller.startFinding(AssessmentArea.bathroom);
  controller
    ..setObservation(
      tubEdge,
      'I notice a raised edge where you step into the tub. A towel hides '
      'the area beside the tub in this photo, so another view may help.',
    )
    ..addEvidence(tubEdge, version: 'fictional-bathroom-overview')
    ..setMeasurement(tubEdge, 'curbHeight', _parse('45', LengthUnit.centimetre))
    ..requestAnotherView(tubEdge);

  final String bathMat = controller.startFinding(AssessmentArea.bathroom);
  controller
    ..setObservation(
      bathMat,
      'I notice a bath mat with a curled corner near the door.',
    )
    ..dismiss(bathMat);

  return [tubEdge, bathMat];
}

List<String> addFictionalEntranceScenario(AssessmentController controller) {
  final String threshold = controller.startFinding(AssessmentArea.entrance);
  controller
    ..setObservation(
      threshold,
      'I notice a raised threshold at the front door.',
    )
    ..addEvidence(threshold, version: 'fictional-entrance-overview')
    ..addEvidence(threshold, version: 'fictional-entrance-close-up')
    ..setMeasurement(
      threshold,
      'thresholdHeight',
      _parse('1.5', LengthUnit.inch),
    )
    ..confirmMeasurement(threshold, 'thresholdHeight')
    ..confirm(threshold);
  return [threshold];
}

MeasurementInput _parse(String text, LengthUnit unit) {
  final LengthParseResult result = const MeasurementParser(
    DecimalSeparator.point,
  ).parse(text, unit);
  if (result is! LengthParsed) {
    throw StateError('Fictional scenario measurement did not parse.');
  }
  return result.input;
}
