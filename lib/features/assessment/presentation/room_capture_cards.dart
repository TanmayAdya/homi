import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';
import '../../../shared/services/local_private_store.dart';
import '../application/bathroom_scan_availability.dart';
import '../application/bathroom_scan_session.dart';
import '../application/whole_home_session.dart';
import '../domain/assessment_location.dart';
import '../domain/home_safety/home_safety.dart';
import '../domain/local_place_rooms.dart';
import 'assessment_location_guide.dart';

class RoomCaptureCards extends StatefulWidget {
  const RoomCaptureCards({
    super.key,
    required this.store,
    required this.caseId,
    required this.rooms,
    required this.availability,
    required this.isCurrent,
    required this.enabled,
    required this.onScan,
    required this.onOpenRoom,
    this.summary,
    this.mergeLegacyBathroom = false,
    this.savedPlacesOnly = false,
    this.onConnected,
  });

  final LocalPrivateStore store;
  final String caseId;
  final List<RoomInstance> rooms;
  final BathroomScanAvailability availability;
  final bool Function() isCurrent;
  final bool enabled, mergeLegacyBathroom, savedPlacesOnly;
  final void Function(RoomInstance? room) onScan;
  final ValueChanged<RoomInstance> onOpenRoom;
  final String Function(RoomInstance)? summary;
  final VoidCallback? onConnected;

  @override
  State<RoomCaptureCards> createState() => _RoomCaptureCardsState();
}

class _RoomCaptureCardsState extends State<RoomCaptureCards> {
  final _saved = <String?>{};
  final _attention = <String?>{};
  final _connectedRooms = <String>{};
  bool _loaded = false, _connected = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    for (final room in <RoomInstance?>[
      if (widget.mergeLegacyBathroom) null,
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
        if (review?.scene != null) _saved.add(room?.id);
        if (review?.pendingScanId != null) _attention.add(room?.id);
      } catch (_) {
        if (!mounted || !widget.isCurrent()) return;
        _attention.add(room?.id);
      }
    }
    try {
      _connectedRooms.addAll(
        await WholeHomeSession.readSavedConnectedRoomIds(
          store: widget.store,
          caseId: widget.caseId,
          rooms: widget.rooms,
          isCurrent: () => mounted && widget.isCurrent(),
          localPlaces:
              widget.rooms.isNotEmpty &&
              widget.rooms.every(LocalPlaceRooms.contains),
        ),
      );
    } catch (_) {}
    if (!mounted || !widget.isCurrent()) return;
    if (widget.savedPlacesOnly) {
      try {
        _connected =
            await widget.store.readBytes(
              LocalPlaceRooms.homeKey(widget.caseId),
            ) !=
            null;
      } catch (_) {
        _connected = true;
      }
    }
    if (mounted && widget.isCurrent()) setState(() => _loaded = true);
  }

  Widget _card(RoomInstance room) {
    final outdoor = room.type == AssessmentLocation.outdoorPaths;
    final legacy =
        widget.mergeLegacyBathroom &&
        room.type == AssessmentLocation.bathroom &&
        (_saved.contains(null) || _attention.contains(null));
    final useLegacy = legacy && !_saved.contains(room.id);
    final id = useLegacy ? null : room.id;
    final model = _saved.contains(id);
    final attention = _attention.contains(id);
    final connected = _connectedRooms.contains(room.id);
    final available = widget.availability.prefersScan;
    final enabled = widget.enabled && _loaded;
    final status = !_loaded
        ? 'Checking saved scans'
        : attention
        ? 'Review scan'
        : model
        ? 'Scan saved'
        : connected
        ? 'In connected model'
        : outdoor
        ? 'Photos & measurements'
        : 'No scan yet';
    Widget details() => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Semantics(
          header: true,
          child: Text(
            room.name ?? context.tr(room.type.title),
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ),
        const SizedBox(height: 4),
        Text(context.tr(status), style: Theme.of(context).textTheme.bodySmall),
        if (widget.summary != null) ...[
          const SizedBox(height: 4),
          Text(
            widget.summary!(room),
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ],
    );
    List<Widget> actions() => [
      if (!outdoor)
        FilledButton(
          key: ValueKey('open-room-scan-${room.id}'),
          style: FilledButton.styleFrom(
            minimumSize: const Size(104, 44),
            padding: const EdgeInsets.symmetric(horizontal: 12),
          ),
          onPressed: enabled
              ? () => widget.onScan(useLegacy ? null : room)
              : null,
          child: Text(
            context.tr(
              model
                  ? 'View model'
                  : available
                  ? 'Scan room'
                  : 'Scan options',
            ),
            textAlign: TextAlign.center,
          ),
        ),
      TextButton(
        key: ValueKey(
          LocalPlaceRooms.contains(room)
              ? 'area-${room.type.name}'
              : 'open-room-${room.id}',
        ),
        style: TextButton.styleFrom(minimumSize: const Size(104, 44)),
        onPressed: enabled ? () => widget.onOpenRoom(room) : null,
        child: Text(context.tr('Open room'), textAlign: TextAlign.center),
      ),
      if (connected && widget.onConnected != null)
        TextButton(
          key: ValueKey('connected-room-${room.id}'),
          onPressed: enabled ? widget.onConnected : null,
          child: Text(
            context.tr('View connected model'),
            textAlign: TextAlign.center,
          ),
        ),
      if (legacy && !useLegacy)
        TextButton(
          key: const ValueKey('legacy-bathroom-scan'),
          onPressed: enabled ? () => widget.onScan(null) : null,
          child: Text(context.tr('Earlier bathroom scan')),
        ),
    ];
    return Card(
      key: ValueKey('room-${room.id}'),
      margin: const EdgeInsets.only(bottom: 12),
      child: InkWell(
        onTap: enabled ? () => widget.onOpenRoom(room) : null,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: LayoutBuilder(
            builder: (context, size) {
              final compact =
                  size.maxWidth >= 280 &&
                  MediaQuery.textScalerOf(context).scale(14) <= 18;
              final heading = Row(
                children: [
                  Icon(room.type.icon),
                  const SizedBox(width: 12),
                  Expanded(child: details()),
                ],
              );
              if (compact) {
                return Row(
                  children: [
                    Expanded(child: heading),
                    const SizedBox(width: 12),
                    SizedBox(
                      width: 122,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: actions(),
                      ),
                    ),
                  ],
                );
              }
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  heading,
                  const SizedBox(height: 12),
                  Wrap(spacing: 10, runSpacing: 8, children: actions()),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.isCurrent()) return const SizedBox.shrink();
    final rooms = widget.rooms
        .where(
          (r) =>
              !widget.savedPlacesOnly ||
              _saved.contains(r.id) ||
              _attention.contains(r.id) ||
              _connectedRooms.contains(r.id),
        )
        .toList();
    final cards = [for (final room in rooms) _card(room)];
    if (!widget.savedPlacesOnly) return Column(children: cards);
    if (!_loaded || (cards.isEmpty && !_connected)) {
      return const SizedBox.shrink();
    }
    return ExpansionTile(
      title: Text(context.tr('Saved place scans')),
      children: [
        ...cards,
        if (_connected)
          TextButton.icon(
            onPressed: widget.enabled ? widget.onConnected : null,
            icon: const Icon(Icons.home_work_outlined),
            label: Text(context.tr('View connected model')),
          ),
      ],
    );
  }
}
