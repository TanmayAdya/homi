import 'package:flutter/material.dart';
import '../../../shared/presentation/sah_components.dart';
import '../../../l10n/app_localizations.dart';
import '../../../shared/services/local_private_store.dart';
import '../application/bathroom_scan_session.dart';
import '../domain/assessment_location.dart';
import '../domain/home_safety/home_safety.dart';

class RoomScanCards extends StatefulWidget {
  const RoomScanCards({
    super.key,
    required this.store,
    required this.caseId,
    required this.rooms,
    required this.isCurrent,
    required this.onOpen,
    required this.onChecklist,
    required this.enabled,
    this.compact = false,
    this.includeLegacy = true,
    this.onContinueQuestions,
    this.questionsLabel,
    this.onArchive,
  });
  final LocalPrivateStore store;
  final String caseId;
  final List<RoomInstance> rooms;
  final bool Function() isCurrent;
  final ValueChanged<RoomInstance?> onOpen;
  final ValueChanged<RoomInstance> onChecklist;
  final ValueChanged<RoomInstance>? onArchive;
  final bool enabled;
  final bool compact, includeLegacy;
  final VoidCallback? onContinueQuestions;
  final String? questionsLabel;
  @override
  State<RoomScanCards> createState() => _RoomScanCardsState();
}

class _RoomScanCardsState extends State<RoomScanCards> {
  final Map<String?, String> states = {};
  late Future<void> ready;
  @override
  void initState() {
    super.initState();
    ready = load();
  }

  Future<void> load() async {
    for (final room in <RoomInstance?>[
      if (widget.includeLegacy) null,
      ...widget.rooms,
    ]) {
      if (!mounted || !widget.isCurrent()) return;
      try {
        final review = await BathroomScanSession.readSaved(
          widget.store,
          widget.caseId,
          room: room,
        );
        if (!mounted || !widget.isCurrent()) return;
        if (room == null &&
            review?.scene == null &&
            review?.pendingScanId == null) {
          continue;
        }
        states[room?.id] = review?.pendingScanId != null
            ? 'Interrupted scan · saved work retained'
            : review?.scene != null
            ? '3D scan saved on this phone'
            : 'Not scanned on this phone';
      } catch (_) {
        if (!mounted || !widget.isCurrent()) return;
        states[room?.id] = 'Saved scan needs attention';
      }
    }
  }

  Widget _compactCard(BuildContext context, RoomInstance room, bool enabled) {
    final outdoor = room.type == AssessmentLocation.outdoorPaths;
    final hasModel = states[room.id] == '3D scan saved on this phone';
    final startScan =
        !outdoor && states[room.id] == 'Not scanned on this phone';
    final questions = widget.onContinueQuestions;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (questions != null) ...[
          FilledButton.icon(
            key: ValueKey(
              startScan ? 'room-start-assessment' : 'room-continue-questions',
            ),
            onPressed: enabled
                ? startScan
                      ? () => widget.onOpen(room)
                      : questions
                : null,
            icon: Icon(startScan ? Icons.view_in_ar : Icons.checklist_rounded),
            label: Text(
              context.tr(
                startScan
                    ? 'Scan room'
                    : widget.questionsLabel ?? 'Continue room questions',
              ),
            ),
          ),
          const SizedBox(height: 16),
        ],
        if (startScan && questions != null)
          SahActionTile(
            key: const ValueKey('room-continue-questions'),
            title: context.tr('Room questions'),
            icon: Icons.checklist_rounded,
            onTap: enabled ? questions : null,
          )
        else
          SahActionTile(
            key: ValueKey('open-room-scan-${room.id}'),
            title: context.tr(
              outdoor
                  ? 'Use photos and measurements'
                  : hasModel
                  ? 'View room model'
                  : 'Open room scan',
            ),
            subtitle: context.tr(
              outdoor
                  ? 'Photos are optional.'
                  : states[room.id] ?? 'Checking saved scans',
            ),
            icon: outdoor ? Icons.photo_camera_outlined : Icons.view_in_ar,
            onTap: enabled ? () => widget.onOpen(room) : null,
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<void>(
    future: ready,
    builder: (context, snapshot) {
      if (!widget.isCurrent()) return const SizedBox.shrink();
      final enabled =
          widget.enabled && snapshot.connectionState == ConnectionState.done;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (!widget.compact)
            Text(
              context.tr(
                'Each room has its own scan. Room positions are not joined into a floor plan.',
              ),
            ),
          if (snapshot.connectionState != ConnectionState.done)
            const LinearProgressIndicator(),
          for (final room in widget.rooms)
            if (widget.compact)
              _compactCard(context, room, enabled)
            else
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Semantics(
                        header: true,
                        child: Text(
                          room.name ?? context.tr(room.type.title),
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        context.tr(
                          room.type == AssessmentLocation.outdoorPaths
                              ? 'Use photos and measurements outdoors.'
                              : states[room.id] ?? 'Checking saved scans',
                        ),
                      ),
                      const SizedBox(height: 12),
                      FilledButton.icon(
                        key: ValueKey('open-room-scan-${room.id}'),
                        onPressed: enabled ? () => widget.onOpen(room) : null,
                        icon: Icon(
                          room.type == AssessmentLocation.outdoorPaths
                              ? Icons.photo_camera_outlined
                              : Icons.view_in_ar,
                        ),
                        label: Text(
                          context.tr(
                            room.type == AssessmentLocation.outdoorPaths
                                ? 'Use photos and measurements'
                                : states[room.id] == 'Not scanned on this phone'
                                ? 'Scan room'
                                : 'Open room scan',
                          ),
                        ),
                      ),
                      if (widget.onArchive != null)
                        TextButton.icon(
                          key: ValueKey('archive-room-${room.id}'),
                          onPressed: enabled
                              ? () => widget.onArchive!(room)
                              : null,
                          icon: const Icon(Icons.archive_outlined),
                          label: Text(context.tr('Archive room')),
                        ),
                      TextButton(
                        onPressed: enabled
                            ? () => widget.onChecklist(room)
                            : null,
                        child: Text(context.tr('Room checklist')),
                      ),
                    ],
                  ),
                ),
              ),
          if (states.containsKey(null))
            Card(
              child: ListTile(
                key: const ValueKey('legacy-bathroom-scan'),
                title: Text(context.tr('Earlier bathroom scan')),
                subtitle: Text(
                  context.tr('Kept separately from your named rooms.'),
                ),
                trailing: const Icon(Icons.view_in_ar),
                onTap: enabled ? () => widget.onOpen(null) : null,
              ),
            ),
        ],
      );
    },
  );
}
