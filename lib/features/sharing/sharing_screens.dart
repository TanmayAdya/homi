import 'dart:async';
import 'package:flutter/services.dart';
import '../../shared/services/invitation_links.dart';
import '../../shared/models/collaboration.dart';
import '../../shared/models/sensitive_sharing.dart';
import '../../shared/models/evidence.dart';
import '../requests/private_draft_preview.dart';
import '../../shared/models/request_tracking.dart';
import '../../shared/services/matching_api_client.dart';
import 'package:flutter/material.dart' hide SensitiveContent;
import 'package:share_plus/share_plus.dart';
import '../../shared/presentation/sah_components.dart';
import '../../app/live_app.dart';
import '../../l10n/app_localizations.dart';
import '../../shared/models/sharing.dart';
import '../../shared/models/case_draft.dart';
import '../../shared/models/contracts.dart' show Finding;

part 'collaboration_screen.dart';
part 'sensitive_sharing_screen.dart';

abstract class _OnlineState<T extends StatefulWidget> extends State<T>
    with WidgetsBindingObserver {
  AppServices get services;
  late final int _epoch;
  int _request = 0;
  bool busy = false, _foreground = true;
  String? error;
  bool get current =>
      mounted &&
      _foreground &&
      services.coordinator.isCurrent &&
      services.session.epoch == _epoch;
  void clearContent();
  Future<void> reload();
  @override
  void initState() {
    super.initState();
    _epoch = services.session.epoch;
    WidgetsBinding.instance.addObserver(this);
    services.session.addListener(_sessionChanged);
  }

  void _sessionChanged() {
    if (mounted && services.session.epoch != _epoch) {
      _request++;
      setState(() {
        clearContent();
        busy = false;
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (!_foreground) {
      _request++;
      if (mounted) {
        setState(() {
          clearContent();
          busy = false;
        });
      }
    } else if (current) {
      unawaited(reload());
    }
  }

  Future<void> run(Future<void> Function(bool Function()) action) async {
    if (!current || busy) return;
    final request = ++_request;
    bool valid() => current && request == _request;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await action(valid);
    } catch (_) {
      if (valid()) {
        setState(() {
          clearContent();
          error =
              'Sharing could not be confirmed. Refresh access before trying again.';
        });
      }
    } finally {
      if (valid()) setState(() => busy = false);
    }
  }

  Future<SharingResponse> call(
    String route,
    Map<String, Object?> body,
    bool Function() valid,
  ) => services.sharing.request(route, body, isCurrent: valid);
  @override
  void dispose() {
    _request++;
    WidgetsBinding.instance.removeObserver(this);
    services.session.removeListener(_sessionChanged);
    super.dispose();
  }

  List<Widget> status() => [
    if (busy) const LinearProgressIndicator(),
    if (error != null)
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Text(context.tr(error!), semanticsLabel: context.tr(error!)),
      ),
  ];
}

String _day(BuildContext context, String iso) {
  final local = DateTime.parse(iso).toLocal(),
      l = MaterialLocalizations.of(context);
  return local.year == DateTime.now().year
      ? l.formatMediumDate(local)
      : l.formatFullDate(local);
}

String _moment(BuildContext context, String iso) =>
    '${_day(context, iso)} ${MaterialLocalizations.of(context).formatTimeOfDay(TimeOfDay.fromDateTime(DateTime.parse(iso).toLocal()))}';

String _sharedTitle(BuildContext context, CaseMembership grant) =>
    grant.ownerLabel == null
    ? context.tr('Plan shared with you')
    : context.tr('Shared by {name}', {'name': grant.ownerLabel});

String _access(BuildContext context, String role) =>
    context.tr(role == 'helper' ? 'Can view and help' : 'Can view');

Map<String, String> _programNames(
  BuildContext context,
  AppServices services,
  String caseId,
  Iterable<String> ids,
) {
  final known = {
    for (final p in services.progress?.cached[caseId]?.programs ?? const [])
      p.id: p.name,
  };
  var n = 0;
  return {
    for (final id in ids)
      id: known[id] ?? context.tr('Tracked program {number}', {'number': ++n}),
  };
}

class PeopleWithAccessScreen extends StatefulWidget {
  const PeopleWithAccessScreen({super.key, required this.services});
  final AppServices services;
  @override
  State<PeopleWithAccessScreen> createState() => _PeopleState();
}

class _PeopleState extends _OnlineState<PeopleWithAccessScreen> {
  @override
  AppServices get services => widget.services;
  bool get emailInvite => services.config.simpleInvitationsEnabled;
  String get listRoute => emailInvite ? 'list-email-sharing' : 'list-sharing';
  late final String caseId;
  List<OwnerShare> shares = [];
  List<String> programs = [];
  @override
  void initState() {
    super.initState();
    caseId = services.coordinator.snapshot!.caseId;
    unawaited(reload());
  }

  @override
  void clearContent() {
    shares = [];
    programs = [];
  }

  @override
  Future<void> reload() => run((valid) async {
    final response = await call(listRoute, {'caseId': caseId}, valid);
    if (valid()) {
      setState(() {
        shares = response.shares;
        programs = response.availableProgramIds;
      });
    }
  });

  Future<void> _revoke(OwnerShare share) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(ctx.tr('Remove access?')),
        content: Text(
          ctx.tr(
            'Revocation stops future access. It cannot erase information someone has already seen or copied.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(ctx.tr('Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(ctx.tr('Remove access')),
          ),
        ],
      ),
    );
    if (yes != true || !current) return;
    final grant = share.membership;
    await run((valid) async {
      await call('revoke-sharing', {
        'caseId': caseId,
        'invitationId': grant.id,
        'expectedPermissionRevision': grant.revision,
      }, valid);
      final response = await call(listRoute, {'caseId': caseId}, valid);
      if (valid()) setState(() => shares = response.shares);
    });
  }

  Future<void> _invite([OwnerShare? editing]) async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => InviteSomeoneScreen(
          services: services,
          caseId: caseId,
          programIds: programs,
          editing: editing,
        ),
      ),
    );
    if (changed == true && current) await reload();
  }

  Future<void> _open(Widget screen) async {
    await Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => screen));
    if (current) await reload();
  }

  String _name(OwnerShare share) =>
      share.membership.recipientLabel ??
      share.invitedEmail ??
      context.tr(
        share.membership.state == 'pending'
            ? 'Waiting for the invited person'
            : 'Someone you invited',
      );

  String? _eventAt(OwnerShare share, String type) =>
      share.audit.where((e) => e['type'] == type).firstOrNull?['at'] as String?;

  String _actor(OwnerShare share, Object? id) =>
      id == share.membership.recipientId &&
          share.membership.recipientLabel != null
      ? share.membership.recipientLabel!
      : context.tr(
          id == share.membership.grantorId
              ? 'You'
              : id == share.membership.recipientId
              ? 'This person'
              : 'Someone else',
        );

  Widget _person(BuildContext context, OwnerShare share) {
    final m = share.membership;
    final invited = _eventAt(share, 'invited'),
        since = _eventAt(share, 'accepted') ?? invited;
    final lines = [
      _access(context, m.role),
      if (m.state == 'pending')
        context.tr('Invitation expires on {date}', {
          'date': _day(context, m.invitationExpiresAt),
        })
      else if (since != null)
        context.tr('Since {date}', {'date': _day(context, since)}),
      if (m.expiresAt != null)
        context.tr('Access expires on {date}', {
          'date': _day(context, m.expiresAt!),
        }),
    ];
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(_name(share), style: Theme.of(context).textTheme.titleMedium),
          if (m.recipientLabel != null && share.invitedEmail != null)
            Text(share.invitedEmail!),
          Text(lines.join(' · ')),
          if (share.projection?.stale == true)
            Text(
              context.tr(
                'The owner has newer information. This shared copy needs review.',
              ),
            ),
          for (final note in share.notes) Text(note.text),
          Wrap(
            spacing: 8,
            children: [
              TextButton(
                onPressed: busy ? null : () => _invite(share),
                child: Text(context.tr('Change access')),
              ),
              TextButton(
                onPressed: busy ? null : () => _revoke(share),
                style: TextButton.styleFrom(
                  foregroundColor: Theme.of(context).colorScheme.error,
                ),
                child: Text(context.tr('Remove access')),
              ),
            ],
          ),
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: Text(context.tr('More')),
            children: [
              if (services.config.trackingEnabled && m.state == 'active')
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(context.tr('Shared tasks and proposals')),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: busy
                      ? null
                      : () => _open(
                          CollaborationScreen(
                            services: services,
                            membership: m,
                            ownerView: true,
                          ),
                        ),
                ),
              if (services.config.sensitiveSharingEnabled &&
                  m.role == 'helper' &&
                  m.state == 'active')
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(context.tr('Detailed helper access')),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: busy
                      ? null
                      : () => _open(
                          SensitiveSharingScreen(
                            services: services,
                            membership: m,
                            ownerView: true,
                          ),
                        ),
                ),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: Text(
                  context.tr('Recent access events: {count}', {
                    'count': share.audit.length,
                  }),
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
              for (final event in share.audit.reversed)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(context.tr(event['type']! as String)),
                  subtitle: Text(
                    '${_actor(share, event['actorId'])} · ${_moment(context, event['at']! as String)}',
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final live = shares
            .where((s) => {'active', 'pending'}.contains(s.membership.state))
            .toList(),
        past = shares.where((s) => !live.contains(s)).toList();
    return Scaffold(
      appBar: AppBar(
        title: Text(context.tr('People with access')),
        actions: [
          IconButton(
            onPressed: busy ? null : reload,
            tooltip: context.tr('Refresh access'),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            ...status(),
            SahNotice(
              message: context.tr(
                'Obtain the resident’s permission before sharing. Account access does not establish professional consent or legal authority.',
              ),
            ),
            if (live.isEmpty && !busy)
              SahEmptyState(
                icon: Icons.lock_outline,
                title: context.tr('Only you can see this plan.'),
                message: context.tr(
                  'Invite someone to view it or help. You choose exactly what they can see.',
                ),
              )
            else if (live.isNotEmpty)
              SahListGroup(
                title: context.tr('People'),
                children: [for (final s in live) _person(context, s)],
              ),
            const SizedBox(height: 8),
            FilledButton.icon(
              key: const ValueKey('invite-someone'),
              onPressed: busy ? null : () => _invite(),
              icon: const Icon(Icons.person_add_alt_1_outlined),
              label: Text(context.tr('Invite someone')),
            ),
            const SizedBox(height: 8),
            Text(
              context.tr(
                'Invitations last 7 days and work once. You send the link yourself.',
              ),
              style: Theme.of(context).textTheme.bodySmall,
            ),
            if (past.isNotEmpty)
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: Text(
                  context.tr('Past access ({count})', {'count': past.length}),
                ),
                children: [
                  for (final s in past)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(_name(s)),
                      subtitle: Text(
                        '${_access(context, s.membership.role)} · ${context.tr(s.membership.state)}',
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

class InviteSomeoneScreen extends StatefulWidget {
  const InviteSomeoneScreen({
    super.key,
    required this.services,
    required this.caseId,
    required this.programIds,
    this.editing,
  });
  final AppServices services;
  final String caseId;
  final List<String> programIds;
  final OwnerShare? editing;
  @override
  State<InviteSomeoneScreen> createState() => _InviteState();
}

class _InviteState extends _OnlineState<InviteSomeoneScreen> {
  @override
  AppServices get services => widget.services;
  String get caseId => widget.caseId;
  CaseMembership? get editing => widget.editing?.membership;
  bool get emailInvite => services.config.simpleInvitationsEnabled;
  bool get labels => services.config.sharingLabelsEnabled;
  final recipient = TextEditingController(),
      recipientLabel = TextEditingController(),
      ownerLabel = TextEditingController();
  final findings = <String>{}, selectedPrograms = <String>{};
  bool helper = false, notes = false, _expiryChanged = false;
  int? days = 30;
  late int step = editing == null ? 0 : 1;
  String? code;
  SharedCaseProjection? preview;
  Map<String, Object?>? _reviewed;
  static const maxFindings = 32, maxPrograms = 4;
  bool get validRecipient =>
      (emailInvite
          ? normalizeInvitationEmail(recipient.text) != null
          : recipient.text.trim().isNotEmpty) &&
      _labelText(recipientLabel) != false &&
      _labelText(ownerLabel) != false;

  Object? _labelText(TextEditingController field) {
    final text = field.text.trim();
    return !labels || text.isEmpty
        ? null
        : validSharingLabel(text)
        ? text
        : false;
  }

  @override
  void initState() {
    super.initState();
    final grant = editing;
    if (grant != null) {
      helper = grant.role == 'helper';
      notes = grant.scope.allowHelperNotes;
      findings.addAll(grant.scope.findingIds);
      selectedPrograms.addAll(grant.scope.programIds);
      days = grant.expiresAt == null
          ? null
          : DateTime.parse(
              grant.expiresAt!,
            ).difference(DateTime.now().toUtc()).inDays.clamp(1, 90);
    }
  }

  @override
  void dispose() {
    recipient.dispose();
    recipientLabel.dispose();
    ownerLabel.dispose();
    super.dispose();
  }

  @override
  void clearContent() {
    code = null;
    preview = null;
    _reviewed = null;
    if (step > 1) step = 1;
  }

  @override
  Future<void> reload() async {}

  ShareScope get scope => ShareScope(
    findingIds: findings.toList(),
    programIds: selectedPrograms.toList(),
    allowHelperNotes: helper && notes,
  );
  void _changed() {
    preview = null;
    _reviewed = null;
    code = null;
  }

  Future<void> _preview() => run((valid) async {
    final snapshot = services.coordinator.snapshot;
    if (snapshot == null ||
        snapshot.caseId != caseId ||
        services.coordinator.hasUnsavedChanges) {
      throw StateError('Save first');
    }
    final fields = <String, Object?>{
      'caseId': caseId,
      'expectedCaseRevision': snapshot.revision,
      'scope': scope.toJson(),
    };
    final response = await call('preview-sharing', fields, valid);
    if (valid()) {
      setState(() {
        preview = response.projection;
        _reviewed = {
          ...fields,
          'role': helper ? 'helper' : 'viewer',
          'expiresAt': editing != null && !_expiryChanged
              ? editing!.expiresAt
              : days == null
              ? null
              : DateTime.fromMillisecondsSinceEpoch(
                  DateTime.now().millisecondsSinceEpoch +
                      Duration(days: days!).inMilliseconds,
                  isUtc: true,
                ).toIso8601String(),
        };
        step = 2;
      });
    }
  });

  Future<void> _save() => run((valid) async {
    final reviewed = _reviewed;
    if (reviewed == null) throw StateError('Review first');
    final edit = editing;
    final fields = {
      ...reviewed,
      'invitationId': edit?.id ?? newUuidV4(),
      if (edit == null && !emailInvite) 'recipientId': recipient.text.trim(),
      if (edit == null && emailInvite)
        'recipientEmail': normalizeInvitationEmail(recipient.text),
      if (edit == null && _labelText(recipientLabel) is String)
        'recipientLabel': _labelText(recipientLabel),
      if (edit == null && _labelText(ownerLabel) is String)
        'ownerLabel': _labelText(ownerLabel),
      if (edit != null) 'expectedPermissionRevision': edit.revision,
    };
    final response = await call(
      edit == null
          ? emailInvite
                ? 'create-email-invitation'
                : 'create-invitation'
          : 'change-sharing',
      fields,
      valid,
    );
    if (!valid() || !mounted) return;
    if (edit != null) {
      Navigator.of(context).pop(true);
      return;
    }
    setState(() {
      code = response.invitationCode;
      preview = null;
      _reviewed = null;
      step = 3;
    });
  });

  String get _shareText => emailInvite
      ? invitationLink(services.config.apiOrigin, code!).toString()
      : code!;

  Future<void> _share(BuildContext origin) async {
    final box = origin.findRenderObject() as RenderBox?;
    try {
      await SharePlus.instance.share(
        ShareParams(
          text: _shareText,
          sharePositionOrigin: box == null
              ? null
              : box.localToGlobal(Offset.zero) & box.size,
        ),
      );
    } catch (_) {
      if (mounted) {
        setState(
          () => error =
              'The share sheet could not open. Copy the invitation instead.',
        );
      }
    }
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: _shareText));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            context.tr(
              emailInvite
                  ? 'Invitation link copied.'
                  : 'Invitation code copied.',
            ),
          ),
        ),
      );
    }
  }

  Widget _stepLabel(BuildContext context, int number, String title) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Text(
      context.tr('Step {number} of 3 · {title}', {
        'number': number,
        'title': context.tr(title),
      }),
      style: Theme.of(context).textTheme.labelLarge,
    ),
  );

  List<Widget> _who(BuildContext context) => [
    _stepLabel(context, 1, 'Who'),
    TextField(
      controller: recipient,
      enabled: !busy,
      autofocus: true,
      keyboardType: emailInvite
          ? TextInputType.emailAddress
          : TextInputType.text,
      autocorrect: false,
      enableSuggestions: false,
      decoration: InputDecoration(
        labelText: context.tr(
          emailInvite ? 'Recipient’s sign-in email' : 'Recipient account ID',
        ),
        helperText: context.tr(
          emailInvite
              ? 'Use the email they sign in with. Nothing is sent automatically.'
              : 'Ask the recipient for the account ID shown in Shared with me.',
        ),
        helperMaxLines: 6,
      ),
      onChanged: (_) => setState(_changed),
    ),
    if (labels)
      for (final (field, label, help) in [
        (
          recipientLabel,
          'Who is this for? (optional)',
          'Only you see this name.',
        ),
        (
          ownerLabel,
          'Your name, as they will see it (optional)',
          'Shown to the person you invite.',
        ),
      ])
        TextField(
          controller: field,
          enabled: !busy,
          maxLength: 80,
          decoration: InputDecoration(
            labelText: context.tr(label),
            helperText: context.tr(help),
            helperMaxLines: 3,
            errorText: _labelText(field) == false
                ? context.tr('Use plain text up to 80 characters.')
                : null,
          ),
          onChanged: (_) => setState(_changed),
        ),
    const SizedBox(height: 16),
    FilledButton(
      onPressed: busy || !validRecipient
          ? null
          : () => setState(() => step = 1),
      child: Text(context.tr('Next')),
    ),
  ];

  List<Widget> _what(BuildContext context, List<Finding> available) {
    final names = _programNames(context, services, caseId, widget.programIds);
    return [
      _stepLabel(context, 2, 'What they can do'),
      RadioGroup<bool>(
        groupValue: helper,
        onChanged: (value) {
          if (busy || value == null) return;
          setState(() {
            helper = value;
            if (!helper) notes = false;
            _changed();
          });
        },
        child: Column(
          children: [
            RadioListTile<bool>(
              value: false,
              title: Text(context.tr('Can view')),
              subtitle: Text(context.tr('Sees only what you choose below.')),
            ),
            RadioListTile<bool>(
              value: true,
              title: Text(context.tr('Can view and help')),
              subtitle: Text(
                context.tr(
                  'Can also work on tasks you share and suggest status updates.',
                ),
              ),
            ),
          ],
        ),
      ),
      if (helper)
        CheckboxListTile(
          value: notes,
          onChanged: busy
              ? null
              : (v) => setState(() {
                  notes = v!;
                  _changed();
                }),
          title: Text(context.tr('Allow progress notes')),
        ),
      SahSectionHeading(
        title: context.tr('What they can see'),
        description: context.tr(
          'Choose exactly what this person can see. New findings and programs are not added automatically.',
        ),
      ),
      for (final finding in available)
        CheckboxListTile(
          value: findings.contains(finding.id),
          title: Text(finding.observation),
          onChanged:
              busy ||
                  (!findings.contains(finding.id) &&
                      findings.length >= maxFindings)
              ? null
              : (v) => setState(() {
                  v! ? findings.add(finding.id) : findings.remove(finding.id);
                  _changed();
                }),
        ),
      for (final id in widget.programIds)
        CheckboxListTile(
          value: selectedPrograms.contains(id),
          title: Text(names[id]!),
          subtitle: Text(context.tr('Reported program progress')),
          onChanged:
              busy ||
                  (!selectedPrograms.contains(id) &&
                      selectedPrograms.length >= maxPrograms)
              ? null
              : (v) => setState(() {
                  v! ? selectedPrograms.add(id) : selectedPrograms.remove(id);
                  _changed();
                }),
        ),
      if (widget.programIds.length > maxPrograms)
        Text(
          context.tr('You can share up to {count} programs.', {
            'count': maxPrograms,
          }),
        ),
      const SizedBox(height: 8),
      Text(
        context.tr(
          'Photos, PDFs, income, health answers, and downloads are not shared.',
        ),
      ),
      if (services.config.sensitiveSharingEnabled && helper)
        Text(
          context.tr(
            'After they accept, you can choose private details to share separately under Detailed helper access.',
          ),
        ),
      const SizedBox(height: 24),
      DropdownButtonFormField<int>(
        isExpanded: true,
        itemHeight: null,
        key: ValueKey('sharing-expiry-$days'),
        initialValue: days ?? 0,
        decoration: InputDecoration(labelText: context.tr('Access expires')),
        items: [
          for (final d in {0, 7, 30, 90, ?days})
            DropdownMenuItem(
              value: d,
              child: Text(
                d == 0
                    ? context.tr('No access expiry')
                    : context.tr('After {days} days', {'days': d}),
              ),
            ),
        ],
        onChanged: busy
            ? null
            : (v) => setState(() {
                _expiryChanged = true;
                days = v == 0 ? null : v;
                _changed();
              }),
      ),
      const SizedBox(height: 16),
      FilledButton(
        onPressed: busy ? null : _preview,
        child: Text(context.tr('Next')),
      ),
      if (editing == null)
        TextButton(
          onPressed: busy ? null : () => setState(() => step = 0),
          child: Text(context.tr('Back')),
        ),
    ];
  }

  List<Widget> _review(BuildContext context) => [
    _stepLabel(context, 3, 'Review'),
    if (editing == null)
      Text(
        _labelText(recipientLabel) as String? ??
            (emailInvite
                ? recipient.text.trim()
                : context.tr('Someone you invited')),
        style: Theme.of(context).textTheme.titleMedium,
      ),
    Text(_access(context, helper ? 'helper' : 'viewer')),
    if (helper && notes) Text(context.tr('Progress notes allowed')),
    ProjectionContent(
      projection: preview!,
      programNames: _programNames(context, services, caseId, widget.programIds),
    ),
    const SizedBox(height: 12),
    if (editing == null)
      Text(context.tr('The invitation expires in 7 days and works once.')),
    const SizedBox(height: 12),
    FilledButton(
      onPressed: busy || (editing == null && !validRecipient) ? null : _save,
      child: Text(
        context.tr(editing == null ? 'Create invitation' : 'Save permissions'),
      ),
    ),
    TextButton(
      onPressed: busy
          ? null
          : () => setState(() {
              _changed();
              step = 1;
            }),
      child: Text(context.tr('Back')),
    ),
  ];

  List<Widget> _done(BuildContext context) => [
    SahNotice(
      tone: SahNoticeTone.success,
      title: context.tr('Invitation created'),
      message: context.tr(
        emailInvite
            ? 'Send this link only to the person you invited. They must sign in with that verified email. The invitation expires within seven days and can be used once.'
            : 'Share this code manually. Creating it has not sent a message. It expires within seven days and can be used once by the selected account.',
      ),
    ),
    const SizedBox(height: 12),
    if (emailInvite)
      SelectableText(
        invitationLink(services.config.apiOrigin, code!).toString(),
        key: const ValueKey('invitation-link'),
      ),
    Text(
      context.tr('Invitation code'),
      style: Theme.of(context).textTheme.labelLarge,
    ),
    SelectableText(code!, key: const ValueKey('invitation-code')),
    const SizedBox(height: 16),
    Builder(
      builder: (origin) => FilledButton.icon(
        key: const ValueKey('invitation-share'),
        onPressed: () => _share(origin),
        icon: const Icon(Icons.ios_share),
        label: Text(context.tr('Send this yourself')),
      ),
    ),
    OutlinedButton.icon(
      onPressed: _copy,
      icon: const Icon(Icons.copy),
      label: Text(
        context.tr(
          emailInvite ? 'Copy invitation link' : 'Copy invitation code',
        ),
      ),
    ),
    const SizedBox(height: 8),
    TextButton(
      onPressed: () => Navigator.of(context).pop(true),
      child: Text(context.tr('Done')),
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final snapshot = services.coordinator.snapshot;
    final available = snapshot?.caseId == caseId
        ? snapshot!.findings
        : <Finding>[];
    return PopScope(
      canPop: step != 3,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) Navigator.of(context).pop(true);
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(
            context.tr(editing == null ? 'Invite someone' : 'Change access'),
          ),
        ),
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              ...status(),
              ...switch (step) {
                0 => _who(context),
                1 => _what(context, available),
                2 when preview != null => _review(context),
                3 when code != null => _done(context),
                _ => _what(context, available),
              },
            ],
          ),
        ),
      ),
    );
  }
}

class SharedWithMeScreen extends StatefulWidget {
  const SharedWithMeScreen({
    super.key,
    required this.services,
    this.initialInvitationCode,
  });
  final AppServices services;
  final String? initialInvitationCode;
  @override
  State<SharedWithMeScreen> createState() => _SharedListState();
}

class _SharedListState extends _OnlineState<SharedWithMeScreen> {
  @override
  AppServices get services => widget.services;
  final code = TextEditingController();
  List<CaseMembership> memberships = [];
  CaseMembership? invitation;
  @override
  void initState() {
    super.initState();
    code.text = widget.initialInvitationCode ?? '';
    unawaited(reload());
  }

  @override
  void dispose() {
    code.dispose();
    super.dispose();
  }

  @override
  void clearContent() {
    memberships = [];
    invitation = null;
    code.clear();
  }

  @override
  Future<void> reload() => run((valid) async {
    final response = await call('list-shared-cases', {}, valid);
    if (valid()) {
      setState(() {
        memberships = response.memberships;
        invitation = null;
      });
    }
  });
  Future<void> _review() => run((valid) async {
    final parsed = readInvitationCode(code.text, services.config.apiOrigin);
    if (parsed == null) {
      setState(() => error = 'Paste a valid invitation code or link.');
      return;
    }
    code.text = parsed;
    final result = await call('review-invitation', {
      'code': code.text.trim(),
    }, valid);
    if (valid()) setState(() => invitation = result.membership);
  });
  Future<void> _accept() => run((valid) async {
    await call('accept-invitation', {
      'code': code.text.trim(),
      'expectedPermissionRevision': invitation!.revision,
    }, valid);
    final listed = await call('list-shared-cases', {}, valid);
    if (valid()) {
      setState(() {
        memberships = listed.memberships;
        invitation = null;
        code.clear();
      });
    }
  });
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(context.tr('Shared with me')),
      actions: [
        IconButton(
          onPressed: busy ? null : reload,
          tooltip: context.tr('Refresh access'),
          icon: const Icon(Icons.refresh),
        ),
      ],
    ),
    body: SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          ...status(),
          if (!services.config.simpleInvitationsEnabled) ...[
            Text(context.tr('Your account ID')),
            SelectableText(services.store.accountId),
          ],
          if (services.config.simpleInvitationsEnabled)
            Text(
              context.tr(
                'Sign in with the verified email the owner invited. Opening a link does not accept it.',
              ),
            ),
          TextField(
            controller: code,
            enabled: !busy,
            autocorrect: false,
            enableSuggestions: false,
            decoration: InputDecoration(
              labelText: context.tr(
                services.config.simpleInvitationsEnabled
                    ? 'Invitation code or link'
                    : 'Invitation code',
              ),
            ),
            onChanged: (_) => setState(() => invitation = null),
          ),
          OutlinedButton(
            onPressed: busy ? null : _review,
            child: Text(context.tr('Review invitation')),
          ),
          if (invitation != null) ...[
            if (invitation!.ownerLabel != null)
              Text(
                context.tr('Invitation from {name}', {
                  'name': invitation!.ownerLabel,
                }),
                style: Theme.of(context).textTheme.titleMedium,
              ),
            AccessDetails(membership: invitation!),
            Text(_access(context, invitation!.role)),
            Text(
              context.tr('Selected findings: {count}', {
                'count': invitation!.scope.findingIds.length,
              }),
            ),
            Text(
              context.tr('Selected programs: {count}', {
                'count': invitation!.scope.programIds.length,
              }),
            ),
            Text(
              context.tr(
                invitation!.scope.allowHelperNotes
                    ? 'Progress notes allowed'
                    : 'Read only',
              ),
            ),
            FilledButton(
              onPressed: busy ? null : _accept,
              child: Text(context.tr('Accept invitation')),
            ),
          ],
          if (memberships.isEmpty && !busy)
            Text(context.tr('No active shared plans.')),
          if (memberships.isNotEmpty)
            SahSectionHeading(title: context.tr('Plans shared with you')),
          for (final grant in memberships)
            ListTile(
              title: Text(_sharedTitle(context, grant)),
              subtitle: Text(
                [
                  _access(context, grant.role),
                  if (grant.expiresAt != null)
                    context.tr('Access expires on {date}', {
                      'date': _day(context, grant.expiresAt!),
                    }),
                ].join(' · '),
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: busy
                  ? null
                  : () async {
                      setState(clearContent);
                      await Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => SharedCaseScreen(
                            services: services,
                            membership: grant,
                          ),
                        ),
                      );
                      if (current) await reload();
                    },
            ),
        ],
      ),
    ),
  );
}

class SharedCaseScreen extends StatefulWidget {
  const SharedCaseScreen({
    super.key,
    required this.services,
    required this.membership,
  });
  final AppServices services;
  final CaseMembership membership;
  @override
  State<SharedCaseScreen> createState() => _SharedCaseState();
}

class _SharedCaseState extends _OnlineState<SharedCaseScreen> {
  @override
  AppServices get services => widget.services;
  SharingResponse? view;
  late CaseMembership _grant;
  final note = TextEditingController();
  String? _mutation;
  Timer? _timer;
  @override
  void initState() {
    super.initState();
    _grant = widget.membership;
    unawaited(reload());
    _timer = Timer.periodic(const Duration(seconds: 20), (_) {
      if (current) unawaited(reload());
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    note.dispose();
    super.dispose();
  }

  @override
  void clearContent() {
    view = null;
    note.clear();
    _mutation = null;
  }

  Map<String, Object?> get binding => {
    'membershipId': _grant.id,
    'expectedPermissionRevision': _grant.revision,
  };
  @override
  Future<void> reload() => run((valid) async {
    setState(() => view = null);
    final list = await call('list-shared-cases', {}, valid);
    if (!valid()) return;
    _grant = list.memberships.firstWhere((m) => m.id == widget.membership.id);
    final response = await call('read-shared-case', binding, valid);
    if (valid()) setState(() => view = response);
  });
  Future<void> _add() => run((valid) async {
    _mutation ??= newUuidV4();
    setState(() => view = null);
    final response = await call('add-shared-note', {
      ...binding,
      'mutationId': _mutation,
      'note': note.text.trim(),
    }, valid);
    if (valid()) {
      setState(() {
        view = response;
        note.clear();
        _mutation = null;
      });
    }
  });
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(_sharedTitle(context, _grant)),
      actions: [
        IconButton(
          onPressed: busy ? null : reload,
          tooltip: context.tr('Refresh access'),
          icon: const Icon(Icons.refresh),
        ),
      ],
    ),
    body: SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          ...status(),
          if (view == null && !busy)
            Text(context.tr('Refresh access to view this shared plan.')),
          if (view != null) ...[
            AccessDetails(membership: view!.membership!),
            ProjectionContent(projection: view!.projection!),
            if (services.config.sensitiveSharingEnabled &&
                view!.membership!.role == 'helper')
              OutlinedButton(
                onPressed: busy
                    ? null
                    : () async {
                        final grant = _grant;
                        setState(clearContent);
                        await Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => SensitiveSharingScreen(
                              services: services,
                              membership: grant,
                              ownerView: false,
                            ),
                          ),
                        );
                        if (current) await reload();
                      },
                child: Text(context.tr('Detailed helper access')),
              ),
            if (services.config.trackingEnabled)
              OutlinedButton(
                onPressed: busy
                    ? null
                    : () async {
                        final grant = _grant;
                        setState(clearContent);
                        await Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => CollaborationScreen(
                              services: services,
                              membership: grant,
                              ownerView: false,
                            ),
                          ),
                        );
                        if (current) await reload();
                      },
                child: Text(context.tr('Shared tasks and proposals')),
              ),

            for (final item in view!.notes)
              ListTile(title: Text(item.text), subtitle: Text(item.recordedAt)),
            if (view!.membership!.role == 'helper' &&
                view!.membership!.scope.allowHelperNotes) ...[
              TextField(
                controller: note,
                maxLength: 500,
                decoration: InputDecoration(
                  labelText: context.tr('Progress note'),
                ),
                onChanged: (_) {
                  _mutation = null;
                },
              ),
              FilledButton(
                onPressed: busy ? null : _add,
                child: Text(context.tr('Add progress note')),
              ),
            ],
          ],
        ],
      ),
    ),
  );
}

class ProjectionContent extends StatelessWidget {
  const ProjectionContent({
    super.key,
    required this.projection,
    this.programNames = const {},
  });
  final SharedCaseProjection projection;
  final Map<String, String> programNames;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const SizedBox(height: 12),
      Text(
        context.tr('Selected home safety information'),
        style: Theme.of(context).textTheme.titleLarge,
      ),
      Text(
        context.tr('Updated {date}', {
          'date': _moment(context, projection.publishedAt),
        }),
      ),
      if (projection.stale)
        Text(
          context.tr(
            'The owner has newer information. This shared copy needs review.',
          ),
        ),
      for (final finding in projection.findings)
        ListTile(
          title: Text(finding.observation),
          subtitle: Text(context.tr(finding.reviewState)),
        ),
      for (final program in projection.programs)
        ListTile(
          title: Text(
            programNames[program.id] ?? context.tr('A tracked program'),
          ),
          subtitle: Text(
            context.tr('Reported status: {status}', {
              'status': program.status == null
                  ? context.tr('Unknown')
                  : context.tr(program.status!),
            }),
          ),
        ),
      Text(
        context.tr(
          'Reported progress does not confirm agency receipt or approval.',
        ),
      ),
    ],
  );
}

class AccessDetails extends StatelessWidget {
  const AccessDetails({super.key, required this.membership});
  final CaseMembership membership;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        membership.expiresAt == null
            ? context.tr('No access expiry')
            : context.tr('Access expires on {date}', {
                'date': _day(context, membership.expiresAt!),
              }),
      ),
    ],
  );
}
