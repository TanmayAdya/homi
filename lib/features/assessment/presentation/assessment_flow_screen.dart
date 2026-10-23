import 'package:flutter/material.dart';

import '../application/assessment_controller.dart';
import '../application/assessment_flow.dart';
import '../domain/annotation/box_annotation.dart';
import '../domain/capture/capture_adapter.dart';
import '../domain/measurement/length_unit.dart';
import '../domain/measurement/measurement_fields.dart';
import '../domain/review/finding_review_state.dart';
import '../domain/review/finding_review_tracker.dart';
import 'annotation_editor_screen.dart';
import 'assessment_copy.dart';

class AssessmentFlowScreen extends StatelessWidget {
  const AssessmentFlowScreen({super.key, required this.flow});

  final AssessmentFlow flow;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([flow, flow.controller]),
      builder: (context, _) {
        final AssessmentStep step = flow.step;
        return Scaffold(
          appBar: AppBar(
            title: Text(_title(step)),
            leading: flow.canGoBack
                ? IconButton(
                    icon: const Icon(Icons.arrow_back),
                    tooltip: 'Back',
                    onPressed: flow.back,
                  )
                : null,
          ),
          body: SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _Progress(step: step),
                  const SizedBox(height: 16),
                  ...switch (step) {
                    AssessmentStep.chooseArea => _chooseArea(context),
                    AssessmentStep.viewPrompt => _viewPrompt(context),
                    AssessmentStep.preview => _preview(context),
                    AssessmentStep.details => [
                      _DetailsStep(
                        key: ValueKey('details-${flow.findingId}'),
                        flow: flow,
                      ),
                    ],
                    AssessmentStep.review => _review(context),
                  },
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  static String _title(AssessmentStep step) => switch (step) {
    AssessmentStep.chooseArea => 'Choose an area',
    AssessmentStep.viewPrompt => 'Photo',
    AssessmentStep.preview => 'Check the photo',
    AssessmentStep.details => 'What you notice',
    AssessmentStep.review => 'Review',
  };

  List<Widget> _chooseArea(BuildContext context) {
    final List<FindingDraft> drafts = flow.controller.drafts;
    return [
      for (final AssessmentArea area in AssessmentArea.values)
        Card(
          child: ListTile(
            key: ValueKey('area-${area.name}'),
            minVerticalPadding: 16,
            title: Text(AssessmentCopy.areaTitle(area)),
            subtitle: Text(AssessmentCopy.areaExplanation(area)),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => flow.chooseArea(area),
          ),
        ),
      if (drafts.isNotEmpty) ...[
        const SizedBox(height: 16),
        Text('Your findings', style: Theme.of(context).textTheme.titleMedium),
        for (final FindingDraft d in drafts)
          Card(
            child: ListTile(
              key: ValueKey('finding-${d.id}'),
              minVerticalPadding: 12,
              title: Text(
                d.observation.trim().isEmpty
                    ? 'No observation yet'
                    : d.observation.trim(),
              ),
              subtitle: Text(
                '${AssessmentCopy.areaTitle(d.area)} · '
                '${AssessmentCopy.reviewState(flow.controller.reviewOf(d.id)!.state)} · '
                '${d.evidence.length} ${d.evidence.length == 1 ? 'photo' : 'photos'}',
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => flow.openFinding(d.id),
            ),
          ),
      ],
    ];
  }

  List<Widget> _viewPrompt(BuildContext context) {
    final AssessmentArea area = flow.area!;
    return [
      Text(
        AssessmentCopy.viewPrompt(area, flow.view),
        style: Theme.of(context).textTheme.titleMedium,
      ),
      const SizedBox(height: 8),
      Text(AssessmentCopy.safetyNote(area)),
      const SizedBox(height: 8),
      const Text(AssessmentCopy.noPhotoOption),
      _NoticeCard(text: AssessmentCopy.notice(flow.notice)),
      const SizedBox(height: 16),
      if (flow.isBusy)
        const Center(
          child: CircularProgressIndicator(semanticsLabel: 'Opening camera'),
        )
      else ...[
        if (flow.cameraBlocked)
          _wide(
            OutlinedButton(
              onPressed: flow.permissionMayHaveChanged,
              child: const Text('I changed the setting'),
            ),
          )
        else
          _wide(
            FilledButton.icon(
              onPressed: () => flow.openCamera(),
              icon: const Icon(Icons.photo_camera),
              label: const Text('Open camera'),
            ),
          ),
        _wide(
          OutlinedButton(
            onPressed: flow.continueWithoutPhoto,
            child: const Text('Continue without a photo'),
          ),
        ),
      ],
    ];
  }

  List<Widget> _preview(BuildContext context) {
    final String? evidenceId = flow.previewEvidenceId;
    return [
      if (evidenceId != null)
        _Photo(
          flow: flow,
          evidenceId: evidenceId,
          height: 360,
          label: 'The photo you just took',
        ),
      const SizedBox(height: 12),
      const Text(AssessmentCopy.privacyCheck),
      if (evidenceId != null) ..._markArea(context, evidenceId),
      _NoticeCard(text: AssessmentCopy.notice(flow.notice)),
      const SizedBox(height: 16),
      if (flow.isBusy)
        const Center(
          child: CircularProgressIndicator(semanticsLabel: 'Opening camera'),
        )
      else ...[
        _wide(
          FilledButton(
            onPressed: flow.continueFromPreview,
            child: const Text('Continue'),
          ),
        ),
        _wide(
          OutlinedButton.icon(
            onPressed: flow.cameraBlocked
                ? null
                : () => flow.openCamera(retake: true),
            icon: const Icon(Icons.replay),
            label: const Text('Retake'),
          ),
        ),
        _wide(
          OutlinedButton.icon(
            onPressed: () async {
              if (await _confirm(
                context,
                title: 'Remove this photo?',
                action: 'Remove',
              )) {
                await flow.removePreviewPhoto();
              }
            },
            icon: const Icon(Icons.delete_outline),
            label: const Text('Remove'),
          ),
        ),
        _wide(
          TextButton(
            onPressed: flow.addCloseUp,
            child: const Text('Add a closer photo'),
          ),
        ),
      ],
    ];
  }

  List<Widget> _markArea(BuildContext context, String evidenceId) {
    final AnnotationStore? store = flow.annotations;
    if (store == null) return const [];
    final AnnotatedImage? image = flow.annotatableImage(evidenceId);
    final bytes = flow.bytesFor(evidenceId);
    if (image == null || bytes == null) {
      return const [SizedBox(height: 8), Text(AssessmentCopy.markAfterSaving)];
    }
    final int marks = store
        .on(image)
        .where((b) => b.findingId == flow.findingId)
        .length;
    return [
      _wide(
        OutlinedButton.icon(
          onPressed: () async {
            await Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => AnnotationEditorScreen(
                  store: store,
                  findingId: flow.findingId!,
                  image: image,
                  bytes: bytes,
                  observation: flow.observationText.trim().isEmpty
                      ? 'Not written yet.'
                      : flow.observationText,
                ),
              ),
            );
            flow.annotationsChanged();
          },
          icon: const Icon(Icons.crop_square),
          label: Text(
            marks == 0 ? 'Mark the area on this photo' : 'Change the mark',
          ),
        ),
      ),
    ];
  }

  List<Widget> _review(BuildContext context) {
    final String id = flow.findingId!;
    final FindingDraft draft = flow.controller.draftOf(id)!;
    final FindingReview review = flow.controller.reviewOf(id)!;
    final FindingReviewState state = review.state;
    final TextTheme text = Theme.of(context).textTheme;
    final List<String> cleared = [
      for (final MeasurementFieldSpec spec in proposedMeasurementFields)
        if (draft.measurementOf(spec.type) == null &&
            flow.controller.measurementHistoryOf(id, spec.type).isNotEmpty)
          spec.type,
    ];

    return [
      Semantics(
        liveRegion: true,
        child: Text(
          AssessmentCopy.reviewState(state),
          key: const ValueKey('review-state'),
          style: text.titleMedium,
        ),
      ),
      if (review.anotherViewRequested)
        const _NoticeCard(text: AssessmentCopy.anotherViewRequested),
      const SizedBox(height: 12),
      Text(
        '${AssessmentCopy.areaTitle(draft.area)} · what you notice',
        style: text.labelLarge,
      ),
      Text(draft.observation.trim()),
      const SizedBox(height: 12),
      Text('Photos', style: text.labelLarge),
      if (draft.evidence.isEmpty)
        const Text(AssessmentCopy.noPhotos)
      else
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final (int i, e) in draft.evidence.indexed)
              _Photo(
                key: ValueKey('review-photo-${e.evidenceId}'),
                flow: flow,
                evidenceId: e.evidenceId,
                height: 96,
                label: 'Photo ${i + 1} of ${draft.evidence.length}',
                onTap: () => flow.openPhoto(e.evidenceId),
              ),
          ],
        ),
      const SizedBox(height: 12),
      Text('Measurements', style: text.labelLarge),
      if (draft.measurements.isEmpty && cleared.isEmpty)
        const Text('None recorded.'),
      for (final RecordedMeasurement m in draft.measurements)
        _MeasurementSummary(
          measurement: m,
          history: flow.controller.measurementHistoryOf(id, m.type),
          onConfirm: () => flow.controller.confirmMeasurement(id, m.type),
        ),
      for (final String type in cleared)
        _ClearedMeasurement(
          type: type,
          history: flow.controller.measurementHistoryOf(id, type),
        ),
      const SizedBox(height: 16),
      const Text(AssessmentCopy.confirmMeaning),
      const SizedBox(height: 8),
      const Text(AssessmentCopy.notSavedYet),
      const SizedBox(height: 16),
      if (state == FindingReviewState.needsReview)
        _wide(
          FilledButton(
            onPressed: () => flow.controller.confirm(id),
            child: const Text('Confirm this finding'),
          ),
        ),
      _wide(OutlinedButton(onPressed: flow.edit, child: const Text('Edit'))),
      if (state != FindingReviewState.dismissed)
        _wide(
          OutlinedButton(
            onPressed: flow.requestAnotherView,
            child: const Text('Request another photo'),
          ),
        ),
      if (state == FindingReviewState.dismissed)
        _wide(
          OutlinedButton(
            onPressed: () => flow.controller.restore(id),
            child: const Text('Restore'),
          ),
        )
      else
        _wide(
          OutlinedButton(
            onPressed: () => flow.controller.dismiss(id),
            child: const Text('Dismiss'),
          ),
        ),
      _wide(
        TextButton(
          onPressed: flow.startAnother,
          child: const Text('Done, add another finding'),
        ),
      ),
      _wide(
        TextButton(
          onPressed: () async {
            if (await _confirm(
              context,
              title: 'Delete this finding and its photos?',
              action: 'Delete',
            )) {
              await flow.discardFinding();
            }
          },
          child: const Text('Delete this finding'),
        ),
      ),
    ];
  }
}

class _Progress extends StatelessWidget {
  const _Progress({required this.step});

  final AssessmentStep step;

  @override
  Widget build(BuildContext context) {
    final int number = step.index + 1;
    final int total = AssessmentStep.values.length;
    return Semantics(
      container: true,
      label: 'Step $number of $total',
      excludeSemantics: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Step $number of $total'),
          const SizedBox(height: 4),
          LinearProgressIndicator(value: number / total),
        ],
      ),
    );
  }
}

class _NoticeCard extends StatelessWidget {
  const _NoticeCard({required this.text});

  final String? text;

  @override
  Widget build(BuildContext context) {
    final String? message = text;
    if (message == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Semantics(
        liveRegion: true,
        child: Card(
          color: Theme.of(context).colorScheme.secondaryContainer,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.info_outline),
                const SizedBox(width: 8),
                Expanded(child: Text(message)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Photo extends StatefulWidget {
  const _Photo({
    super.key,
    required this.flow,
    required this.evidenceId,
    required this.height,
    required this.label,
    this.onTap,
  });

  final AssessmentFlow flow;
  final String evidenceId;
  final double height;
  final String label;

  final VoidCallback? onTap;

  @override
  State<_Photo> createState() => _PhotoState();
}

class _PhotoState extends State<_Photo> {
  @override
  void initState() {
    super.initState();
    widget.flow.loadBytes(widget.evidenceId);
  }

  @override
  Widget build(BuildContext context) {
    final bytes = widget.flow.bytesFor(widget.evidenceId);
    final bool savedOnly = widget.flow.evidence[widget.evidenceId] == null;
    final String status = bytes != null
        ? ''
        : savedOnly
        ? 'Saved to your case'
        : 'Loading photo';
    final Widget fallback = SizedBox(
      height: widget.height,
      width: widget.height * 4 / 3,
      child: Center(
        child: Text(
          bytes == null ? status : 'Preview unavailable',
          textAlign: TextAlign.center,
        ),
      ),
    );
    final String label = [
      widget.label,
      if (status.isNotEmpty) status.toLowerCase(),
      if (widget.onTap != null) 'open to retake or remove',
    ].join(', ');
    final Widget image = bytes == null
        ? fallback
        : Image.memory(
            bytes,
            height: widget.height,
            fit: BoxFit.contain,
            excludeFromSemantics: true,
            errorBuilder: (_, _, _) => fallback,
          );
    return Semantics(
      container: true,
      image: true,
      button: widget.onTap != null,
      label: label,
      excludeSemantics: true,
      child: widget.onTap == null
          ? image
          : InkWell(onTap: widget.onTap, child: image),
    );
  }
}

class _MeasurementSummary extends StatelessWidget {
  const _MeasurementSummary({
    required this.measurement,
    required this.history,
    required this.onConfirm,
  });

  final RecordedMeasurement measurement;
  final List<MeasurementChange> history;
  final VoidCallback onConfirm;

  @override
  Widget build(BuildContext context) {
    final RecordedMeasurement m = measurement;
    final String label = measurementFieldSpecFor(m.type)?.label ?? m.type;
    final String method = m.method == MeasurementMethod.estimated
        ? 'your estimate'
        : 'measured';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('$label: ${describeMeasurement(m)}'),
            Text(
              '${method[0].toUpperCase()}${method.substring(1)} · '
              '${m.confirmed ? 'checked by you' : 'not checked yet'}',
            ),
            if (m.promptsZeroReview) const Text(AssessmentCopy.zeroCheck),
            if (history.isNotEmpty)
              Text('Earlier: ${describeHistory(history)}'),
            if (!m.confirmed)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: onConfirm,
                  child: Text('This $label is right'),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _ClearedMeasurement extends StatelessWidget {
  const _ClearedMeasurement({required this.type, required this.history});

  final String type;
  final List<MeasurementChange> history;

  @override
  Widget build(BuildContext context) {
    final String label = measurementFieldSpecFor(type)?.label ?? type;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('$label: not recorded now'),
            Text('Earlier: ${describeHistory(history)}'),
          ],
        ),
      ),
    );
  }
}

class _DetailsStep extends StatefulWidget {
  const _DetailsStep({super.key, required this.flow});

  final AssessmentFlow flow;

  @override
  State<_DetailsStep> createState() => _DetailsStepState();
}

class _DetailsStepState extends State<_DetailsStep> {
  late final TextEditingController _observation = TextEditingController(
    text: widget.flow.observationText,
  );
  late final Map<String, TextEditingController> _values = {
    for (final String type in widget.flow.measurementTypes)
      type: TextEditingController(text: widget.flow.entryFor(type).text),
  };

  @override
  void dispose() {
    _observation.dispose();
    for (final TextEditingController c in _values.values) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AssessmentFlow flow = widget.flow;
    final DetailsErrors errors = flow.errors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          key: const ValueKey('observation'),
          controller: _observation,
          minLines: 3,
          maxLines: 6,
          onChanged: flow.setObservationText,
          decoration: InputDecoration(
            labelText: AssessmentCopy.observationLabel,
            helperText: AssessmentCopy.observationHint,
            helperMaxLines: 3,
            errorText: errors.observationMissing
                ? AssessmentCopy.observationRequired
                : null,
            border: const OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 16),
        const Text(AssessmentCopy.measurementsIntro),
        for (final String type in flow.measurementTypes)
          _measurementField(context, type),
        const SizedBox(height: 16),
        FilledButton(onPressed: flow.saveDetails, child: const Text('Review')),
      ],
    );
  }

  Widget _measurementField(BuildContext context, String type) {
    final AssessmentFlow flow = widget.flow;
    final MeasurementFieldSpec spec = measurementFieldSpecFor(type)!;
    final MeasurementEntry entry = flow.entryFor(type);
    final error = flow.errors.measurements[type];
    return Card(
      margin: const EdgeInsets.only(top: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(spec.label, style: Theme.of(context).textTheme.titleSmall),
            Text(spec.definition),
            const SizedBox(height: 4),
            Text('How to measure: ${spec.howToMeasure}'),
            const SizedBox(height: 8),
            TextField(
              key: ValueKey('measurement-$type'),
              controller: _values[type],
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              onChanged: (text) => flow.setMeasurementText(type, text),
              decoration: InputDecoration(
                labelText: '${spec.label} (${entry.unit.symbol})',
                errorText: error == null
                    ? null
                    : AssessmentCopy.measurementError(error),
                errorMaxLines: 3,
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            SegmentedButton<LengthUnit>(
              key: ValueKey('unit-$type'),
              segments: [
                for (final LengthUnit unit in LengthUnit.values)
                  ButtonSegment(
                    value: unit,
                    label: Text(unit.symbol),
                    tooltip: _unitName(unit),
                  ),
              ],
              selected: {entry.unit},
              onSelectionChanged: (s) =>
                  flow.setMeasurementUnit(type, s.single),
            ),
            CheckboxListTile(
              key: ValueKey('estimate-$type'),
              contentPadding: EdgeInsets.zero,
              value: entry.method == MeasurementMethod.estimated,
              title: const Text(AssessmentCopy.estimateLabel),
              onChanged: (v) => flow.setMeasurementMethod(
                type,
                v == true
                    ? MeasurementMethod.estimated
                    : MeasurementMethod.manual,
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _unitName(LengthUnit unit) => switch (unit) {
    LengthUnit.millimetre => 'millimetres',
    LengthUnit.centimetre => 'centimetres',
    LengthUnit.inch => 'inches',
  };
}

Widget _wide(Widget button) => Padding(
  padding: const EdgeInsets.only(top: 8),
  child: SizedBox(width: double.infinity, child: button),
);

Future<bool> _confirm(
  BuildContext context, {
  required String title,
  required String action,
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(action),
          ),
        ],
      ),
    ) ??
    false;

String describeMeasurement(RecordedMeasurement m) {
  final String entered = m.input.unit == LengthUnit.millimetre
      ? ''
      : ' (you entered ${m.input.originalText.trim()} ${m.input.unit.symbol})';
  final String estimate = m.method == MeasurementMethod.estimated
      ? ', estimate'
      : '';
  return '${formatMillimetres(m.input.millimetres)} mm$entered$estimate';
}

String describeHistory(List<MeasurementChange> history) =>
    history.map((h) => describeMeasurement(h.previous)).join(', then ');

String formatMillimetres(double value) {
  if (value == value.truncateToDouble()) return value.toInt().toString();
  String text = value.toStringAsFixed(6);
  text = text.replaceFirst(RegExp(r'0+$'), '');
  return text.endsWith('.') ? text.substring(0, text.length - 1) : text;
}
