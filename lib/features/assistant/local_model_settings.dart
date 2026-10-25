import 'dart:async';
import 'package:flutter/material.dart';
import 'package:homi_local_llm/homi_local_llm.dart';
import '../../l10n/app_localizations.dart';
import '../../shared/models/case_draft.dart';
import '../../shared/presentation/sah_components.dart';

class LocalModelSettings extends StatefulWidget {
  const LocalModelSettings({super.key, this.runtime = const HomiLocalLlm()});
  final HomiLocalLlm runtime;
  @override
  State<LocalModelSettings> createState() => _LocalModelSettingsState();
}

class _LocalModelSettingsState extends State<LocalModelSettings>
    with WidgetsBindingObserver {
  LocalModelStatus? _status;
  String? _request, _message;
  bool _busy = false, _checking = false;
  int _statusEpoch = 0;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_refresh());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && !_busy) unawaited(_refresh());
  }

  Future<void> _refresh() async {
    if (_busy || _checking) return;
    final epoch = ++_statusEpoch;
    setState(() => _checking = true);
    try {
      final status = await widget.runtime.status();
      if (mounted && epoch == _statusEpoch) {
        setState(() {
          _status = status;
          _message = null;
        });
      }
    } catch (_) {
      if (mounted && epoch == _statusEpoch) {
        setState(() {
          _status = null;
          _message = 'On-device chat is not available on this phone.';
        });
      }
    } finally {
      if (mounted && epoch == _statusEpoch) setState(() => _checking = false);
    }
  }

  Future<void> _import() async {
    if (_busy || _checking) return;
    ++_statusEpoch;
    final id = newUuidV4();
    setState(() {
      _busy = true;
      _request = id;
      _message = null;
    });
    try {
      final status = await widget.runtime.importModel(id);
      if (mounted) {
        setState(() {
          _status = status;
          _message = 'Model installed.';
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() => _message = 'The model file could not be imported.');
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _request = null;
        });
      }
    }
  }

  Future<void> _remove() async {
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.tr('Remove local model')),
        content: const Text(localModelId),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(context.tr('Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(context.tr('Remove local model')),
          ),
        ],
      ),
    );
    if (!mounted || accepted != true || _busy) return;
    setState(() => _busy = true);
    try {
      final status = await widget.runtime.deleteModel();
      if (mounted) {
        setState(() {
          _status = status;
          _message = 'Model removed.';
        });
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => _message =
              'The response could not be completed. Check availability and try again.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    ++_statusEpoch;
    final id = _request;
    if (id != null) {
      unawaited(widget.runtime.cancel(id).catchError((Object _) {}));
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      SahSectionHeading(title: context.tr('Local model trial')),
      const Text('$localModelId · 639.4 MB · Apache-2.0'),
      Text(context.tr('Model file stays on this phone.')),
      if (_status?.compiled == false)
        Text(context.tr('On-device chat is not available on this phone.')),
      if (_message != null) SahNotice(message: context.tr(_message!)),
      if (_busy || _checking) ...[
        const LinearProgressIndicator(),
        if (_request != null) Text(context.tr('Importing model…')),
      ],
      Wrap(
        spacing: 8,
        children: [
          TextButton(
            onPressed: _busy || _checking ? null : _refresh,
            child: Text(context.tr('Check again')),
          ),
          OutlinedButton(
            onPressed:
                !_busy &&
                    !_checking &&
                    _status?.compiled == true &&
                    _status?.busy == false
                ? _import
                : null,
            child: Text(context.tr('Import verified model')),
          ),
          if (_status?.installed == true)
            TextButton(
              onPressed: _busy || _checking || _status?.busy != false
                  ? null
                  : _remove,
              child: Text(context.tr('Remove local model')),
            ),
          if (_request != null)
            TextButton(
              onPressed: () => widget.runtime.cancel(_request!),
              child: Text(context.tr('Cancel')),
            ),
        ],
      ),
    ],
  );
}
