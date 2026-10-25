import 'package:flutter/material.dart';
import 'package:safe_at_home/l10n/app_localizations.dart';

import '../../../shared/presentation/sah_components.dart';
import '../application/assessment_sync.dart';

class SaveStatusCard extends StatelessWidget {
  const SaveStatusCard({
    super.key,
    required this.sync,
    this.onSave,
    this.onRecover,
    this.durableLocal = false,
    this.enabled = true,
    this.undescribedDraftOpen = false,
    this.photoMarksUnsaved = false,
  });

  final AssessmentSync sync;
  final VoidCallback? onSave, onRecover;
  final bool durableLocal;
  final bool enabled;

  final bool undescribedDraftOpen;

  final bool? photoMarksUnsaved;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: sync,
      builder: (context, _) {
        final (
          String message,
          String? action,
          VoidCallback? onAction,
        ) = switch (sync.phase) {
          SyncPhase.working => (context.tr('Saving…'), null, null),
          SyncPhase.uncertain => (
            context.tr(
              'We couldn’t confirm the last save. Check before changing anything.',
            ),
            'Check what is saved',
            onRecover ?? sync.recover,
          ),
          SyncPhase.needsReload => (
            context.tr(
              'Your case changed elsewhere. Reload, then review your findings.',
            ),
            'Reload',
            onRecover ?? sync.recover,
          ),
          SyncPhase.signInNeeded => (
            context.tr('Sign in again to save. Your findings are still here.'),
            null,
            null,
          ),
          SyncPhase.failed => (
            context.tr('{error} Your findings are still here.', {
              'error': context.tr(sync.errorMessage ?? 'Saving failed.'),
            }),
            'Try saving again',
            onSave ?? sync.save,
          ),
          SyncPhase.idle when sync.hasUnsavedWork => (
            durableLocal
                ? context.tr(
                    'Kept privately here. Save to store it in your case online.',
                  )
                : context.tr('Not saved yet. Lost if the app closes.'),
            'Save to my case',
            onSave ?? sync.save,
          ),
          SyncPhase.idle when undescribedDraftOpen => (
            context.tr('{earlier}{current}', {
              'earlier': sync.savedCase.findings.isEmpty
                  ? ''
                  : context.tr('Earlier findings are saved. '),
              'current': context.tr(
                durableLocal
                    ? 'Kept on this device until you save.'
                    : 'Only on this screen until you save.',
              ),
            }),
            null,
            null,
          ),
          SyncPhase.idle when photoMarksUnsaved == true => (
            context.tr(
              'Findings are saved. Changed photo marks are only on this device.',
            ),
            'Save findings and photo marks online',
            onSave ?? sync.save,
          ),
          SyncPhase.idle => (context.tr('Saved to your case.'), null, null),
        };
        final (
          String? title,
          SahNoticeTone tone,
          IconData icon,
        ) = switch (sync.phase) {
          SyncPhase.working => (null, SahNoticeTone.info, Icons.sync_rounded),
          SyncPhase.uncertain || SyncPhase.needsReload => (
            'Save needs checking',
            SahNoticeTone.warning,
            Icons.sync_problem_outlined,
          ),
          SyncPhase.signInNeeded => (
            'Sign in to save',
            SahNoticeTone.warning,
            Icons.lock_clock_outlined,
          ),
          SyncPhase.failed => (
            'Not saved online',
            SahNoticeTone.error,
            Icons.error_outline,
          ),
          SyncPhase.idle when sync.hasUnsavedWork =>
            durableLocal
                ? (
                    'On this device only',
                    SahNoticeTone.info,
                    Icons.phone_iphone_rounded,
                  )
                : (
                    'Only on this screen',
                    SahNoticeTone.warning,
                    Icons.warning_amber_rounded,
                  ),
          SyncPhase.idle when undescribedDraftOpen => (
            'This finding is not saved online yet',
            SahNoticeTone.info,
            Icons.edit_note_rounded,
          ),
          SyncPhase.idle when photoMarksUnsaved == true => (
            'Photo marks not saved online',
            SahNoticeTone.info,
            Icons.edit_note_rounded,
          ),
          SyncPhase.idle when photoMarksUnsaved == null => (
            null,
            SahNoticeTone.info,
            Icons.cloud_done_outlined,
          ),
          SyncPhase.idle => (
            null,
            SahNoticeTone.success,
            Icons.cloud_done_outlined,
          ),
        };
        if (sync.phase == SyncPhase.idle &&
            !sync.hasUnsavedWork &&
            !undescribedDraftOpen &&
            photoMarksUnsaved == false) {
          return Semantics(
            liveRegion: true,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                message,
                key: const ValueKey('save-status'),
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          );
        }
        return SahNotice(
          title: title == null ? null : context.tr(title),
          message: message,
          messageKey: const ValueKey('save-status'),
          tone: tone,
          icon: icon,
          action: action == null
              ? null
              : OutlinedButton.icon(
                  onPressed: enabled ? onAction : null,
                  icon: Icon(
                    sync.phase == SyncPhase.idle
                        ? Icons.cloud_upload_outlined
                        : Icons.refresh_rounded,
                  ),
                  label: Text(context.tr(action), textAlign: TextAlign.center),
                ),
        );
      },
    );
  }
}
