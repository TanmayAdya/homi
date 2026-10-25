import 'package:flutter/material.dart';
import 'package:safe_at_home/l10n/app_localizations.dart';

import '../../../shared/models/contracts.dart';
import '../../../shared/models/evidence.dart';
import '../application/export_review.dart';
import '../domain/export/export_selection_draft.dart';
import 'assessment_copy.dart';
import 'photo_decode_gate.dart';

class ExportReviewScreen extends StatefulWidget {
  const ExportReviewScreen({
    super.key,
    required this.review,
    required this.savedCase,
    required this.onDone,
  });

  final ExportReview review;

  final CaseSnapshot Function() savedCase;

  final void Function(List<EvidenceSelection> selections) onDone;

  @override
  State<ExportReviewScreen> createState() => _ExportReviewScreenState();
}

class _ExportReviewScreenState extends State<ExportReviewScreen> {
  String? _rejection;
  final Map<String, int> _decoded = {};

  @override
  void initState() {
    super.initState();
    if (widget.review.catalog == null) widget.review.load();
  }

  @override
  void didUpdateWidget(ExportReviewScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(widget.review, oldWidget.review)) {
      _decoded.clear();
      if (widget.review.catalog == null) widget.review.load();
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.review,
      builder: (context, _) {
        final ExportReview review = widget.review;
        final List<ExportCandidate> candidates = review.candidates;
        final selection = review.draft.selection;
        return Scaffold(
          appBar: AppBar(title: Text(context.tr('Photos for the draft'))),
          body: SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    context.tr(
                      'Choose up to 6 photos for the draft. Look at each photo first: these are the saved copies, with hidden photo data removed, but anything visible in the picture is still there. Only photos from findings you confirmed can be included. Including a photo does not send it anywhere.',
                    ),
                  ),
                  _status(review),
                  if (review.isLoading)
                    Padding(
                      padding: EdgeInsets.all(16),
                      child: Center(
                        child: CircularProgressIndicator(
                          semanticsLabel: context.tr('Loading saved photos'),
                        ),
                      ),
                    ),
                  if (!review.isLoading &&
                      candidates.isEmpty &&
                      review.catalog != null &&
                      !review.isStale)
                    Padding(
                      padding: EdgeInsets.only(top: 12),
                      child: Text(context.tr('No saved photos yet.')),
                    ),
                  for (final ExportCandidate c in candidates) _candidate(c),
                  SizedBox(height: 16),
                  Semantics(
                    liveRegion: true,
                    child: Text(
                      context.tr('{count} of 6 photos chosen', {
                        'count': selection.length,
                      }),
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  for (final (int i, s) in selection.indexed)
                    _ordered(i, s.evidenceId, selection.length),
                  SizedBox(height: 16),
                  FilledButton(
                    onPressed:
                        review.isStale ||
                            review.catalog == null ||
                            selection.any(
                              (item) =>
                                  _decoded[item.evidenceId] !=
                                  item.expectedEvidenceRevision,
                            )
                        ? null
                        : () => widget.onDone(review.selections),
                    child: Text(
                      selection.isEmpty
                          ? context.tr('Continue without photos')
                          : context.tr('Use these photos'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _status(ExportReview review) {
    final List<String> messages = [
      if (review.errorMessage != null) context.tr(review.errorMessage!),
      if (review.isStale)
        context.tr(
          'Your case changed since these photos were loaded. Reload them.',
        ),
      if (review.lastDropped.isNotEmpty)
        context.tr(
          review.lastDropped.length == 1
              ? '{count} chosen photo was removed from the list because it changed, was deleted, or its finding is no longer confirmed.'
              : '{count} chosen photos were removed from the list because they changed, were deleted, or their finding is no longer confirmed.',
          {'count': review.lastDropped.length},
        ),
      if (_rejection != null) context.tr(_rejection!),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final String m in messages)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Semantics(liveRegion: true, child: Text(m)),
          ),
        if (review.isStale || review.errorCode != null)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: review.isLoading ? null : review.load,
              child: Text(context.tr('Reload photos')),
            ),
          ),
      ],
    );
  }

  Widget _candidate(ExportCandidate c) {
    final ExportReview review = widget.review;
    final Finding? finding = widget
        .savedCase()
        .findings
        .where((f) => f.id == c.findingId)
        .firstOrNull;
    final pixels = review.pixelsFor(c.evidenceId);
    final bool checked = review.draft.isReviewed(c.evidenceId);
    final bool selected = review.draft.selection.any(
      (s) => s.evidenceId == c.evidenceId,
    );
    final observation = finding == null
        ? context.tr('Finding not found')
        : localizedAssessmentObservation(
            context,
            observation: finding.observation,
            room: finding.room,
          );
    return PhotoDecodeGate(
      key: ValueKey(
        'decode-${review.catalog?.caseId}-${c.evidenceId}-${c.evidenceRevision}',
      ),
      bytes: pixels,
      onChanged: (ready) {
        if (!mounted || !identical(widget.review, review)) return;
        setState(() {
          if (ready) {
            _decoded[c.evidenceId] = c.evidenceRevision;
          } else if (_decoded[c.evidenceId] == c.evidenceRevision) {
            _decoded.remove(c.evidenceId);
          }
        });
      },
      builder: (context, ready, failed) => Card(
        key: ValueKey('candidate-${c.evidenceId}'),
        margin: const EdgeInsets.only(top: 12),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(observation),
              if (!c.findingConfirmed)
                Text(
                  context.tr(
                    'This finding is not confirmed, so its photos cannot be included.',
                  ),
                ),
              SizedBox(height: 8),
              if (pixels != null)
                Semantics(
                  container: true,
                  image: true,
                  label: context.tr('Saved photo for: {observation}', {
                    'observation': finding == null ? '' : observation,
                  }),
                  excludeSemantics: true,
                  child: Image.memory(
                    pixels,
                    cacheWidth: 1024,
                    height: 220,
                    fit: BoxFit.contain,
                    errorBuilder: (_, _, _) => SizedBox(
                      height: 60,
                      child: Center(
                        child: Text(context.tr('Preview unavailable')),
                      ),
                    ),
                  ),
                )
              else
                OutlinedButton(
                  onPressed: review.isLoadingPixels(c.evidenceId)
                      ? null
                      : () => review.showPhoto(c.evidenceId),
                  child: Text(
                    review.isLoadingPixels(c.evidenceId)
                        ? context.tr('Loading photo')
                        : context.tr('Show photo'),
                  ),
                ),
              if (failed)
                Text(
                  context.tr(
                    'This photo could not be opened for review. Leave it out and reload it.',
                  ),
                ),
              if (pixels != null && !checked)
                OutlinedButton(
                  onPressed: !ready
                      ? null
                      : () => setState(() {
                          _rejection = null;
                          review.markChecked(c.evidenceId);
                        }),
                  child: Text(context.tr('I checked this photo')),
                ),
              if (checked)
                Padding(
                  padding: EdgeInsets.only(top: 4),
                  child: Text(context.tr('Checked by you')),
                ),
              CheckboxListTile(
                key: ValueKey('include-${c.evidenceId}'),
                contentPadding: EdgeInsets.zero,
                value: selected,
                title: Text(context.tr('Include in the draft')),
                onChanged: !c.findingConfirmed || !checked || !ready
                    ? null
                    : (v) => setState(() {
                        if (v == true) {
                          final SelectionRejection? r = review.include(
                            c.evidenceId,
                          );
                          _rejection = r == null ? null : _rejectionText(r);
                        } else {
                          review.exclude(c.evidenceId);
                          _rejection = null;
                        }
                      }),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _ordered(int index, String evidenceId, int count) {
    final ExportReview review = widget.review;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(context.tr('Photo {number}', {'number': index + 1})),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: context.tr('Move photo {number} earlier', {
              'number': index + 1,
            }),
            onPressed: index == 0 ? null : () => review.move(index, index - 1),
            icon: const Icon(Icons.arrow_upward),
          ),
          IconButton(
            tooltip: context.tr('Move photo {number} later', {
              'number': index + 1,
            }),
            onPressed: index == count - 1
                ? null
                : () => review.move(index, index + 1),
            icon: const Icon(Icons.arrow_downward),
          ),
          IconButton(
            tooltip: context.tr('Remove photo {number} from the draft', {
              'number': index + 1,
            }),
            onPressed: () => review.exclude(evidenceId),
            icon: const Icon(Icons.close),
          ),
        ],
      ),
    );
  }

  static String _rejectionText(SelectionRejection r) => switch (r) {
    SelectionRejection.unknownEvidence =>
      'That photo is no longer saved. Reload photos.',
    SelectionRejection.findingNotConfirmed =>
      'Confirm the finding before including its photos.',
    SelectionRejection.notReviewed => 'Look at the photo first.',
    SelectionRejection.alreadySelected => 'That photo is already included.',
    SelectionRejection.imageLimitReached =>
      'You can include at most 6 photos. Remove one first.',
    SelectionRejection.sizeLimitReached =>
      'These photos are too large together. Remove one first.',
  };
}
