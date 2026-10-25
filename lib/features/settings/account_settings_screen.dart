import '../../shared/presentation/sah_floating_nav.dart';
import '../assistant/assistant_runtime.dart';
import '../assistant/local_model_settings.dart';
import 'package:flutter/material.dart';
import 'package:safe_at_home/l10n/app_localizations.dart';
import '../../app/live_app.dart';
import '../../shared/models/account_deletion.dart';
import '../../shared/models/contracts.dart';
import '../../shared/presentation/sah_components.dart';
import '../../shared/presentation/feature_availability_section.dart';
import '../../shared/services/io_matching_transport.dart';
import '../../shared/services/lifecycle_api_client.dart';
import '../../shared/services/local_private_store.dart';
import '../../shared/services/matching_api_client.dart';
import '../../app/appearance.dart';
import '../../l10n/app_language.dart';
import 'appearance_section.dart';
import 'language_section.dart';

class AccountSettingsScreen extends StatefulWidget {
  const AccountSettingsScreen({
    super.key,
    required this.services,
    this.embedded = false,
  });
  final AppServices services;
  final bool embedded;
  @override
  State<AccountSettingsScreen> createState() => AccountSettingsScreenState();
}

enum _SettingsAction { device, selectedCase, account }

enum _AccountPage { display, privacy, technical }

class AccountSettingsScreenState extends State<AccountSettingsScreen> {
  bool _busy = true, _caseDeletionPending = false;
  bool get canLeave => !_busy;
  String? _error;
  _SettingsAction _feedbackAction = _SettingsAction.selectedCase;

  final _revision = ValueNotifier(0);

  @override
  void setState(VoidCallback fn) {
    super.setState(fn);
    _revision.value++;
  }

  @override
  void dispose() {
    _revision.dispose();
    super.dispose();
  }

  void _beginAction(_SettingsAction action) => setState(() {
    _busy = true;
    _error = null;
    _feedbackAction = action;
  });

  Widget _feedback(_SettingsAction action) =>
      _error != null && _feedbackAction == action
      ? SahActionFeedback(
          key: ValueKey('settings-feedback-${action.name}'),
          message: context.tr(_error!),
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
              'The plan still exists. Review it before choosing Delete again.';
        });
      }
    } on MatchingApiException catch (error) {
      if (error.code == 'CASE_NOT_FOUND' &&
          _selectedIsCurrent(id, generation)) {
        await c.clearSelected();
        if (mounted) {
          setState(() {
            _caseDeletionPending = false;
            _error = 'The plan is deleted. Its local copies were removed.';
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
        builder: (ctx) => Dialog(
          insetPadding: const EdgeInsets.symmetric(
            horizontal: 20,
            vertical: 12,
          ),
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
                      title,
                      style: Theme.of(ctx).textTheme.headlineSmall,
                    ),
                  ),
                  const SizedBox(height: 20),
                  Text(text),
                  const SizedBox(height: 20),
                  Wrap(
                    alignment: WrapAlignment.end,
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      TextButton(
                        onPressed: () => Navigator.pop(ctx, false),
                        child: Text(ctx.tr('Cancel')),
                      ),
                      FilledButton(
                        onPressed: () => Navigator.pop(ctx, true),
                        child: Text(ctx.tr('Continue')),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ) ??
      false;
  Future<void> _signOut() async {
    if (_busy) return;
    final session = widget.services.session;
    final owner = session.userId, epoch = session.epoch;
    if (!await _confirm(
      context.tr('Sign out and clear this device?'),
      context.tr(
        'Names saved to your account will stay available on your other devices. Local drafts and staged photos will be removed. Unsynced names must finish syncing first.',
      ),
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
      await widget.services.coordinator.nameSync?.requireSyncedBeforeSignOut();
      if (!mounted || session.userId != owner || session.epoch != epoch) return;
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
      context.tr('Delete this plan?'),
      context.tr(
        'This removes the saved plan, its photos, answers and generated drafts. Copies already shared outside the app cannot be removed.',
      ),
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
          _error = 'Plan deleted.';
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
      context.tr('Remove this local draft?'),
      context.tr(
        'This removes the selected draft and its staged photos from this device.',
      ),
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
      if (!mounted || !current()) return;
      if (!await _confirm(
        context.tr('Delete this account?'),
        context.tr(
          'This removes {cases} plans and {photos} photos. Application data is removed first; account-provider cleanup may complete later. This cannot be undone.',
          {'cases': preview.counts.cases, 'photos': preview.counts.evidence},
        ),
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
        await widget.services.signOutAfterAccountDeletion();
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

  Widget _progress(BuildContext ctx) => _busy
      ? TickerMode(
          enabled: ModalRoute.of(ctx)?.isCurrent ?? true,
          child: LinearProgressIndicator(
            semanticsLabel: ctx.tr('Updating account settings'),
          ),
        )
      : const SizedBox.shrink();

  String _pageTitle(_AccountPage page) => switch (page) {
    _AccountPage.display => 'Language and display',
    _AccountPage.privacy => 'Privacy and data',
    _AccountPage.technical => 'Technical details',
  };

  void _open(_AccountPage page) {
    FocusManager.instance.primaryFocus?.unfocus();
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (pageContext) => ValueListenableBuilder<int>(
          valueListenable: _revision,
          builder: (pageContext, _, _) => Scaffold(
            appBar: AppBar(title: Text(pageContext.tr(_pageTitle(page)))),
            body: SafeArea(
              child: SahContent(
                child: SingleChildScrollView(
                  key: ValueKey('account-page-${page.name}'),
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: switch (page) {
                      _AccountPage.display => _display(pageContext),
                      _AccountPage.privacy => _privacy(pageContext),
                      _AccountPage.technical => _technical(pageContext),
                    },
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _display(BuildContext ctx) => [
    const SizedBox(height: 12),
    const LanguageSection(),
    const SizedBox(height: 20),
    const AppearanceSection(),
    const SizedBox(height: 16),
    Text(
      ctx.tr('Text size follows your phone’s settings.'),
      style: Theme.of(ctx).textTheme.bodySmall,
    ),
  ];

  List<Widget> _privacy(BuildContext ctx) {
    final c = widget.services.coordinator;
    return [
      SahListGroup(
        title: ctx.tr('What’s stored where'),
        children: [
          ListTile(
            leading: const Icon(Icons.cloud_outlined),
            title: Text(ctx.tr('Stored in your account')),
            subtitle: Text(
              ctx.tr(
                'Plans and the answers, rooms, photos, applications and tasks saved in them',
              ),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.phone_iphone_rounded),
            title: Text(ctx.tr('Only on this phone')),
            subtitle: Text(
              ctx.tr(
                'Assistant chats, reminders and work that hasn’t synced yet',
              ),
            ),
          ),
        ],
      ),
      _progress(ctx),
      SahSectionHeading(title: ctx.tr('On this phone')),
      Text(
        ctx.tr(
          'Signing out removes plans, scans and other work stored on this phone. Plans saved to your account come back when you sign in.',
        ),
      ),
      const SizedBox(height: 12),
      _feedback(_SettingsAction.device),
      OutlinedButton(
        key: const ValueKey('settings-sign-out'),
        onPressed: _busy ? null : _signOut,
        child: Text(
          ctx.tr('Sign out and clear local data'),
          textAlign: TextAlign.center,
        ),
      ),
      SahSectionHeading(title: ctx.tr('This plan')),
      if (c.draft == null)
        Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: Text(ctx.tr('Choose a plan from Plan to manage it here.')),
        ),
      OutlinedButton(
        key: const ValueKey('settings-delete-case'),
        onPressed: _busy || _caseDeletionPending || c.snapshot == null
            ? null
            : _deleteCase,
        child: Text(ctx.tr('Delete this plan')),
      ),
      if (c.snapshot == null && c.draft != null)
        OutlinedButton(
          onPressed: _busy || c.uncertain || c.conflict
              ? null
              : _removeLocalDraft,
          child: Text(ctx.tr('Remove selected local draft')),
        ),
      if (_caseDeletionPending)
        OutlinedButton(
          key: const ValueKey('settings-check-case-deletion'),
          onPressed: _busy ? null : _checkCaseDeletion,
          child: Text(
            ctx.tr('Check whether plan deletion finished'),
            textAlign: TextAlign.center,
          ),
        ),
      _feedback(_SettingsAction.selectedCase),
      SahSectionHeading(title: ctx.tr('Your account')),
      TextButton(
        key: const ValueKey('settings-delete-account'),
        style: TextButton.styleFrom(
          foregroundColor: Theme.of(ctx).colorScheme.error,
        ),
        onPressed: _busy ? null : _deleteAccount,
        child: Text(
          ctx.tr('Delete account and application data'),
          textAlign: TextAlign.center,
        ),
      ),
      _feedback(_SettingsAction.account),
      const SizedBox(height: 8),
      TextButton(
        onPressed: _busy
            ? null
            : () => Navigator.of(ctx).push(
                MaterialPageRoute<void>(
                  builder: (_) => DeletionReceiptScreen(
                    config: widget.services.config,
                    services: widget.services,
                  ),
                ),
              ),
        child: Text(
          ctx.tr('Check pending account deletion'),
          textAlign: TextAlign.center,
        ),
      ),
    ];
  }

  List<Widget> _technical(BuildContext ctx) => [
    Text(
      ctx.tr(
        'For troubleshooting with the project team. Everyday screens don’t use these terms.',
      ),
      style: Theme.of(ctx).textTheme.bodySmall,
    ),
    FeatureAvailabilitySection(services: widget.services),
    if (localAssistantTrial) const LocalModelSettings(),
  ];

  String _appearanceLabel(ThemeMode mode) => switch (mode) {
    ThemeMode.system => 'Match phone setting',
    ThemeMode.light => 'Light',
    ThemeMode.dark => 'Dark',
  };

  @override
  Widget build(BuildContext context) {
    final languages = AppLanguageController.instance;
    final body = SahContent(
      child: SingleChildScrollView(
        padding: sahFloatingContentPadding(context),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _progress(context),
            SahListGroup(
              children: [
                ListenableBuilder(
                  listenable: Listenable.merge([
                    languages,
                    AppAppearance.instance,
                  ]),
                  builder: (context, _) => SahActionTile(
                    key: const ValueKey('account-display'),
                    icon: Icons.translate_rounded,
                    title: context.tr('Language and display'),
                    subtitle: [
                      languages.value == AppLanguage.system
                          ? context.tr(languages.value.nativeName)
                          : languages.value.nativeName,
                      context.tr(
                        _appearanceLabel(AppAppearance.instance.value),
                      ),
                    ].join(' · '),
                    onTap: () => _open(_AccountPage.display),
                  ),
                ),
                SahActionTile(
                  key: const ValueKey('account-privacy'),
                  icon: Icons.lock_outline_rounded,
                  title: context.tr('Privacy and data'),
                  subtitle: context.tr(
                    'Sign out · delete a plan or your account',
                  ),
                  onTap: () => _open(_AccountPage.privacy),
                ),
                SahActionTile(
                  key: const ValueKey('account-technical'),
                  icon: Icons.build_outlined,
                  title: context.tr('Technical details'),
                  subtitle: context.tr('For troubleshooting'),
                  onTap: () => _open(_AccountPage.technical),
                ),
              ],
            ),
            if (_caseDeletionPending)
              SahNotice(
                message: context.tr(
                  'A plan deletion is waiting to be checked. Open Privacy and data to check it.',
                ),
              ),
          ],
        ),
      ),
    );
    if (widget.embedded) return body;
    return Scaffold(
      appBar: AppBar(title: Text(context.tr('Account'))),
      body: SafeArea(child: body),
    );
  }
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
                  context.tr('Confirm your password'),
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
              ),
              const SizedBox(height: 20),
              Text(
                context.tr(
                  'Confirm the current account password before reviewing account deletion.',
                ),
              ),
              const SizedBox(height: 20),
              TextField(
                key: const ValueKey('reauth-password'),
                controller: _password,
                obscureText: true,
                autocorrect: false,
                enableSuggestions: false,
                enabled: !_busy,
                decoration: InputDecoration(
                  label: Text(context.tr('Current password')),
                ),
                onSubmitted: (_) => _confirmPassword(),
              ),
              if (_error != null)
                SahNotice(
                  message: context.tr(_error!),
                  tone: SahNoticeTone.error,
                ),
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
                    child: Text(context.tr('Cancel')),
                  ),
                  FilledButton(
                    onPressed: _busy ? null : _confirmPassword,
                    child: Text(
                      _busy
                          ? context.tr('Confirming…')
                          : context.tr('Confirm password'),
                    ),
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
        await services!.signOutAfterAccountDeletion();
      }
    } catch (error) {
      if (mounted) setState(() => _message = safeOperationMessage(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(context.tr('Account deletion'))),
    body: SafeArea(
      child: SahContent(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            SahPageHeader(
              title: context.tr('Deletion status'),
              description: context.tr(
                'Check the saved receipt for this device. Account cleanup can finish after application data is removed.',
              ),
            ),
            if (_busy)
              LinearProgressIndicator(
                semanticsLabel: context.tr('Checking deletion status'),
              ),
            if (_message != null) SahNotice(message: context.tr(_message!)),
            if (_state != null)
              SahNotice(
                message: switch (_state!.status) {
                  'complete' => context.tr(
                    'Application data and the provider account were deleted.',
                  ),
                  'auth_pending' => context.tr(
                    'Application data is deleted. Provider account cleanup is still pending.',
                  ),
                  _ => context.tr(
                    'Deletion is awaiting confirmation; data has not been deleted.',
                  ),
                },
                tone: _state!.complete
                    ? SahNoticeTone.success
                    : SahNoticeTone.info,
              ),
            const SizedBox(height: 16),
            OutlinedButton(
              onPressed: _busy ? null : _check,
              child: Text(context.tr('Refresh status')),
            ),
          ],
        ),
      ),
    ),
  );
}
