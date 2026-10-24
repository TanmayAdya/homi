import 'package:flutter/material.dart';

import '../application/assessment_sync.dart';

class SaveStatusCard extends StatelessWidget {
  const SaveStatusCard({
    super.key,
    required this.sync,
    this.onSave,
    this.onRecover,
    this.durableLocal = false,
    this.enabled = true,
  });

  final AssessmentSync sync;
  final VoidCallback? onSave, onRecover;
  final bool durableLocal;
  final bool enabled;

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
          SyncPhase.working => ('Saving…', null, null),
          SyncPhase.uncertain => (
            'We could not confirm whether your last change was saved. '
                'Check what is saved before changing anything else.',
            'Check what is saved',
            onRecover ?? sync.recover,
          ),
          SyncPhase.needsReload => (
            'Your case changed somewhere else. Reload it, then review '
                'your findings.',
            'Reload',
            onRecover ?? sync.recover,
          ),
          SyncPhase.signInNeeded => (
            'Your session ended. Sign in again to save. Your findings '
                'are still on this screen.',
            null,
            null,
          ),
          SyncPhase.failed => (
            '${sync.errorMessage ?? 'Saving failed.'} Your findings are '
                'still on this screen.',
            'Try saving again',
            onSave ?? sync.save,
          ),
          SyncPhase.idle when sync.hasUnsavedWork => (
            durableLocal
                ? 'Saved privately on this device. Save online to continue on another device.'
                : 'Not saved yet. These findings and photos are only on this screen and are lost if the app closes.',
            'Save to my case',
            onSave ?? sync.save,
          ),
          SyncPhase.idle => ('Saved to your case.', null, null),
        };
        return Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Semantics(
                  liveRegion: true,
                  child: Text(message, key: const ValueKey('save-status')),
                ),
                if (action != null)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton(
                      onPressed: enabled ? onAction : null,
                      child: Text(action),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}
