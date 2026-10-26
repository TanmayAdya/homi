import 'package:flutter/material.dart';
import 'package:safe_at_home/l10n/app_localizations.dart';

import '../../app/live_app.dart';
import '../../shared/models/plan_name.dart';
import '../../shared/presentation/sah_components.dart';
import '../../shared/services/case_coordinator.dart';
import '../../shared/models/account_plan_name.dart';

Future<String?> showPlanNameDialog({
  required BuildContext context,
  required String defaultName,
  String? initialName,
  bool creating = false,
  Future<void> Function(String? name)? onSave,
  CaseCoordinator? coordinator,
  String? caseId,
}) => showDialog<String>(
  context: context,
  barrierDismissible: false,
  builder: (_) => _PlanNameDialog(
    defaultName: defaultName,
    initialName: initialName,
    creating: creating,
    onSave: onSave,
    coordinator: coordinator,
    caseId: caseId,
  ),
);

class _PlanNameDialog extends StatefulWidget {
  const _PlanNameDialog({
    required this.defaultName,
    required this.initialName,
    required this.creating,
    required this.onSave,
    required this.coordinator,
    required this.caseId,
  });
  final String defaultName;
  final String? initialName;
  final bool creating;
  final Future<void> Function(String? name)? onSave;
  final CaseCoordinator? coordinator;
  final String? caseId;

  @override
  State<_PlanNameDialog> createState() => _PlanNameDialogState();
}

class _PlanNameDialogState extends State<_PlanNameDialog> {
  late final _name = TextEditingController(text: widget.initialName ?? '');
  String? _validation, _error;
  bool _saving = false;
  late final int? _generation;
  @override
  void initState() {
    super.initState();
    _generation = widget.coordinator?.generation;
  }

  bool get _pending =>
      widget.caseId != null &&
      widget.coordinator?.nameSync?.pendingFor(widget.caseId!) == true;
  bool get _conflict =>
      widget.caseId != null &&
      widget.coordinator?.nameSync?.hasConflict(widget.caseId!) == true;

  Future<void> _check({
    bool? keepLocal,
    AccountPlanName? reviewedRemote,
  }) async {
    if (_saving || widget.coordinator == null || widget.caseId == null) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    final c = widget.coordinator!, id = widget.caseId!;
    final generation = _generation;
    try {
      await c.serialize(() async {
        if (!c.isCurrent || c.generation != generation) {
          throw StateError('Reopen the plan’s name editor.');
        }
        if (keepLocal == null) {
          await c.syncPlanName(id);
        } else {
          if (reviewedRemote == null) {
            throw StateError('Review both names first.');
          }
          await c.nameSync!.resolve(
            id,
            keepLocal: keepLocal,
            reviewedRemote: reviewedRemote,
          );
        }
      });
      if (mounted && c.isCurrent && c.generation == generation) {
        _name.text = c.planNameFor(id) ?? '';
      }
    } catch (error) {
      if (mounted) setState(() => _error = safeOperationMessage(error));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving) return;
    final String? value;
    try {
      value = normalizePlanName(_name.text);
    } on FormatException {
      setState(() => _validation = 'Use up to 80 characters on one line.');
      return;
    }
    setState(() {
      _saving = true;
      _validation = null;
      _error = null;
    });
    final route = ModalRoute.of(context);
    try {
      await widget.onSave?.call(value);
      if (_pending) return;
      if (mounted && route != null && route.isActive) {
        final navigator = Navigator.of(context);
        if (route.isCurrent) {
          navigator.pop(value ?? '');
        } else {
          navigator.removeRoute(route, value ?? '');
        }
      }
    } catch (error) {
      if (mounted) setState(() => _error = safeOperationMessage(error));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.coordinator != null) {
      return ListenableBuilder(
        listenable: widget.coordinator!,
        builder: (context, _) => _dialog(context),
      );
    }
    return _dialog(context);
  }

  Widget _dialog(BuildContext context) {
    final reviewedRemote = widget.caseId == null
        ? null
        : widget.coordinator?.nameSync?.remoteFor(widget.caseId!);
    return PopScope(
      canPop: !_saving,
      child: AlertDialog(
        scrollable: true,
        title: Text(
          widget.creating
              ? context.tr('Name your plan')
              : context.tr('Rename plan'),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              key: const ValueKey('plan-name-input'),
              controller: _name,
              enabled: !_saving && !_pending,
              textCapitalization: TextCapitalization.sentences,
              textInputAction: TextInputAction.done,
              decoration: InputDecoration(
                label: Text(context.tr('Plan name (optional)')),
                hintText: context.tr('For example, Mom’s home'),
                error: _validation == null
                    ? null
                    : Text(
                        context.tr(_validation!),
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                helperText: context.tr('Up to 80 characters'),
                helperMaxLines: 2,
              ),
              onSubmitted: (_) => _save(),
            ),
            const SizedBox(height: 12),
            Text(
              context.tr('Leave blank to use “{name}”.', {
                'name': widget.defaultName,
              }),
            ),

            if (widget.caseId != null &&
                widget.coordinator?.planNameStatus(widget.caseId!) != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  context.tr(
                    widget.coordinator!.planNameStatus(widget.caseId!)!,
                  ),
                ),
              ),
            if (_conflict) ...[
              const SizedBox(height: 12),
              Text(
                context.tr('On this device: {name}', {
                  'name':
                      widget.coordinator!.planNameFor(widget.caseId!) ??
                      widget.defaultName,
                }),
              ),
              Text(
                context.tr('In your account: {name}', {
                  'name':
                      widget.coordinator!.nameSync!
                          .remoteFor(widget.caseId!)!
                          .name ??
                      widget.defaultName,
                }),
              ),
              Wrap(
                spacing: 8,
                children: [
                  TextButton(
                    onPressed: _saving
                        ? null
                        : () => _check(
                            keepLocal: false,
                            reviewedRemote: reviewedRemote,
                          ),
                    child: Text(context.tr('Use account name')),
                  ),
                  TextButton(
                    onPressed: _saving
                        ? null
                        : () => _check(
                            keepLocal: true,
                            reviewedRemote: reviewedRemote,
                          ),
                    child: Text(context.tr('Keep this device’s name')),
                  ),
                ],
              ),
            ],
            if (_pending)
              OutlinedButton.icon(
                onPressed: _saving ? null : _check,
                icon: const Icon(Icons.sync),
                label: Text(context.tr('Check name sync')),
              ),
            if (_error != null) SahActionFeedback(message: context.tr(_error!)),
            if (_saving) ...[
              const SizedBox(height: 12),
              LinearProgressIndicator(
                semanticsLabel: context.tr('Saving plan name'),
              ),
            ],
            const SizedBox(height: 20),
            Wrap(
              alignment: WrapAlignment.end,
              spacing: 12,
              runSpacing: 12,
              children: [
                TextButton(
                  onPressed: _saving ? null : () => Navigator.of(context).pop(),
                  child: Text(
                    _pending ? context.tr('Close') : context.tr('Cancel'),
                  ),
                ),
                FilledButton(
                  key: const ValueKey('plan-name-save'),
                  onPressed: _saving || _pending ? null : _save,
                  child: Text(
                    widget.creating
                        ? context.tr('Create plan')
                        : context.tr('Save name'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
