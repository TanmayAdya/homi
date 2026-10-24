import 'package:flutter/material.dart';
import '../../app/live_app.dart';
import '../../shared/models/case_draft.dart';
import '../../shared/presentation/sah_components.dart';
import '../programs/live_programs_screen.dart';
import '../assessment/presentation/live_assessment_screen.dart';
import 'case_home_screen.dart';
import 'profile_editor_screen.dart';

class CaseWorkspaceScreen extends StatelessWidget {
  const CaseWorkspaceScreen({super.key, required this.services});
  final AppServices services;
  Future<void> _run(
    BuildContext context,
    Future<void> Function() action,
  ) async {
    try {
      await action();
    } catch (error) {
      if (context.mounted) await showOperationError(context, error);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: services.coordinator,
    builder: (context, _) {
      final c = services.coordinator;
      final draft = c.draft;
      if (draft == null) {
        return const Scaffold(
          body: SafeArea(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: SahEmptyState(
                title: 'This case is no longer selected.',
                message: 'Return to your cases to open it again.',
                icon: Icons.folder_open_outlined,
              ),
            ),
          ),
        );
      }
      return Scaffold(
        appBar: AppBar(title: Text('Case ${shortCaseId(draft.caseId)}')),
        body: SafeArea(
          child: SahContent(
            child: ListView(
              padding: const EdgeInsets.all(20),
              children: [
                const SahPageHeader(
                  title: 'Build your case',
                  description:
                      'Add the details you know, review your home, and explore possible assistance.',
                ),
                SahNotice(
                  key: const ValueKey('case-save-status'),
                  title: c.localSaveFailed
                      ? 'Not saved on this device'
                      : c.localWritePending
                      ? 'Saving on this device'
                      : c.busy
                      ? 'Case update in progress'
                      : c.conflict
                      ? 'Case versions need review'
                      : c.uncertain
                      ? 'Save confirmation needed'
                      : c.snapshot == null
                      ? 'Local draft'
                      : 'Saved revision ${c.snapshot!.revision}',
                  message: c.localSaveFailed
                      ? 'The latest changes could not be kept on this device. Keep this case open and retry before leaving.'
                      : c.localWritePending
                      ? 'Wait for the private device save to finish before leaving this case.'
                      : c.busy
                      ? 'Wait for confirmation before continuing.'
                      : c.conflict
                      ? 'The saved case and this device differ. Compare the versions before choosing what to keep.'
                      : c.uncertain
                      ? 'A save may already have succeeded. Check saved state before another save.'
                      : c.hasUnsavedChanges
                      ? 'This device has changes not confirmed online.'
                      : 'Your case matches the last saved version.',
                  icon: c.localSaveFailed
                      ? Icons.error_outline
                      : c.localWritePending || c.busy
                      ? Icons.sync_rounded
                      : c.uncertain || c.conflict
                      ? Icons.sync_problem_outlined
                      : c.hasUnsavedChanges
                      ? Icons.edit_note_rounded
                      : Icons.cloud_done_outlined,
                  tone: c.localSaveFailed
                      ? SahNoticeTone.error
                      : c.localWritePending
                      ? SahNoticeTone.info
                      : c.uncertain || c.conflict
                      ? SahNoticeTone.warning
                      : c.busy || c.hasUnsavedChanges
                      ? SahNoticeTone.info
                      : SahNoticeTone.success,
                ),
                if (c.notice != null)
                  SahNotice(message: c.notice!, tone: SahNoticeTone.warning),
                if (c.localSaveFailed)
                  OutlinedButton.icon(
                    key: const ValueKey('case-retry-device-save'),
                    onPressed: c.busy || c.localWritePending
                        ? null
                        : () => _run(context, c.retryDeviceSave),
                    icon: const Icon(Icons.save_outlined),
                    label: const Text('Retry saving on this device'),
                  ),
                if (c.busy)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 12),
                    child: LinearProgressIndicator(
                      semanticsLabel: 'Updating saved case',
                    ),
                  ),
                if (c.conflict) ...[
                  const SahNotice(
                    title: 'Choose which version to continue',
                    message:
                        'Compare saved content with local edits before choosing a version.',
                    tone: SahNoticeTone.warning,
                  ),
                  ExpansionTile(
                    title: const Text('Compare versions'),
                    children: [
                      _CaseVersionSummary(
                        title: 'Saved online',
                        draft: c.snapshot == null
                            ? null
                            : CaseDraft.fromSnapshot(c.snapshot!),
                      ),
                      _CaseVersionSummary(
                        title: 'On this device',
                        draft: draft,
                      ),
                    ],
                  ),
                  OutlinedButton(
                    onPressed: c.busy
                        ? null
                        : () => _run(
                            context,
                            () => c.resolveConflict(keepLocal: false),
                          ),
                    child: const Text('Use the saved version'),
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton(
                    onPressed: c.busy
                        ? null
                        : () => _run(
                            context,
                            () => c.resolveConflict(keepLocal: true),
                          ),
                    child: const Text('Keep my edits for another save'),
                  ),
                  const SizedBox(height: 16),
                ],
                const SizedBox(height: 8),
                FilledButton.icon(
                  key: const ValueKey('case-save-online'),
                  onPressed: c.busy || c.uncertain || c.conflict
                      ? null
                      : () => _run(context, c.save),
                  icon: const Icon(Icons.cloud_upload_outlined),
                  label: const Text('Save online'),
                ),
                const SizedBox(height: 10),
                OutlinedButton(
                  key: const ValueKey('case-check-saved-state'),
                  onPressed: c.busy ? null : () => _run(context, c.reconcile),
                  child: const Text('Check saved state'),
                ),
                const SahSectionHeading(title: 'Your next steps'),
                SahActionTile(
                  key: const ValueKey('case-profile'),
                  title: 'Resident details',
                  subtitle:
                      '${draft.profile.city ?? 'City not provided'} · ${draft.profile.healthPlan ?? 'Health plan not provided'}',
                  icon: Icons.person_outline_rounded,
                  onTap: c.busy
                      ? null
                      : () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) =>
                                ProfileEditorScreen(services: services),
                          ),
                        ),
                ),
                SahActionTile(
                  key: const ValueKey('case-assessment'),
                  title: 'Home assessment',
                  subtitle: c.snapshot == null
                      ? 'Save this case online once to begin photos and measurements.'
                      : '${draft.findings.length} ${draft.findings.length == 1 ? 'finding' : 'findings'} · Bathroom and entrance',
                  icon: Icons.home_outlined,
                  onTap: c.busy
                      ? null
                      : () async {
                          if (c.snapshot == null) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text(
                                  'Save this new case online once before opening its assessment. You can then continue photos and measurements offline.',
                                ),
                              ),
                            );
                            return;
                          }
                          await Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) =>
                                  LiveAssessmentScreen(services: services),
                            ),
                          );
                        },
                ),
                SahActionTile(
                  key: const ValueKey('case-programs'),
                  title: 'Possible assistance and drafts',
                  subtitle:
                      c.snapshot == null ||
                          c.hasUnsavedChanges ||
                          c.uncertain ||
                          c.conflict
                      ? 'Save and confirm the current case to review program checks.'
                      : 'Explained checks and unresolved next steps',
                  icon: Icons.article_outlined,
                  onTap:
                      c.busy ||
                          c.snapshot == null ||
                          c.hasUnsavedChanges ||
                          c.uncertain ||
                          c.conflict
                      ? null
                      : () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) =>
                                LiveProgramsScreen(services: services),
                          ),
                        ),
                ),
                const SizedBox(height: 20),
                Text(
                  'An observation is not a diagnosis or funding decision. Drafts are not submitted applications.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
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

class _CaseVersionSummary extends StatelessWidget {
  const _CaseVersionSummary({required this.title, required this.draft});
  final String title;
  final CaseDraft? draft;
  @override
  Widget build(BuildContext context) {
    final value = draft;
    if (value == null) return Text('$title: no saved case');
    const names = {
      'city': 'City',
      'county': 'County',
      'healthPlan': 'Health plan',
      'tenure': 'Housing',
      'ageYears': 'Age',
      'householdSize': 'Household size',
      'annualIncomeUsd': 'Annual household income (USD)',
      'ownerConsentReported': 'Owner consent reported',
    };
    String display(Object? item) => switch (item) {
      null => 'Not provided',
      true => 'Yes',
      false => 'No',
      'owner' => 'Owner',
      'renter' => 'Renter',
      _ => item.toString(),
    };
    String words(String text) => text
        .replaceAll('_', ' ')
        .replaceAllMapped(
          RegExp(r'([a-z])([A-Z])'),
          (m) => '${m[1]} ${m[2]!.toLowerCase()}',
        );
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            for (final entry in value.profile.toJson().entries)
              Text('${names[entry.key]}: ${display(entry.value)}'),
            const SizedBox(height: 8),
            Text('${value.findings.length} home findings'),
            for (final finding in value.findings)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Text(
                  '${words(finding.room)} · ${words(finding.reviewState)}\n'
                  '${finding.observation}\n'
                  '${finding.evidenceIds.length} photos'
                  '${finding.measurements.isEmpty ? '' : '\n${finding.measurements.map((m) => '${words(m.type)}: ${m.value} mm (${m.method}, ${m.confirmed ? 'confirmed' : 'needs review'})').join('; ')}'}',
                ),
              ),
            if (value.unresolvedFields.isNotEmpty)
              Text(
                'Still to answer: ${value.unresolvedFields.map(words).join(', ')}',
              ),
          ],
        ),
      ),
    );
  }
}
