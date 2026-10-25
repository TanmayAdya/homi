import 'package:flutter/material.dart';
import '../../app/live_app.dart';
import '../../l10n/app_localizations.dart';
import '../services/feature_capabilities.dart';
import 'sah_components.dart';

class FeatureAvailabilitySection extends StatefulWidget {
  const FeatureAvailabilitySection({super.key, required this.services});
  final AppServices services;
  @override
  State<FeatureAvailabilitySection> createState() =>
      _FeatureAvailabilitySectionState();
}

class _FeatureAvailabilitySectionState
    extends State<FeatureAvailabilitySection> {
  FeatureCapabilities? _backend;
  bool _loading = false;
  String? _error;
  Future<void> _check() async {
    final app = widget.services;
    final generation = app.coordinator.generation;
    bool current() =>
        mounted &&
        app.coordinator.isCurrent &&
        app.coordinator.generation == generation;
    setState(() {
      _loading = true;
      _backend = null;
      _error = null;
    });
    try {
      final result = await FeatureCapabilities.read(
        origin: app.config.apiOrigin,
        transport: app.transport,
        token: app.session.accessToken,
        isCurrent: current,
      );
      if (current()) setState(() => _backend = result);
    } catch (error) {
      if (current()) {
        setState(
          () => _error = error is FeatureCheckUnsupported
              ? 'This service does not support availability checks yet. You can still try the enabled features.'
              : safeOperationMessage(error),
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final config = widget.services.config;
    final rows = <(String, String?, bool)>[
      ('Room photos and measurements', null, true),
      (
        'Named rooms and checklists',
        'structuredRooms',
        config.homeSafetyEnabled,
      ),
      ('Tasks', 'tracking', config.trackingEnabled),
      ('Local providers', null, config.localHelpEnabled),
      ('Saved scan sync', 'scanSync', config.scanSyncEnabled),
      (
        'People with access',
        'permissionSharing',
        config.permissionSharingEnabled,
      ),
      ('Detailed sharing', 'sensitiveSharing', config.sensitiveSharingEnabled),
      ('Invitations', 'simpleInvitations', config.simpleInvitationsEnabled),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SahSectionHeading(title: context.tr('Feature availability')),
        for (final (label, feature, enabled) in rows)
          ListTile(
            title: Text(context.tr(label)),
            subtitle: Text(
              [
                context.tr(
                  enabled ? 'Enabled in this build' : 'Disabled in this build',
                ),
                if (feature != null && _backend != null)
                  context.tr(
                    _backend!.features[feature] == true
                        ? 'Available on this service'
                        : 'Unavailable on this service',
                  ),
              ].join(' · '),
            ),
          ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(context.tr(_error!)),
          ),
        if (_loading) const LinearProgressIndicator(),
        TextButton(
          onPressed: _loading ? null : _check,
          child: Text(context.tr('Check service availability')),
        ),
      ],
    );
  }
}
