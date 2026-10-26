import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../l10n/app_localizations.dart';
import '../../shared/presentation/sah_components.dart';
import '../../shared/presentation/sah_floating_nav.dart';
import 'local_help_record.dart';
import 'help_finder.dart';
import 'referral_directory.dart';
import 'zip_states.dart';

class NationwideHelpBrowser extends StatefulWidget {
  const NationwideHelpBrowser({
    super.key,
    this.directory = const OfficialReferralDirectory(),
    this.openExternal,
    this.now,
    this.embedded = false,
    this.onChoosePlan,
  });
  final ReferralDirectory directory;
  final Future<bool> Function(Uri)? openExternal;
  final DateTime Function()? now;
  final bool embedded;

  final VoidCallback? onChoosePlan;

  @override
  State<NationwideHelpBrowser> createState() => _NationwideHelpBrowserState();
}

class _NationwideHelpBrowserState extends State<NationwideHelpBrowser> {
  HelpLocation? _location;
  String? _error;
  bool _opening = false;

  Future<bool> _open(Uri uri) async {
    if (_opening) return false;
    setState(() {
      _opening = true;
      _error = null;
    });
    try {
      final opened =
          await (widget.openExternal?.call(uri) ??
              launchUrl(uri, mode: LaunchMode.externalApplication));
      if (!opened) throw StateError('External application unavailable');
      return true;
    } catch (_) {
      if (mounted) {
        setState(
          () => _error =
              'Could not open this link or dialer. Check your connection, try the official locator, or use the phone number or website shown below.',
        );
      }
      return false;
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  Future<void> _planNeeded(
    ReferralProvider provider,
  ) => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (sheet) => SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Semantics(
              header: true,
              child: Text(
                sheet.tr('Save to a plan'),
                style: Theme.of(sheet).textTheme.titleLarge,
              ),
            ),
            const SizedBox(height: 8),
            Text(provider.name),
            const SizedBox(height: 8),
            Text(
              sheet.tr(
                'Create or open a plan to save contacts and add follow-ups.',
              ),
            ),
            const SizedBox(height: 8),
            Text(
              sheet.tr(
                'Saved contacts stay on this phone and are removed when you sign out.',
              ),
            ),
            const SizedBox(height: 16),
            if (widget.onChoosePlan case final choose?)
              FilledButton(
                key: const ValueKey('help-choose-plan'),
                onPressed: () {
                  Navigator.pop(sheet);
                  choose();
                },
                child: Text(sheet.tr('Choose or create a plan')),
              ),
            TextButton(
              onPressed: () => Navigator.pop(sheet),
              child: Text(sheet.tr('Not now')),
            ),
          ],
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final body = SafeArea(
      child: SahContent(
        child: ListView(
          padding: widget.embedded
              ? sahFloatingContentPadding(context)
              : const EdgeInsets.all(16),
          children: [
            if (widget.embedded)
              SahPageHeader(
                title: context.tr('Find help'),
                description: context.tr(
                  'You can search without a plan. To check program requirements or save contacts, create a plan.',
                ),
              )
            else
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(
                  context.tr(
                    'You can search without a plan. To check program requirements or save contacts, create a plan.',
                  ),
                ),
              ),
            if (_error != null)
              SahNotice(
                message: context.tr(_error!),
                tone: SahNoticeTone.warning,
              ),
            if (_opening) const LinearProgressIndicator(),
            HelpFinder(
              directory: widget.directory,
              now: widget.now?.call() ?? DateTime.now(),
              location: _location,
              onLocation: (location) => setState(() => _location = location),
              actions: HelpActions(
                open: _open,
                save: _planNeeded,
                followUp: _planNeeded,
                isSaved: (_) => false,
                busy: _opening,
              ),
            ),
          ],
        ),
      ),
    );
    return widget.embedded
        ? body
        : Scaffold(
            appBar: AppBar(title: Text(context.tr('Find help nationwide'))),
            body: body,
          );
  }
}

String referralWebsiteLabel(ReferralProvider p) => switch (p.id) {
  'referral-211-national' => 'Find my local 211',
  'referral-rebuilding-together-national' =>
    'Find a Rebuilding Together affiliate',
  'referral-eldercare-national' => 'Open Eldercare Locator',
  _ => 'Open official website',
};

String referralLocationLabel(HelpLocation location) => [
  location.city,
  location.county,
  if (location.stateCode != null)
    referralState(location.stateCode)?.name ?? location.stateCode!,
  location.zip ?? '',
].where((v) => v.isNotEmpty).join(', ');

class ReferralLocationEditor extends StatefulWidget {
  const ReferralLocationEditor({
    super.key,
    this.initialLocation,
    required this.onConfirm,
    this.busy = false,
  });
  final HelpLocation? initialLocation;
  final void Function(HelpLocation) onConfirm;
  final bool busy;
  @override
  State<ReferralLocationEditor> createState() => _ReferralLocationEditorState();
}

class _ReferralLocationEditorState extends State<ReferralLocationEditor>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;
  static final _zipPattern = RegExp(r'^[0-9]{5}(-[0-9]{4})?$');
  final _form = GlobalKey<FormState>();
  late final _initialPlace =
      widget.initialLocation?.zip ?? widget.initialLocation?.city ?? '';
  late final _place = TextEditingController(text: _initialPlace);
  late final _county = TextEditingController(
    text: widget.initialLocation?.county ?? '',
  );
  late bool _showCounty = _county.text.trim().isNotEmpty;
  late String? _state = widget.initialLocation?.stateCode;
  bool _stateFromZip = false;

  static String? _routable(String place) {
    final state = stateForZip(place);
    return referralState(state)?.routingSupported == true ? state : null;
  }

  void _placeChanged(String value) {
    if (!_zipPattern.hasMatch(value.trim())) {
      if (_stateFromZip) setState(() => _stateFromZip = false);
      return;
    }
    final state = _routable(value);
    setState(() {
      _stateFromZip = state != null;
      if (state != null) _state = state;
    });
  }

  @override
  void dispose() {
    _place.dispose();
    _county.dispose();
    super.dispose();
  }

  void _confirm() {
    if (!_form.currentState!.validate()) return;
    FocusScope.of(context).unfocus();
    final place = _place.text.trim();
    final initial = widget.initialLocation;
    final unchanged = place == _initialPlace.trim() && initial != null;
    final zip = _zipPattern.hasMatch(place);
    widget.onConfirm(
      HelpLocation(
        stateCode: _state,
        city: unchanged ? initial.city : (zip ? '' : place),
        county: _county.text.trim(),
        zip: unchanged ? initial.zip : (zip ? place : null),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Form(
      key: _form,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SahSectionHeading(title: context.tr('Where should we look?')),
          DropdownButtonFormField<String>(
            key: const ValueKey('help-location-state'),
            initialValue: _state,
            isExpanded: true,
            itemHeight: null,
            decoration: InputDecoration(
              labelText: context.tr('State or DC'),
              helperText: _stateFromZip
                  ? context.tr(
                      'Filled from ZIP code {zip}. You can change it.',
                      {'zip': _place.text.trim()},
                    )
                  : null,
            ),
            items: [
              for (final state in usStates)
                DropdownMenuItem(value: state.code, child: Text(state.name)),
            ],
            onChanged: widget.busy
                ? null
                : (value) => setState(() {
                    _state = value;
                    _stateFromZip = false;
                  }),
            validator: (value) => referralState(value)?.routingSupported == true
                ? null
                : context.tr(
                    _zipPattern.hasMatch(_place.text.trim()) &&
                            _routable(_place.text) == null
                        ? 'Choose the state. This ZIP code doesn’t tell us which one.'
                        : 'Choose your state or DC. No GPS is needed.',
                  ),
          ),
          TextFormField(
            key: const ValueKey('help-location-place'),
            controller: _place,
            enabled: !widget.busy,
            maxLength: 100,
            textInputAction: TextInputAction.done,
            decoration: InputDecoration(
              labelText: context.tr('ZIP code or city (optional)'),
            ),
            validator: (value) {
              final v = value!.trim();
              return v.isEmpty ||
                      _zipPattern.hasMatch(v) ||
                      !RegExp(r'^[0-9 -]+$').hasMatch(v)
                  ? null
                  : context.tr('Enter a 5-digit ZIP or ZIP+4.');
            },
            onChanged: _placeChanged,
            onFieldSubmitted: (_) => widget.busy ? null : _confirm(),
          ),
          if (_showCounty)
            TextFormField(
              controller: _county,
              enabled: !widget.busy,
              maxLength: 100,
              decoration: InputDecoration(
                labelText: context.tr('County (optional)'),
              ),
            )
          else
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton(
                onPressed: widget.busy
                    ? null
                    : () => setState(() => _showCounty = true),
                child: Text(context.tr('Add county (optional)')),
              ),
            ),
          FilledButton(
            onPressed: widget.busy ? null : _confirm,
            child: Text(context.tr('Confirm location')),
          ),
          const SizedBox(height: 8),
          Text(
            context.tr(
              'Unknown location? Use the national locators. Location is not sent to these websites.',
            ),
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}
