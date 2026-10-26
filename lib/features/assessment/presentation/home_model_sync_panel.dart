import 'package:flutter/material.dart';
import '../../../l10n/app_localizations.dart';
import '../application/home_model_sync.dart';

class HomeModelSyncPanel extends StatelessWidget {
  const HomeModelSyncPanel({
    super.key,
    required this.sync,
    required this.enabled,
    required this.localAvailable,
    required this.run,
    required this.confirm,
  });
  final HomeModelSync sync;
  final bool enabled, localAvailable;
  final Future<void> Function(Future<void> Function()) run;
  final Future<bool> Function(String, String, String) confirm;
  @override
  Widget build(BuildContext context) {
    final account = sync.remote;
    Future<void> action(
      String title,
      String description,
      String label,
      Future<void> Function() work,
    ) => run(() async {
      if (await confirm(
        context.tr(title),
        context.tr(description),
        context.tr(label),
      )) {
        await work();
      }
    });
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              context.tr('Private account model'),
              style: Theme.of(context).textTheme.titleMedium,
            ),
            if (account?.bundle != null)
              Text(
                context.tr('Connected rooms saved: {count}', {
                  'count': '${account!.bundle!.model.rooms.length}',
                }),
              ),
            if (account != null && account.bundle == null)
              Text(context.tr('No model is saved in this account slot.')),
            if (sync.feedback != null)
              Semantics(
                liveRegion: true,
                child: Text(context.tr(sync.feedback!)),
              ),
            if (!sync.hasRecovery && localAvailable && account != null)
              FilledButton.tonal(
                onPressed: enabled
                    ? () => action(
                        sync.accountChanged
                            ? 'Replace the account model?'
                            : 'Save this model to your account?',
                        'Save this connected layout and its source scans privately to your account. This replaces the previous account layout.',
                        sync.accountChanged
                            ? 'Replace account copy'
                            : 'Save model to account',
                        () => sync.upload(replaceAccount: sync.accountChanged),
                      )
                    : null,
                child: Text(
                  context.tr(
                    sync.accountChanged
                        ? 'Replace account copy'
                        : 'Save model to account',
                  ),
                ),
              ),
            if (!sync.hasRecovery && account?.bundle != null)
              OutlinedButton(
                onPressed: enabled
                    ? () => action(
                        'Restore the account model?',
                        'Replace this device layout with the account copy. Separate room scans stay saved; different scans must be reconciled first.',
                        'Restore account model',
                        sync.restore,
                      )
                    : null,
                child: Text(context.tr('Restore account model')),
              ),
            if (sync.pending != null && !sync.corrupt)
              FilledButton.tonal(
                onPressed: enabled ? () => run(sync.retry) : null,
                child: Text(context.tr('Retry pending model upload')),
              ),
            TextButton(
              onPressed: enabled ? () => run(sync.refresh) : null,
              child: Text(context.tr('Check account copy')),
            ),
            if (sync.hasRecovery)
              TextButton(
                onPressed: enabled
                    ? () => action(
                        'Discard model sync recovery?',
                        'An upload may already have been saved to your account. This clears only device sync recovery. Your device model stays saved. Check the account copy afterward.',
                        'Clear sync recovery',
                        sync.discardRecovery,
                      )
                    : null,
                child: Text(context.tr('Clear sync recovery')),
              ),
            if (!sync.hasRecovery && account?.bundle != null)
              TextButton(
                onPressed: enabled
                    ? () => action(
                        'Remove the account model?',
                        'Remove this connected layout from your account. Device copies and separate room scans stay saved.',
                        'Remove account copy',
                        () => sync.upload(removeAccount: true),
                      )
                    : null,
                child: Text(context.tr('Remove account copy')),
              ),
          ],
        ),
      ),
    );
  }
}
