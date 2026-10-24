import 'package:flutter/material.dart';
import '../../app/live_app.dart';
import '../../shared/models/account_deletion.dart';
import '../../shared/models/contracts.dart';
import '../../shared/presentation/sah_components.dart';
import '../../shared/services/io_matching_transport.dart';
import '../../shared/services/lifecycle_api_client.dart';
import '../../shared/services/local_private_store.dart';
import '../../shared/services/matching_api_client.dart';

class AccountSettingsScreen extends StatefulWidget {
  const AccountSettingsScreen({super.key, required this.services});
  final AppServices services;
  @override
  State<AccountSettingsScreen> createState() => _AccountSettingsScreenState();
}

enum _SettingsAction { device, selectedCase, account }

class _AccountSettingsScreenState extends State<AccountSettingsScreen> {
  bool _busy = true, _caseDeletionPending = false;
  String? _error;
  _SettingsAction _feedbackAction = _SettingsAction.selectedCase;

  void _beginAction(_SettingsAction action) => setState(() {
    _busy = true;
    _error = null;
    _feedbackAction = action;
  });

  Widget _feedback(_SettingsAction action) =>
      _error != null && _feedbackAction == action
      ? SahActionFeedback(
          key: ValueKey('settings-feedback-${action.name}'),
          message: _error!,
        )
      : const SizedBox.shrink();
  bool _selectedIsCurrent(String id, int generation) {
    final c = widget.services.coordinator;
    return mounted &&
        c.isCurrent &&
        c.generation == generation &&
        c.draft?.caseId == id;
  }

  void _guardSelection(String id, int generation) {
    if (!_selectedIsCurrent(id, generation)) {
      throw MatchingApiException.forCode('STALE_RESPONSE');
    }
  }

  CaseSnapshot _selectedCase(String id, int generation) {
    _guardSelection(id, generation);
    return widget.services.coordinator.currentCase();
  }

  @override
  void initState() {
    super.initState();
    _restoreDeletion();
  }

  Future<void> _restoreDeletion() async {
    final c = widget.services.coordinator;
    final id = c.snapshot?.caseId, generation = c.generation;
    if (id == null) {
      _busy = false;
      return;
    }
    try {
      final value = await widget.services.store.readJson('case-delete.$id');
      if (_selectedIsCurrent(id, generation)) {
        setState(() => _caseDeletionPending = value != null);
      }
    } catch (error) {
      if (mounted) setState(() => _error = safeOperationMessage(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _checkCaseDeletion() async {
    final c = widget.services.coordinator;
    final id = c.snapshot?.caseId;
    if (_busy || id == null) return;
    _beginAction(_SettingsAction.selectedCase);
    final generation = c.generation;
    try {
      _guardSelection(id, generation);
      final remote = await widget.services.answers.reloadCase(
        id,
        currentCase: () => _selectedCase(id, generation),
      );
      _guardSelection(id, generation);
      await c.adoptRemoteSnapshot(remote);
      _guardSelection(id, generation);
      await widget.services.store.delete('case-delete.$id');
      if (_selectedIsCurrent(id, generation)) {
        setState(() {
          _caseDeletionPending = false;
          _error =
              'The case still exists. Review it before choosing Delete again.';
        });
      }
    } on MatchingApiException catch (error) {
      if (error.code == 'CASE_NOT_FOUND' &&
          _selectedIsCurrent(id, generation)) {
        await c.clearSelected();
        if (mounted) {
          setState(() {
            _caseDeletionPending = false;
            _error = 'The case is deleted. Its local copies were removed.';
          });
        }
      } else if (mounted) {
        setState(() => _error = safeOperationMessage(error));
      }
    } catch (error) {
      if (mounted) setState(() => _error = safeOperationMessage(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  LifecycleApiClient get _client => widget.services.lifecycle;
  Future<bool> _confirm(String title, String text) async =>
      await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          scrollable: true,
          title: Text(title),
          content: Text(text),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Continue'),
            ),
          ],
        ),
      ) ??
      false;
  Future<void> _signOut() async {
    if (_busy) return;
    final session = widget.services.session;
    final owner = session.userId, epoch = session.epoch;
    if (!await _confirm(
      'Sign out and clear this device?',
      'Local drafts and staged photos will be removed. Save any work you want to keep online first.',
    )) {
      return;
    }
    if (!mounted ||
        !widget.services.coordinator.isCurrent ||
        session.userId != owner ||
        session.epoch != epoch) {
      return;
    }
    _beginAction(_SettingsAction.device);
    try {
      await widget.services.signOut();
    } catch (error) {
      if (mounted) setState(() => _error = safeOperationMessage(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _deleteCase() async {
    final c = widget.services.coordinator;
    if (_busy || c.snapshot == null) return;
    final id = c.snapshot!.caseId, generation = c.generation;
    if (!await _confirm(
      'Delete selected case?',
      'This removes its saved case, photos, answers and generated drafts. Copies already shared outside the app cannot be removed.',
    )) {
      return;
    }
    if (!_selectedIsCurrent(id, generation)) return;
    _beginAction(_SettingsAction.selectedCase);
    try {
      await c.serialize(() async {
        final saved = _selectedCase(id, generation);
        final catalog = await widget.services.exports.listEvidence(
          saved,
          currentCase: () => _selectedCase(id, generation),
          currentCatalog: () => null,
        );
        _guardSelection(id, generation);
        await widget.services.store.writeJson('case-delete.$id', {
          'snapshot': saved.toJson(),
          'catalogRevision': catalog.catalogRevision,
        });
        _guardSelection(id, generation);
        if (mounted) setState(() => _caseDeletionPending = true);
        await _client.deleteCase(
          saved,
          expectedCatalogRevision: catalog.catalogRevision,
          isCurrent: () => _selectedIsCurrent(id, generation),
        );
      });
      _guardSelection(id, generation);
      await c.clearSelected();
      if (mounted) {
        setState(() {
          _caseDeletionPending = false;
          _error = 'Selected case deleted.';
        });
      }
    } catch (error) {
      if (mounted) setState(() => _error = safeOperationMessage(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _removeLocalDraft() async {
    final c = widget.services.coordinator;
    final id = c.draft?.caseId, generation = c.generation;
    if (_busy || id == null) return;
    if (!await _confirm(
      'Remove this local draft?',
      'This removes the selected draft and its staged photos from this device.',
    )) {
      return;
    }
    if (!_selectedIsCurrent(id, generation)) return;
    _beginAction(_SettingsAction.selectedCase);
    try {
      await widget.services.coordinator.clearSelected();
      if (mounted) setState(() => _error = 'Local draft removed.');
    } catch (error) {
      if (mounted) setState(() => _error = safeOperationMessage(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _deleteAccount() async {
    if (_busy) return;
    _beginAction(_SettingsAction.account);
    try {
      final c = widget.services.coordinator;
      final owner = widget.services.session.userId;
      final epoch = widget.services.session.epoch;
      bool current() =>
          mounted &&
          c.isCurrent &&
          widget.services.session.userId == owner &&
          widget.services.session.epoch == epoch;
      final confirmed = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (context) => _ReauthenticateDialog(services: widget.services),
      );
      if (confirmed != true || !current()) {
        return;
      }
      final preview = await _client.prepareAccountDeletion(isCurrent: current);
      if (!current()) return;
      if (!await _confirm(
        'Delete this account?',
        'This removes ${preview.counts.cases} cases and ${preview.counts.evidence} photos. Application data is removed first; account-provider cleanup may complete later. This cannot be undone.',
      )) {
        return;
      }
      if (!current()) return;
      final secrets = DeviceSecretStore();
      await secrets.write(
        'sah.deletion.${widget.services.config.apiOrigin.host}',
        preview.deletionToken,
      );
      if (!current()) return;
      await secrets.write(
        'sah.deletion-owner.${widget.services.config.apiOrigin.host}',
        widget.services.store.accountId,
      );
      if (!current()) return;
      final state = await _client.confirmAccountDeletion(
        preview,
        isCurrent: current,
      );
      if (!current()) return;
      if (state.applicationDataDeleted) {
        await widget.services.signOut();
      } else if (mounted) {
        setState(
          () => _error =
              'Deletion is not complete. Check the stored deletion receipt.',
        );
      }
    } catch (error) {
      if (mounted) setState(() => _error = safeOperationMessage(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Account and privacy')),
    body: SafeArea(
      child: SahContent(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SahPageHeader(
                title: 'Your data, your choices',
                description:
                    'Review what stays on this device and manage your saved work.',
              ),
              const SahNotice(
                title: 'Private team beta',
                message: 'Use fictional resident records.',
                icon: Icons.lock_outline,
              ),
              const SahSectionHeading(title: 'On this device'),
              const Text(
                'Drafts on this device are encrypted. Signing out removes local work. A shared PDF is controlled by the recipient.',
              ),
              const SizedBox(height: 20),
              if (_busy)
                TickerMode(
                  enabled: ModalRoute.of(context)?.isCurrent ?? true,
                  child: const LinearProgressIndicator(
                    semanticsLabel: 'Updating account settings',
                  ),
                ),
              _feedback(_SettingsAction.device),
              OutlinedButton(
                key: const ValueKey('settings-sign-out'),
                onPressed: _busy ? null : _signOut,
                child: const Text(
                  'Sign out and clear local data',
                  textAlign: TextAlign.center,
                ),
              ),
              const SahSectionHeading(
                title: 'Selected case',
                description:
                    'Deleting a case removes its saved photos, answers and generated drafts. Copies already shared outside the app remain with their recipients.',
              ),
              if (widget.services.coordinator.draft == null)
                const Padding(
                  padding: EdgeInsets.only(bottom: 16),
                  child: Text('Open a case from Your cases to manage it here.'),
                ),
              OutlinedButton(
                key: const ValueKey('settings-delete-case'),
                onPressed:
                    _busy ||
                        _caseDeletionPending ||
                        widget.services.coordinator.snapshot == null
                    ? null
                    : _deleteCase,
                child: const Text('Delete selected case'),
              ),
              if (widget.services.coordinator.snapshot == null &&
                  widget.services.coordinator.draft != null)
                OutlinedButton(
                  onPressed:
                      _busy ||
                          widget.services.coordinator.uncertain ||
                          widget.services.coordinator.conflict
                      ? null
                      : _removeLocalDraft,
                  child: const Text('Remove selected local draft'),
                ),
              if (_caseDeletionPending)
                OutlinedButton(
                  key: const ValueKey('settings-check-case-deletion'),
                  onPressed: _busy ? null : _checkCaseDeletion,
                  child: const Text(
                    'Check whether case deletion completed',
                    textAlign: TextAlign.center,
                  ),
                ),
              _feedback(_SettingsAction.selectedCase),
              const SahSectionHeading(
                title: 'Account deletion',
                description:
                    'You will confirm your password and review what will be removed before deleting your account.',
              ),
              TextButton(
                key: const ValueKey('settings-delete-account'),
                onPressed: _busy ? null : _deleteAccount,
                child: const Text(
                  'Delete account and application data',
                  textAlign: TextAlign.center,
                ),
              ),
              _feedback(_SettingsAction.account),
              const SizedBox(height: 8),
              TextButton(
                onPressed: _busy
                    ? null
                    : () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => DeletionReceiptScreen(
                            config: widget.services.config,
                            services: widget.services,
                          ),
                        ),
                      ),
                child: const Text(
                  'Check pending account deletion',
                  textAlign: TextAlign.center,
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _ReauthenticateDialog extends StatefulWidget {
  const _ReauthenticateDialog({required this.services});
  final AppServices services;
  @override
  State<_ReauthenticateDialog> createState() => _ReauthenticateDialogState();
}

class _ReauthenticateDialogState extends State<_ReauthenticateDialog> {
  final _password = TextEditingController();
  bool _busy = false;
  String? _error;
  @override
  void dispose() {
    _password.clear();
    _password.dispose();
    super.dispose();
  }

  Future<void> _confirmPassword() async {
    if (_busy || _password.text.isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.services.session.reauthenticate(_password.text);
      if (!mounted) return;
      _password.clear();
      setState(() => _busy = false);
      Navigator.pop(context, true);
    } catch (_) {
      if (mounted) {
        _password.clear();
        setState(
          () => _error =
              'Password confirmation failed. Check your password and connection. Nothing was deleted.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Semantics(
                namesRoute: true,
                header: true,
                child: Text(
                  'Confirm your password',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
              ),
              const SizedBox(height: 20),
              const Text(
                'Confirm the current account password before reviewing account deletion.',
              ),
              const SizedBox(height: 20),
              TextField(
                controller: _password,
                obscureText: true,
                autocorrect: false,
                enableSuggestions: false,
                enabled: !_busy,
                decoration: const InputDecoration(
                  labelText: 'Current password',
                ),
                onSubmitted: (_) => _confirmPassword(),
              ),
              if (_error != null)
                SahNotice(message: _error!, tone: SahNoticeTone.error),
              const SizedBox(height: 20),
              Wrap(
                alignment: WrapAlignment.end,
                spacing: 12,
                runSpacing: 12,
                children: [
                  TextButton(
                    onPressed: _busy
                        ? null
                        : () => Navigator.pop(context, false),
                    child: const Text('Cancel'),
                  ),
                  FilledButton(
                    onPressed: _busy ? null : _confirmPassword,
                    child: Text(_busy ? 'Confirming…' : 'Confirm password'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class DeletionReceiptScreen extends StatefulWidget {
  const DeletionReceiptScreen({
    super.key,
    required this.config,
    this.services,
    this.transport,
  });
  final LiveAppConfig config;
  final AppServices? services;
  final MatchingTransport? transport;
  @override
  State<DeletionReceiptScreen> createState() => _DeletionReceiptScreenState();
}

class _DeletionReceiptScreenState extends State<DeletionReceiptScreen> {
  bool _busy = false;
  String? _message;
  AccountDeletionState? _state;
  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    if (_busy) return;
    final services = widget.services;
    final initialOwner = services?.session.userId;
    final initialEpoch = services?.session.epoch;
    bool mayClearAccount(String? receiptOwner) =>
        mounted &&
        services != null &&
        initialOwner != null &&
        receiptOwner == initialOwner &&
        services.store.accountId == initialOwner &&
        services.session.userId == initialOwner &&
        services.session.epoch == initialEpoch &&
        services.coordinator.isCurrent;
    setState(() {
      _busy = true;
      _message = null;
      _state = null;
    });
    try {
      final secrets = DeviceSecretStore();
      final token = await secrets.read(
        'sah.deletion.${widget.config.apiOrigin.host}',
      );
      if (!mounted) return;
      if (token == null) {
        if (mounted) {
          setState(
            () => _message =
                'No account deletion receipt is stored on this device.',
          );
        }
        return;
      }
      final receiptOwner = await secrets.read(
        'sah.deletion-owner.${widget.config.apiOrigin.host}',
      );
      if (!mounted) return;
      final client = LifecycleApiClient(
        apiBaseUrl: widget.config.apiOrigin,
        tokenProvider: () async => null,
        transport:
            widget.transport ??
            widget.services?.transport ??
            IoMatchingTransport(),
      );
      final state = await client.readAccountDeletionStatus(
        token,
        isCurrent: () => mounted,
      );
      if (mounted) setState(() => _state = state);
      if (state.applicationDataDeleted && mayClearAccount(receiptOwner)) {
        await services!.signOut();
      }
    } catch (error) {
      if (mounted) setState(() => _message = safeOperationMessage(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Account deletion')),
    body: SafeArea(
      child: SahContent(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            const SahPageHeader(
              title: 'Deletion status',
              description:
                  'Check the saved receipt for this device. Account cleanup can finish after application data is removed.',
            ),
            if (_busy)
              const LinearProgressIndicator(
                semanticsLabel: 'Checking deletion status',
              ),
            if (_message != null) SahNotice(message: _message!),
            if (_state != null)
              SahNotice(
                message: switch (_state!.status) {
                  'complete' =>
                    'Application data and the provider account were deleted.',
                  'auth_pending' =>
                    'Application data is deleted. Provider account cleanup is still pending.',
                  _ =>
                    'Deletion is awaiting confirmation; data has not been deleted.',
                },
                tone: _state!.complete
                    ? SahNoticeTone.success
                    : SahNoticeTone.info,
              ),
            const SizedBox(height: 16),
            OutlinedButton(
              onPressed: _busy ? null : _check,
              child: const Text('Refresh status'),
            ),
          ],
        ),
      ),
    ),
  );
}
