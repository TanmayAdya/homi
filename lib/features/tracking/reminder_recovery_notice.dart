import 'package:flutter/material.dart';
import '../../l10n/app_localizations.dart';

class ReminderRecoveryNotice extends StatelessWidget {
  const ReminderRecoveryNotice({
    super.key,
    required this.enabled,
    required this.onReset,
  });
  final bool enabled;
  final Future<void> Function() onReset;

  @override
  Widget build(BuildContext context) => TextButton(
    onPressed: !enabled
        ? null
        : () async {
            final confirmed = await showDialog<bool>(
              context: context,
              builder: (ctx) => AlertDialog(
                scrollable: true,
                title: Text(ctx.tr('Reset device reminders?')),
                content: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      ctx.tr(
                        'This removes reminder times on this device. Your tasks and target dates stay saved. Enable each reminder again when ready.',
                      ),
                    ),
                    const SizedBox(height: 16),
                    TextButton(
                      onPressed: () => Navigator.pop(ctx, false),
                      child: Text(ctx.tr('Cancel')),
                    ),
                    FilledButton(
                      onPressed: () => Navigator.pop(ctx, true),
                      child: Text(ctx.tr('Reset device reminders')),
                    ),
                  ],
                ),
              ),
            );
            if (confirmed == true && context.mounted) await onReset();
          },
    child: Text(context.tr('Reset device reminders')),
  );
}
