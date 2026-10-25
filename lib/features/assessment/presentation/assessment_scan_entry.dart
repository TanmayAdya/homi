import 'package:flutter/material.dart';
import 'package:safe_at_home/l10n/app_localizations.dart';

import '../../../app/theme.dart';
import '../application/bathroom_scan_availability.dart';

enum SavedScanState { loading, none, unreviewed, reviewed, otherDevice }

class AssessmentScanEntry extends StatelessWidget {
  const AssessmentScanEntry({
    super.key,
    required this.availability,
    required this.onOpen,
    required this.onCheck,
    this.saved = SavedScanState.none,
    this.rooms = false,
    this.roomTitle,
  });

  final BathroomScanAvailability availability;
  final VoidCallback? onOpen, onCheck;
  final SavedScanState saved;
  final bool rooms;
  final String? roomTitle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final capability = availability.capabilities;
    final hasModel =
        saved == SavedScanState.unreviewed || saved == SavedScanState.reviewed;
    final primary = availability.prefersScan || hasModel;
    final title = rooms || roomTitle != null
        ? 'Room scans'
        : hasModel
        ? 'Bathroom scan saved'
        : saved == SavedScanState.otherDevice
        ? 'Bathroom scanned on another phone'
        : primary
        ? 'Scan or view your bathroom'
        : availability.checking || saved == SavedScanState.loading
        ? 'Checking 3D scan support'
        : 'Photos and measurements work here';
    final description = saved == SavedScanState.unreviewed
        ? 'Not reviewed yet. Open it to choose what feels difficult.'
        : saved == SavedScanState.reviewed
        ? 'Open it to check what was found or add another concern.'
        : saved == SavedScanState.otherDevice
        ? 'The 3D model stays on the phone that made it. Its findings are listed above.'
        : availability.checking || saved == SavedScanState.loading
        ? 'You can start with photos or measurements while we check this phone.'
        : availability.failed
        ? 'The scanner check could not finish. Try again, or use photos and measurements.'
        : switch (capability?.reason) {
            'services_missing' =>
              'This Android phone supports ARCore. Set up Google Play Services for AR to scan.',
            'services_update_required' =>
              'Update Google Play Services for AR when you start scanning.',
            'permission_denied' =>
              capability?.source != 'arcore'
                  ? 'Allow camera access for Safe at Home in Settings, then return to scan.'
                  : 'Allow camera access when prompted, or in Settings if permission was previously blocked.',
            'available' when primary => null,
            'checking' =>
              'Device support is not confirmed yet. Check again, or use photos and measurements.',
            'unsupported_os' =>
              '3D scanning needs a newer operating system. Photos and manual measurements are ready now.',
            'simulator' =>
              '3D capture needs a supported physical phone. You can still review a saved model.',
            _ =>
              '3D capture is unavailable on this phone. You can still review a saved model.',
          };
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: primary
            ? theme.colorScheme.primaryContainer
            : theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(SahRadius.large),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            header: true,
            child: Text(
              roomTitle ?? context.tr(title),
              style: theme.textTheme.titleLarge,
            ),
          ),
          if (description != null && !rooms && roomTitle == null) ...[
            const SizedBox(height: 8),
            Text(context.tr(description)),
          ],
          const SizedBox(height: 16),
          if (primary)
            FilledButton.icon(
              key: const ValueKey('open-bathroom-scan'),
              onPressed: onOpen,
              icon: const Icon(Icons.view_in_ar),
              label: Text(
                context.tr(
                  rooms
                      ? 'Room scans'
                      : roomTitle != null
                      ? 'Open room scan'
                      : hasModel
                      ? 'Review bathroom scan'
                      : capability?.source == 'arkit'
                      ? 'Start camera scan'
                      : 'Open 3D bathroom',
                ),
                textAlign: TextAlign.center,
              ),
            )
          else
            OutlinedButton.icon(
              key: const ValueKey('open-bathroom-scan'),
              onPressed: onOpen,
              icon: const Icon(Icons.view_in_ar),
              label: Text(
                context.tr('Saved 3D model & scan options'),
                textAlign: TextAlign.center,
              ),
            ),
          if (!primary && !availability.checking)
            TextButton(
              key: const ValueKey('recheck-bathroom-scan'),
              onPressed: onCheck,
              child: Text(context.tr('Check scanning support again')),
            ),
        ],
      ),
    );
  }
}
