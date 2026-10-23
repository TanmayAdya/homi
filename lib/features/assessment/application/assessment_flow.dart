import 'package:flutter/foundation.dart';

import '../domain/annotation/box_annotation.dart';
import '../domain/capture/capture_adapter.dart';
import '../domain/capture/photo_capture_coordinator.dart';
import '../domain/capture/staging_store.dart';
import '../domain/image/image_validator.dart';
import '../domain/measurement/length_unit.dart';
import '../domain/measurement/measurement_input.dart';
import 'assessment_controller.dart';
import 'local_evidence_index.dart';

enum AssessmentStep { chooseArea, viewPrompt, preview, details, review }

sealed class FlowNotice {
  const FlowNotice();
}

final class CaptureCancelledNotice extends FlowNotice {
  const CaptureCancelledNotice();
}

final class PermissionNotice extends FlowNotice {
  const PermissionNotice({required this.canAskAgain});
  final bool canAskAgain;
}

final class CameraUnavailableNotice extends FlowNotice {
  const CameraUnavailableNotice();
}

final class PhotoRejectedNotice extends FlowNotice {
  const PhotoRejectedNotice(this.reason);
  final ImageRejection reason;
}

final class CaptureFailedNotice extends FlowNotice {
  const CaptureFailedNotice();
}

final class PhotoRemovedNotice extends FlowNotice {
  const PhotoRemovedNotice();
}

final class MeasurementEntry {
  const MeasurementEntry({
    this.text = '',
    this.unit = LengthUnit.millimetre,
    this.method = MeasurementMethod.manual,
  });

  final String text;
  final LengthUnit unit;
  final MeasurementMethod method;

  MeasurementEntry copyWith({
    String? text,
    LengthUnit? unit,
    MeasurementMethod? method,
  }) => MeasurementEntry(
    text: text ?? this.text,
    unit: unit ?? this.unit,
    method: method ?? this.method,
  );
}

final class DetailsErrors {
  const DetailsErrors({
    this.observationMissing = false,
    this.measurements = const {},
  });

  final bool observationMissing;
  final Map<String, LengthParseError> measurements;

  bool get isEmpty => !observationMissing && measurements.isEmpty;
}

typedef _Place = ({
  AssessmentStep step,
  CaptureView view,
  String? previewEvidenceId,
});

const Map<AssessmentArea, List<String>> measurementTypesByArea = {
  AssessmentArea.bathroom: ['curbHeight', 'clearOpening'],
  AssessmentArea.entrance: ['thresholdHeight', 'clearOpening'],
};

class AssessmentFlow extends ChangeNotifier {
  AssessmentFlow({
    required this.controller,
    required PhotoCaptureCoordinator capture,
    required StagingStore staging,
    LocalEvidenceIndex? evidence,
    this.annotations,
    this.decimalSeparator = DecimalSeparator.point,
  }) : _capture = capture,
       _staging = staging,
       evidence = evidence ?? LocalEvidenceIndex();

  final AssessmentController controller;
  final PhotoCaptureCoordinator _capture;
  final StagingStore _staging;
  final LocalEvidenceIndex evidence;

  final AnnotationStore? annotations;

  final DecimalSeparator decimalSeparator;

  AssessmentStep _step = AssessmentStep.chooseArea;
  final List<_Place> _backStack = [];
  AssessmentArea? _area;
  String? _findingId;
  CaptureView _view = CaptureView.overview;
  String? _previewEvidenceId;
  FlowNotice? _notice;
  bool _busy = false;
  bool _disposed = false;
  String _observation = '';
  Map<String, MeasurementEntry> _entries = {};
  DetailsErrors _errors = const DetailsErrors();
  final Map<String, Uint8List> _bytes = {};

  AssessmentStep get step => _step;
  AssessmentArea? get area => _area;
  String? get findingId => _findingId;
  CaptureView get view => _view;
  FlowNotice? get notice => _notice;
  bool get isBusy => _busy;
  bool get canGoBack => _backStack.isNotEmpty && !_busy;
  String get observationText => _observation;
  DetailsErrors get errors => _errors;
  bool get cameraBlocked => _capture.permissionBlocked;

  String? get previewEvidenceId => _previewEvidenceId;

  Uint8List? bytesFor(String evidenceId) => _bytes[evidenceId];

  List<String> get measurementTypes =>
      _area == null ? const [] : measurementTypesByArea[_area]!;

  MeasurementEntry entryFor(String type) =>
      _entries[type] ?? const MeasurementEntry();

  AnnotatedImage? annotatableImage(String evidenceId) {
    final StagedImage? staged = evidence[evidenceId];
    if (staged == null || staged.format != SupportedImageFormat.png) {
      return null;
    }
    return AnnotatedImage(
      evidenceId: evidenceId,
      version: localEvidenceVersion(staged.key),
      width: staged.width,
      height: staged.height,
    );
  }

  void chooseArea(AssessmentArea area) {
    if (_step != AssessmentStep.chooseArea) return;
    _area = area;
    _view = CaptureView.overview;
    _go(AssessmentStep.viewPrompt);
  }

  Future<void> openCamera({bool retake = false}) async {
    final AssessmentArea? area = _area;
    if (_busy || area == null) return;
    final String? replacingId = retake ? _previewEvidenceId : null;
    _busy = true;
    _notice = null;
    _notify();

    final PhotoOutcome outcome = await _capture.capture(
      CaptureRequest(
        area: area,
        view: _view,
        promptId: '${area.name}-${_view.name}',
      ),
      replacing: replacingId == null ? null : evidence[replacingId]?.key,
    );
    _busy = false;
    if (_disposed) return;

    switch (outcome) {
      case PhotoStaged(:final image):
        final String id = _ensureFinding();
        final String version = localEvidenceVersion(image.key);
        final String evidenceId;
        if (replacingId != null) {
          controller.replaceEvidence(id, replacingId, version: version);
          evidenceId = replacingId;
        } else {
          evidenceId = controller.addEvidence(id, version: version);
        }
        evidence.put(evidenceId, image);
        if (replacingId != null) {
          annotations?.imageChanged(evidenceId, annotatableImage(evidenceId));
        }
        _previewEvidenceId = evidenceId;
        await _loadBytes(evidenceId);
        if (_disposed) return;
        if (_step != AssessmentStep.preview) _go(AssessmentStep.preview);
      case PhotoKept():
        _notice = const CaptureCancelledNotice();
      case PhotoPermissionBlocked(:final canAskAgain):
        _notice = PermissionNotice(canAskAgain: canAskAgain);
      case PhotoUnavailable():
        _notice = const CameraUnavailableNotice();
      case PhotoRejected(:final reason):
        _notice = PhotoRejectedNotice(reason);
      case PhotoFailed(:final code):
        if (code != PhotoFailed.busy) _notice = const CaptureFailedNotice();
    }
    _notify();
  }

  void permissionMayHaveChanged() {
    _capture.permissionMayHaveChanged();
    _notice = null;
    _notify();
  }

  Future<void> removePreviewPhoto() async {
    final String? evidenceId = _previewEvidenceId;
    final String? id = _findingId;
    if (_busy || evidenceId == null || id == null) return;
    controller.removeEvidence(id, evidenceId);
    final StagedImage? staged = evidence.remove(evidenceId);
    annotations?.removeForEvidence(evidenceId);
    _bytes.remove(evidenceId);
    _previewEvidenceId = null;
    _notice = const PhotoRemovedNotice();
    if (_step == AssessmentStep.preview && !_popBack()) {
      _step = AssessmentStep.viewPrompt;
    }
    _notify();
    if (staged != null) await _capture.remove(staged.key);
  }

  void addCloseUp() {
    _notice = null;
    _go(AssessmentStep.viewPrompt);
    _view = CaptureView.closeUp;
  }

  void continueFromPreview() {
    if (_step == AssessmentStep.preview) _go(AssessmentStep.details);
  }

  void continueWithoutPhoto() {
    if (_step != AssessmentStep.viewPrompt) return;
    _ensureFinding();
    _notice = null;
    _go(AssessmentStep.details);
  }

  void setObservationText(String text) {
    _observation = text;
    if (_errors.observationMissing && text.trim().isNotEmpty) {
      _errors = DetailsErrors(measurements: _errors.measurements);
    }
    _notify();
  }

  void setMeasurementText(String type, String text) =>
      _setEntry(type, entryFor(type).copyWith(text: text));

  void setMeasurementUnit(String type, LengthUnit unit) =>
      _setEntry(type, entryFor(type).copyWith(unit: unit));

  void setMeasurementMethod(String type, MeasurementMethod method) =>
      _setEntry(type, entryFor(type).copyWith(method: method));

  bool saveDetails() {
    final String? id = _findingId;
    if (id == null || _step != AssessmentStep.details) return false;

    final parser = MeasurementParser(decimalSeparator);
    final Map<String, MeasurementInput?> parsed = {};
    final Map<String, LengthParseError> failures = {};
    for (final String type in measurementTypes) {
      final MeasurementEntry entry = entryFor(type);
      if (entry.text.trim().isEmpty) {
        parsed[type] = null;
        continue;
      }
      switch (parser.parse(entry.text, entry.unit)) {
        case LengthParsed(:final input):
          parsed[type] = input;
        case LengthParseFailure(:final error):
          failures[type] = error;
      }
    }
    _errors = DetailsErrors(
      observationMissing: _observation.trim().isEmpty,
      measurements: failures,
    );
    if (!_errors.isEmpty) {
      _notify();
      return false;
    }

    controller.setObservation(id, _observation);
    parsed.forEach((type, input) {
      final RecordedMeasurement? existing = controller
          .draftOf(id)
          ?.measurementOf(type);
      final MeasurementMethod method = entryFor(type).method;
      if (input == null) {
        controller.clearMeasurement(id, type);
      } else if (existing != null &&
          existing.input.millimetres == input.millimetres &&
          existing.input.unit == input.unit &&
          existing.method == method) {
      } else {
        controller.setMeasurement(id, type, input, method: method);
      }
    });
    _go(AssessmentStep.review);
    return true;
  }

  void edit() {
    if (_step == AssessmentStep.review) _go(AssessmentStep.details);
  }

  void requestAnotherView() {
    final String? id = _findingId;
    if (id == null || _step != AssessmentStep.review) return;
    if (controller.requestAnotherView(id).applied) addCloseUp();
  }

  void back() {
    if (!canGoBack || !_popBack()) return;
    _notice = null;
    _errors = const DetailsErrors();
    if (_step == AssessmentStep.chooseArea && _findingId != null) {
      _resetForNewFinding();
    }
    _notify();
  }

  void openFinding(String findingId) {
    if (_busy) return;
    final FindingDraft? draft = controller.draftOf(findingId);
    if (draft == null) return;
    _resetForNewFinding();
    _area = draft.area;
    _findingId = findingId;
    _observation = draft.observation;
    _entries = {
      for (final RecordedMeasurement m in draft.measurements)
        m.type: MeasurementEntry(
          text: m.input.decimalSeparator == decimalSeparator
              ? m.input.originalText
              : m.input.originalText.replaceAll(
                  m.input.decimalSeparator.character,
                  decimalSeparator.character,
                ),
          unit: m.input.unit,
          method: m.method,
        ),
    };
    _go(AssessmentStep.review);
  }

  void openPhoto(String evidenceId) {
    final String? id = _findingId;
    if (_busy || id == null || _step != AssessmentStep.review) return;
    if (!_isAttached(evidenceId)) return;
    _notice = null;
    _go(AssessmentStep.preview);
    _previewEvidenceId = evidenceId;
    _view = CaptureView.overview;
  }

  void startAnother() {
    _resetForNewFinding();
    _notify();
  }

  Future<void> discardFinding() async {
    final String? id = _findingId;
    final List<StagingKey> keys = [];
    if (id != null) {
      annotations?.removeForFinding(id);
      final FindingDraft? removed = controller.removeFinding(id);
      for (final e in removed?.evidence ?? const []) {
        final StagedImage? staged = evidence.remove(e.evidenceId);
        if (staged != null) keys.add(staged.key);
      }
    }
    _resetForNewFinding();
    _notify();
    for (final StagingKey key in keys) {
      await _capture.remove(key);
    }
  }

  void annotationsChanged() => _notify();

  Future<void> loadBytes(String evidenceId) async {
    if (_bytes.containsKey(evidenceId)) return;
    await _loadBytes(evidenceId);
    _notify();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  String _ensureFinding() {
    final String? existing = _findingId;
    if (existing != null) return existing;
    final String id = controller.startFinding(_area!);
    _findingId = id;
    _backStack.removeWhere((p) => p.step == AssessmentStep.chooseArea);
    return id;
  }

  Future<void> _loadBytes(String evidenceId) async {
    final StagedImage? staged = evidence[evidenceId];
    if (staged == null) return;
    final Uint8List? bytes = await _staging.read(staged.key);
    if (bytes != null && evidence[evidenceId]?.key == staged.key) {
      _bytes[evidenceId] = bytes;
    }
  }

  void _setEntry(String type, MeasurementEntry entry) {
    _entries = {..._entries, type: entry};
    if (_errors.measurements.containsKey(type)) {
      _errors = DetailsErrors(
        observationMissing: _errors.observationMissing,
        measurements: {..._errors.measurements}..remove(type),
      );
    }
    _notify();
  }

  void _go(AssessmentStep next) {
    _backStack.add((
      step: _step,
      view: _view,
      previewEvidenceId: _previewEvidenceId,
    ));
    _step = next;
    _notify();
  }

  bool _isAttached(String evidenceId) {
    final String? id = _findingId;
    return id != null &&
        (controller
                .draftOf(id)
                ?.evidence
                .any((e) => e.evidenceId == evidenceId) ??
            false);
  }

  bool _popBack() {
    while (_backStack.isNotEmpty) {
      final _Place place = _backStack.removeLast();
      final String? photo = place.previewEvidenceId;
      if (place.step == AssessmentStep.preview &&
          (photo == null || !_isAttached(photo))) {
        continue;
      }
      _step = place.step;
      _view = place.view;
      _previewEvidenceId = photo;
      return true;
    }
    return false;
  }

  void _resetForNewFinding() {
    _step = AssessmentStep.chooseArea;
    _backStack.clear();
    _area = null;
    _findingId = null;
    _view = CaptureView.overview;
    _previewEvidenceId = null;
    _notice = null;
    _observation = '';
    _entries = {};
    _errors = const DetailsErrors();
    _bytes.clear();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }
}
