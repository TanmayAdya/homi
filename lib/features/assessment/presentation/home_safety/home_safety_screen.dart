import 'package:flutter/material.dart';
import '../../../../shared/models/evidence.dart';
import 'home_safety_notes_dialog.dart';
import 'home_safety_report_screen.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../../../app/live_app.dart';
import '../../../../l10n/app_localizations.dart';
import '../../../../shared/models/case_draft.dart';
import '../../../../shared/presentation/sah_components.dart';
import '../../../../shared/presentation/sah_floating_nav.dart';
import '../../../../shared/services/matching_api_client.dart';
import '../../application/home_safety/home_safety_session.dart';
import '../../domain/assessment_location.dart';
import '../../domain/local_place_rooms.dart';
import '../../application/bathroom_scan_adapter.dart';
import '../../application/bathroom_scan_availability.dart';
import '../../domain/home_safety/home_safety.dart';
import '../live_assessment_screen.dart';
import '../room_scan_cards.dart';
import '../room_capture_cards.dart';
import '../assessment_location_guide.dart';
import '../whole_home_screen.dart';
import '../../../tracking/program_progress_screen.dart';
import '../../../local_help/local_help_screen.dart';
import '../../application/bathroom_scan_session.dart';
import '../../application/whole_home_session.dart';
import '../../domain/scan/bathroom_scan_scene.dart';
import '../bathroom_scan_screen.dart' show scanModeCopy;

class HomeSafetyScreen extends StatefulWidget {
  const HomeSafetyScreen({
    super.key,
    required this.services,
    this.catalog,
    this.scansFirst = false,
    this.workspaceMode = false,
    this.embedded = false,
    this.initialRoomId,
    this.onFindHelp,
  });
  final HomeSafetyCatalog? catalog;

  final ValueChanged<String?>? onFindHelp;
  final bool scansFirst;
  final bool workspaceMode;
  final bool embedded;
  final String? initialRoomId;
  final AppServices services;
  @override
  State<HomeSafetyScreen> createState() => HomeSafetyScreenState();
}

class HomeSafetyScreenState extends State<HomeSafetyScreen>
    with WidgetsBindingObserver {
  HomeSafetySession? session;
  late final scanAvailability = BathroomScanAvailability(
    adapter:
        widget.services.bathroomScanAdapter ??
        const NativeBathroomScanAdapter(),
    isCurrent: () => mounted && session?.isCurrent == true,
  );
  late Future<void> ready;
  String? selectedRoom, error;
  bool working = false;
  int scanEpoch = 0;
  int _roomSection = 0;
  String? _assistantFindingId;

  final Map<String, _RoomScan> _roomScans = {};
  final Set<String> _connectedRoomIds = {};
  bool _scansLoaded = false;
  int _scanLoad = 0;

  Future<void> _loadRoomScans() async {
    final s = session;
    if (s == null || !s.initialized) return;
    final token = ++_scanLoad;
    bool stale() => !mounted || !s.isCurrent || token != _scanLoad;
    final next = <String, _RoomScan>{};
    for (final room in s.document.rooms) {
      try {
        final review = await BathroomScanSession.readSaved(
          widget.services.store,
          s.caseId,
          room: room,
        );
        if (stale()) return;
        next[room.id] = review?.pendingScanId != null
            ? const _RoomScan(_ScanState.interrupted)
            : review?.scene != null
            ? _RoomScan(_ScanState.saved, review!.scene!.source)
            : const _RoomScan(_ScanState.none);
      } catch (_) {
        if (stale()) return;
        next[room.id] = const _RoomScan(_ScanState.attention);
      }
    }
    var connected = <String>{};
    try {
      connected = await WholeHomeSession.readSavedConnectedRoomIds(
        store: widget.services.store,
        caseId: s.caseId,
        rooms: s.document.activeRooms,
        isCurrent: () => !stale(),
      );
    } catch (_) {}
    if (stale()) return;
    setState(() {
      _roomScans
        ..clear()
        ..addAll(next);
      _connectedRoomIds
        ..clear()
        ..addAll(connected);
      _scansLoaded = true;
    });
  }

  void _scansChanged() {
    setState(() => scanEpoch++);
    _loadRoomScans();
  }

  bool get canLeave =>
      !working && session?.busy != true && session?.localSaveFailed != true;

  void openAssistantRoom(String id, {String? findingId}) {
    final s = session;
    if (!mounted ||
        !enabled ||
        !canLeave ||
        s == null ||
        !s.initialized ||
        !s.document.activeRooms.any((room) => room.id == id)) {
      return;
    }
    if (findingId != null &&
        !s.document.findingRooms.any(
          (f) => f.roomId == id && f.findingId == findingId,
        )) {
      return;
    }
    setState(() {
      selectedRoom = id;
      _roomSection = findingId == null ? 0 : 2;
      _assistantFindingId = findingId;
    });
  }

  void _selectRoom(String? id) => setState(() {
    selectedRoom = id;
    _roomSection = 0;
    _assistantFindingId = null;
  });

  bool handleBack() {
    if (!canLeave || !enabled) return true;
    if (selectedRoom == null) return false;
    _roomBack();
    return true;
  }

  void _roomBack() {
    if (_roomSection != 0) {
      setState(() {
        _roomSection = 0;
        _assistantFindingId = null;
      });
    } else {
      _selectRoom(null);
    }
  }

  Future<void> _syncIfReady() async {
    final s = session;
    if (widget.workspaceMode &&
        s != null &&
        s.isCurrent &&
        s.initialized &&
        s.hasPending &&
        !s.busy &&
        !s.offline &&
        !s.caseWriteBlocked &&
        s.conflict == null &&
        !s.needsReconcile &&
        !s.localSaveFailed) {
      await s.save();
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    selectedRoom = widget.initialRoomId;
    ready = initialize();
  }

  Future<void> initialize() async {
    final catalog = widget.catalog ?? await HomeSafetyCatalog.load();
    if (!mounted) return;
    final next = HomeSafetySession(services: widget.services, catalog: catalog);
    session = next;
    await next.initialize();
    scanAvailability.refresh();
    try {
      if (await next.recoverScanRoomLinks() > 0) await next.save();
    } catch (_) {
      if (mounted && next.isCurrent) {
        error =
            'Room scan concerns could not be linked yet. Saved work is retained.';
      }
    }
    await _loadRoomScans();
  }

  bool get enabled =>
      !working && session?.busy != true && session?.isCurrent == true;
  bool get editable =>
      enabled && session?.conflict == null && session?.needsReconcile == false;
  String roomTitle(RoomInstance r) => r.name ?? context.tr(r.type.title);
  Future<void> run(Future<void> Function() action) async {
    if (!enabled) return;
    setState(() {
      working = true;
      error = null;
    });
    try {
      await action();
      await _syncIfReady();
    } catch (e) {
      if (mounted) {
        setState(
          () => error =
              e is MatchingApiException && e.code == 'HOME_SAFETY_HISTORY_LIMIT'
              ? 'The checklist history limit has been reached. Existing work is retained.'
              : 'This step could not finish. Your saved device changes are retained. Check saved state before trying again.',
        );
      }
    } finally {
      if (mounted) setState(() => working = false);
    }
  }

  Future<void> changeRoomArchive(RoomInstance room) async {
    final accepted = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        scrollable: true,
        title: Text(ctx.tr(room.archived ? 'Restore room?' : 'Archive room?')),
        content: Text(
          ctx.tr(
            room.archived
                ? 'This returns the room to your active rooms with its saved scans and checklist history. Findings, tasks and reminders keep their current status.'
                : 'This hides the room from active rooms. Scans, checklist history and findings are retained. Linked tasks and reminders remain active until you change them separately. You can restore the room later.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(ctx.tr('Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              ctx.tr(room.archived ? 'Restore room' : 'Archive room'),
            ),
          ),
        ],
      ),
    );
    if (accepted != true || !mounted || !session!.isCurrent) return;
    await session!.edit({
      'type': room.archived ? 'restore_room' : 'archive_room',
      'roomId': room.id,
    });
    await session!.save();
    if (mounted) {
      setState(() => selectedRoom = null);
      _scansChanged();
    }
  }

  Future<void> deleteRoom(RoomInstance room) async {
    final s = session!;
    await s.save();
    if (s.hasPending || s.conflict != null || !mounted) return;
    final current = s.document.rooms.where((r) => r.id == room.id).firstOrNull;
    if (current == null || !current.archived) return;
    final model = await widget.services.scanModels?.read(
      s.caseId,
      room: current,
      isCurrent: () => mounted && s.isCurrent,
    );
    s.guard();
    if (!mounted) return;
    final accepted = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        scrollable: true,
        title: Text(ctx.tr('Delete room permanently?')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(roomTitle(current)),
            const SizedBox(height: 12),
            Text(
              ctx.tr(
                'This removes this room, its checklist answers and its 3D models on this phone and in your account. Existing findings, photos, linked tasks and reminders are kept. Findings will need a new room assignment.',
              ),
            ),
            const SizedBox(height: 12),
            Text(
              ctx.tr(
                'Connected models containing this room will also be cleared. Other rooms keep their individual scans.',
              ),
            ),
            const SizedBox(height: 12),
            Text(
              ctx.tr(
                'You cannot restore this room after deletion. Audit history and backups may retain earlier information. Other phones may retain downloaded models until they refresh.',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(ctx.tr('Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(ctx.tr('Delete room and scans')),
          ),
        ],
      ),
    );
    if (accepted != true || !mounted || !s.isCurrent) return;
    await s.edit({
      'type': 'delete_room',
      'roomId': room.id,
      'expectedModelRevision': model?.modelRevision ?? 0,
    });
    await s.save();
    if (mounted) {
      setState(() => selectedRoom = null);
      _scansChanged();
    }
  }

  Widget archiveAction(RoomInstance room) => TextButton.icon(
    key: ValueKey('archive-room-${room.id}'),
    onPressed: editable ? () => run(() => changeRoomArchive(room)) : null,
    icon: const Icon(Icons.archive_outlined),
    label: Text(context.tr('Archive room')),
  );

  List<Widget> archivedRooms(HomeSafetySession s) => [
    if (s.document.archivedRooms.isNotEmpty)
      ExpansionTile(
        key: const ValueKey('archived-rooms'),
        title: Text(context.tr('Archived rooms')),
        children: [
          for (final room in s.document.archivedRooms)
            ListTile(
              key: ValueKey('archived-room-${room.id}'),
              title: Text(roomTitle(room)),
              subtitle: Text(
                context.tr(
                  'Saved scans and history retained. Tasks and reminders remain active.',
                ),
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: enabled ? () => _selectRoom(room.id) : null,
            ),
        ],
      ),
  ];

  List<Widget> archivedRoom(HomeSafetySession s, RoomInstance room) => [
    Text(
      context.tr('Archived room'),
      style: Theme.of(context).textTheme.titleLarge,
    ),
    Text(
      context.tr(
        'Saved scans and history retained. Tasks and reminders remain active.',
      ),
    ),
    const SizedBox(height: 16),
    FilledButton.icon(
      key: ValueKey('restore-room-${room.id}'),
      onPressed: editable ? () => run(() => changeRoomArchive(room)) : null,
      icon: const Icon(Icons.unarchive_outlined),
      label: Text(context.tr('Restore room')),
    ),
    const SizedBox(height: 16),
    for (final link in s.document.findingRooms.where(
      (l) => l.roomId == room.id,
    ))
      for (final finding in s.snapshot.findings.where(
        (f) => f.id == link.findingId,
      ))
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(finding.observation),
                TextButton(
                  onPressed: enabled ? () => openFinding(finding.id) : null,
                  child: Text(context.tr('Review concern and evidence')),
                ),
                if (widget.services.config.trackingEnabled)
                  TextButton(
                    onPressed: enabled ? () => openTasks(finding.id) : null,
                    child: Text(context.tr('View or add next steps')),
                  ),
              ],
            ),
          ),
        ),
    const SizedBox(height: 16),
    TextButton.icon(
      key: ValueKey('delete-room-${room.id}'),
      onPressed: editable && !s.caseWriteBlocked
          ? () => run(() => deleteRoom(room))
          : null,
      icon: const Icon(Icons.delete_outline),
      label: Text(context.tr('Delete room permanently')),
    ),
  ];

  Future<void> roomDialog([RoomInstance? room]) async {
    final s = session!;
    final previousIds = s.document.rooms.map((r) => r.id).toSet();
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _RoomDialog(room: room, onSave: s.edit),
    );
    if (mounted && s.isCurrent) {
      _scansChanged();
      if (widget.workspaceMode && room == null) {
        final added = s.document.rooms
            .where((r) => !previousIds.contains(r.id))
            .firstOrNull;
        if (added != null) _selectRoom(added.id);
      }
      await run(_syncIfReady);
    }
  }

  Future<void> editNotes(RoomInstance room, SafetyQuestion question) async {
    final s = session!;
    EvidenceCatalog? evidence;
    try {
      evidence = await widget.services.exports.listEvidence(
        s.snapshot,
        currentCase: () {
          s.guard();
          return s.snapshot;
        },
        currentCatalog: () => null,
      );
    } on MatchingApiException catch (e) {
      if (!{
        'NETWORK_ERROR',
        'TIMEOUT',
        'SERVICE_UNAVAILABLE',
        'CASE_REVISION_MISMATCH',
      }.contains(e.code)) {
        rethrow;
      }
    }
    s.guard();
    if (!mounted) return;
    final prior = answerAnnotation(s.operations, room.id, question.id);
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => HomeSafetyNotesDialog(
        initial: prior,
        catalog: evidence,
        onSave: (note, refs) => s.edit({
          'type': 'annotate_answer',
          'roomId': room.id,
          'questionId': question.id,
          'answerRevision':
              s.document.answer(room.id, question.id)?.revision ?? 0,
          'note': note,
          'evidence': refs,
          'expectedCatalogRevision':
              evidence?.catalogRevision ??
              prior?['expectedCatalogRevision'] ??
              0,
        }),
      ),
    );
  }

  Future<void> legacyAssignment(String findingId) async {
    final s = session!,
        finding = session!.snapshot.findings.firstWhere(
          (f) => f.id == findingId,
        );
    final suggested = suggestedRooms(s.document, finding.room);
    final rooms = [
      ...suggested,
      ...s.document.activeRooms.where(
        (r) => !suggested.any((candidate) => candidate.id == r.id),
      ),
    ];
    final selected = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(ctx.tr('Confirm the room for this concern')),
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(finding.observation),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              ctx.tr(
                suggested.isEmpty
                    ? 'The room is unknown. Choose a room; no assignment is made automatically.'
                    : 'Suggested rooms use the original area only. Confirm the correct room.',
              ),
            ),
          ),
          for (final room in rooms)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, room.id),
              child: Text(roomTitle(room)),
            ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, '__add_room__'),
            child: Text(ctx.tr('Add a room')),
          ),
        ],
      ),
    );
    if (!mounted || !s.isCurrent || selected == null) return;
    if (selected == '__add_room__') {
      await roomDialog();
      if (mounted && s.isCurrent) await legacyAssignment(findingId);
    } else {
      await run(
        () => s.edit({
          'type': 'assign_finding',
          'roomId': selected,
          'findingId': findingId,
        }),
      );
    }
  }

  Widget questionNotes(
    HomeSafetySession s,
    RoomInstance room,
    SafetyQuestion question,
  ) {
    final note = answerAnnotation(s.operations, room.id, question.id);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (note?['note'] != null) Text(note!['note'] as String),
        if (note != null &&
            note['answerRevision'] !=
                (s.document.answer(room.id, question.id)?.revision ?? 0))
          Text(
            context.tr(
              'The answer changed. Review the saved note and photo references.',
            ),
          ),
        if ((note?['evidence'] as List? ?? []).isNotEmpty)
          Text(
            context.tr(
              '{count} saved photo references; refresh to check their current versions.',
              {'count': (note!['evidence'] as List).length},
            ),
          ),
        TextButton(
          key: ValueKey('question-notes-${question.id}'),
          onPressed: editable
              ? () => run(() => editNotes(room, question))
              : null,
          child: Text(context.tr('Notes and photo references')),
        ),
        ?questionActions(s, room, question),
      ],
    );
  }

  Future<void> review(RoomInstance room, SafetyQuestion q) async {
    final s = session!, answer = s.document.answer(room.id, q.id)!;
    final link = s.document.link(room.id, q.id);
    final finding = s.snapshot.findings
        .where((f) => f.id == link?.findingId)
        .firstOrNull;
    final findingId = link?.findingId ?? newUuidV4();
    final note =
        finding?.observation ??
        '${roomTitle(room)}: ${context.tr(q.prompt)} ${context.tr('Reported answer')}: ${context.tr(answerLabel(answer.value))}';
    Map<String, Object?> edit(Map<String, Object?> result) => {
      'type': 'review_concern',
      'roomId': room.id,
      'questionId': q.id,
      'findingId': findingId,
      ...result,
    };
    Map<String, Object?>? saved;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _ConcernDialog(
        observation: note,
        state: finding?.reviewState ?? 'needs_review',
        onSave: (result) async {
          await s.edit(edit(result));
          saved = result;
        },
      ),
    );
    if (!mounted || !s.isCurrent) return;
    await run(_syncIfReady);
    if (finding == null ||
        saved == null ||
        !mounted ||
        (saved!['state'] == finding.reviewState &&
            saved!['observation'] == finding.observation)) {
      return;
    }
    ScaffoldMessenger.maybeOf(context)
      ?..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.fixed,
          content: Text(context.tr('Concern updated')),
          action: SnackBarAction(
            label: context.tr('Undo'),
            onPressed: () {
              if (mounted && s.isCurrent) {
                run(
                  () => s.edit(
                    edit({
                      'observation': finding.observation,
                      'state': finding.reviewState,
                    }),
                  ),
                );
              }
            },
          ),
        ),
      );
  }

  Future<void> assign(RoomInstance room) async {
    final s = session!;
    final candidates = s.snapshot.findings
        .where((f) => !s.document.findingRooms.any((l) => l.findingId == f.id))
        .toList();
    final id = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(context.tr('Link an existing concern')),
        children: [
          for (final finding in candidates)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, finding.id),
              child: Text(finding.observation),
            ),
          if (candidates.isEmpty)
            Padding(
              padding: const EdgeInsets.all(24),
              child: Text(context.tr('No unassigned concerns.')),
            ),
        ],
      ),
    );
    if (id != null && mounted && s.isCurrent) {
      await run(
        () => s.edit({
          'type': 'assign_finding',
          'roomId': room.id,
          'findingId': id,
        }),
      );
    }
  }

  Future<void> openFinding(String id) => run(() async {
    final s = session!;
    await s.save();
    s.guard();
    if (s.hasPending || s.conflict != null || s.caseWriteBlocked || !mounted) {
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => LiveAssessmentScreen(
          services: widget.services,
          initialFindingId: id,
        ),
      ),
    );
    if (!mounted) return;
    s.guard();
    await s.refresh();
  });

  Future<void> openRoomScan(RoomInstance? room) => openRoomEvidence(
    room,
    scan: room?.type != AssessmentLocation.outdoorPaths,
  );

  Future<void> openRoomEvidence(
    RoomInstance? room, {
    bool scan = false,
    bool photo = true,
  }) => run(() async {
    final previous = session!;
    if (previous.hasPending &&
        !previous.offline &&
        !previous.caseWriteBlocked) {
      await previous.save();
      if (previous.conflict != null || previous.needsReconcile) return;
    }
    previous.guard();
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => LiveAssessmentScreen(
          services: widget.services,
          scanRoom: room,
          legacyScan: room == null,
          startWithRoomScan: scan,
          initialManualPhoto: photo,
        ),
      ),
    );
    if (!mounted || !previous.isCurrent) return;
    previous.dispose();
    setState(() {
      scanEpoch++;
      ready = initialize();
    });
    await ready;
  });

  Future<void> openHomeModel({bool localPlaces = false}) async {
    final s = session;
    if (s == null || !enabled || !s.isCurrent || s.localSaveFailed) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => WholeHomeScreen(
          services: widget.services,
          rooms: () => localPlaces ? LocalPlaceRooms.all : s.document.rooms,
          isCurrent: () => mounted && s.isCurrent,
          scope: Listenable.merge([s, widget.services.coordinator]),
          localPlaces: localPlaces,
        ),
      ),
    );
    if (mounted && s.isCurrent) _scansChanged();
  }

  Widget homeModelEntry() => OutlinedButton.icon(
    key: const ValueKey('open-whole-home-model'),
    onPressed: enabled ? openHomeModel : null,
    icon: const Icon(Icons.home_work_outlined),
    label: Text(context.tr('Scan connected rooms')),
  );

  Future<void> openReport() => run(() async {
    final s = session!;
    await s.save();
    s.guard();
    if (!mounted || s.hasPending || s.conflict != null || s.caseWriteBlocked) {
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) =>
            HomeSafetyReportScreen(services: widget.services, session: s),
      ),
    );
    if (mounted && s.isCurrent) await s.refresh();
  });
  Future<void> openTasks(String id) => run(() async {
    final s = session!;
    await s.save();
    s.guard();
    if (s.hasPending || s.conflict != null || s.caseWriteBlocked || !mounted) {
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ProgramProgressScreen(
          services: widget.services,
          tasksFirst: true,
          findingId: id,
        ),
      ),
    );
    if (!mounted) return;
    s.guard();
    await s.refresh();
  });

  Future<void> reportAddressed(FindingRoom link, bool addressed) async {
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        scrollable: true,
        title: Text(
          context.tr(addressed ? 'Mark concern addressed?' : 'Reopen concern?'),
        ),
        content: Text(
          context.tr(
            'This records your report only. It does not verify a repair or certify home safety. Completing a next step does not automatically address a concern.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(context.tr('Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(
              context.tr(addressed ? 'Mark addressed' : 'Reopen concern'),
            ),
          ),
        ],
      ),
    );
    if (accepted == true && mounted) {
      await run(() => session!.setAddressed(link, addressed));
    }
  }

  String progressText(HomeSafetySession s, RoomInstance room) {
    final progress = roomConcernProgress(
      s.document,
      s.snapshot,
      s.catalog,
      room,
      s.operations,
      evidenceCatalogRevision: s.baseline.evidenceCatalogRevision,
    );
    return context.tr('{count} of {total} concerns addressed', {
      'count': progress.addressed,
      'total': progress.concerns,
    });
  }

  Widget concernActions(HomeSafetySession s, FindingRoom link) {
    final addressed = concernIsAddressed(
      s.document,
      s.snapshot,
      link,
      s.operations,
      evidenceCatalogRevision: s.baseline.evidenceCatalogRevision,
    );
    final priorReport = s.operations
        .where(
          (o) =>
              o['type'] == 'set_addressed' && o['findingId'] == link.findingId,
        )
        .lastOrNull;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (priorReport?['addressed'] == true && !addressed)
          Text(
            context.tr(
              'This concern or its photos changed. Review it before reporting it addressed again.',
            ),
          ),
        if (widget.services.config.trackingEnabled)
          TextButton(
            key: ValueKey('concern-tasks-${link.findingId}'),
            onPressed: editable && !s.caseWriteBlocked
                ? () => openTasks(link.findingId)
                : null,
            child: Text(context.tr('View or add next steps')),
          ),
        if (addressed) Text(context.tr('Addressed - reported by you')),
        if (addressed || canReportAddressed(s.document, s.snapshot, link))
          TextButton(
            key: ValueKey('concern-addressed-${link.findingId}'),
            onPressed: editable
                ? () => reportAddressed(link, !addressed)
                : null,
            child: Text(
              context.tr(addressed ? 'Reopen concern' : 'Mark addressed'),
            ),
          ),
      ],
    );
  }

  Widget? questionActions(
    HomeSafetySession s,
    RoomInstance room,
    SafetyQuestion question,
  ) {
    final link = s.document.link(room.id, question.id);
    return link != null &&
            s.snapshot.findings.any((f) => f.id == link.findingId)
        ? concernActions(s, link)
        : null;
  }

  Future<void> resolve(bool keepDevice) async {
    final s = session!, fresh = s.conflict!;
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.tr('Review device and saved changes')),
        content: SizedBox(
          width: 480,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  context.tr(
                    keepDevice
                        ? 'Apply the device changes below to the latest saved version? You will still need to save online.'
                        : 'Use the saved version and discard these device changes?',
                  ),
                ),
                for (final request in s.pending)
                  Padding(
                    padding: const EdgeInsets.only(top: 16),
                    child: _ConflictChange(
                      operation: request.operation,
                      device: s.document,
                      saved: fresh.document,
                      deviceSnapshot: s.snapshot.toJson(),
                      savedSnapshot: fresh.snapshot.toJson(),
                      catalog: s.catalog,
                      savedOperations: fresh.history
                          .map(
                            (e) => Map<String, Object?>.from(
                              e['operation'] as Map,
                            ),
                          )
                          .toList(),
                    ),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(context.tr('Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(
              context.tr(
                keepDevice
                    ? 'Keep device changes for review'
                    : 'Use saved checklist',
              ),
            ),
          ),
        ],
      ),
    );
    if (accepted == true && mounted && s.isCurrent) {
      await run(() => s.resolve(keepDevice: keepDevice));
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    scanAvailability.dispose();
    session?.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && enabled) {
      scanAvailability.refresh();
    }
  }

  Widget _page({required Widget body, required AppBar appBar}) =>
      widget.embedded
      ? body
      : Scaffold(
          appBar: appBar,
          body: SafeArea(child: body),
        );

  String _count(int n, String one, String many) =>
      n == 1 ? context.tr(one) : context.tr(many, {'count': n});

  Widget _saveStatus(HomeSafetySession s) {
    final (label, state) = s.localSaveFailed
        ? ('Not saved on this device', SahSaveState.problem)
        : working || s.busy
        ? ('Saving…', SahSaveState.saving)
        : s.hasPending
        ? ('Waiting to sync', SahSaveState.waiting)
        : ('Saved', SahSaveState.saved);
    return SahStatusLine(
      key: const ValueKey('rooms-save-status'),
      label: context.tr(label),
      state: state,
    );
  }

  bool _canSync(HomeSafetySession s) =>
      s.hasPending &&
      !s.offline &&
      !s.caseWriteBlocked &&
      s.conflict == null &&
      !s.needsReconcile &&
      !s.localSaveFailed;

  Widget _syncRetry(HomeSafetySession s) => TextButton.icon(
    key: const ValueKey('rooms-sync'),
    onPressed: editable && !s.caseWriteBlocked ? () => run(s.save) : null,
    icon: const Icon(Icons.cloud_upload_outlined),
    label: Text(context.tr('Save checklist online')),
  );

  List<Widget> _header(HomeSafetySession s, RoomInstance? room) {
    if (room == null) {
      return [
        SahPageHeader(title: context.tr('Rooms'), trailing: _saveStatus(s)),
      ];
    }
    final overview = _roomSection == 0;
    return [
      if (widget.embedded)
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: TextButton.icon(
            key: const ValueKey('rooms-back'),
            onPressed: enabled && canLeave ? handleBack : null,
            icon: const Icon(Icons.arrow_back),
            label: Text(context.tr('Back')),
          ),
        ),
      SahPageHeader(
        title: overview
            ? roomTitle(room)
            : context.tr(
                _roomSection == 1 ? 'Room questions' : 'Concerns and evidence',
              ),
        description: !overview
            ? roomTitle(room)
            : room.name != null
            ? context.tr(room.type.title)
            : null,
        trailing: Row(
          children: [
            Expanded(child: _saveStatus(s)),
            if (overview && !room.archived) _roomMenu(s, room),
          ],
        ),
      ),
    ];
  }

  Widget _roomMenu(HomeSafetySession s, RoomInstance room) =>
      PopupMenuButton<String>(
        key: ValueKey('room-menu-${room.id}'),
        tooltip: context.tr('Room options'),
        enabled: editable,
        icon: const Icon(Icons.more_horiz),
        onSelected: (value) {
          if (value == 'rename') {
            roomDialog(room);
          } else if (value == 'archive') {
            run(() => changeRoomArchive(room));
          } else if (value == 'report') {
            openReport();
          }
        },
        itemBuilder: (ctx) => [
          PopupMenuItem(
            key: ValueKey('rename-room-${room.id}'),
            value: 'rename',
            child: Text(ctx.tr('Rename room')),
          ),
          PopupMenuItem(
            key: ValueKey('archive-room-${room.id}'),
            value: 'archive',
            child: Text(ctx.tr('Archive room')),
          ),
          if (!s.caseWriteBlocked)
            PopupMenuItem(
              key: ValueKey('room-report-${room.id}'),
              value: 'report',
              child: Text(ctx.tr('Room and checklist report')),
            ),
        ],
      );

  _RoomFacts _facts(HomeSafetySession s, RoomInstance room) {
    final questions = s.catalog.forRoom(room);
    var answered = 0, fromAnswers = 0;
    for (final q in questions) {
      final answer = s.document.answer(room.id, q.id);
      if (answer != null && answer.value != 'unanswered') answered++;
      if (answer?.value == q.concernWhen &&
          s.document.link(room.id, q.id) == null) {
        fromAnswers++;
      }
    }
    final toReview = <String>[], kept = <String>[];
    var addressed = 0;
    for (final link in s.document.findingRooms.where(
      (l) => l.roomId == room.id,
    )) {
      final finding = s.snapshot.findings
          .where((f) => f.id == link.findingId)
          .firstOrNull;
      if (finding == null || finding.reviewState == 'dismissed') continue;
      if (finding.reviewState != 'confirmed') {
        toReview.add(finding.id);
      } else if (concernIsAddressed(
        s.document,
        s.snapshot,
        link,
        s.operations,
        evidenceCatalogRevision: s.baseline.evidenceCatalogRevision,
      )) {
        addressed++;
      } else {
        kept.add(finding.id);
      }
    }
    return _RoomFacts(
      toReview: toReview,
      kept: kept,
      addressed: addressed,
      fromAnswers: fromAnswers,
      answered: answered,
      questions: questions.length,
    );
  }

  String _roomStatus(HomeSafetySession s, RoomInstance room) {
    final f = _facts(s, room);
    final scan = _roomScans[room.id]?.state;
    final scanned = scan == _ScanState.saved;
    if (f.suggested > 0) {
      final text = _count(
        f.suggested,
        '1 suggested concern to review',
        '{count} suggested concerns to review',
      );
      return scanned ? '$text · ${context.tr('Scanned')}' : text;
    }
    if (scan == _ScanState.interrupted) {
      return context.tr('Interrupted scan · saved work retained');
    }
    if (scan == _ScanState.attention) {
      return context.tr('Saved scan needs attention');
    }
    final parts = [
      if (scanned)
        context.tr('Scanned')
      else if (_connectedRoomIds.contains(room.id))
        context.tr('In connected model'),
      if (f.kept.isNotEmpty)
        _count(f.kept.length, '1 concern', '{count} concerns'),
      if (f.addressed > 0)
        _count(
          f.addressed,
          '1 reported addressed',
          '{count} reported addressed',
        ),
    ];
    if (parts.isNotEmpty) return parts.join(' · ');
    if (f.answered > 0) return context.tr('Questions started');
    return context.tr(_scansLoaded ? 'Not started' : 'Checking saved scans');
  }

  bool get _canFindHelp =>
      widget.onFindHelp != null || widget.services.config.localHelpEnabled;

  void _findHelp(String? findingId) {
    if (!enabled || !canLeave) return;
    if (widget.onFindHelp != null) {
      widget.onFindHelp!(findingId);
      return;
    }
    final coordinator = widget.services.coordinator;
    if (coordinator.busy || coordinator.hasUndurableEdits) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) =>
            LocalHelpScreen(services: widget.services, findingId: findingId),
      ),
    );
  }

  void _openConcerns([String? findingId]) => setState(() {
    _roomSection = 2;
    _assistantFindingId = findingId;
  });

  void _openQuestions() => setState(() {
    _roomSection = 1;
    _assistantFindingId = null;
  });

  _NextStep? _nextStep(HomeSafetySession s, RoomInstance room, _RoomFacts f) {
    final outdoor = room.type == AssessmentLocation.outdoorPaths;
    final scan = _roomScans[room.id]?.state;
    final capability = scanAvailability.capabilities;
    final canScan =
        !outdoor && (capability == null || capability.canRequestCapture);
    final scanTap = editable ? () => openRoomScan(room) : null;
    final suggested = _count(
      f.suggested,
      '1 suggested concern to review',
      '{count} suggested concerns to review',
    );
    if (scan == _ScanState.interrupted && !outdoor) {
      return _NextStep(
        id: 'room-start-assessment',
        title: context.tr('Your scan didn’t finish'),
        message: context.tr(
          'Your saved work is kept. Try again in good light, or use photos.',
        ),
        action: context.tr('Scan this room'),
        onTap: scanTap,
      );
    }
    if (f.toReview.isNotEmpty) {
      return _NextStep(
        id: 'room-next-review',
        title: suggested,
        message: context.tr(
          'Keep the ones that are real. You can change this later.',
        ),
        action: context.tr('Review concerns'),
        onTap: enabled ? () => _openConcerns(f.toReview.first) : null,
      );
    }
    if (f.fromAnswers > 0) {
      return _NextStep(
        id: 'room-review-answers',
        title: suggested,
        message: context.tr(
          'Your answers point to a possible concern. Review it before adding it to your assessment.',
        ),
        action: context.tr('Review concerns'),
        onTap: enabled ? _openQuestions : null,
      );
    }
    final started = scan == _ScanState.saved || f.answered > 0;
    if (!started && canScan) {
      final mode = scanModeCopy(capability);
      return _NextStep(
        id: 'room-start-assessment',
        title: context.tr('Scan this room'),
        message:
            '${context.tr(mode.$1)}. ${context.tr('Takes about 1–3 minutes.')}',
        action: context.tr('Scan this room'),
        onTap: scanTap,
        secondary: TextButton(
          key: const ValueKey('room-next-questions'),
          onPressed: enabled ? _openQuestions : null,
          child: Text(context.tr('Answer questions instead')),
        ),
      );
    }
    if (!started) {
      return _NextStep(
        id: 'room-next-questions',
        title: context.tr('Answer {count} quick questions', {
          'count': f.questions,
        }),
        message: context.tr(
          outdoor
              ? 'Outdoor areas use photos and measurements.'
              : scanModeCopy(capability).$2,
        ),
        action: context.tr('Answer questions'),
        onTap: enabled ? _openQuestions : null,
      );
    }
    if (f.kept.isNotEmpty && _canFindHelp) {
      return _NextStep(
        id: 'room-find-help',
        title: context.tr('Find help for these concerns'),
        message: _count(
          f.kept.length,
          '1 concern kept in this room.',
          '{count} concerns kept in this room.',
        ),
        action: context.tr('Find help'),
        onTap: enabled ? () => _findHelp(f.kept.first) : null,
      );
    }
    final next = s.document.activeRooms
        .where(
          (r) =>
              r.id != room.id &&
              _roomScans[r.id]?.state != _ScanState.saved &&
              _facts(s, r).answered == 0,
        )
        .firstOrNull;
    if (next == null) return null;
    return _NextStep(
      id: 'room-next-room',
      title: context.tr(
        f.kept.isEmpty ? 'No concerns here so far' : 'Next room',
      ),
      message: context.tr('Next: {room}', {'room': roomTitle(next)}),
      action: context.tr('Open {room}', {'room': roomTitle(next)}),
      onTap: enabled ? () => _selectRoom(next.id) : null,
    );
  }

  Widget _stepCard(_NextStep step) => SahNextStepCard(
    key: const ValueKey('room-next-step'),
    title: step.title,
    message: step.message,
    actionLabel: step.action,
    actionKey: ValueKey(step.id),
    onAction: step.onTap,
    secondary: step.secondary,
  );

  List<Widget> _forward(
    HomeSafetySession s,
    RoomInstance room,
    Set<String> here,
  ) {
    final step = _nextStep(s, room, _facts(s, room));
    return [
      const SizedBox(height: 8),
      if (step != null && !here.contains(step.id)) _stepCard(step),
      OutlinedButton(
        key: const ValueKey('room-return-overview'),
        onPressed: enabled
            ? () => setState(() {
                _roomSection = 0;
                _assistantFindingId = null;
              })
            : null,
        child: Text(
          context.tr('Done — back to {room}', {'room': roomTitle(room)}),
        ),
      ),
    ];
  }

  List<Widget> _notices(HomeSafetySession s) => [
    if (error != null)
      SahNotice(
        message: context.tr(error!),
        tone: SahNoticeTone.warning,
        action: widget.workspaceMode && _canSync(s) ? _syncRetry(s) : null,
      )
    else if (widget.workspaceMode && _canSync(s) && !working && !s.busy)
      SahNotice(
        title: context.tr('Not synced yet'),
        message: context.tr(
          'Some checklist changes are saved on this phone but have not reached your account yet.',
        ),
        tone: SahNoticeTone.warning,
        action: _syncRetry(s),
      ),
    if (s.localSaveFailed)
      SahNotice(
        message: context.tr(
          'The device save failed. Keep this screen open and try again.',
        ),
        tone: SahNoticeTone.error,
      ),
    if (s.offline)
      SahNotice(
        message: context.tr(
          'Your checklist is saved on this device. Online saving is unavailable right now. You can keep working here.',
        ),
      ),
    if (s.caseWriteBlocked)
      SahNotice(
        message: context.tr(
          'Resident details have unsaved changes. You can continue the checklist here; resolve those details before syncing.',
        ),
      ),
    if (s.conflict != null) ...[
      SahNotice(
        message: context.tr(
          'This device and the saved checklist differ. Review both before continuing.',
        ),
        tone: SahNoticeTone.warning,
      ),
      if (s.pendingRoomDeletion)
        Text(
          context.tr(
            'Use the saved checklist, then reopen the archived room to review deletion again.',
          ),
        )
      else
        OutlinedButton(
          onPressed: enabled ? () => resolve(true) : null,
          child: Text(context.tr('Keep device changes for review')),
        ),
      TextButton(
        onPressed: enabled ? () => resolve(false) : null,
        child: Text(context.tr('Use saved checklist')),
      ),
    ] else if (s.needsReconcile)
      OutlinedButton(
        onPressed: enabled ? () => run(s.refresh) : null,
        child: Text(context.tr('Check saved state')),
      ),
    if (!widget.workspaceMode) ...[
      _saveStatus(s),
      if (s.hasPending)
        FilledButton.icon(
          key: const ValueKey('rooms-sync'),
          onPressed: editable && !s.caseWriteBlocked ? () => run(s.save) : null,
          icon: const Icon(Icons.cloud_upload_outlined),
          label: Text(context.tr('Save checklist online')),
        ),
    ],
    const SizedBox(height: 8),
  ];

  @override
  Widget build(BuildContext context) => FutureBuilder<void>(
    future: ready,
    builder: (context, loading) {
      final s = session;
      if (loading.hasError) {
        return _page(
          appBar: AppBar(
            title: Text(
              context.tr(
                widget.workspaceMode
                    ? 'Rooms'
                    : widget.scansFirst
                    ? 'Room scans'
                    : 'Rooms and checklist',
              ),
            ),
          ),
          body: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              context.tr(
                'The checklist could not be opened. Existing device changes have been kept. Reopen the case to try again.',
              ),
            ),
          ),
        );
      }
      if (loading.connectionState != ConnectionState.done || s == null) {
        return _page(
          appBar: AppBar(
            title: Text(
              context.tr(
                widget.workspaceMode
                    ? 'Rooms'
                    : widget.scansFirst
                    ? 'Room scans'
                    : 'Rooms and checklist',
              ),
            ),
          ),
          body: const Center(child: CircularProgressIndicator()),
        );
      }
      return AnimatedBuilder(
        animation: Listenable.merge([s, scanAvailability]),
        builder: (context, _) {
          final room = s.document.rooms
              .where((r) => r.id == selectedRoom)
              .firstOrNull;
          return PopScope(
            canPop: widget.embedded || (room == null && canLeave),
            onPopInvokedWithResult: (popped, result) {
              if (!widget.embedded && !popped && room != null && enabled) {
                _roomBack();
              }
            },
            child: _page(
              appBar: AppBar(
                title: Text(
                  room == null
                      ? context.tr(
                          widget.workspaceMode
                              ? 'Rooms'
                              : widget.scansFirst
                              ? 'Room scans'
                              : 'Rooms and checklist',
                        )
                      : roomTitle(room),
                ),
                leading: BackButton(
                  onPressed: enabled && canLeave
                      ? () {
                          if (room != null) {
                            _roomBack();
                          } else {
                            Navigator.pop(context);
                          }
                        }
                      : null,
                ),
                actions: [
                  IconButton(
                    tooltip: context.tr('Room and checklist report'),
                    onPressed: editable && !s.caseWriteBlocked
                        ? openReport
                        : null,
                    icon: const Icon(Icons.picture_as_pdf_outlined),
                  ),
                  IconButton(
                    tooltip: context.tr('Check saved state'),
                    onPressed: enabled ? () => run(s.refresh) : null,
                    icon: const Icon(Icons.refresh),
                  ),
                ],
              ),
              body: Align(
                alignment: Alignment.topCenter,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 720),
                  child: ListView(
                    key: widget.workspaceMode
                        ? ValueKey('room-page-${room?.id}-$_roomSection')
                        : null,
                    padding: widget.embedded
                        ? sahFloatingContentPadding(context)
                        : const EdgeInsets.all(20),
                    children: [
                      if (widget.workspaceMode) ..._header(s, room),
                      if (!widget.workspaceMode &&
                          (!widget.scansFirst || room != null)) ...[
                        Text(
                          context.tr(
                            'Home safety questions adapted from CDC STEADI. This is not a clinical fall-risk score or a safety certification.',
                          ),
                        ),
                        TextButton(
                          onPressed: enabled
                              ? () => run(() async {
                                  if (!await launchUrl(
                                    Uri.parse(s.catalog.sourceUrl),
                                    mode: LaunchMode.externalApplication,
                                  )) {
                                    {
                                      throw StateError('Source unavailable.');
                                    }
                                  }
                                })
                              : null,
                          child: Text(context.tr('View CDC source (2017)')),
                        ),
                        Text(
                          context.tr(
                            'Checklist translations are provided by the app; they are not official CDC translations.',
                          ),
                        ),
                      ],
                      ..._notices(s),
                      if (room?.archived == true) ...[
                        ...archivedRoom(s, room!),
                      ] else if (widget.workspaceMode && room != null) ...[
                        if (_roomSection == 0)
                          ...roomOverview(s, room)
                        else if (_roomSection == 1)
                          ...roomQuestions(s, room)
                        else
                          ...roomConcerns(s, room),
                      ] else if (room == null && widget.scansFirst) ...[
                        FilledButton.icon(
                          key: const ValueKey('rooms-add'),
                          onPressed: editable && s.document.rooms.length < 32
                              ? roomDialog
                              : null,
                          icon: const Icon(Icons.add),
                          label: Text(context.tr('Add a room')),
                        ),
                        const SizedBox(height: 16),
                        homeModelEntry(),
                        RoomScanCards(
                          key: ValueKey('room-scans-$scanEpoch'),
                          store: widget.services.store,
                          caseId: s.caseId,
                          rooms: s.document.activeRooms,
                          isCurrent: () => mounted && s.isCurrent,
                          enabled: editable,
                          onOpen: openRoomScan,
                          onChecklist: (r) => _selectRoom(r.id),
                          onArchive: (r) => run(() => changeRoomArchive(r)),
                        ),
                        ...archivedRooms(s),
                      ] else if (room == null)
                        ...roomList(s)
                      else
                        ...roomChecklist(s, room),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      );
    },
  );

  Widget _roomRow(HomeSafetySession s, RoomInstance room) => SahActionTile(
    key: ValueKey('room-${room.id}'),
    title: roomTitle(room),
    subtitle: _roomStatus(s, room),
    icon: room.type.icon,
    onTap: enabled ? () => _selectRoom(room.id) : null,
  );

  List<Widget> roomList(HomeSafetySession s) {
    final active = s.document.activeRooms;
    bool outside(RoomInstance r) => r.type == AssessmentLocation.outdoorPaths;
    final unassigned = s.snapshot.findings
        .where((f) => !s.document.findingRooms.any((l) => l.findingId == f.id))
        .toList();
    return [
      if (unassigned.isNotEmpty)
        SahListGroup(
          title: context.tr('Concerns that need a room'),
          children: [
            for (final finding in unassigned)
              SahActionTile(
                title: finding.observation,
                subtitle: context.tr('Room assignment needs confirmation'),
                icon: Icons.room_outlined,
                onTap: editable ? () => legacyAssignment(finding.id) : null,
              ),
          ],
        ),
      if (active.isEmpty)
        SahEmptyState(
          title: context.tr('Add the rooms you want to check'),
          message: context.tr(
            'Add each room separately, including rooms of the same type. Photos are optional.',
          ),
          icon: Icons.meeting_room_outlined,
        ),
      if (active.any((r) => !outside(r)))
        SahListGroup(
          title: context.tr('Inside'),
          children: [
            for (final room in active.where((r) => !outside(r)))
              _roomRow(s, room),
          ],
        ),
      if (active.any(outside))
        SahListGroup(
          title: context.tr('Outside'),
          children: [
            for (final room in active.where(outside)) _roomRow(s, room),
          ],
        ),
      if (active.isEmpty)
        FilledButton.icon(
          key: const ValueKey('rooms-add'),
          onPressed: editable && s.document.rooms.length < 32
              ? roomDialog
              : null,
          icon: const Icon(Icons.add),
          label: Text(context.tr('Add a room')),
        )
      else
        OutlinedButton.icon(
          key: const ValueKey('rooms-add'),
          onPressed: editable && s.document.rooms.length < 32
              ? roomDialog
              : null,
          icon: const Icon(Icons.add),
          label: Text(context.tr('Add a room')),
        ),
      Align(
        alignment: AlignmentDirectional.centerStart,
        child: TextButton.icon(
          key: const ValueKey('open-whole-home-model'),
          onPressed: enabled ? openHomeModel : null,
          icon: const Icon(Icons.home_work_outlined),
          label: Text(context.tr('Scan connected rooms')),
        ),
      ),
      if (widget.workspaceMode)
        RoomScanCards(
          key: ValueKey('legacy-scans-$scanEpoch'),
          store: widget.services.store,
          caseId: s.caseId,
          rooms: const [],
          isCurrent: () => mounted && s.isCurrent,
          enabled: editable,
          onOpen: openRoomScan,
          onChecklist: (r) => _selectRoom(r.id),
          compact: true,
        ),
      RoomCaptureCards(
        key: ValueKey('saved-place-cards-${s.caseId}-$scanEpoch'),
        store: widget.services.store,
        caseId: s.caseId,
        rooms: LocalPlaceRooms.all,
        availability: scanAvailability,
        isCurrent: () => mounted && s.isCurrent,
        enabled: editable,
        onScan: openRoomScan,
        onOpenRoom: (room) => openRoomEvidence(room),
        savedPlacesOnly: true,
        onConnected: () => openHomeModel(localPlaces: true),
      ),
      ...archivedRooms(s),
      if (widget.embedded)
        Wrap(
          spacing: 8,
          children: [
            TextButton.icon(
              onPressed: editable && !s.caseWriteBlocked ? openReport : null,
              icon: const Icon(Icons.picture_as_pdf_outlined),
              label: Text(context.tr('Room and checklist report')),
            ),
            TextButton.icon(
              onPressed: enabled ? () => run(s.refresh) : null,
              icon: const Icon(Icons.refresh),
              label: Text(context.tr('Check saved state')),
            ),
          ],
        ),
    ];
  }

  String _findingStatus(HomeSafetySession s, FindingRoom link, String state) {
    if (state != 'confirmed') return context.tr('Needs your review');
    return context.tr(
      concernIsAddressed(
            s.document,
            s.snapshot,
            link,
            s.operations,
            evidenceCatalogRevision: s.baseline.evidenceCatalogRevision,
          )
          ? 'Addressed - reported by you'
          : 'Confirmed by you',
    );
  }

  List<Widget> roomOverview(HomeSafetySession s, RoomInstance room) {
    final f = _facts(s, room);
    final step = _nextStep(s, room, f);
    final outdoor = room.type == AssessmentLocation.outdoorPaths;
    final scan = _roomScans[room.id];
    final lidar =
        scan?.state == _ScanState.saved && scan?.source == ScanSource.roomplan;
    final concerns = [
      for (final link in s.document.findingRooms.where(
        (l) => l.roomId == room.id,
      ))
        for (final finding in s.snapshot.findings.where(
          (f) => f.id == link.findingId && f.reviewState != 'dismissed',
        ))
          (link, finding),
    ];
    return [
      if (step != null) _stepCard(step),
      if (!outdoor)
        SahListGroup(
          title: context.tr('Scan'),
          children: [
            SahActionTile(
              key: ValueKey('open-room-scan-${room.id}'),
              title: context.tr(switch (scan?.state) {
                _ScanState.saved => 'View room model',
                null => 'Checking saved scans',
                _ScanState.none => 'Scan this room',
                _ => 'Open room scan',
              }),
              subtitle: context.tr(switch (scan?.state) {
                _ScanState.saved when lidar =>
                  '3D scan · sizes are estimates. Check important sizes with a tape measure.',
                _ScanState.saved =>
                  'Camera scan · rough surfaces only. Label what matters.',
                _ScanState.interrupted =>
                  'Interrupted scan · saved work retained',
                _ScanState.attention => 'Saved scan needs attention',
                _ => scanModeCopy(scanAvailability.capabilities).$1,
              }),
              icon: Icons.view_in_ar,
              onTap: editable ? () => openRoomScan(room) : null,
            ),
            if (_connectedRoomIds.contains(room.id))
              SahActionTile(
                key: ValueKey('connected-room-${room.id}'),
                title: context.tr('View connected model'),
                icon: Icons.home_work_outlined,
                onTap: enabled ? openHomeModel : null,
              ),
          ],
        ),
      SahListGroup(
        title: context.tr('Concerns'),
        children: [
          for (final (link, finding) in concerns)
            SahActionTile(
              key: ValueKey('room-concern-${finding.id}'),
              title: finding.observation,
              subtitle: _findingStatus(s, link, finding.reviewState),
              icon: finding.reviewState == 'confirmed'
                  ? Icons.report_outlined
                  : Icons.help_outline,
              onTap: enabled ? () => _openConcerns(finding.id) : null,
            ),
          if (f.fromAnswers > 0)
            SahActionTile(
              key: const ValueKey('room-possible-concerns'),
              title: _count(
                f.fromAnswers,
                '1 possible concern from your answers',
                '{count} possible concerns from your answers',
              ),
              subtitle: context.tr('Review before adding to your assessment.'),
              icon: Icons.help_outline,
              onTap: enabled ? _openQuestions : null,
            ),
          SahActionTile(
            key: const ValueKey('room-concerns'),
            title: context.tr('Concerns and evidence'),
            subtitle: context.tr(
              concerns.isEmpty && f.fromAnswers == 0
                  ? 'None yet. Concerns come from your scan, your answers, or you.'
                  : 'Report addressed, add next steps, or link an existing concern.',
            ),
            icon: Icons.fact_check_outlined,
            onTap: enabled ? _openConcerns : null,
          ),
        ],
      ),
      SahListGroup(
        title: context.tr('More about this room'),
        children: [
          SahActionTile(
            key: const ValueKey('room-continue-questions'),
            title: context.tr('Questions'),
            subtitle: f.answered > 0
                ? context.tr('{count} of {total} answered', {
                    'count': f.answered,
                    'total': f.questions,
                  })
                : context.tr('Optional · {count} quick questions', {
                    'count': f.questions,
                  }),
            icon: Icons.checklist_rounded,
            onTap: enabled ? _openQuestions : null,
          ),
          SahActionTile(
            key: const ValueKey('room-add-photo'),
            title: context.tr('Photos'),
            subtitle: context.tr(
              'Optional · add a photo of anything you notice',
            ),
            icon: Icons.add_a_photo_outlined,
            onTap: editable ? () => openRoomEvidence(room) : null,
          ),
          SahActionTile(
            key: const ValueKey('room-enter-measurement'),
            title: context.tr('Measurements'),
            subtitle: context.tr(
              lidar
                  ? 'Scan sizes are estimates · add your own any time'
                  : 'Optional · measured by you',
            ),
            icon: Icons.straighten,
            onTap: editable ? () => openRoomEvidence(room, photo: false) : null,
          ),
        ],
      ),
    ];
  }

  Widget questionCard(
    HomeSafetySession s,
    RoomInstance room,
    SafetyQuestion q,
  ) => _QuestionCard(
    question: q,
    answer: s.document.answer(room.id, q.id),
    link: s.document.link(room.id, q.id),
    findingPresent: s.snapshot.findings.any(
      (f) => f.id == s.document.link(room.id, q.id)?.findingId,
    ),
    editable: editable,
    onAnswer: (value) => run(
      () => s.edit({
        'type': 'answer',
        'roomId': room.id,
        'questionId': q.id,
        'value': value,
      }),
    ),
    onReview: () => review(room, q),
    onPhoto: () => openFinding(s.document.link(room.id, q.id)!.findingId),
    onlineReady: editable && !s.caseWriteBlocked,
    followUp: questionNotes(s, room, q),
  );

  List<Widget> roomQuestions(HomeSafetySession s, RoomInstance room) => [
    Text(
      context.tr(
        'Choose Not applicable for features this room does not have. Not sure and unanswered remain unknown.',
      ),
    ),
    const SizedBox(height: 16),
    for (final q in s.catalog.forRoom(room)) questionCard(s, room, q),
    ..._forward(s, room, const {'room-next-questions', 'room-review-answers'}),
    ExpansionTile(
      title: Text(context.tr('About these questions')),
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            context.tr(
              'Home safety questions adapted from CDC STEADI. This is not a clinical fall-risk score or a safety certification.',
            ),
          ),
        ),
        TextButton(
          onPressed: enabled
              ? () => run(() async {
                  if (!await launchUrl(
                    Uri.parse(s.catalog.sourceUrl),
                    mode: LaunchMode.externalApplication,
                  )) {
                    throw StateError('Source unavailable.');
                  }
                })
              : null,
          child: Text(context.tr('View CDC source (2017)')),
        ),
        Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            context.tr(
              'Checklist translations are provided by the app; they are not official CDC translations.',
            ),
          ),
        ),
      ],
    ),
  ];

  List<Widget> roomConcerns(HomeSafetySession s, RoomInstance room) => [
    if (_assistantFindingId != null)
      TextButton(
        onPressed: () => setState(() => _assistantFindingId = null),
        child: Text(context.tr('All concerns')),
      ),
    if (_facts(s, room) case final f
        when f.toReview.length + f.kept.length + f.addressed > 0)
      Text(progressText(s, room)),
    for (final link in s.document.findingRooms.where(
      (l) => l.roomId == room.id,
    ))
      for (final finding in s.snapshot.findings.where(
        (f) =>
            f.id == link.findingId &&
            f.reviewState != 'dismissed' &&
            (_assistantFindingId == null || f.id == _assistantFindingId),
      ))
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  finding.observation,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                Text(
                  context.tr(
                    finding.reviewState == 'confirmed'
                        ? 'Confirmed by you'
                        : 'Needs your review',
                  ),
                ),
                TextButton.icon(
                  onPressed: editable && !s.caseWriteBlocked
                      ? () => openFinding(finding.id)
                      : null,
                  icon: const Icon(Icons.edit_note),
                  label: Text(context.tr('Review concern and evidence')),
                ),
                concernActions(s, link),
                if (finding.reviewState == 'confirmed' && _canFindHelp)
                  FilledButton.tonal(
                    key: ValueKey('concern-find-help-${finding.id}'),
                    onPressed: enabled ? () => _findHelp(finding.id) : null,
                    child: Text(context.tr('Find help for this')),
                  ),
              ],
            ),
          ),
        ),
    TextButton(
      onPressed: editable ? () => assign(room) : null,
      child: Text(context.tr('Link an existing concern')),
    ),
    ..._forward(s, room, const {'room-next-review'}),
    ExpansionTile(
      title: Text(context.tr('About addressed concerns')),
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            context.tr(
              'Addressed counts are your reports, not verified repairs. Currently dismissed concerns are excluded. Changed answers or findings need review. Unknown answers are not a safety result.',
            ),
          ),
        ),
      ],
    ),
  ];

  List<Widget> roomChecklist(HomeSafetySession s, RoomInstance room) => [
    FilledButton.icon(
      key: ValueKey('scan-room-${room.id}'),
      onPressed: editable ? () => openRoomScan(room) : null,
      icon: Icon(
        room.type == AssessmentLocation.outdoorPaths
            ? Icons.photo_camera_outlined
            : Icons.view_in_ar,
      ),
      label: Text(
        context.tr(
          room.type == AssessmentLocation.outdoorPaths
              ? 'Use photos and measurements'
              : 'Open room scan',
        ),
      ),
    ),
    archiveAction(room),
    Text(progressText(s, room)),
    Text(
      context.tr(
        'Addressed counts are your reports, not verified repairs. Currently dismissed concerns are excluded. Changed answers or findings need review. Unknown answers are not a safety result.',
      ),
    ),
    Wrap(
      spacing: 8,
      children: [
        OutlinedButton.icon(
          onPressed: editable ? () => roomDialog(room) : null,
          icon: const Icon(Icons.edit_outlined),
          label: Text(context.tr('Rename room')),
        ),
        TextButton(
          onPressed: editable ? () => assign(room) : null,
          child: Text(context.tr('Link an existing concern')),
        ),
      ],
    ),
    Text(
      context.tr(
        'Choose Not applicable for features this room does not have. Not sure and unanswered remain unknown.',
      ),
    ),
    for (final q in s.catalog.forRoom(room)) questionCard(s, room, q),
    for (final link in s.document.findingRooms.where(
      (l) => l.roomId == room.id && l.questionId == null,
    ))
      for (final finding in s.snapshot.findings.where(
        (f) => f.id == link.findingId,
      ))
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(finding.observation),
                concernActions(s, link),
                TextButton(
                  onPressed: editable && !s.caseWriteBlocked
                      ? () => openFinding(finding.id)
                      : null,
                  child: Text(context.tr('Photos and measurements')),
                ),
              ],
            ),
          ),
        ),
  ];
}

String answerLabel(String value) => switch (value) {
  'yes' => 'Yes',
  'no' => 'No',
  'not_sure' => 'Not sure',
  'not_applicable' => 'Not applicable',
  _ => 'Unanswered',
};

class _QuestionCard extends StatelessWidget {
  const _QuestionCard({
    required this.question,
    required this.answer,
    required this.link,
    required this.findingPresent,
    required this.editable,
    required this.onAnswer,
    required this.onReview,
    required this.onPhoto,
    required this.onlineReady,
    this.followUp,
  });
  final SafetyQuestion question;
  final SafetyAnswer? answer;
  final FindingRoom? link;
  final bool findingPresent, editable, onlineReady;
  final ValueChanged<String> onAnswer;
  final VoidCallback onReview, onPhoto;
  final Widget? followUp;
  @override
  Widget build(BuildContext context) {
    final concern = answer?.value == question.concernWhen;
    final answered = answer != null && answer!.value != 'unanswered';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              context.tr(question.prompt),
              style: Theme.of(context).textTheme.titleMedium,
            ),
            Text(
              context.tr(answered ? 'Answered' : 'Not answered'),
              key: ValueKey('answer-state-${question.id}'),
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 4),
            RadioGroup<String>(
              key: ValueKey('answer-${question.id}'),
              groupValue: answered ? answer!.value : null,
              onChanged: (v) {
                if (editable && v != null && v != answer?.value) onAnswer(v);
              },
              child: Column(
                children: [
                  for (final value in safetyAnswerValues)
                    if (value != 'unanswered')
                      RadioListTile<String>(
                        key: ValueKey('answer-${question.id}-$value'),
                        value: value,
                        enabled: editable,
                        contentPadding: EdgeInsets.zero,
                        title: Text(context.tr(answerLabel(value))),
                      ),
                ],
              ),
            ),
            if (answered)
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: TextButton(
                  key: ValueKey('answer-clear-${question.id}'),
                  onPressed: editable ? () => onAnswer('unanswered') : null,
                  child: Text(context.tr('Clear answer')),
                ),
              ),
            if (concern) ...[
              const SizedBox(height: 12),
              Text(
                context.tr(
                  'Possible concern — review before adding to your assessment.',
                ),
              ),
              Text(context.tr(question.guidance)),
            ],
            if (link != null && link!.answerRevision != answer?.revision)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  context.tr(
                    'The answer changed. Review the linked concern; it has not been automatically removed.',
                  ),
                ),
              ),
            if (link != null && !findingPresent)
              Text(
                context.tr(
                  'The linked concern was removed in the assessment. Its checklist history is retained.',
                ),
              ),
            if ((concern || link != null) && (link == null || findingPresent))
              TextButton(
                onPressed: editable ? onReview : null,
                child: Text(
                  context.tr(
                    link == null ? 'Review concern' : 'Review linked concern',
                  ),
                ),
              ),
            if (link != null && findingPresent)
              TextButton(
                onPressed: onlineReady ? onPhoto : null,
                child: Text(context.tr('Photos and measurements')),
              ),
            ?followUp,
          ],
        ),
      ),
    );
  }
}

mixin _DurableDialog<T extends StatefulWidget> on State<T> {
  bool saving = false;
  String? error;
  Future<void> saveOperation(
    Map<String, Object?> operation,
    Future<void> Function(Map<String, Object?>) callback,
  ) async {
    if (saving) return;
    setState(() {
      saving = true;
      error = null;
    });
    try {
      await callback(operation);
      if (mounted) Navigator.pop(context);
    } catch (_) {
      if (mounted) {
        setState(
          () => error =
              'The device save failed. Your input is still here; try again before closing.',
        );
      }
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }
}

class _RoomDialog extends StatefulWidget {
  const _RoomDialog({this.room, required this.onSave});
  final RoomInstance? room;
  final Future<void> Function(Map<String, Object?>) onSave;
  @override
  State<_RoomDialog> createState() => _RoomDialogState();
}

class _RoomDialogState extends State<_RoomDialog> with _DurableDialog {
  late final name = TextEditingController(text: widget.room?.name ?? '');
  late final roomId = widget.room?.id ?? newUuidV4();
  late AssessmentLocation type =
      widget.room?.type ?? AssessmentLocation.bedroom;
  @override
  void dispose() {
    name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !saving,
    child: AlertDialog(
      title: Text(
        context.tr(widget.room == null ? 'Add a room' : 'Rename room'),
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.room == null)
              DropdownButtonFormField<AssessmentLocation>(
                initialValue: type,
                isExpanded: true,
                decoration: InputDecoration(labelText: context.tr('Room type')),
                items: [
                  for (final value in AssessmentLocation.values)
                    DropdownMenuItem(
                      value: value,
                      child: Text(context.tr(value.title)),
                    ),
                ],
                onChanged: saving
                    ? null
                    : (v) {
                        if (v != null) setState(() => type = v);
                      },
              ),
            const SizedBox(height: 12),
            TextField(
              controller: name,
              enabled: !saving,
              maxLength: 80,
              decoration: InputDecoration(
                labelText: context.tr('Room name (optional)'),
                hintText: context.tr('For example: Upstairs bathroom'),
              ),
            ),
            if (error != null) Text(context.tr(error!)),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: saving ? null : () => Navigator.pop(context),
          child: Text(context.tr('Cancel')),
        ),
        FilledButton(
          onPressed: saving
              ? null
              : () {
                  final text = name.text.trim();
                  try {
                    roomName(text.isEmpty ? null : text);
                  } catch (_) {
                    setState(
                      () => error =
                          'Use a single-line name of up to 80 characters.',
                    );
                    return;
                  }
                  saveOperation(
                    widget.room == null
                        ? {
                            'type': 'add_room',
                            'room': RoomInstance(
                              id: roomId,
                              type: type,
                              name: text.isEmpty ? null : text,
                            ).toJson(),
                          }
                        : {
                            'type': 'rename_room',
                            'roomId': roomId,
                            'name': text.isEmpty ? null : text,
                          },
                    widget.onSave,
                  );
                },
          child: Text(context.tr('Save on device')),
        ),
      ],
    ),
  );
}

class _ConcernDialog extends StatefulWidget {
  const _ConcernDialog({
    required this.observation,
    required this.state,
    required this.onSave,
  });
  final String observation, state;
  final Future<void> Function(Map<String, Object?>) onSave;
  @override
  State<_ConcernDialog> createState() => _ConcernDialogState();
}

class _ConcernDialogState extends State<_ConcernDialog> with _DurableDialog {
  late final note = TextEditingController(text: widget.observation);
  late String state = widget.state;
  @override
  void dispose() {
    note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !saving,
    child: AlertDialog(
      title: Text(context.tr('Review concern')),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              context.tr(
                'Describe what you observed. Confirming a concern does not establish medical need or program eligibility.',
              ),
            ),
            TextField(
              controller: note,
              enabled: !saving,
              minLines: 2,
              maxLines: 6,
              maxLength: 500,
              decoration: InputDecoration(labelText: context.tr('Observation')),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              initialValue: state,
              isExpanded: true,
              decoration: InputDecoration(
                labelText: context.tr('Review state'),
              ),
              items: [
                for (final entry in {
                  'needs_review': 'Needs review',
                  'confirmed': 'Confirmed',
                  'dismissed': 'Dismissed',
                }.entries)
                  DropdownMenuItem(
                    value: entry.key,
                    child: Text(context.tr(entry.value)),
                  ),
              ],
              onChanged: saving
                  ? null
                  : (v) {
                      if (v != null) setState(() => state = v);
                    },
            ),
            if (error != null) Text(context.tr(error!)),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: saving ? null : () => Navigator.pop(context),
          child: Text(context.tr('Cancel')),
        ),
        FilledButton(
          onPressed: saving
              ? null
              : () {
                  final text = note.text.trim();
                  if (text.isEmpty ||
                      text.length > 500 ||
                      RegExp(r'[\x00-\x1f]').hasMatch(text)) {
                    setState(
                      () => error =
                          'Enter an observation of up to 500 characters on one line.',
                    );
                    return;
                  }
                  saveOperation({
                    'observation': text,
                    'state': state,
                  }, widget.onSave);
                },
          child: Text(context.tr('Save reviewed concern')),
        ),
      ],
    ),
  );
}

class _ConflictChange extends StatelessWidget {
  const _ConflictChange({
    required this.operation,
    required this.device,
    required this.saved,
    required this.deviceSnapshot,
    required this.savedSnapshot,
    required this.catalog,
    required this.savedOperations,
  });
  final List<Map<String, Object?>> savedOperations;
  final Map<String, Object?> operation, deviceSnapshot, savedSnapshot;
  final SafetyDocument device, saved;
  final HomeSafetyCatalog catalog;
  @override
  Widget build(BuildContext context) {
    final roomId = operation['roomId'] ?? (operation['room'] as Map?)?['id'];
    String describe(
      SafetyDocument doc,
      Map<String, Object?> snapshot,
      bool isDevice,
    ) {
      final room = doc.rooms.where((r) => r.id == roomId).firstOrNull;
      final title =
          room?.name ??
          (room == null
              ? context.tr('Room not present')
              : context.tr(room.type.title));
      if (operation['type'] == 'annotate_answer') {
        final value = isDevice
            ? operation
            : answerAnnotation(
                savedOperations,
                roomId as String,
                operation['questionId'] as String,
              );
        return '$title · ${value?['note'] ?? ''} · ${(value?['evidence'] as List? ?? []).map((r) => r['evidenceId']).join(', ')}';
      }
      if (operation['type'] == 'set_addressed') {
        final value = isDevice
            ? operation
            : savedOperations
                  .where(
                    (o) =>
                        o['type'] == 'set_addressed' &&
                        o['findingId'] == operation['findingId'],
                  )
                  .lastOrNull;
        return '$title · ${context.tr(value?['addressed'] == true ? 'Addressed - reported by you' : 'Reopen concern')}';
      }
      if (operation['type'] == 'answer') {
        return '$title · ${context.tr(answerLabel(doc.answer(roomId as String, operation['questionId'] as String)?.value ?? 'unanswered'))}';
      }
      if (operation['type'] == 'review_concern' ||
          operation['type'] == 'assign_finding') {
        final finding = (snapshot['findings'] as List)
            .cast<Map>()
            .where((f) => f['id'] == operation['findingId'])
            .firstOrNull;
        return '$title · ${finding?['observation'] ?? context.tr('Concern not present')}';
      }
      return title;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (operation['questionId'] != null)
          Text(
            context.tr(
              catalog.question(operation['questionId'] as String).prompt,
            ),
          ),
        Text(
          context.tr('Device: {value}', {
            'value': describe(device, deviceSnapshot, true),
          }),
        ),
        Text(
          context.tr('Saved: {value}', {
            'value': describe(saved, savedSnapshot, false),
          }),
        ),
      ],
    );
  }
}

enum _ScanState { none, saved, interrupted, attention }

class _RoomScan {
  const _RoomScan(this.state, [this.source]);
  final _ScanState state;
  final ScanSource? source;
}

class _RoomFacts {
  const _RoomFacts({
    required this.toReview,
    required this.kept,
    required this.addressed,
    required this.fromAnswers,
    required this.answered,
    required this.questions,
  });

  final List<String> toReview, kept;
  final int addressed, fromAnswers, answered, questions;
  int get suggested => toReview.length + fromAnswers;
}

class _NextStep {
  const _NextStep({
    required this.id,
    required this.title,
    required this.message,
    required this.action,
    required this.onTap,
    this.secondary,
  });
  final String id, title, message, action;
  final VoidCallback? onTap;
  final Widget? secondary;
}
