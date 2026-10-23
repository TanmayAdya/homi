import 'package:flutter/material.dart';

import '../../../shared/models/contracts.dart';
import '../../../shared/models/evidence.dart';
import '../application/export_review.dart';
import '../domain/export/export_selection_draft.dart';

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

  @override
  void initState() {
    super.initState();
    if (widget.review.catalog == null) widget.review.load();
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
          appBar: AppBar(title: const Text('Photos for the draft')),
          body: SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    'Choose up to 6 photos for the draft. Look at each photo '
                    'first: these are the saved copies, with hidden photo data '
                    'removed, but anything visible in the picture is still '
                    'there. Only photos from findings you confirmed can be '
                    'included. Including a photo does not send it anywhere.',
                  ),
                  _status(review),
                  if (review.isLoading)
                    const Padding(
                      padding: EdgeInsets.all(16),
                      child: Center(
                        child: CircularProgressIndicator(
                          semanticsLabel: 'Loading saved photos',
                        ),
                      ),
                    ),
                  if (!review.isLoading &&
                      candidates.isEmpty &&
                      review.catalog != null &&
                      !review.isStale)
                    const Padding(
                      padding: EdgeInsets.only(top: 12),
                      child: Text('No saved photos yet.'),
                    ),
                  for (final ExportCandidate c in candidates) _candidate(c),
                  const SizedBox(height: 16),
                  Semantics(
                    liveRegion: true,
                    child: Text(
                      '${selection.length} of 6 photos chosen',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  for (final (int i, s) in selection.indexed)
                    _ordered(i, s.evidenceId, selection.length),
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed: review.isStale || review.catalog == null
                        ? null
                        : () => widget.onDone(review.selections),
                    child: Text(
                      selection.isEmpty
                          ? 'Continue without photos'
                          : 'Use these photos',
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
      if (review.errorMessage != null) review.errorMessage!,
      if (review.isStale)
        'Your case changed since these photos were loaded. Reload them.',
      if (review.lastDropped.isNotEmpty)
        '${review.lastDropped.length} chosen '
            '${review.lastDropped.length == 1 ? 'photo was' : 'photos were'} '
            'removed from the list because '
            '${review.lastDropped.length == 1 ? 'it' : 'they'} changed, '
            '${review.lastDropped.length == 1 ? 'was' : 'were'} deleted, or '
            '${review.lastDropped.length == 1 ? 'its' : 'their'} finding is '
            'no longer confirmed.',
      ?_rejection,
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
              child: const Text('Reload photos'),
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
    return Card(
      key: ValueKey('candidate-${c.evidenceId}'),
      margin: const EdgeInsets.only(top: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(finding?.observation ?? 'Finding not found'),
            if (!c.findingConfirmed)
              const Text(
                'This finding is not confirmed, so its photos cannot be '
                'included.',
              ),
            const SizedBox(height: 8),
            if (pixels != null)
              Semantics(
                container: true,
                image: true,
                label: 'Saved photo for: ${finding?.observation ?? ''}',
                excludeSemantics: true,
                child: Image.memory(
                  pixels,
                  height: 220,
                  fit: BoxFit.contain,
                  errorBuilder: (_, _, _) => const SizedBox(
                    height: 60,
                    child: Center(child: Text('Preview unavailable')),
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
                      ? 'Loading photo'
                      : 'Show photo',
                ),
              ),
            if (pixels != null && !checked)
              OutlinedButton(
                onPressed: () => setState(() {
                  _rejection = null;
                  review.markChecked(c.evidenceId);
                }),
                child: const Text('I checked this photo'),
              ),
            if (checked)
              const Padding(
                padding: EdgeInsets.only(top: 4),
                child: Text('Checked by you'),
              ),
            CheckboxListTile(
              key: ValueKey('include-${c.evidenceId}'),
              contentPadding: EdgeInsets.zero,
              value: selected,
              title: const Text('Include in the draft'),
              onChanged: !c.findingConfirmed || !checked
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
    );
  }

  Widget _ordered(int index, String evidenceId, int count) {
    final ExportReview review = widget.review;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text('Photo ${index + 1}'),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: 'Move photo ${index + 1} earlier',
            onPressed: index == 0 ? null : () => review.move(index, index - 1),
            icon: const Icon(Icons.arrow_upward),
          ),
          IconButton(
            tooltip: 'Move photo ${index + 1} later',
            onPressed: index == count - 1
                ? null
                : () => review.move(index, index + 1),
            icon: const Icon(Icons.arrow_downward),
          ),
          IconButton(
            tooltip: 'Remove photo ${index + 1} from the draft',
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
