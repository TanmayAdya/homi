import 'package:flutter/material.dart';
import '../../../../l10n/app_localizations.dart';
import '../../../../shared/models/evidence.dart';

class HomeSafetyNotesDialog extends StatefulWidget {
  const HomeSafetyNotesDialog({
    super.key,
    required this.initial,
    required this.catalog,
    required this.onSave,
  });
  final Map<String, Object?>? initial;
  final EvidenceCatalog? catalog;
  final Future<void> Function(String? note, List<Map<String, Object?>> evidence)
  onSave;
  @override
  State<HomeSafetyNotesDialog> createState() => _HomeSafetyNotesDialogState();
}

class _HomeSafetyNotesDialogState extends State<HomeSafetyNotesDialog> {
  late final note = TextEditingController(
    text: widget.initial?['note'] as String? ?? '',
  );
  late final selected = <String, int>{
    for (final ref in widget.initial?['evidence'] as List? ?? [])
      (ref as Map)['evidenceId'] as String:
          ref['expectedEvidenceRevision'] as int,
  };
  bool saving = false;
  String? error;
  @override
  void dispose() {
    note.dispose();
    super.dispose();
  }

  Future<void> save() async {
    if (saving) return;
    setState(() {
      saving = true;
      error = null;
    });
    try {
      await widget.onSave(note.text.trim().isEmpty ? null : note.text.trim(), [
        for (final e in selected.entries)
          {'evidenceId': e.key, 'expectedEvidenceRevision': e.value},
      ]);
      if (mounted) Navigator.pop(context);
    } catch (_) {
      if (mounted) {
        setState(
          () => error =
              'The note or photo references could not be saved. Your input is retained; try again.',
        );
      }
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !saving,
    child: AlertDialog(
      scrollable: true,
      title: Text(context.tr('Question notes and photo references')),
      content: SizedBox(
        width: 500,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: note,
              enabled: !saving,
              maxLength: 500,
              decoration: InputDecoration(
                labelText: context.tr('Note (optional)'),
              ),
            ),
            Text(
              context.tr(
                'Photos are optional. Select up to six existing photos. This saves references, not copies or proof of a repair.',
              ),
            ),
            if (widget.catalog == null)
              Text(
                context.tr(
                  'Photos could not be refreshed. Notes still work; saved photo references are retained for review.',
                ),
              ),
            for (final id in {
              ...selected.keys,
              ...?widget.catalog?.evidence.map((e) => e.evidenceId),
            })
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: selected.containsKey(id),
                title: Text(id),
                subtitle:
                    widget.catalog != null &&
                        !widget.catalog!.evidence.any(
                          (e) =>
                              e.evidenceId == id &&
                              e.evidenceRevision == selected[id],
                        ) &&
                        selected.containsKey(id)
                    ? Text(
                        context.tr(
                          'This photo was replaced or removed. Clear it or select the current version.',
                        ),
                      )
                    : null,
                onChanged: saving
                    ? null
                    : (checked) => setState(() {
                        if (checked != true) {
                          selected.remove(id);
                        } else {
                          final photo = widget.catalog?.evidence
                              .where((e) => e.evidenceId == id)
                              .firstOrNull;
                          if (photo != null && selected.length < 6) {
                            selected[id] = photo.evidenceRevision;
                          }
                        }
                      }),
              ),
            if (error != null) Text(context.tr(error!)),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: saving ? null : () => Navigator.pop(context),
          child: Text(context.tr('Cancel')),
        ),
        FilledButton(
          onPressed: saving ? null : save,
          child: Text(context.tr('Save on device')),
        ),
      ],
    ),
  );
}
