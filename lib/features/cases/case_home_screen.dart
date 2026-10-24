import 'dart:async';
import 'package:flutter/material.dart';
import '../../app/live_app.dart';
import '../../shared/models/case_list.dart';
import '../../shared/presentation/sah_components.dart';
import '../settings/account_settings_screen.dart';
import 'case_workspace_screen.dart';

class CaseHomeScreen extends StatefulWidget {
  const CaseHomeScreen({super.key, required this.services});
  final AppServices services;
  @override
  State<CaseHomeScreen> createState() => _CaseHomeScreenState();
}

class _CaseHomeScreenState extends State<CaseHomeScreen> {
  final _cases = <CaseSummary>[];
  List<String> _local = [];
  String? _cursor, _error;
  bool _discovering = false, _opening = false, _loaded = false;
  bool _refreshQueued = false;
  int _request = 0, _localRequest = 0;
  bool get _isCurrent => mounted && widget.services.coordinator.isCurrent;
  bool get _selectionBlocked => widget.services.coordinator.hasUndurableEdits;
  void _caseChanged() {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    widget.services.coordinator.addListener(_caseChanged);
    _load();
  }

  @override
  void dispose() {
    widget.services.coordinator.removeListener(_caseChanged);
    super.dispose();
  }

  Future<void> _refreshLocal() async {
    final request = ++_localRequest;
    try {
      final local = await widget.services.coordinator.localCaseIds();
      if (_isCurrent && request == _localRequest) {
        setState(() => _local = local);
      }
    } catch (_) {
      // ignore: empty_catches
    }
  }

  Future<void> _load({bool more = false}) async {
    if (!_isCurrent) return;
    unawaited(_refreshLocal());
    if (_discovering) {
      _refreshQueued = true;
      return;
    }
    final request = ++_request;
    bool current() => _isCurrent && request == _request && !_refreshQueued;
    setState(() {
      _discovering = true;
      _error = null;
    });
    try {
      final page = await widget.services.discovery.listCases(
        afterCaseId: more ? _cursor : null,
        isCurrent: current,
      );
      if (!current()) return;
      setState(() {
        if (!more) _cases.clear();
        for (final item in page.cases) {
          if (!_cases.any((c) => c.caseId == item.caseId)) _cases.add(item);
        }
        _cursor = page.nextAfterCaseId;
        _loaded = true;
      });
    } catch (error) {
      if (current()) setState(() => _error = safeOperationMessage(error));
    } finally {
      if (_isCurrent && request == _request) {
        final refresh = _refreshQueued;
        _refreshQueued = false;
        setState(() => _discovering = false);
        if (refresh) unawaited(_load());
      }
    }
  }

  Future<void> _open(
    Future<void> Function() action, {
    bool changesSelection = true,
  }) async {
    if (!_isCurrent || _opening || (changesSelection && _selectionBlocked)) {
      return;
    }
    setState(() => _opening = true);
    try {
      await action();
      if (!mounted || !_isCurrent) return;
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => CaseWorkspaceScreen(services: widget.services),
        ),
      );
    } catch (error) {
      if (mounted && _isCurrent) await showOperationError(context, error);
    } finally {
      if (_isCurrent) {
        setState(() => _opening = false);
        unawaited(_load());
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Safe at Home'),
      actions: [
        IconButton(
          tooltip: 'Settings',
          icon: const Icon(Icons.settings_outlined),
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => AccountSettingsScreen(services: widget.services),
            ),
          ),
        ),
      ],
    ),
    body: SafeArea(
      child: SahContent(
        child: RefreshIndicator(
          onRefresh: _load,
          child: ListView(
            padding: const EdgeInsets.all(20),
            physics: const AlwaysScrollableScrollPhysics(),
            children: [
              const SahPageHeader(
                title: 'Your cases',
                description:
                    'Pick up where you left off, or begin a new home assessment.',
              ),
              FilledButton.icon(
                key: const ValueKey('case-start'),
                onPressed: !_isCurrent || _opening || _selectionBlocked
                    ? null
                    : () => _open(widget.services.coordinator.createDraft),
                icon: const Icon(Icons.add),
                label: const Text('Start a case'),
              ),
              if (_selectionBlocked &&
                  widget.services.coordinator.draft != null) ...[
                const SahNotice(
                  title: 'Keep your current work',
                  message:
                      'The current case has a device save that is pending or failed. Return to it before opening another case.',
                  tone: SahNoticeTone.warning,
                ),
                OutlinedButton(
                  key: const ValueKey('continue-undurable-case'),
                  onPressed: !_isCurrent || _opening
                      ? null
                      : () => _open(() async {}, changesSelection: false),
                  child: const Text('Continue current case'),
                ),
              ],
              const SizedBox(height: 12),
              const SahNotice(
                message: 'Private team beta · Fictional information only',
                icon: Icons.lock_outline_rounded,
              ),
              if (_opening)
                const Padding(
                  padding: EdgeInsets.all(20),
                  child: LinearProgressIndicator(
                    semanticsLabel: 'Opening your case',
                  ),
                ),
              if (_error != null) ...[
                SahNotice(
                  message: _error!,
                  title: 'Saved cases are unavailable',
                  tone: SahNoticeTone.warning,
                ),
                TextButton(
                  onPressed: !_isCurrent || _discovering ? null : () => _load(),
                  child: const Text('Retry saved cases'),
                ),
              ],
              if (_local.isNotEmpty) ...[
                const SahSectionHeading(
                  title: 'On this device',
                  description: 'Private local work you can resume here.',
                ),
                for (final id in _local)
                  SahActionTile(
                    key: ValueKey('local-case-$id'),
                    title: 'Case ${shortCaseId(id)}',
                    subtitle:
                        'Local draft · Check saved state before continuing',
                    icon: Icons.phone_iphone_rounded,
                    onTap: !_isCurrent || _opening || _selectionBlocked
                        ? null
                        : () => _open(
                            () => widget.services.coordinator.restoreLocal(id),
                          ),
                  ),
              ],
              const SahSectionHeading(title: 'Saved online'),
              if (_discovering)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 16),
                  child: LinearProgressIndicator(
                    semanticsLabel: 'Checking saved cases online',
                  ),
                ),
              if (_loaded && !_discovering && _error == null && _cases.isEmpty)
                const SahEmptyState(
                  title: 'No saved cases yet.',
                  message:
                      'Start with the details you know. You can add photos and review assistance programs as you go.',
                  icon: Icons.cottage_outlined,
                ),
              for (final item in _cases)
                SahActionTile(
                  key: ValueKey('saved-case-${item.caseId}'),
                  title: 'Case ${shortCaseId(item.caseId)}',
                  subtitle: 'Saved revision ${item.caseRevision}',
                  icon: Icons.cloud_done_outlined,
                  onTap: !_isCurrent || _opening || _selectionBlocked
                      ? null
                      : () => _open(
                          () => widget.services.coordinator.resume(item),
                        ),
                ),
              if (_cursor != null)
                OutlinedButton(
                  onPressed: !_isCurrent || _discovering
                      ? null
                      : () => _load(more: true),
                  child: const Text('Load more cases'),
                ),
            ],
          ),
        ),
      ),
    ),
  );
}

String shortCaseId(String id) => id.length > 8 ? id.substring(0, 8) : id;
