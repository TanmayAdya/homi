import 'package:flutter/material.dart';
import '../../../l10n/app_localizations.dart';
import '../application/bathroom_scan_session.dart';

class ScanModelSyncPanel extends StatelessWidget {
  const ScanModelSyncPanel({
    super.key,
    required this.scan,
    required this.enabled,
    required this.run,
    required this.confirm,
  });
  final BathroomScanSession scan;
  final bool enabled;
  final Future<void> Function(Future<void> Function()) run;
  final Future<bool> Function(String, String, String) confirm;
  @override
  Widget build(BuildContext context) {
    final sync = scan.synchronization!,
        account = sync.remote,
        usable = enabled && !scan.dirty;
    Future<void> confirmAction(
      String title,
      String message,
      String action,
      Future<void> Function() work,
    ) => run(() async {
      if (await confirm(
        context.tr(title),
        context.tr(message),
        context.tr(action),
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
            Semantics(
              header: true,
              child: Text(
                context.tr('Private account model'),
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            Text(
              context.tr(
                'Save a private copy to restore on another phone signed into your account. Each room has its own model.',
              ),
            ),
            if (scan.review.scene case final local?)
              Text(
                context.tr('Device model: {source} - {date}', {
                  'source': local.sourceLabel,
                  'date': local.capturedAt,
                }),
              ),
            if (account?.review?.scene case final scene?)
              Text(
                context.tr('Account model: {source} - {date}', {
                  'source': scene.sourceLabel,
                  'date': scene.capturedAt,
                }),
              ),
            if (account != null && account.review == null)
              Text(context.tr('No model is saved in this account slot.')),
            if (sync.feedback != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(context.tr(sync.feedback!)),
              ),
            TextButton(
              onPressed: usable ? () => run(scan.checkAccountModel) : null,
              child: Text(context.tr('Check account copy')),
            ),
            if (sync.pending != null && !sync.corrupt)
              FilledButton.tonal(
                onPressed: usable ? () => run(scan.retryModelUpload) : null,
                child: Text(context.tr('Retry pending model upload')),
              ),
            if (sync.hasRecovery)
              TextButton(
                onPressed: usable
                    ? () => confirmAction(
                        'Discard model sync recovery?',
                        'An upload may already have been saved to your account. This clears only device sync recovery. Your device model stays saved. Check the account copy afterward.',
                        'Clear sync recovery',
                        scan.discardSyncRecovery,
                      )
                    : null,
                child: Text(context.tr('Clear sync recovery')),
              ),
            if (!sync.hasRecovery &&
                account != null &&
                scan.review.scene != null)
              FilledButton.tonal(
                onPressed: usable
                    ? () => confirmAction(
                        sync.accountChanged
                            ? 'Replace the account model?'
                            : 'Save this model to your account?',
                        'This uploads this room model, labels and review choices to your private account. A previous account model is replaced. Raw camera images are not included.',
                        sync.accountChanged
                            ? 'Replace account copy'
                            : 'Save model to account',
                        () => scan.uploadModel(
                          replaceAccount: sync.accountChanged,
                        ),
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
            if (!sync.hasRecovery && account?.review != null)
              OutlinedButton(
                onPressed: usable
                    ? () => confirmAction(
                        'Restore the account model?',
                        'This replaces this device model and feature reviews for this room. Findings already saved in your plan stay unchanged.',
                        'Restore account model',
                        scan.restoreModel,
                      )
                    : null,
                child: Text(context.tr('Restore account model')),
              ),
            if (!sync.hasRecovery && account?.review != null)
              TextButton(
                onPressed: usable
                    ? () => confirmAction(
                        'Remove the account model?',
                        'The account copy for this room will be removed. This phone and other phones may still retain their device copies. Findings already saved in the plan stay unchanged.',
                        'Remove account copy',
                        () => scan.uploadModel(removeAccount: true),
                      )
                    : null,
                child: Text(context.tr('Remove account copy')),
              ),
            Text(
              context.tr(
                'Shared helpers cannot access these models. Restoring a model does not resume a live camera session or verify its measurements.',
              ),
            ),
          ],
        ),
      ),
    );
  }
}
