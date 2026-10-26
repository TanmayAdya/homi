import 'dart:async';
import 'package:flutter/material.dart';
import 'package:safe_at_home/l10n/app_localizations.dart';
import '../services/draft_save_tracker.dart';

class DraftExitGuard extends StatefulWidget {
  const DraftExitGuard({
    super.key,
    required this.tracker,
    required this.builder,
    this.beforeExit,
  });
  final DraftSaveTracker tracker;
  final Future<void> Function()? beforeExit;
  final Widget Function(
    BuildContext context,
    VoidCallback requestExit,
    bool exiting,
  )
  builder;

  @override
  State<DraftExitGuard> createState() => _DraftExitGuardState();
}

class _DraftExitGuardState extends State<DraftExitGuard> {
  bool _exiting = false, _allowPop = false, _preparingExit = false;

  Future<void> _leaveRoute(Route<dynamic>? route) async {
    setState(() {
      _allowPop = true;
      _exiting = true;
    });
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    if (route?.isCurrent == true && identical(ModalRoute.of(context), route)) {
      Navigator.of(context).pop();
    } else {
      setState(() {
        _allowPop = false;
        _exiting = false;
      });
    }
  }

  Future<void> _requestExit() async {
    if (_exiting ||
        _preparingExit ||
        !mounted ||
        !Navigator.of(context).canPop()) {
      return;
    }
    final route = ModalRoute.of(context);
    final prepare = widget.beforeExit;
    if (prepare != null) {
      setState(() => _preparingExit = true);
      try {
        await prepare();
      } catch (_) {
        return;
      } finally {
        if (mounted) setState(() => _preparingExit = false);
      }
      if (!mounted || route?.isCurrent != true) return;
    }
    if (!widget.tracker.isCurrent || !widget.tracker.needsSave) {
      await _leaveRoute(route);
      return;
    }
    setState(() => _exiting = true);
    FocusManager.instance.primaryFocus?.unfocus();
    final leave = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _DraftExitDialog(tracker: widget.tracker),
    );
    if (!mounted) return;
    if (leave == true && route?.isCurrent == true) {
      await _leaveRoute(route);
    } else {
      setState(() => _exiting = false);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.tracker,
    builder: (context, _) => PopScope<void>(
      canPop:
          _allowPop ||
          (widget.beforeExit == null &&
              !_exiting &&
              (!_preparingExit &&
                  (!widget.tracker.isCurrent || !widget.tracker.needsSave))),
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_requestExit());
      },
      child: ExcludeFocus(
        excluding: _exiting || _preparingExit,
        child: AbsorbPointer(
          absorbing: _exiting || _preparingExit,
          child: widget.builder(
            context,
            () => unawaited(_requestExit()),
            _exiting || _preparingExit,
          ),
        ),
      ),
    ),
  );
}

class _DraftExitDialog extends StatefulWidget {
  const _DraftExitDialog({required this.tracker});
  final DraftSaveTracker tracker;
  @override
  State<_DraftExitDialog> createState() => _DraftExitDialogState();
}

class _DraftExitDialogState extends State<_DraftExitDialog> {
  bool _waiting = true, _confirmDiscard = false;

  void _finish(bool leave) {
    if (!mounted) return;
    final route = ModalRoute.of(context);
    if (route == null || !route.isActive) return;
    final navigator = Navigator.of(context);
    if (route.isCurrent) {
      navigator.pop(leave);
    } else {
      navigator.removeRoute(route, leave);
    }
  }

  @override
  void initState() {
    super.initState();
    unawaited(_settle());
  }

  Future<void> _settle() async {
    final saved = await widget.tracker.settle();
    if (!mounted) return;
    if (!widget.tracker.isCurrent) {
      _finish(false);
    } else if (saved) {
      _finish(true);
    } else {
      setState(() => _waiting = false);
    }
  }

  Future<void> _retry() async {
    if (_waiting || !widget.tracker.isCurrent) return;
    setState(() => _waiting = true);
    try {
      await widget.tracker.retry();
    } catch (_) {
      // ignore: empty_catches
    }
    if (mounted) await _settle();
  }

  void _discard() {
    if (_waiting || widget.tracker.pending || !widget.tracker.isCurrent) return;
    widget.tracker.discardLatest();
    _finish(true);
  }

  @override
  Widget build(BuildContext context) => PopScope<void>(
    canPop: false,
    child: Dialog(
      insetPadding: const EdgeInsets.all(16),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Semantics(
                header: true,
                child: Text(
                  _waiting
                      ? context.tr('Saving on this device')
                      : _confirmDiscard
                      ? context.tr('Leave this editor?')
                      : context.tr('Changes are not saved on this device'),
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
              ),
              const SizedBox(height: 16),
              Text(
                _waiting
                    ? context.tr(
                        'Wait for the accepted device save, or return to editing. No online save is being started.',
                      )
                    : _confirmDiscard
                    ? context.tr(
                        'Unsaved entries kept only in this editor will be lost. Earlier device-saved entries remain. Changes already applied to the case or saved online are not undone.',
                      )
                    : context.tr(
                        'Your latest entries are still here. Retry their device save before leaving, or keep editing.',
                      ),
              ),
              const SizedBox(height: 20),
              if (_waiting)
                Padding(
                  padding: EdgeInsets.only(bottom: 20),
                  child: LinearProgressIndicator(
                    key: ValueKey('draft-exit-waiting'),
                    semanticsLabel: context.tr('Waiting for the device save'),
                  ),
                ),
              if (_confirmDiscard) ...[
                FilledButton(
                  key: const ValueKey('draft-exit-cancel-discard'),
                  onPressed: () => _finish(false),
                  child: Text(context.tr('Keep these edits')),
                ),
                const SizedBox(height: 8),
                OutlinedButton(
                  key: const ValueKey('draft-exit-confirm-discard'),
                  onPressed: _discard,
                  child: Text(context.tr('Leave without retrying')),
                ),
              ] else ...[
                FilledButton(
                  key: const ValueKey('draft-exit-keep-editing'),
                  onPressed: () => _finish(false),
                  child: Text(context.tr('Keep editing')),
                ),
                if (!_waiting) ...[
                  const SizedBox(height: 8),
                  OutlinedButton(
                    key: const ValueKey('draft-exit-retry'),
                    onPressed: _retry,
                    child: Text(context.tr('Retry saving and leave')),
                  ),
                  const SizedBox(height: 8),
                  TextButton(
                    key: const ValueKey('draft-exit-discard'),
                    onPressed: () => setState(() => _confirmDiscard = true),
                    child: Text(context.tr('Leave without retrying')),
                  ),
                ],
              ],
            ],
          ),
        ),
      ),
    ),
  );
}
