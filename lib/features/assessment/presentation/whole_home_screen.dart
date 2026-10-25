import '../application/home_model_sync.dart';
import 'home_model_sync_panel.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import '../../../app/live_app.dart';
import '../../../l10n/app_localizations.dart';
import '../application/whole_home_session.dart';
import '../application/whole_home_capture_adapter.dart';
import '../domain/home_safety/home_safety.dart';
import '../domain/scan/whole_home_model.dart';
import '../domain/scan/bathroom_scan_scene.dart';
import 'bathroom_model_view.dart';
import '../../../shared/presentation/sah_components.dart';

class WholeHomeScreen extends StatefulWidget {
  const WholeHomeScreen({
    super.key,
    required this.services,
    required this.rooms,
    required this.isCurrent,
    required this.scope,
    this.captureAdapter,
    this.localPlaces = false,
  });
  final AppServices services;
  final List<RoomInstance> Function() rooms;
  final bool Function() isCurrent;
  final Listenable scope;
  final WholeHomeCaptureAdapter? captureAdapter;
  final bool localPlaces;
  @override
  State<WholeHomeScreen> createState() => _WholeHomeScreenState();
}

class _WholeHomeScreenState extends State<WholeHomeScreen>
    with WidgetsBindingObserver {
  late final session = WholeHomeSession(
    store: widget.services.store,
    caseId: widget.services.coordinator.draft!.caseId,
    isCurrent: widget.isCurrent,
    currentRooms: widget.rooms,
    adapter: widget.captureAdapter ?? const NativeWholeHomeCaptureAdapter(),
    localPlaces: widget.localPlaces,
  );
  late Future<void> ready;
  HomeModelSync? synchronization;
  bool syncing = false;
  bool get working => session.busy || syncing;
  Future<void> initialize() async {
    await session.initialize();
    final api = widget.localPlaces ? null : widget.services.scanModels;
    if (api != null && synchronization == null && session.current) {
      final sync = HomeModelSync(
        api: api,
        store: widget.services.store,
        caseId: session.caseId,
        storageKey: session.key,
        isCurrent: () => mounted && session.current,
        caseRevision: () => widget.services.coordinator.currentCase().revision,
        localBundle: () {
          try {
            return session.bundle();
          } catch (_) {
            return null;
          }
        },
        applyBundle: session.restoreBundle,
      );
      synchronization = sync;
      sync.addListener(changed);
      await sync.initialize();
    }
  }

  Future<void> syncAction(Future<void> Function() action) async {
    if (working || !session.current) return;
    setState(() => syncing = true);
    try {
      await action();
    } catch (_) {
      if (mounted && session.current) {
        setState(() => error = _modelStepFailure);
      }
    } finally {
      if (mounted) setState(() => syncing = false);
    }
  }

  Future<bool> confirmSync(String title, String text, String action) async =>
      await showDialog<bool>(
        context: context,
        builder: (ctx) => scopedDialog(
          AlertDialog(
            scrollable: true,
            title: Text(title),
            content: Text(text),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text(ctx.tr('Cancel')),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: Text(action),
              ),
            ],
          ),
          {},
        ),
      ) ??
      false;

  String? error;
  String get _modelStepFailure =>
      session.model != null || session.scans.isNotEmpty
      ? 'This model step could not finish. Your saved models are retained.'
      : 'This model step could not finish. Try again when ready.';
  String? selectedFeature, selectedProposalFeature;
  bool reviewedCapture = false, refreshing = false;
  @override
  void initState() {
    super.initState();
    ready = initialize();
    session.addListener(changed);
    widget.scope.addListener(scopeChanged);
    WidgetsBinding.instance.addObserver(this);
  }

  void changed() {
    if (mounted) setState(() {});
  }

  void scopeChanged() {
    unawaited(session.cancelIfScopeChanged().catchError((Object _) {}));
    changed();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed &&
        session.initialized &&
        !working &&
        !refreshing &&
        session.current) {
      refreshing = true;
      setState(
        () =>
            ready = session.initialize().whenComplete(() => refreshing = false),
      );
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.scope.removeListener(scopeChanged);
    session.removeListener(changed);
    synchronization?.removeListener(changed);
    synchronization?.dispose();
    session.dispose();
    super.dispose();
  }

  String name(RoomInstance r) => r.name ?? context.tr(r.type.title);
  String? featureLabel(
    String? id,
    BathroomScanScene scene, [
    List<PlacedRoomScene>? placed,
  ]) {
    if (id == null) return null;
    if (placed == null) {
      final feature = scene.elements.where((e) => e.id == id).firstOrNull;
      return feature == null ? null : context.tr(feature.kind.label);
    }
    for (final r in placed) {
      final feature = r.scene.elements
          .where((e) => r.featureId(e.id) == id)
          .firstOrNull;
      if (feature != null) {
        final room = session.rooms.where((v) => v.id == r.roomId).firstOrNull;
        return '${room == null ? context.tr('Room no longer available') : name(room)}: ${context.tr(feature.kind.label)}';
      }
    }
    return null;
  }

  Widget extent(PlacedRoomScene room) {
    final bounds = room.bounds;
    if (bounds == null) return const SizedBox.shrink();
    return Text(
      context.tr(
        'Observed model bounds (m): X {x1} to {x2}; height {y1} to {y2}; Z {z1} to {z2}.',
        {
          for (var i = 0; i < 6; i++)
            ['x1', 'x2', 'y1', 'y2', 'z1', 'z2'][i]: bounds[i].toStringAsFixed(
              1,
            ),
        },
      ),
    );
  }

  Widget scopedDialog(Widget child, Set<String> protectedRooms) =>
      ListenableBuilder(
        listenable: Listenable.merge([widget.scope, session]),
        builder: (ctx, _) =>
            !session.current ||
                !session.rooms
                    .map((r) => r.id)
                    .toSet()
                    .containsAll(protectedRooms)
            ? AlertDialog(
                scrollable: true,
                content: Text(
                  ctx.tr('Reopen the selected plan to view its model.'),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: Text(ctx.tr('Cancel')),
                  ),
                ],
              )
            : child,
      );
  Future<void> run(Future<void> Function() action) async {
    if (!session.current || working) return;
    setState(() => error = null);
    try {
      await action();
    } on HomeModelSourceChanged {
      if (mounted && session.current) {
        setState(() {
          error =
              'A room or source scan changed. Review its placement before including it again.';
          ready = initialize();
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() => error = _modelStepFailure);
      }
    }
  }

  Future<void> reference(RoomInstance room) async {
    final replace =
        session.model != null &&
        (session.model!.referenceRoomId != room.id ||
            session.model!.method != 'reviewed_alignment');
    if (replace &&
        await showDialog<bool>(
              context: context,
              builder: (ctx) => scopedDialog(
                AlertDialog(
                  scrollable: true,
                  title: Text(ctx.tr('Start a new room alignment?')),
                  content: Text(
                    ctx.tr(
                      'This replaces the connected layout. Your original room scans stay saved.',
                    ),
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(ctx, false),
                      child: Text(ctx.tr('Cancel')),
                    ),
                    FilledButton(
                      onPressed: () => Navigator.pop(ctx, true),
                      child: Text(ctx.tr('Start new alignment')),
                    ),
                  ],
                ),
                {room.id},
              ),
            ) !=
            true) {
      return;
    }
    await run(() => session.setReference(room.id));
  }

  Widget captureChooser(
    BuildContext ctx,
    List<Widget> fields,
    List<Widget> actions,
  ) => Dialog.fullscreen(
    child: SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  ctx.tr('Choose connected rooms'),
                  style: Theme.of(ctx).textTheme.headlineSmall,
                ),
                ...fields,
                Wrap(
                  alignment: WrapAlignment.end,
                  spacing: 12,
                  runSpacing: 12,
                  children: actions,
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );

  Future<void> capture() async {
    final selected = <String>{};
    final limit = session.rooms.length.clamp(2, 8);
    var limitReached = false;
    final result = await showDialog<List<String>>(
      context: context,
      builder: (ctx) => scopedDialog(
        StatefulBuilder(
          builder: (ctx, change) => captureChooser(
            ctx,
            [
              SahNotice(
                title: ctx.tr('One level, in walking order'),
                message: ctx.tr(
                  'Choose 2–{count} rooms on one level, in walking order. Keep a safe, clear path between rooms. Do not walk on stairs while scanning.',
                  {'count': limit},
                ),
                liveRegion: false,
              ),
              Semantics(
                liveRegion: true,
                child: Text(
                  ctx.tr('{count} of {total} chosen', {
                    'count': selected.length,
                    'total': limit,
                  }),
                  key: const ValueKey('home-capture-count'),
                  style: Theme.of(ctx).textTheme.titleMedium,
                ),
              ),
              if (limitReached)
                SahNotice(
                  message: ctx.tr(
                    'You can connect up to {count} rooms in one scan. Remove a room to choose another.',
                    {'count': limit},
                  ),
                  tone: SahNoticeTone.warning,
                ),
              for (final room in session.rooms)
                CheckboxListTile(
                  title: Text(name(room)),
                  secondary: selected.contains(room.id)
                      ? CircleAvatar(
                          radius: 16,
                          child: Text(
                            '${selected.toList().indexOf(room.id) + 1}',
                            semanticsLabel: ctx.tr('Stop {number}', {
                              'number': selected.toList().indexOf(room.id) + 1,
                            }),
                          ),
                        )
                      : const SizedBox(width: 32),
                  subtitle: selected.contains(room.id)
                      ? Text(
                          ctx.tr('Stop {number} of {total}', {
                            'number': selected.toList().indexOf(room.id) + 1,
                            'total': selected.length,
                          }),
                        )
                      : null,
                  value: selected.contains(room.id),
                  onChanged: (v) => change(() {
                    if (v == true) {
                      limitReached = selected.length >= limit;
                      if (!limitReached) selected.add(room.id);
                    } else {
                      selected.remove(room.id);
                      limitReached = false;
                    }
                  }),
                ),
            ],
            [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text(ctx.tr('Cancel')),
              ),
              FilledButton(
                onPressed: selected.length < 2
                    ? null
                    : () => Navigator.pop(ctx, selected.toList()),
                child: Text(ctx.tr('Start connected capture')),
              ),
            ],
          ),
        ),
        session.rooms.map((r) => r.id).toSet(),
      ),
    );
    if (result != null && mounted) {
      await run(() {
        reviewedCapture = false;
        return session.capture(result, {
          for (final r in session.rooms) r.id: name(r),
        });
      });
    }
  }

  Future<void> align(RoomInstance room) async {
    final model = session.model!;
    final old = model.rooms.where((r) => r.roomId == room.id).singleOrNull;
    final connected = session.connected();
    final sourceFingerprint = session.scans[room.id]!.fingerprint;
    final parentFingerprints = {
      for (final r in model.rooms) r.roomId: r.fingerprint,
    };
    bool descendant(String id) {
      final seen = <String>{};
      String? next = id;
      while (next != null && seen.add(next)) {
        if (next == room.id) return true;
        next = model.rooms
            .where((r) => r.roomId == next)
            .singleOrNull
            ?.parentId;
      }
      return false;
    }

    final parents = connected.where((r) => !descendant(r.roomId)).toList();
    if (parents.isEmpty) return;
    final x = TextEditingController(text: '${old?.pose.x ?? 0}');
    final z = TextEditingController(text: '${old?.pose.z ?? 0}');
    final y = TextEditingController(text: '${old?.pose.y ?? 0}');
    final angle = TextEditingController(text: '${old?.pose.yaw ?? 0}');
    var parent = parents.any((r) => r.roomId == old?.parentId)
        ? old!.parentId!
        : parents.first.roomId;
    var reviewed = false, saving = false, preview = false;
    String? previewSelection;
    String? failure;
    RoomPose pose() => RoomPose(
      x: double.parse(x.text),
      y: double.parse(y.text),
      z: double.parse(z.text),
      yaw: double.parse(angle.text),
    );
    try {
      final route = DialogRoute<void>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => scopedDialog(
          StatefulBuilder(
            builder: (ctx, change) {
              List<PlacedRoomScene>? proposed;
              try {
                final next = WholeHomeModel(
                  referenceRoomId: model.referenceRoomId,
                  method: 'reviewed_alignment',
                  rooms: [
                    for (final r in model.rooms)
                      if (r.roomId != room.id) r,
                    HomeRoomPlacement(
                      roomId: room.id,
                      fingerprint: sourceFingerprint,
                      parentId: parent,
                      parentFingerprint: parentFingerprints[parent],
                      pose: pose(),
                      reviewed: true,
                    ),
                  ],
                );
                proposed = next.resolve(
                  session.scans,
                  session.rooms.map((r) => r.id).toSet(),
                );
              } catch (_) {
                // ignore: empty_catches
              }
              return PopScope(
                canPop: !saving,
                child: Dialog.fullscreen(
                  child: SafeArea(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(20),
                      child: Align(
                        alignment: Alignment.topCenter,
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 720),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Text(
                                ctx.tr('Align room: {room}', {
                                  'room': name(room),
                                }),
                                style: Theme.of(ctx).textTheme.headlineSmall,
                              ),
                              Text(
                                ctx.tr(
                                  'Match the room to its connected room. Offsets use that room’s axes and metres. Rotation turns around the vertical axis. Check the preview before confirming.',
                                ),
                              ),
                              DropdownButtonFormField<String>(
                                initialValue: parent,
                                isExpanded: true,
                                decoration: InputDecoration(
                                  labelText: ctx.tr('Connected room'),
                                ),
                                items: [
                                  for (final p in parents)
                                    DropdownMenuItem(
                                      value: p.roomId,
                                      child: Text(
                                        name(
                                          session.rooms.firstWhere(
                                            (r) => r.id == p.roomId,
                                          ),
                                        ),
                                      ),
                                    ),
                                ],
                                onChanged: saving
                                    ? null
                                    : (v) => change(() {
                                        parent = v!;
                                        reviewed = false;
                                        preview = false;
                                      }),
                              ),
                              for (final field in [
                                (x, 'X offset (m)'),
                                (z, 'Z offset (m)'),
                                (y, 'Height offset (m)'),
                                (angle, 'Rotation (degrees)'),
                              ])
                                TextFormField(
                                  controller: field.$1,
                                  enabled: !saving,
                                  keyboardType:
                                      const TextInputType.numberWithOptions(
                                        decimal: true,
                                        signed: true,
                                      ),
                                  decoration: InputDecoration(
                                    labelText: ctx.tr(field.$2),
                                  ),
                                  onChanged: (_) => change(() {
                                    reviewed = false;
                                    preview = false;
                                  }),
                                ),
                              TextButton(
                                onPressed: proposed == null || saving
                                    ? null
                                    : () => change(() => preview = true),
                                child: Text(ctx.tr('Preview placement')),
                              ),
                              if (preview && proposed != null) ...[
                                Text(ctx.tr('Unreviewed placement preview')),
                                BathroomModelView(
                                  scene: proposed.first.scene,
                                  placedRooms: proposed,
                                  homeModel: true,
                                  selectedId: previewSelection,
                                  selectedLabel: featureLabel(
                                    previewSelection,
                                    proposed.first.scene,
                                    proposed,
                                  ),
                                  onSelect: (id) =>
                                      change(() => previewSelection = id),
                                ),
                                Text(
                                  ctx.tr(
                                    'In Top view, reference +X points right and +Z points down. Height is +Y. Offsets follow the selected connected room’s rotated axes.',
                                  ),
                                ),
                                extent(
                                  proposed.firstWhere(
                                    (r) => r.roomId == room.id,
                                  ),
                                ),
                              ],
                              CheckboxListTile(
                                contentPadding: EdgeInsets.zero,
                                value: reviewed,
                                title: Text(
                                  ctx.tr(
                                    'I checked the room position, orientation and height.',
                                  ),
                                ),
                                onChanged:
                                    saving || !preview || proposed == null
                                    ? null
                                    : (v) => change(() => reviewed = v == true),
                              ),
                              if (failure != null) Text(ctx.tr(failure!)),
                              Wrap(
                                alignment: WrapAlignment.end,
                                spacing: 12,
                                runSpacing: 12,
                                children: [
                                  TextButton(
                                    onPressed: saving
                                        ? null
                                        : () => Navigator.pop(ctx),
                                    child: Text(ctx.tr('Cancel')),
                                  ),
                                  FilledButton(
                                    onPressed:
                                        !reviewed ||
                                            !preview ||
                                            saving ||
                                            proposed == null
                                        ? null
                                        : () async {
                                            change(() {
                                              saving = true;
                                              failure = null;
                                            });
                                            try {
                                              await session.place(
                                                room.id,
                                                parent,
                                                pose(),
                                                expectedFingerprint:
                                                    sourceFingerprint,
                                                expectedParentFingerprint:
                                                    parentFingerprints[parent],
                                              );
                                              if (ctx.mounted) {
                                                Navigator.pop(ctx);
                                              }
                                            } on HomeModelSourceChanged {
                                              if (ctx.mounted) {
                                                change(() {
                                                  saving = false;
                                                  reviewed = false;
                                                  failure =
                                                      'A room or source scan changed. Review its placement before including it again.';
                                                });
                                              }
                                            } catch (_) {
                                              if (ctx.mounted) {
                                                change(() {
                                                  saving = false;
                                                  failure =
                                                      'The device save failed. Keep this screen open and try again.';
                                                });
                                              }
                                            }
                                          },
                                    child: Text(
                                      ctx.tr('Save reviewed placement'),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
          {room.id, ...connected.map((r) => r.roomId)},
        ),
      );
      await Navigator.of(context, rootNavigator: true).push(route);
      await route.completed;
    } finally {
      x.dispose();
      y.dispose();
      z.dispose();
      angle.dispose();
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(context.tr('Connected home model'))),
    body: SafeArea(
      child: FutureBuilder<void>(
        future: ready,
        builder: (ctx, state) {
          if (!session.current) {
            return Center(
              child: Text(
                ctx.tr('Reopen the selected plan to view its model.'),
              ),
            );
          }
          if (state.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (state.hasError) {
            return ListView(
              padding: const EdgeInsets.all(20),
              children: [
                Text(ctx.tr('The home model could not be opened. Try again.')),
                TextButton(
                  onPressed: () => setState(() => ready = session.initialize()),
                  child: Text(ctx.tr('Try again')),
                ),
              ],
            );
          }
          final model = session.model, proposal = session.proposal;
          List<PlacedRoomScene> placed = [];
          try {
            placed = session.connected();
          } catch (_) {
            // ignore: empty_catches
          }
          final active = placed.map((r) => r.roomId).toSet();
          final complete = model != null && placed.length == model.rooms.length;
          final proposalAvailable =
              proposal != null &&
              session.rooms
                  .map((r) => r.id)
                  .toSet()
                  .containsAll(proposal.rooms.map((r) => r.roomId));
          return Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 720),
              child: ListView(
                padding: const EdgeInsets.all(20),
                children: [
                  Text(
                    ctx.tr(
                      'This is a partial model for review. Unscanned rooms, hidden surfaces and uncertain connections remain unknown. It is not a verified floor plan or safety inspection.',
                    ),
                  ),
                  Text(
                    ctx.tr(
                      'Saved privately on this phone. Original room scans are kept.',
                    ),
                  ),
                  if (model?.mergedScene?.truncated == true ||
                      proposal?.mergedScene?.truncated == true ||
                      placed.any((r) => r.scene.truncated))
                    Text(
                      ctx.tr(
                        'Some captured geometry was omitted. Treat missing surfaces as unknown.',
                      ),
                    ),
                  if (working) const LinearProgressIndicator(),
                  TextButton(
                    onPressed: working || refreshing
                        ? null
                        : () => setState(() {
                            reviewedCapture = false;
                            ready = initialize();
                          }),
                    child: Text(ctx.tr('Refresh saved scans')),
                  ),
                  if (session.notice != null) Text(ctx.tr(session.notice!)),
                  if (error != null) Text(ctx.tr(error!)),
                  if (model != null && placed.length < model.rooms.length)
                    Text(
                      ctx.tr(
                        'A room or source scan changed. Review its placement before including it again.',
                      ),
                    ),
                  if (placed.length >= 2 &&
                      (model?.method == 'reviewed_alignment' || complete))
                    BathroomModelView(
                      scene: model!.mergedScene ?? placed.first.scene,
                      placedRooms: model.method == 'reviewed_alignment'
                          ? placed
                          : null,
                      homeModel: true,
                      selectedId: selectedFeature,
                      selectedLabel: featureLabel(
                        selectedFeature,
                        model.mergedScene ?? placed.first.scene,
                        model.method == 'reviewed_alignment' ? placed : null,
                      ),
                      onSelect: (id) => setState(() => selectedFeature = id),
                    ),
                  if (synchronization case final sync?)
                    HomeModelSyncPanel(
                      sync: sync,
                      enabled: !working && !refreshing,
                      localAvailable: complete,
                      run: syncAction,
                      confirm: confirmSync,
                    ),
                  if (proposal != null)
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(
                              ctx.tr('Unreviewed connected capture'),
                              style: Theme.of(ctx).textTheme.titleLarge,
                            ),
                            for (final r in proposal.rooms)
                              Text(
                                session.rooms
                                        .where((v) => v.id == r.roomId)
                                        .map(name)
                                        .firstOrNull ??
                                    ctx.tr('Room no longer available'),
                              ),
                            if (!proposalAvailable)
                              Text(
                                ctx.tr(
                                  'A room or source scan changed. Review its placement before including it again.',
                                ),
                              ),
                            if (proposalAvailable) ...[
                              BathroomModelView(
                                scene: proposal.mergedScene!,
                                homeModel: true,
                                selectedId: selectedProposalFeature,
                                selectedLabel: featureLabel(
                                  selectedProposalFeature,
                                  proposal.mergedScene!,
                                ),
                                onSelect: (id) => setState(
                                  () => selectedProposalFeature = id,
                                ),
                              ),
                              for (final r in proposal.rooms)
                                extent(
                                  PlacedRoomScene(
                                    r.roomId,
                                    proposal.captures[r.roomId]!,
                                    RoomPose(),
                                  ),
                                ),
                              CheckboxListTile(
                                value: reviewedCapture,
                                title: Text(
                                  ctx.tr(
                                    'I checked the connected room positions.',
                                  ),
                                ),
                                onChanged: working
                                    ? null
                                    : (v) => setState(
                                        () => reviewedCapture = v == true,
                                      ),
                              ),
                              FilledButton(
                                onPressed: !reviewedCapture || working
                                    ? null
                                    : () => run(session.acceptCapture),
                                child: Text(ctx.tr('Save reviewed home model')),
                              ),
                            ],
                            TextButton(
                              onPressed: working
                                  ? null
                                  : () => run(session.discardCapture),
                              child: Text(ctx.tr('Discard this capture')),
                            ),
                          ],
                        ),
                      ),
                    ),
                  const SizedBox(height: 16),
                  Text(
                    ctx.tr('Continuous room capture'),
                    style: Theme.of(ctx).textTheme.titleLarge,
                  ),
                  Text(
                    ctx.tr(
                      'Continuous capture connects the rooms you choose in one tracking session. Android captures approximate surfaces and points, not identified fixtures. Existing independent scans use reviewed alignment below.',
                    ),
                  ),
                  if (session.supported)
                    FilledButton.icon(
                      key: const ValueKey('home-capture'),
                      onPressed:
                          working ||
                              session.rooms.length < 2 ||
                              proposal != null
                          ? null
                          : capture,
                      icon: const Icon(Icons.view_in_ar),
                      label: Text(ctx.tr('Capture connected rooms')),
                    )
                  else
                    Text(
                      ctx.tr(
                        'Continuous capture is unavailable on this phone. It needs an iPhone with LiDAR, or an Android phone with ARCore. You can still align saved room scans.',
                      ),
                    ),
                  if (session.busy)
                    TextButton(
                      onPressed: session.cancelCapture,
                      child: Text(ctx.tr('Cancel scan')),
                    ),
                  const SizedBox(height: 20),
                  Text(
                    ctx.tr('Align saved room scans'),
                    style: Theme.of(ctx).textTheme.titleLarge,
                  ),
                  Text(
                    ctx.tr(
                      'Choose a reference room, then preview and confirm each connected room’s position. No position is guessed from the room name.',
                    ),
                  ),
                  if (session.rooms.isEmpty)
                    Text(
                      ctx.tr(
                        'Add named rooms and scan them before connecting models.',
                      ),
                    ),
                  for (final room in session.rooms)
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(
                              name(room),
                              style: Theme.of(ctx).textTheme.titleMedium,
                            ),
                            Text(
                              ctx.tr(
                                session.unreadable.contains(room.id)
                                    ? 'Saved scan needs attention'
                                    : active.contains(room.id)
                                    ? 'Reviewed position included'
                                    : !session.scans.containsKey(room.id)
                                    ? 'Scan this room first'
                                    : 'Position needs review',
                              ),
                            ),
                            if (active.contains(room.id))
                              extent(
                                placed.firstWhere((r) => r.roomId == room.id),
                              ),
                            if (session.scans.containsKey(room.id)) ...[
                              if (model == null ||
                                  model.method != 'reviewed_alignment' ||
                                  model.referenceRoomId == room.id)
                                TextButton(
                                  key: ValueKey('home-reference-${room.id}'),
                                  onPressed: working
                                      ? null
                                      : () => reference(room),
                                  child: Text(ctx.tr('Use as reference room')),
                                )
                              else
                                OutlinedButton(
                                  key: ValueKey('home-align-${room.id}'),
                                  onPressed: working || active.isEmpty
                                      ? null
                                      : () => align(room),
                                  child: Text(ctx.tr('Review room placement')),
                                ),
                              if (model?.method == 'reviewed_alignment' &&
                                  model!.referenceRoomId != room.id &&
                                  model.rooms.any((r) => r.roomId == room.id))
                                TextButton(
                                  onPressed: working
                                      ? null
                                      : () =>
                                            run(() => session.remove(room.id)),
                                  child: Text(
                                    ctx.tr(
                                      'Exclude room and dependent connections',
                                    ),
                                  ),
                                ),
                            ],
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
          );
        },
      ),
    ),
  );
}
