import 'package:flutter/material.dart';
import 'package:safe_at_home/l10n/app_localizations.dart';

import '../../app/live_app.dart';
import '../../shared/presentation/sah_components.dart';
import 'case_display_details.dart';
import 'plan_deletion_action.dart';

Future<bool> showPlanDeletionDialog({
  required BuildContext context,
  required AppServices services,
  required String caseId,
  required String title,
  int? minimumCaseRevision,
}) async =>
    await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _PlanDeletionDialog(
        services: services,
        caseId: caseId,
        title: title,
        minimumCaseRevision: minimumCaseRevision,
      ),
    ) ??
    false;

class _PlanDeletionDialog extends StatefulWidget {
  const _PlanDeletionDialog({
    required this.services,
    required this.caseId,
    required this.title,
    this.minimumCaseRevision,
  });
  final AppServices services;
  final String caseId, title;
  final int? minimumCaseRevision;

  @override
  State<_PlanDeletionDialog> createState() => _PlanDeletionDialogState();
}

class _PlanDeletionDialogState extends State<_PlanDeletionDialog> {
  late final PlanDeletionAction _action;
  bool _busy = true;
  String? _feedback;

  @override
  void initState() {
    super.initState();
    _action = PlanDeletionAction(
      services: widget.services,
      caseId: widget.caseId,
      minimumCaseRevision: widget.minimumCaseRevision,
    );
    _prepare();
  }

  @override
  void dispose() {
    _action.dispose();
    super.dispose();
  }

  Future<void> _run(Future<bool> Function() operation) async {
    setState(() {
      _busy = true;
      _feedback = null;
    });
    try {
      final removed = await operation();
      if (!mounted) return;
      if (removed) {
        Navigator.pop(context, true);
      } else if (_action.ready) {
        setState(() {
          _feedback =
              'The plan still exists. Review the details before deleting it.';
        });
      }
    } catch (error) {
      if (mounted) setState(() => _feedback = safeOperationMessage(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _prepare() async {
    try {
      await _action.prepare();
    } catch (error) {
      if (mounted) setState(() => _feedback = safeOperationMessage(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: Dialog(
      key: const ValueKey('plan-deletion-dialog'),
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Semantics(
                namesRoute: true,
                header: true,
                child: Text(
                  _action.pending
                      ? context.tr('Check plan deletion')
                      : context.tr('Delete this plan?'),
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
              ),
              const SizedBox(height: 16),
              Text(
                widget.title,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 4),
              Text(homePlanReference(widget.caseId, context: context)),
              const SizedBox(height: 16),
              Text(
                _action.pending
                    ? context.tr(
                        'An earlier removal needs checking. Check its status before trying again.',
                      )
                    : _action.localOnly
                    ? context.tr(
                        'This removes this device-only plan and its staged photos. Your other plans stay saved.',
                      )
                    : _action.absentOnline
                    ? context.tr(
                        'This plan is no longer online. Remove its remaining copies from this device? Your other plans stay saved.',
                      )
                    : context.tr(
                        'This permanently removes this plan, its photos, answers and generated drafts from your account and this device. Your other plans stay saved. Copies already shared outside the app remain with their recipients.',
                      ),
              ),
              if (_busy) ...[
                const SizedBox(height: 16),
                LinearProgressIndicator(
                  semanticsLabel: context.tr('Checking this home safety plan'),
                ),
              ],
              if (_feedback != null)
                SahActionFeedback(message: context.tr(_feedback!)),
              const SizedBox(height: 20),
              if (_action.pending)
                FilledButton(
                  onPressed: _busy ? null : () => _run(_action.checkPending),
                  child: Text(
                    context.tr('Check deletion status'),
                    textAlign: TextAlign.center,
                  ),
                )
              else if (_action.ready)
                FilledButton(
                  key: const ValueKey('confirm-delete-home-plan'),
                  style: FilledButton.styleFrom(
                    backgroundColor: Theme.of(context).colorScheme.error,
                    foregroundColor: Theme.of(context).colorScheme.onError,
                  ),
                  onPressed: _busy
                      ? null
                      : () => _run(() async {
                          await _action.deleteConfirmed();
                          return true;
                        }),
                  child: Text(
                    _action.localOnly
                        ? context.tr('Delete local plan')
                        : context.tr('Delete plan'),
                    textAlign: TextAlign.center,
                  ),
                )
              else
                TextButton(
                  onPressed: _busy
                      ? null
                      : () {
                          setState(() {
                            _busy = true;
                            _feedback = null;
                          });
                          _prepare();
                        },
                  child: Text(context.tr('Try again')),
                ),
              TextButton(
                onPressed: _busy ? null : () => Navigator.pop(context, false),
                child: Text(context.tr('Cancel')),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
