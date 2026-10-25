import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../shared/presentation/sah_components.dart';
import 'local_help_record.dart';
import 'nationwide_help_browser.dart';
import 'provider_search.dart';
import 'referral_coverage_summary.dart';
import 'referral_directory.dart';

class HelpActions {
  const HelpActions({
    required this.open,
    required this.save,
    required this.followUp,
    required this.isSaved,
    this.busy = false,
    this.checklist,
  });

  final Future<bool> Function(Uri) open;
  final Future<void> Function(ReferralProvider) save, followUp;
  final bool Function(ReferralProvider) isSaved;
  final bool busy;

  final VoidCallback? Function(String programId)? checklist;

  VoidCallback? checklistFor(ReferralProvider p) =>
      p.programId == null ? null : checklist?.call(p.programId!);
}

class HelpFinder extends StatefulWidget {
  const HelpFinder({
    super.key,
    required this.directory,
    required this.now,
    required this.actions,
    required this.location,
    required this.onLocation,
    this.residentLocation,
  });
  final ReferralDirectory directory;
  final DateTime now;
  final HelpActions actions;
  final HelpLocation? location, residentLocation;
  final void Function(HelpLocation) onLocation;

  @override
  State<HelpFinder> createState() => _HelpFinderState();
}

class _HelpFinderState extends State<HelpFinder>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;
  final _query = TextEditingController();
  ReferralService? _service;
  ReferralRole? _role;
  bool _showRole = false, _wholeState = false, _editing = false;

  @override
  void didUpdateWidget(covariant HelpFinder oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.location, widget.location)) {
      _wholeState = false;
      _editing = false;
    }
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  bool get _filtered =>
      _query.text.trim().isNotEmpty || _service != null || _role != null;

  void _clear() => setState(() {
    FocusScope.of(context).unfocus();
    _query.clear();
    _service = null;
    _role = null;
    _wholeState = false;
  });

  bool get _fromResident {
    final r = widget.residentLocation, l = widget.location;
    if (r == null ||
        l == null ||
        [
          r.city,
          r.county,
          r.zip ?? '',
          r.stateCode ?? '',
        ].every((v) => v.trim().isEmpty)) {
      return false;
    }
    bool same(String a, String b) =>
        a.trim().toLowerCase() == b.trim().toLowerCase();
    return same(r.city, l.city) &&
        same(r.county, l.county) &&
        (r.stateCode == null || r.stateCode == l.stateCode) &&
        (r.zip == null || l.zip == null || r.zip == l.zip);
  }

  HelpLocation? get _residentArea {
    final r = widget.residentLocation;
    return referralState(r?.stateCode)?.routingSupported == true ? r : null;
  }

  String _place(HelpLocation l) {
    final state = l.stateCode!;
    if (_wholeState) return referralState(state)?.name ?? state;
    final local = [
      l.city,
      l.county,
    ].firstWhere((v) => v.trim().isNotEmpty, orElse: () => '');
    return local.isEmpty
        ? referralState(state)?.name ?? state
        : '${local.trim()}, $state';
  }

  Widget _card(ReferralProvider p) => HelpResultCard(
    provider: p,
    location: widget.location,
    now: widget.now,
    actions: widget.actions,
  );

  Widget _locationLine(BuildContext context, HelpLocation location) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 6,
        children: [
          Icon(
            Icons.home_outlined,
            size: 18,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          Text.rich(
            TextSpan(
              children: [
                TextSpan(
                  text: context.tr(
                    _fromResident ? 'Near the resident' : 'Searching near',
                  ),
                ),
                const TextSpan(text: ' · '),
                TextSpan(
                  text: referralLocationLabel(location),
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ],
            ),
          ),
          TextButton(
            key: const ValueKey('help-location-change'),
            onPressed: widget.actions.busy
                ? null
                : () => setState(() => _editing = !_editing),
            child: Text(context.tr(_editing ? 'Cancel' : 'Change')),
          ),
          if (_residentArea case final resident? when !_fromResident)
            TextButton(
              key: const ValueKey('help-use-resident-area'),
              onPressed: widget.actions.busy
                  ? null
                  : () => widget.onLocation(resident),
              child: Text(context.tr('Use the resident’s area')),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final theme = Theme.of(context);
    final location = widget.location;
    final state = location?.stateCode;
    final needsLocation = state == null;
    final county = _wholeState ? null : location?.county;
    final searching = state != null || _filtered;
    final organizations = searching
        ? searchLocalProviders(
            widget.directory,
            query: _query.text,
            stateCode: state,
            county: county,
            countyFips: _wholeState ? null : location?.countyFips,
            service: _service,
            role: _role,
            translate: (s) => context.tr(s),
          )
        : const <ReferralProvider>[];
    final countyFilter =
        state != null &&
        !_wholeState &&
        ((county?.trim().isNotEmpty ?? false) || location?.countyFips != null);
    final referrals = widget.directory.providers.where(
      (p) =>
          (p.providerKind == ReferralProviderKind.nationalLocator ||
              p.providerKind == ReferralProviderKind.referralContact) &&
          (p.isLocator || state != null && p.stateCodes.contains(state)),
    );
    final programs = widget.directory.providers.where(
      (p) => p.providerKind == ReferralProviderKind.programReferral,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (location != null && state != null) _locationLine(context, location),
        if (needsLocation || _editing)
          ReferralLocationEditor(
            key: ValueKey(location),
            initialLocation: location ?? widget.residentLocation,
            busy: widget.actions.busy,
            onConfirm: widget.onLocation,
          ),
        const SizedBox(height: 8),
        KeyedSubtree(
          key: const ValueKey('local-provider-search'),
          child: TextField(
            key: const ValueKey('provider-search-query'),
            controller: _query,
            maxLength: 100,
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.search),
              labelText: context.tr('Search by name, city or service'),
              counterText: '',
            ),
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) => FocusScope.of(context).unfocus(),
          ),
        ),
        const SizedBox(height: 8),
        Semantics(
          container: true,
          label: context.tr('Type of help'),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final service in <ReferralService?>[
                null,
                ...ReferralService.values,
              ])
                ChoiceChip(
                  key: ValueKey('help-type-${service?.name ?? 'all'}'),
                  label: Text(
                    context.tr(service?.label ?? 'All kinds of help'),
                  ),
                  selected: _service == service,
                  onSelected: (_) => setState(() => _service = service),
                ),
            ],
          ),
        ),
        Wrap(
          spacing: 8,
          children: [
            if (!_showRole && _role == null)
              TextButton.icon(
                onPressed: () => setState(() => _showRole = true),
                icon: const Icon(Icons.tune),
                label: Text(context.tr('Filter by organization role')),
              ),
            if (_filtered || _wholeState)
              TextButton(
                onPressed: _clear,
                child: Text(context.tr('Clear search and filters')),
              ),
          ],
        ),
        if (_showRole || _role != null)
          DropdownButtonFormField<String>(
            key: ValueKey('provider-role-${_role?.name ?? ''}'),
            initialValue: _role?.name ?? '',
            isExpanded: true,
            itemHeight: null,
            decoration: InputDecoration(
              labelText: context.tr('Organization role'),
            ),
            items: [
              DropdownMenuItem(value: '', child: Text(context.tr('All roles'))),
              for (final role in ReferralRole.values)
                DropdownMenuItem(
                  value: role.name,
                  child: Text(context.tr(role.label)),
                ),
            ],
            onChanged: (value) => setState(
              () => _role = ReferralRole.values
                  .where((r) => r.name == value)
                  .firstOrNull,
            ),
          ),
        if (state != null)
          SahSectionHeading(
            title: context.tr('Listed organizations near {place}', {
              'place': _place(location!),
            }),
          )
        else
          SahSectionHeading(title: context.tr('Listed organizations')),
        if (searching)
          Semantics(
            liveRegion: true,
            child: Text(
              context.tr('Providers found: {count}', {
                'count': '${organizations.length}',
              }),
              style: theme.textTheme.bodySmall,
            ),
          )
        else
          Text(
            context.tr(
              'Enter a location to see listed organizations near it, or search by name.',
            ),
          ),
        if (searching && organizations.isEmpty)
          _HelpEmptyResults(
            directory: widget.directory,
            title: state == null
                ? context.tr('No listed organizations match yet')
                : context.tr(
                    _filtered
                        ? 'No listed organizations near {place} match these filters'
                        : 'No listed organizations near {place} yet',
                    {'place': _place(location!)},
                  ),
            actions: widget.actions,
            onShowAll: _filtered ? _clear : null,
            onWholeState: countyFilter
                ? () => setState(() => _wholeState = true)
                : null,
            onChangeArea: state == null || widget.actions.busy
                ? null
                : () => setState(() => _editing = true),
          ),
        for (final p in organizations) _card(p),
        SahSectionHeading(title: context.tr('Ask who serves this address')),
        for (final p in referrals) _card(p),
        SahSectionHeading(
          title: context.tr('Program research and preparation'),
        ),
        for (final p in programs) _card(p),
        const SizedBox(height: 16),
        _HelpFootnote(
          directory: widget.directory,
          state: state,
          now: widget.now,
        ),
      ],
    );
  }
}

class _HelpEmptyResults extends StatelessWidget {
  const _HelpEmptyResults({
    required this.directory,
    required this.title,
    required this.actions,
    this.onShowAll,
    this.onWholeState,
    this.onChangeArea,
  });
  final ReferralDirectory directory;
  final String title;
  final HelpActions actions;
  final VoidCallback? onShowAll, onWholeState, onChangeArea;

  static const _everyAddress = {
    'referral-211-national': 'Local help line for most areas',
    'referral-eldercare-national': 'Aging services in all states and DC',
    'referral-rebuilding-together-national': 'Find a local affiliate',
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      key: const ValueKey('help-empty-results'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Semantics(
              header: true,
              child: Text(title, style: theme.textTheme.titleMedium),
            ),
            const SizedBox(height: 4),
            Text(
              context.tr(
                'This app’s list of local organizations is small. That does not mean no help exists. These referral services serve every address and can tell you who serves this one:',
              ),
            ),
            for (final entry in _everyAddress.entries)
              if (directory.provider(entry.key) case final p?)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(p.name),
                  subtitle: Text(context.tr(entry.value)),
                  trailing: const Icon(Icons.open_in_new),
                  enabled: !actions.busy,
                  onTap: () => actions.open(referralDestination(p)),
                ),
            Wrap(
              spacing: 8,
              children: [
                if (onShowAll != null)
                  TextButton(
                    onPressed: onShowAll,
                    child: Text(context.tr('Show all kinds of help')),
                  ),
                if (onWholeState != null)
                  TextButton(
                    onPressed: onWholeState,
                    child: Text(context.tr('Search the whole state')),
                  ),
                if (onChangeArea != null)
                  TextButton(
                    onPressed: onChangeArea,
                    child: Text(context.tr('Search a different area')),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _HelpFootnote extends StatelessWidget {
  const _HelpFootnote({
    required this.directory,
    required this.state,
    required this.now,
  });
  final ReferralDirectory directory;
  final String? state;
  final DateTime now;
  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.bodySmall?.copyWith(
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          context.tr(
            'A listing does not confirm that an organization serves your address, has funding or works with this app. Program research is preparation only: it does not check eligibility, create an official form or submit an application.',
          ),
          style: style,
        ),
        const SizedBox(height: 8),
        Text(
          context.tr(
            'Listings work offline. Opening websites needs a connection. Your location and plan details are not sent in these links.',
          ),
          style: style,
        ),
        ExpansionTile(
          key: const PageStorageKey('help-about-list'),
          tilePadding: EdgeInsets.zero,
          title: Text(context.tr('About this list')),
          children: [
            ReferralCoverageSummary(
              directory: directory,
              stateCode: state,
              now: now,
            ),
          ],
        ),
      ],
    );
  }
}

String helpWhere(BuildContext context, ReferralProvider p) {
  if (p.isLocator) return context.tr('All 50 states and DC');
  if (p.stateCodes.length == usStates.length &&
      usStates.every((s) => p.stateCodes.contains(s.code))) {
    return context.tr('National program route; requirements vary.');
  }
  final states = p.stateCodes
      .map((c) => referralState(c)?.name ?? c)
      .join(', ');
  final counties = <String>{
    ...p.counties,
    for (final a in p.listedAreas) ?a.countyName,
  };
  final area = counties.isEmpty ? states : '${counties.join(', ')} ($states)';
  final partial =
      p.cities.isNotEmpty ||
      p.listedAreas.any((a) => a.cities.isNotEmpty || a.zipCodes.isNotEmpty);
  return partial
      ? context.tr('{area}; selected areas only', {'area': area})
      : area;
}

String helpCoverage(
  BuildContext context,
  ReferralProvider p,
  HelpLocation? location,
  DateTime now,
) => context.tr(switch (p.coverage(
  location?.county,
  now,
  stateCode: location?.stateCode,
  countyFips: location?.countyFips,
  city: location?.city,
  zip: location?.zip,
)) {
  ReferralCoverage.locator => 'National locator: ask who serves your address.',
  ReferralCoverage.listedCounty =>
    'Listed for this county; confirm address coverage.',
  ReferralCoverage.unknown => 'Coverage unknown: contact to confirm.',
});

String? helpNotConfirmed(ReferralProvider p) => p.isLocator
    ? null
    : p.providerKind == ReferralProviderKind.programReferral
    ? 'eligibility, funding or approval. Only the program decides.'
    : 'whether they serve your address, current intake or funding.';

SahOutputKind helpOutput(ReferralProvider p) =>
    p.providerKind == ReferralProviderKind.nationalLocator ||
        p.providerKind == ReferralProviderKind.referralContact
    ? SahOutputKind.referral
    : SahOutputKind.contactOnly;

class _Labeled extends StatelessWidget {
  const _Labeled(this.label, this.value);
  final String label, value;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 4),
    child: Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text: context.tr(label),
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          TextSpan(text: ' $value'),
        ],
      ),
    ),
  );
}

List<Widget> _cautions(BuildContext context, ReferralProvider p, DateTime now) {
  final warning = Theme.of(context).colorScheme.error;
  return [
    if (p.availability == ReferralAvailability.closed)
      Text(
        context.tr('Intake closed: ask about alternatives.'),
        style: TextStyle(color: warning, fontWeight: FontWeight.w700),
      ),
    if (p.needsReview(now))
      Text(context.tr('Listing needs review. Contact to confirm.')),
  ];
}

String _saveLabel(bool saved) =>
    saved ? 'Saved · on this phone' : 'Save · on this phone';

class HelpResultCard extends StatelessWidget {
  const HelpResultCard({
    super.key,
    required this.provider,
    required this.now,
    required this.actions,
    this.location,
  });
  final ReferralProvider provider;
  final DateTime now;
  final HelpLocation? location;
  final HelpActions actions;

  @override
  Widget build(BuildContext context) {
    final p = provider;
    final theme = Theme.of(context);
    final busy = actions.busy;
    final saved = actions.isSaved(p);
    final notConfirmed = helpNotConfirmed(p);
    final openChecklist = actions.checklistFor(p);
    final reviewed = MaterialLocalizations.of(
      context,
    ).formatMediumDate(DateTime.parse(p.reviewedOn));
    return Card(
      key: ValueKey(p.id),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Semantics(
              header: true,
              child: Text(
                p.name,
                key: ValueKey('provider-result-${p.id}'),
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              context.tr(p.description),
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            _Labeled('Where:', helpWhere(context, p)),
            Text(
              helpCoverage(context, p, location, now),
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            SahOutputLabel(
              kind: openChecklist != null
                  ? SahOutputKind.checklist
                  : helpOutput(p),
            ),
            if (openChecklist != null)
              Text(context.tr('This app has a checklist for this program')),
            if (notConfirmed != null)
              _Labeled('Not confirmed:', context.tr(notConfirmed)),
            ..._cautions(context, p, now),
            const SizedBox(height: 12),
            if (openChecklist != null)
              FilledButton.icon(
                key: ValueKey('help-checklist-${p.id}'),
                onPressed: busy ? null : openChecklist,
                icon: const Icon(Icons.checklist),
                label: Text(context.tr('Open checklist')),
              )
            else if (p.phone != null)
              FilledButton.icon(
                onPressed: busy
                    ? null
                    : () => actions.open(referralDestination(p, phone: true)),
                icon: const Icon(Icons.call),
                label: Text(
                  context.tr(
                    p.phone == '211' ? 'Call 211' : 'Call organization',
                  ),
                ),
              )
            else
              FilledButton.icon(
                onPressed: busy
                    ? null
                    : () => actions.open(referralDestination(p)),
                icon: const Icon(Icons.open_in_new),
                label: Text(context.tr(referralWebsiteLabel(p))),
              ),
            Wrap(
              spacing: 4,
              children: [
                if (p.phone != null || openChecklist != null)
                  TextButton(
                    onPressed: busy
                        ? null
                        : () => actions.open(referralDestination(p)),
                    child: Text(context.tr(referralWebsiteLabel(p))),
                  ),
                TextButton.icon(
                  onPressed: busy ? null : () => actions.save(p),
                  icon: Icon(saved ? Icons.bookmark : Icons.bookmark_border),
                  label: Text(context.tr(_saveLabel(saved))),
                ),
                TextButton(
                  onPressed: busy ? null : () => actions.followUp(p),
                  child: Text(context.tr('Add follow-up')),
                ),
                TextButton(
                  key: ValueKey('help-details-${p.id}'),
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => HelpResultDetailScreen(
                        provider: p,
                        location: location,
                        now: now,
                        actions: actions,
                      ),
                    ),
                  ),
                  child: Text(context.tr('Details')),
                ),
              ],
            ),
            Text(
              context.tr('Reviewed {date}', {'date': reviewed}),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String helpSourceName(String source) {
  final host = Uri.tryParse(source)?.host ?? '';
  return host.startsWith('www.') ? host.substring(4) : host;
}

Uri? helpSourceUri(String source) {
  final uri = Uri.tryParse(source);
  return uri == null ||
          uri.scheme != 'https' ||
          uri.host.isEmpty ||
          uri.userInfo.isNotEmpty ||
          uri.hasFragment
      ? null
      : uri;
}

class HelpResultDetailScreen extends StatefulWidget {
  const HelpResultDetailScreen({
    super.key,
    required this.provider,
    required this.now,
    required this.actions,
    this.location,
  });
  final ReferralProvider provider;
  final DateTime now;
  final HelpLocation? location;
  final HelpActions actions;
  @override
  State<HelpResultDetailScreen> createState() => _HelpResultDetailState();
}

class _HelpResultDetailState extends State<HelpResultDetailScreen> {
  bool _failed = false, _running = false;

  Future<void> _open(Uri uri) async {
    setState(() => _failed = false);
    final opened = await widget.actions.open(uri);
    if (mounted) setState(() => _failed = !opened);
  }

  Future<void> _act(Future<void> Function(ReferralProvider) action) async {
    if (_running) return;
    setState(() => _running = true);
    try {
      await action(widget.provider);
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.provider;
    final theme = Theme.of(context);
    final busy = widget.actions.busy || _running;
    final notConfirmed = helpNotConfirmed(p);
    final kind = helpOutput(p);
    final format = MaterialLocalizations.of(context).formatMediumDate;
    final cities = <String>{
      ...p.cities,
      for (final a in p.listedAreas) ...a.cities,
    };
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 64,
        title: MediaQuery.withClampedTextScaling(
          maxScaleFactor: 1.3,
          child: Text(p.name, maxLines: 2, overflow: TextOverflow.ellipsis),
        ),
      ),
      body: SafeArea(
        child: SahContent(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            children: [
              if (_failed)
                SahNotice(
                  message: context.tr(
                    'Could not open this link or dialer. Check your connection, try the official locator, or use the phone number or website shown below.',
                  ),
                  tone: SahNoticeTone.warning,
                ),
              SahSectionHeading(title: context.tr('Where they work')),
              Text(helpWhere(context, p)),
              Text(helpCoverage(context, p, widget.location, widget.now)),
              if (cities.isNotEmpty)
                _Labeled('Listed cities:', cities.join(', ')),
              if (p.areaNote != null) Text(context.tr(p.areaNote!)),
              if (notConfirmed != null)
                _Labeled('Not confirmed:', context.tr(notConfirmed)),
              ..._cautions(context, p, widget.now),
              SahSectionHeading(title: context.tr('What they may help with')),
              Text(context.tr(p.description)),
              if (p.services.isNotEmpty)
                Text(p.services.map((s) => context.tr(s.label)).join(' · ')),
              Text(p.roles.map((r) => context.tr(r.label)).join(' · ')),
              SahSectionHeading(title: context.tr('What this app can do')),
              SahOutputLabel(kind: kind, prefix: false),
              const SizedBox(height: 4),
              Text(
                context.tr(
                  p.providerKind == ReferralProviderKind.programReferral
                      ? 'Program research is preparation only. It does not check eligibility, generate an official form or submit an application.'
                      : kind == SahOutputKind.referral
                      ? 'You can save this service on this phone and add a follow-up. It can tell you who may serve this address; this app does not make the referral for you.'
                      : 'You can save this organization on this phone and add a follow-up. This app does not prepare an application for this organization.',
                ),
              ),
              SahSectionHeading(title: context.tr('Contact')),
              if (p.phone != null) ...[
                FilledButton.icon(
                  onPressed: busy
                      ? null
                      : () => _open(referralDestination(p, phone: true)),
                  icon: const Icon(Icons.call),
                  label: Text(
                    context.tr(
                      p.phone == '211' ? 'Call 211' : 'Call organization',
                    ),
                  ),
                ),
                SelectableText(
                  p.phone!,
                  key: PageStorageKey('referral-phone-${p.id}'),
                ),
                const SizedBox(height: 8),
              ],
              OutlinedButton.icon(
                onPressed: busy ? null : () => _open(referralDestination(p)),
                icon: const Icon(Icons.open_in_new),
                label: Text(context.tr(referralWebsiteLabel(p))),
              ),
              SahSectionHeading(title: context.tr('Sources')),
              for (final source in p.sources)
                ListTile(
                  key: ValueKey('referral-source-${p.id}-$source'),
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.public),
                  title: Text(helpSourceName(source)),
                  subtitle: Text(
                    context.tr('Checked {date}', {
                      'date': format(DateTime.parse(p.reviewedOn)),
                    }),
                  ),
                  trailing: const Icon(Icons.open_in_new),
                  enabled: !busy && helpSourceUri(source) != null,
                  onTap: () => _open(helpSourceUri(source)!),
                ),
              Text(
                context.tr('Review due {date}', {
                  'date': format(DateTime.parse(p.reviewAfter)),
                }),
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 16),
              FilledButton.tonalIcon(
                onPressed: busy ? null : () => _act(widget.actions.save),
                icon: Icon(
                  widget.actions.isSaved(p)
                      ? Icons.bookmark
                      : Icons.bookmark_border,
                ),
                label: Text(context.tr(_saveLabel(widget.actions.isSaved(p)))),
              ),
              TextButton(
                onPressed: busy ? null : () => _act(widget.actions.followUp),
                child: Text(context.tr('Add follow-up')),
              ),
              Text(
                context.tr(
                  'Saved contacts stay on this phone and are removed when you sign out.',
                ),
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
