import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../../../app/theme.dart';
import 'package:safe_at_home/l10n/app_localizations.dart';

import '../application/assessment_controller.dart';
import '../application/assessment_flow.dart';
import '../domain/annotation/box_annotation.dart';
import '../domain/assessment_location.dart';
import '../domain/capture/capture_adapter.dart';
import '../domain/measurement/length_unit.dart';
import '../domain/measurement/measurement_fields.dart';
import '../domain/review/finding_review_state.dart';
import '../domain/review/finding_review_tracker.dart';
import '../../../shared/presentation/sah_components.dart';
import '../../../shared/presentation/sah_floating_nav.dart';
import 'annotation_editor_screen.dart';
import 'photo_privacy_screen.dart';
import 'assessment_copy.dart';
import 'assessment_location_guide.dart';

class AssessmentFlowScreen extends StatelessWidget {
  const AssessmentFlowScreen({
    super.key,
    required this.flow,
    this.status,
    this.actions = const [],
    this.enabled = true,
    this.embedded = false,
    this.expandMeasurements = false,
    this.areaTools,
    this.areaToolsFirst = false,
    this.keptOnDevice = false,
    this.onContinue,
    this.scanFindingIds = const {},
    this.onChooseLocation,
    this.locationStatus = const {},
    this.roomCards,
  });

  final ValueChanged<AssessmentLocation>? onChooseLocation;

  final Map<AssessmentLocation, String> locationStatus;

  final AssessmentFlow flow;
  final Widget? status;
  final List<Widget> actions;
  final bool enabled;
  final bool embedded;
  final bool expandMeasurements;

  final Widget? areaTools;
  final Widget? roomCards;
  final bool areaToolsFirst;

  final bool keptOnDevice;
  final VoidCallback? onContinue;
  final Set<String> scanFindingIds;

  @override
  Widget build(BuildContext context) {
    return SahKeyboardDismissal(
      child: ListenableBuilder(
        listenable: Listenable.merge([flow, flow.controller]),
        builder: (context, _) {
          final AssessmentStep step = flow.step;
          final bool editable = enabled && !flow.isBusy;
          return _page(
            bottomNavigationBar: step == AssessmentStep.details
                ? _primaryAction(
                    context,
                    !editable
                        ? null
                        : onContinue == null
                        ? flow.saveDetails
                        : () {
                            if (!flow.saveDetails()) return;
                            final id = flow.findingId;
                            if (id != null &&
                                flow.controller.reviewOf(id)?.state ==
                                    FindingReviewState.needsReview &&
                                !flow.controller
                                    .confirmDisplayedRecord(id)
                                    .applied) {
                              return;
                            }
                            onContinue!();
                          },
                    onContinue == null ? 'Review' : 'Done',
                    'assessment-review',
                  )
                : onContinue != null &&
                      (step == AssessmentStep.review ||
                          step == AssessmentStep.chooseArea)
                ? _primaryAction(
                    context,
                    editable
                        ? () {
                            if (step == AssessmentStep.review &&
                                flow.findingId != null &&
                                flow.controller
                                        .reviewOf(flow.findingId!)
                                        ?.state ==
                                    FindingReviewState.needsReview) {
                              if (!flow.controller
                                  .confirmDisplayedRecord(flow.findingId!)
                                  .applied) {
                                return;
                              }
                            }
                            onContinue!();
                          }
                        : null,
                    step == AssessmentStep.chooseArea
                        ? 'Done'
                        : step == AssessmentStep.review &&
                              flow.controller
                                      .reviewOf(flow.findingId!)
                                      ?.state ==
                                  FindingReviewState.needsReview
                        ? 'Confirm and continue'
                        : 'Continue',
                    'assessment-continue',
                  )
                : null,
            appBar: AppBar(
              actions: actions,
              toolbarHeight: 64,
              title: MediaQuery.withClampedTextScaling(
                maxScaleFactor: 1.3,
                child: Text(
                  step == AssessmentStep.chooseArea && areaTools != null
                      ? context.tr('Home assessment')
                      : context.tr(_title(step)),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              leading: flow.canGoBack
                  ? IconButton(
                      icon: const Icon(Icons.arrow_back),
                      tooltip: context.tr('Back'),
                      onPressed: enabled ? flow.back : null,
                    )
                  : null,
            ),
            body: SingleChildScrollView(
              key: ValueKey('assessment-scroll-${step.name}'),
              padding: embedded
                  ? sahFloatingContentPadding(context, all: 16)
                  : const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (embedded) ...[
                    if (step != AssessmentStep.chooseArea || roomCards != null)
                      Semantics(
                        header: true,
                        child: Text(
                          context.tr(
                            step == AssessmentStep.chooseArea &&
                                    roomCards != null
                                ? 'Rooms'
                                : _title(step),
                          ),
                          style: Theme.of(context).textTheme.headlineSmall,
                        ),
                      ),
                    Wrap(
                      spacing: 8,
                      children: [
                        if (flow.canGoBack)
                          TextButton.icon(
                            onPressed: editable ? flow.back : null,
                            icon: const Icon(Icons.arrow_back),
                            label: Text(context.tr('Back')),
                          ),
                        ...actions,
                      ],
                    ),
                  ],
                  ?status,
                  if (step != AssessmentStep.chooseArea &&
                      step != AssessmentStep.review) ...[
                    _Progress(step: step),
                    const SizedBox(height: 16),
                  ],
                  ExcludeFocus(
                    excluding: !editable,
                    child: AbsorbPointer(
                      absorbing: !editable,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: switch (step) {
                          AssessmentStep.chooseArea => _chooseArea(context),
                          AssessmentStep.viewPrompt => _viewPrompt(context),
                          AssessmentStep.preview => _preview(context),
                          AssessmentStep.details => [
                            _DetailsStep(
                              key: ValueKey('details-${flow.findingId}'),
                              expandMeasurements: expandMeasurements,
                              flow: flow,
                              enabled: editable,
                            ),
                          ],
                          AssessmentStep.review => _review(context),
                        },
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _page({
    required SingleChildScrollView body,
    required AppBar appBar,
    Widget? bottomNavigationBar,
  }) => embedded
      ? SingleChildScrollView(
          key: body.key,
          padding: body.padding,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [body.child!, ?bottomNavigationBar],
          ),
        )
      : Scaffold(
          appBar: appBar,
          body: SafeArea(child: body),
          bottomNavigationBar: bottomNavigationBar == null
              ? null
              : SafeArea(child: bottomNavigationBar),
        );

  static String _title(AssessmentStep step) => switch (step) {
    AssessmentStep.chooseArea => 'Choose an area',
    AssessmentStep.viewPrompt => 'Photo',
    AssessmentStep.preview => 'Check the photo',
    AssessmentStep.details => 'What you notice',
    AssessmentStep.review => 'Review',
  };

  Widget _primaryAction(
    BuildContext context,
    VoidCallback? action,
    String label,
    String key,
  ) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
    child: FilledButton(
      key: ValueKey(key),
      onPressed: action,
      child: Text(context.tr(label), textAlign: TextAlign.center),
    ),
  );

  List<Widget> _chooseArea(BuildContext context) {
    final List<FindingDraft> drafts = flow.controller.drafts;
    return [
      if (drafts.isNotEmpty) ...[
        SahSectionHeading(title: context.tr('Added to your assessment')),
        for (final FindingDraft d in drafts)
          SahActionTile(
            key: ValueKey('finding-${d.id}'),
            title: _findingLocationTitle(context, d),
            subtitle: _findingSummary(context, d),
            status: context.tr(
              AssessmentCopy.reviewState(flow.controller.reviewOf(d.id)!.state),
            ),
            statusIcon: _reviewIcon(flow.controller.reviewOf(d.id)!.state),
            icon: Icons.sticky_note_2_outlined,
            onTap: () => flow.openFinding(d.id),
          ),
      ],
      if (areaToolsFirst) ?areaTools,
      if (roomCards == null)
        SahSectionHeading(
          title: context.tr(
            drafts.isEmpty ? 'Choose a place' : 'Add another concern',
          ),
        ),

      if (roomCards != null)
        roomCards!
      else
        for (final AssessmentLocation location in AssessmentLocation.values)
          SahActionTile(
            key: ValueKey('area-${location.name}'),
            title: context.tr(location.title),
            subtitle: locationStatus[location] == null
                ? null
                : context.tr(locationStatus[location]!),
            icon: location.icon,
            onTap: () => onChooseLocation != null
                ? onChooseLocation!(location)
                : flow.chooseLocation(location),
          ),
      if (!areaToolsFirst) ?areaTools,
    ];
  }

  String _findingSummary(BuildContext context, FindingDraft draft) {
    final observation = _observation(context, draft);
    if (observation.trim().isEmpty) return context.tr('No observation yet');
    final characters = observation.runes.toList();
    return characters.length <= 140
        ? observation
        : '${String.fromCharCodes(characters.take(140))}…';
  }

  String _observation(BuildContext context, FindingDraft draft) {
    final value = draft.observation.trim();
    if (scanFindingIds.contains(draft.id)) {
      final source = RegExp(
        r' Source: (?:iPhone RoomPlan|Android ARCore|iPhone ARKit camera) partial scan '
        r'[^;]+; resident-reviewed identification\. '
        r'Model elements: \[.*\]\. Scene SHA-256: [0-9a-f]{64}\. '
        r'Rule [a-z0-9_.]+ v[0-9]+\. Scan geometry is approximate; '
        r'this is not a verified measurement or a professional determination\.$',
      ).firstMatch(value);
      if (source != null && source.start > 0) {
        return context.tr(value.substring(0, source.start));
      }
    }
    return localizedAssessmentObservation(
      context,
      observation: value,
      room: draft.area.name,
    );
  }

  List<Widget> _viewPrompt(BuildContext context) {
    final AssessmentArea area = flow.area!;
    final location = flow.location;
    return [
      SahSectionHeading(
        title: context.tr(location?.title ?? AssessmentCopy.areaTitle(area)),
      ),
      Semantics(
        header: true,
        child: Text(
          context.tr(
            location?.photoPrompt(flow.view) ??
                AssessmentCopy.viewPrompt(area, flow.view),
          ),
          style: Theme.of(context).textTheme.titleLarge,
        ),
      ),
      const SizedBox(height: 8),
      SahNotice(
        title: context.tr('Stay safe'),
        message: context.tr(
          location?.safetyNote ?? AssessmentCopy.safetyNote(area),
        ),
        icon: Icons.health_and_safety_outlined,
        liveRegion: false,
      ),
      _NoticeCard(text: AssessmentCopy.notice(flow.notice)),
      const SizedBox(height: 8),
      if (flow.isBusy)
        Center(
          child: CircularProgressIndicator(
            semanticsLabel: context.tr('Opening camera'),
          ),
        )
      else ...[
        if (flow.cameraBlocked)
          _wide(
            OutlinedButton(
              onPressed: flow.permissionMayHaveChanged,
              child: Text(context.tr('I changed the setting')),
            ),
          )
        else
          _wide(
            FilledButton.icon(
              onPressed: () => flow.openCamera(),
              icon: const Icon(Icons.photo_camera),
              label: Text(context.tr('Open camera')),
            ),
          ),
        _wide(
          OutlinedButton.icon(
            onPressed: () => flow.openCamera(source: CaptureSource.library),
            icon: const Icon(Icons.photo_library_outlined),
            label: Text(context.tr('Choose a photo')),
          ),
        ),
        const SizedBox(height: 8),
        _wide(
          OutlinedButton(
            onPressed: flow.continueWithoutPhoto,
            child: Text(context.tr('Continue without a photo')),
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
          label: context.tr('The photo you just took'),
        ),
      const SizedBox(height: 12),
      SahNotice(
        title: context.tr('Hide private details'),
        message: context.tr(AssessmentCopy.privacyCheck),
        icon: Icons.privacy_tip_outlined,
        liveRegion: false,
      ),
      SahMoreInfo(details: [context.tr(AssessmentCopy.privacyDetail)]),
      if (evidenceId != null && flow.bytesFor(evidenceId) != null)
        _wide(
          OutlinedButton.icon(
            onPressed: flow.isBusy
                ? null
                : () async {
                    final bytes = flow.bytesFor(evidenceId);
                    if (bytes == null) return;
                    final attempt = await flow.beginPrivacyEdit(evidenceId);
                    if (attempt == null) return;
                    if (!context.mounted) {
                      await flow.finishPrivacyEdit(attempt, null);
                      return;
                    }
                    try {
                      Uint8List? edited;
                      try {
                        edited = await Navigator.of(context).push<Uint8List>(
                          MaterialPageRoute(
                            builder: (_) => PhotoPrivacyScreen(bytes: bytes),
                          ),
                        );
                      } finally {
                        await flow.finishPrivacyEdit(attempt, edited);
                      }
                    } catch (_) {
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(
                              context.tr(
                                'The private edited photo could not be saved. Keep the original and try again when device space is available.',
                              ),
                            ),
                          ),
                        );
                      }
                    }
                  },
            icon: const Icon(Icons.privacy_tip_outlined),
            label: Text(context.tr('Crop or cover private details')),
          ),
        ),
      if (evidenceId != null) ..._markArea(context, evidenceId),
      _NoticeCard(text: AssessmentCopy.notice(flow.notice)),
      const SizedBox(height: 16),
      if (flow.isBusy)
        Center(
          child: CircularProgressIndicator(
            semanticsLabel: context.tr('Opening camera'),
          ),
        )
      else ...[
        _wide(
          FilledButton(
            onPressed: flow.continueFromPreview,
            child: Text(context.tr('Continue')),
          ),
        ),
        _wide(
          OutlinedButton.icon(
            onPressed: flow.cameraBlocked
                ? null
                : () => flow.openCamera(retake: true),
            icon: const Icon(Icons.replay),
            label: Text(context.tr('Retake')),
          ),
        ),
        _wide(
          TextButton(
            onPressed: flow.addCloseUp,
            child: Text(context.tr('Add a closer photo')),
          ),
        ),
        const SizedBox(height: 16),
        _wide(
          _destructive(
            context,
            onPressed: () async {
              if (await _confirm(
                context,
                title: context.tr('Remove this photo?'),
                action: context.tr('Remove'),
              )) {
                await flow.removePreviewPhoto();
              }
            },
            label: context.tr('Remove'),
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
      return [
        const SizedBox(height: 8),
        Text(context.tr(AssessmentCopy.markAfterSaving)),
      ];
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
                  onChanged: flow.annotationsChanged,
                  store: store,
                  findingId: flow.findingId!,
                  image: image,
                  bytes: bytes,
                  observation: flow.observationText.trim().isEmpty
                      ? context.tr('Not written yet.')
                      : flow.observationText,
                ),
              ),
            );
            flow.annotationsChanged();
          },
          icon: const Icon(Icons.crop_square),
          label: Text(
            marks == 0
                ? context.tr('Mark the area on this photo')
                : context.tr('Change the mark'),
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
    Widget heading(String title) => Padding(
      padding: const EdgeInsets.only(top: 20, bottom: 6),
      child: Semantics(
        header: true,
        child: Text(title, style: text.titleMedium),
      ),
    );

    return [
      Semantics(
        liveRegion: true,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ExcludeSemantics(
              child: Padding(
                padding: const EdgeInsets.only(top: 3),
                child: Icon(
                  _reviewIcon(state),
                  color: Theme.of(context).colorScheme.primary,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                context.tr(AssessmentCopy.reviewState(state)),
                key: const ValueKey('review-state'),
                style: text.titleLarge,
              ),
            ),
          ],
        ),
      ),
      if (review.anotherViewRequested)
        const _NoticeCard(text: AssessmentCopy.anotherViewRequested),
      heading(
        context.tr('{area} · what you notice', {
          'area': _findingLocationTitle(context, draft),
        }),
      ),
      Text(_observation(context, draft), style: text.bodyLarge),
      if (scanFindingIds.contains(id))
        ExpansionTile(
          key: ValueKey('scan-finding-source-$id'),
          tilePadding: EdgeInsets.zero,
          title: Text(context.tr('Scan source and technical details')),
          children: [Text(draft.observation), const SizedBox(height: 12)],
        ),
      heading(context.tr('Photos (optional)')),
      if (draft.evidence.isEmpty)
        Text(context.tr(AssessmentCopy.noPhotos))
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
                label: context.tr('Photo {number} of {count}', {
                  'number': i + 1,
                  'count': draft.evidence.length,
                }),
                onTap: () => flow.openPhoto(e.evidenceId),
              ),
          ],
        ),
      if (draft.measurements.isNotEmpty || cleared.isNotEmpty)
        heading(context.tr('Measurements you included')),
      for (final RecordedMeasurement m in draft.measurements)
        _MeasurementSummary(
          measurement: m,
          history: flow.controller.measurementHistoryOf(id, m.type),
        ),
      for (final String type in cleared)
        _ClearedMeasurement(
          type: type,
          history: flow.controller.measurementHistoryOf(id, type),
        ),
      const SizedBox(height: 16),
      if (!keptOnDevice)
        SahNotice(
          message: context.tr(AssessmentCopy.notSavedYet),
          tone: SahNoticeTone.warning,
          liveRegion: false,
        ),
      const SizedBox(height: 8),
      if (state == FindingReviewState.needsReview && onContinue == null)
        _wide(
          FilledButton(
            onPressed: () => flow.controller.confirmDisplayedRecord(id),
            child: Text(context.tr('Confirm this finding')),
          ),
        ),
      _wide(
        state == FindingReviewState.needsReview || onContinue != null
            ? OutlinedButton(
                onPressed: flow.startAnother,
                child: Text(
                  context.tr(
                    onContinue == null
                        ? 'Done, add another finding'
                        : 'Add another concern',
                  ),
                ),
              )
            : FilledButton(
                onPressed: flow.startAnother,
                child: Text(context.tr('Done, add another finding')),
              ),
      ),
      heading(context.tr('Other changes')),
      Wrap(
        spacing: 8,
        runSpacing: 4,
        children: [
          TextButton.icon(
            onPressed: flow.edit,
            icon: const Icon(Icons.edit_outlined),
            label: Text(context.tr('Edit')),
          ),
          if (state != FindingReviewState.dismissed)
            TextButton.icon(
              onPressed: flow.requestAnotherView,
              icon: const Icon(Icons.add_a_photo_outlined),
              label: Text(context.tr('Request another photo')),
            ),
          if (state == FindingReviewState.dismissed)
            TextButton.icon(
              onPressed: () => flow.controller.restore(id),
              icon: const Icon(Icons.undo_rounded),
              label: Text(context.tr('Restore')),
            )
          else
            TextButton.icon(
              onPressed: () => flow.controller.dismiss(id),
              icon: const Icon(Icons.visibility_off_outlined),
              label: Text(context.tr('Dismiss')),
            ),
        ],
      ),
      const Divider(height: 32),
      _wide(
        _destructive(
          context,
          onPressed: () async {
            if (await _confirm(
              context,
              title: context.tr('Delete this finding and its photos?'),
              action: context.tr('Delete'),
            )) {
              await flow.discardFinding();
            }
          },
          label: context.tr('Delete this finding'),
        ),
      ),
    ];
  }
}

String _findingLocationTitle(BuildContext context, FindingDraft draft) =>
    context.tr(
      AssessmentLocation.fromObservation(
            draft.area,
            draft.observation,
          )?.title ??
          AssessmentCopy.areaTitle(draft.area),
    );

IconData _reviewIcon(FindingReviewState state) => switch (state) {
  FindingReviewState.needsReview => Icons.rate_review_outlined,
  FindingReviewState.confirmed => Icons.task_alt_rounded,
  FindingReviewState.dismissed => Icons.visibility_off_outlined,
};

Widget _destructive(
  BuildContext context, {
  required VoidCallback onPressed,
  required String label,
}) {
  final Color color = Theme.of(context).colorScheme.error;
  return OutlinedButton.icon(
    style: OutlinedButton.styleFrom(
      foregroundColor: color,
      side: BorderSide(color: color),
    ),
    onPressed: onPressed,
    icon: const Icon(Icons.delete_outline),
    label: Text(label),
  );
}

class _Progress extends StatelessWidget {
  const _Progress({required this.step});

  final AssessmentStep step;

  @override
  Widget build(BuildContext context) {
    final int number = step == AssessmentStep.details ? 2 : 1;
    const int total = 2;
    return Semantics(
      container: true,
      label: context.tr('Step {number} of {total}', {
        'number': number,
        'total': total,
      }),
      excludeSemantics: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            context.tr('Step {number} of {total}', {
              'number': number,
              'total': total,
            }),
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: number / total,
              minHeight: 6,
              backgroundColor: Theme.of(context).colorScheme.surfaceContainer,
            ),
          ),
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
    return SahNotice(message: context.tr(message));
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
  bool failed = false;
  Future<void> _load() async {
    try {
      await widget.flow.loadBytes(widget.evidenceId);
      if (mounted) {
        setState(
          () => failed =
              widget.flow.evidence[widget.evidenceId] != null &&
              widget.flow.bytesFor(widget.evidenceId) == null,
        );
      }
    } catch (_) {
      if (mounted) setState(() => failed = true);
    }
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final bytes = widget.flow.bytesFor(widget.evidenceId);
    final bool savedOnly = widget.flow.evidence[widget.evidenceId] == null;
    final String status = failed
        ? context.tr('Photo unavailable. Open this finding again to retry.')
        : bytes != null
        ? ''
        : savedOnly
        ? context.tr('Saved to your case')
        : context.tr('Loading photo');
    final Widget fallback = SizedBox(
      height: widget.height,
      width: widget.height * 4 / 3,
      child: Center(
        child: Text(
          bytes == null ? status : context.tr('Preview unavailable'),
          textAlign: TextAlign.center,
        ),
      ),
    );
    final String label = [
      widget.label,
      if (status.isNotEmpty) status.toLowerCase(),
      if (widget.onTap != null) context.tr('open to retake or remove'),
    ].join(', ');
    final Widget image = bytes == null
        ? fallback
        : Image.memory(
            bytes,
            height: widget.height,
            cacheWidth: widget.height >= 300 ? 1024 : 256,
            fit: BoxFit.contain,
            excludeFromSemantics: true,
            errorBuilder: (_, _, _) => fallback,
          );
    return Semantics(
      container: true,
      image: true,
      button: widget.onTap != null,
      onTap: widget.onTap,
      label: label,
      excludeSemantics: true,
      child: widget.onTap == null
          ? image
          : InkWell(onTap: widget.onTap, child: image),
    );
  }
}

class _MeasurementSummary extends StatelessWidget {
  const _MeasurementSummary({required this.measurement, required this.history});

  final RecordedMeasurement measurement;
  final List<MeasurementChange> history;

  @override
  Widget build(BuildContext context) {
    final RecordedMeasurement m = measurement;
    final spec = measurementFieldSpecFor(m.type);
    final String label = spec == null ? m.type : context.tr(spec.label);
    final String method = context.tr(
      m.method == MeasurementMethod.estimated ? 'Your estimate' : 'Measured',
    );
    final ThemeData theme = Theme.of(context);
    return _Panel(
      children: [
        Text(
          context.tr('{label}: {measurement}', {
            'label': label,
            'measurement': describeMeasurement(m, context: context),
          }),
          style: theme.textTheme.bodyLarge,
        ),
        Text(
          context.tr('{method} · {status}', {
            'method': method,
            'status': context.tr(
              m.confirmed ? 'checked by you' : 'not checked yet',
            ),
          }),
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        if (m.promptsZeroReview) Text(context.tr(AssessmentCopy.zeroCheck)),
        if (history.isNotEmpty)
          Text(
            context.tr('Earlier: {history}', {
              'history': describeHistory(history, context: context),
            }),
          ),
        if (!m.originalInputKnown && !m.confirmed)
          Text(
            context.tr(
              'Original input unavailable. This size remains unverified.',
            ),
          ),
      ],
    );
  }
}

class _ClearedMeasurement extends StatelessWidget {
  const _ClearedMeasurement({required this.type, required this.history});

  final String type;
  final List<MeasurementChange> history;

  @override
  Widget build(BuildContext context) {
    final spec = measurementFieldSpecFor(type);
    final String label = spec == null ? type : context.tr(spec.label);
    return _Panel(
      children: [
        Text(context.tr('{label}: not recorded now', {'label': label})),
        Text(
          context.tr('Earlier: {history}', {
            'history': describeHistory(history, context: context),
          }),
        ),
      ],
    );
  }
}

class _DetailsStep extends StatefulWidget {
  const _DetailsStep({
    super.key,
    required this.flow,
    required this.enabled,
    this.expandMeasurements = false,
  });

  final AssessmentFlow flow;
  final bool enabled;
  final bool expandMeasurements;

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
        SahSectionHeading(
          title: context.tr(
            flow.location?.title ?? AssessmentCopy.areaTitle(flow.area!),
          ),
        ),
        _concernChoices(context),
        const SizedBox(height: 16),
        TextField(
          key: const ValueKey('observation'),
          controller: _observation,
          enabled: widget.enabled,
          minLines: 3,
          maxLines: 6,
          onChanged: (text) {
            if (widget.enabled && !flow.isBusy) {
              setState(() {});
              flow.setObservationText(text);
            }
          },
          decoration: InputDecoration(
            labelText: context.tr(AssessmentCopy.observationLabel),

            error: errors.observationMissing
                ? Text(context.tr(AssessmentCopy.observationRequired))
                : null,
            border: const OutlineInputBorder(),
          ),
        ),
        if (flow.measurementTypes.isNotEmpty) ...[
          const SizedBox(height: 16),
          if (errors.measurements.isNotEmpty)
            SahNotice(
              message: context.tr(
                'Open Add measurements below to correct or clear the highlighted size.',
              ),
              tone: SahNoticeTone.warning,
            ),
          ExpansionTile(
            key: ValueKey('optional-measurements-${flow.findingId}'),
            title: Text(context.tr('Add measurements (optional)')),

            tilePadding: EdgeInsets.zero,
            initiallyExpanded:
                widget.expandMeasurements ||
                flow.measurementTypes.any(
                  (type) => flow.entryFor(type).text.isNotEmpty,
                ),
            children: [
              for (final String type in flow.measurementTypes)
                _measurementField(context, type),
            ],
          ),
        ],
      ],
    );
  }

  Widget _concernChoices(BuildContext context) {
    final AssessmentFlow flow = widget.flow;
    final text = _observation.text;
    void toggle(String sentence, bool add) {
      final next = add
          ? [text.trim(), sentence].where((p) => p.isNotEmpty).join(' ')
          : text
                .replaceFirst(sentence, '')
                .replaceAll(RegExp(r' {2,}'), ' ')
                .trim();
      setState(
        () => _observation.value = TextEditingValue(
          text: next,
          selection: TextSelection.collapsed(offset: next.length),
        ),
      );
      flow.setObservationText(next);
    }

    return Column(
      children: [
        for (final concern in AssessmentCopy.concernChoicesFor(flow.area!))
          Builder(
            builder: (context) {
              final sentence = context.tr(concern);
              return CheckboxListTile(
                key: ValueKey('concern-$concern'),
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                title: Text(sentence),
                value: text.contains(sentence),
                onChanged: widget.enabled && !flow.isBusy
                    ? (selected) => toggle(sentence, selected!)
                    : null,
              );
            },
          ),
      ],
    );
  }

  Widget _measurementField(BuildContext context, String type) {
    final AssessmentFlow flow = widget.flow;
    final MeasurementFieldSpec spec = measurementFieldSpecFor(type)!;
    final MeasurementEntry entry = flow.entryFor(type);
    final error = flow.errors.measurements[type];
    return _Panel(
      children: [
        Semantics(
          header: true,
          child: Text(
            context.tr(spec.label),
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ),
        SahMoreInfo(
          label: context.tr('How to measure'),
          details: [context.tr(spec.definition), context.tr(spec.howToMeasure)],
        ),
        ExcludeSemantics(
          child: Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              context.tr('{label} ({unit})', {
                'label': context.tr(spec.label),
                'unit': context.tr(entry.unit.symbol),
              }),
              key: ValueKey('measurement-full-label-$type'),
              style: Theme.of(context).textTheme.bodyLarge,
            ),
          ),
        ),
        TextField(
          key: ValueKey('measurement-$type'),
          controller: _values[type],
          enabled: widget.enabled,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          onChanged: (text) {
            if (widget.enabled && !flow.isBusy) {
              flow.setMeasurementText(type, text);
            }
          },
          decoration: InputDecoration(
            labelText: context.tr('{label} ({unit})', {
              'label': context.tr(spec.label),
              'unit': context.tr(entry.unit.symbol),
            }),
            error: error == null
                ? null
                : Text(context.tr(AssessmentCopy.measurementError(error))),
            border: const OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          key: ValueKey('unit-$type'),
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final LengthUnit unit in LengthUnit.values)
              Tooltip(
                message: context.tr(_unitName(unit)),
                child: ChoiceChip(
                  label: Text(
                    context.tr(unit.symbol),
                    semanticsLabel: context.tr(_unitName(unit)),
                  ),
                  selected: entry.unit == unit,
                  materialTapTargetSize: MaterialTapTargetSize.padded,
                  onSelected: widget.enabled
                      ? (_) => flow.setMeasurementUnit(type, unit)
                      : null,
                ),
              ),
          ],
        ),
        CheckboxListTile(
          key: ValueKey('estimate-$type'),
          contentPadding: EdgeInsets.zero,
          value: entry.method == MeasurementMethod.estimated,
          title: Text(context.tr(AssessmentCopy.estimateLabel)),
          onChanged: widget.enabled
              ? (v) => flow.setMeasurementMethod(
                  type,
                  v == true
                      ? MeasurementMethod.estimated
                      : MeasurementMethod.manual,
                )
              : null,
        ),
      ],
    );
  }

  static String _unitName(LengthUnit unit) => switch (unit) {
    LengthUnit.millimetre => 'millimetres',
    LengthUnit.centimetre => 'centimetres',
    LengthUnit.inch => 'inches',
    LengthUnit.metre => 'metres',
    LengthUnit.foot => 'feet',
  };
}

class _Panel extends StatelessWidget {
  const _Panel({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(top: 12),
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surface,
      borderRadius: BorderRadius.circular(SahRadius.large),
      border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    ),
  );
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
        scrollable: true,
        title: Text(title),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(context.tr('Cancel')),
          ),
          TextButton(
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: Text(action),
          ),
        ],
      ),
    ) ??
    false;

String describeMeasurement(RecordedMeasurement m, {BuildContext? context}) {
  if (context != null) {
    final entered = m.input.unit == LengthUnit.millimetre
        ? ''
        : context.tr(' (you entered {value} {unit})', {
            'value': m.input.originalText.trim(),
            'unit': context.tr(m.input.unit.symbol),
          });
    final estimate = m.method == MeasurementMethod.estimated
        ? context.tr(', estimate')
        : '';
    return context.tr('{value} mm{entered}{estimate}', {
      'value': formatMillimetres(m.input.millimetres),
      'entered': entered,
      'estimate': estimate,
    });
  }
  final String entered = m.input.unit == LengthUnit.millimetre
      ? ''
      : ' (you entered ${m.input.originalText.trim()} ${m.input.unit.symbol})';
  final String estimate = m.method == MeasurementMethod.estimated
      ? ', estimate'
      : '';
  return '${formatMillimetres(m.input.millimetres)} mm$entered$estimate';
}

String describeHistory(
  List<MeasurementChange> history, {
  BuildContext? context,
}) => history
    .map((h) => describeMeasurement(h.previous, context: context))
    .join(context?.tr(', then ') ?? ', then ');

String formatMillimetres(double value) {
  if (value == value.truncateToDouble()) return value.toInt().toString();
  String text = value.toStringAsFixed(6);
  text = text.replaceFirst(RegExp(r'0+$'), '');
  return text.endsWith('.') ? text.substring(0, text.length - 1) : text;
}
