import 'dart:async';
import 'package:flutter/material.dart';
import 'package:safe_at_home/l10n/app_localizations.dart';

import '../application/bathroom_scan_adapter.dart';
import '../application/bathroom_scan_session.dart';
import '../domain/scan/bathroom_scan_scene.dart';
import '../domain/scan/scan_suggestions.dart';
import '../domain/assessment_location.dart';
import 'bathroom_model_view.dart';
import '../../../shared/presentation/sah_components.dart';
import 'scan_model_sync_panel.dart';

class BathroomScanScreen extends StatefulWidget {
  const BathroomScanScreen({
    super.key,
    required this.session,
    required this.onImport,
    required this.importedFinding,
    this.activeImports,
    this.scope,
    this.onContinue,
    this.onAddOtherConcern,
    this.onUsePhotos,
    this.onSetImportActive,
  });
  final BathroomScanSession session;
  final Future<String> Function(ScanSuggestion) onImport;
  final String? Function(String) importedFinding;

  final Set<String> Function()? activeImports;
  final Listenable? scope;
  final ValueChanged<String?>? onContinue;
  final VoidCallback? onAddOtherConcern;
  final VoidCallback? onUsePhotos;

  final Future<void> Function(String suggestionId, bool active)?
  onSetImportActive;
  @override
  State<BathroomScanScreen> createState() => _BathroomScanScreenState();
}

class _BathroomScanScreenState extends State<BathroomScanScreen> {
  BathroomScanSession get scan => widget.session;
  late final Future<void> ready;
  bool busy = false, canPop = false;
  bool confirming = false;
  BuildContext? dialogContext;
  String? selectedId, notice, latestImportedFindingId;
  bool get enabled => !busy && !scan.busy && scan.isCurrent();
  String? get currentReviewFindingId {
    final active = widget.activeImports?.call();
    final current = suggestions
        .where((item) => active == null || active.contains(item.id))
        .map((item) => widget.importedFinding(item.id))
        .whereType<String>()
        .toList();
    return current.contains(latestImportedFindingId)
        ? latestImportedFindingId
        : current.firstOrNull;
  }

  @override
  void initState() {
    super.initState();
    scan.addListener(changed);
    widget.scope?.addListener(scopeChanged);
    ready = scan.initialize();
  }

  void changed() {
    if (mounted) setState(() {});
  }

  void scopeChanged() {
    if (!scan.isCurrent()) {
      unawaited(scan.cancelCapture().catchError((Object _) {}));
      final dialog = dialogContext;
      if (dialog != null && dialog.mounted) {
        dialogContext = null;
        final navigator = Navigator.of(dialog);
        final route = ModalRoute.of(dialog);
        if (route?.isCurrent == true) {
          navigator.pop(false);
        } else if (route?.isActive == true) {
          navigator.removeRoute(route!, false);
        }
      }
    }
    changed();
  }

  @override
  void dispose() {
    scan.removeListener(changed);
    widget.scope?.removeListener(scopeChanged);
    scan.dispose();
    super.dispose();
  }

  Future<void> run(Future<void> Function() action) async {
    if (!enabled) return;
    setState(() {
      busy = true;
      notice = null;
    });
    try {
      await action();
    } on ScanScopeExpired {
      if (mounted) {
        notice =
            'This case or session has changed. Return to the case to continue.';
      }
    } catch (_) {
      if (mounted) {
        notice = scan.dirty
            ? null
            : 'This step could not finish. Review the saved state before trying again.';
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<bool> confirm(String title, String message, String action) async {
    if (confirming || !mounted || !scan.isCurrent()) return false;
    confirming = true;
    try {
      final accepted = await showDialog<bool>(
        context: context,
        builder: (context) {
          dialogContext = context;
          return ListenableBuilder(
            listenable: widget.scope ?? scan,
            builder: (context, _) => !scan.isCurrent()
                ? const SizedBox.shrink()
                : Dialog(
                    insetPadding: const EdgeInsets.all(16),
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
                                style: Theme.of(context).textTheme.titleLarge,
                              ),
                            ),
                            const SizedBox(height: 16),
                            Text(message),
                            const SizedBox(height: 20),
                            TextButton(
                              onPressed: () => Navigator.pop(context, false),
                              child: Text(context.tr('Cancel')),
                            ),
                            const SizedBox(height: 8),
                            FilledButton(
                              onPressed: () => Navigator.pop(context, true),
                              child: Text(action),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
          );
        },
      );
      return mounted && scan.isCurrent() && accepted == true;
    } finally {
      dialogContext = null;
      confirming = false;
    }
  }

  Future<void> close({
    bool continueToReview = false,
    bool addOther = false,
    bool usePhotos = false,
  }) async {
    if (busy || scan.busy) return;
    final route = ModalRoute.of(context);
    if (scan.initialized && scan.dirty && scan.isCurrent()) {
      if (!await confirm(
        context.tr('Device changes are not saved'),
        context.tr(
          'Retry saving to keep this model and review. Discarding returns to the last saved device version.',
        ),
        context.tr('Discard unsaved changes'),
      )) {
        return;
      }
      try {
        await scan.discardUnsaved();
      } catch (_) {
        return;
      }
    }
    if (!mounted ||
        route?.isCurrent != true ||
        !identical(route, ModalRoute.of(context))) {
      return;
    }
    try {
      if (scan.isCurrent()) {
        if (usePhotos) {
          widget.onUsePhotos?.call();
        } else if (addOther) {
          widget.onAddOtherConcern?.call();
        } else if (continueToReview) {
          widget.onContinue?.call(currentReviewFindingId);
        }
      }
    } catch (_) {
      setState(
        () => notice =
            'This case or session has changed. Return to the case to continue.',
      );
      return;
    }
    setState(() => canPop = true);
    Navigator.of(context).pop();
  }

  Future<void> capture() => run(() async {
    if (scan.review.scene != null &&
        !await confirm(
          context.tr('Replace the device model?'),
          context.tr(
            'Your current model and feature reviews stay until a new scan finishes. Observations already added to the assessment remain there.',
          ),
          context.tr('Start new scan'),
        )) {
      return;
    }
    await scan.capture();
    selectedId = null;
  });

  List<ScanSuggestionCandidate> get suggestions => scan.suggestedImprovements;

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: canPop,
    onPopInvokedWithResult: (didPop, result) {
      if (!didPop) close();
    },
    child: Scaffold(
      appBar: AppBar(
        title: Text(
          scan.room == null
              ? context.tr('Bathroom in 3D')
              : context.tr('{room} in 3D', {
                  'room': scan.room!.name ?? context.tr(scan.location.title),
                }),
        ),
        leading: BackButton(onPressed: close),
      ),
      bottomNavigationBar:
          scan.initialized && scan.review.scene != null && scan.isCurrent()
          ? SafeArea(
              minimum: const EdgeInsets.fromLTRB(20, 12, 20, 12),
              child: FilledButton(
                key: const ValueKey('bathroom-continue'),
                onPressed: enabled ? () => close(continueToReview: true) : null,
                child: Text(
                  context.tr('Continue'),
                  textAlign: TextAlign.center,
                ),
              ),
            )
          : null,
      body: SafeArea(
        child: FutureBuilder<void>(
          future: ready,
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return _body([
                Text(
                  context.tr(
                    'The private model could not be opened. The original encrypted record has been kept.',
                  ),
                ),
                OutlinedButton(
                  onPressed: close,
                  child: Text(context.tr('Back to assessment')),
                ),
              ]);
            }
            if (snapshot.connectionState != ConnectionState.done) {
              return Center(
                child: CircularProgressIndicator(
                  semanticsLabel: context.tr('Opening private room scan'),
                ),
              );
            }
            return _body(content(context));
          },
        ),
      ),
    ),
  );

  Widget _body(List<Widget> children) => Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 720),
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          for (final child in children) ...[child, const SizedBox(height: 16)],
        ],
      ),
    ),
  );

  List<Widget> content(BuildContext context) {
    if (!scan.isCurrent()) {
      return [
        Text(
          context.tr(
            'This case or account has changed. Return to the assessment.',
          ),
        ),
        OutlinedButton(
          onPressed: close,
          child: Text(context.tr('Back to assessment')),
        ),
      ];
    }
    final scene = scan.review.scene;
    final prompts = suggestions;
    final earlier = (widget.activeImports?.call() ?? const <String>{})
        .difference(scan.currentReviewedSuggestionIds);
    final capability = scan.capabilities;
    final selected =
        scene?.elementById(selectedId ?? '') ?? scene?.elements.firstOrNull;
    final scanSupported = capability?.canRequestCapture == true;
    final canStart = enabled && !scan.dirty && scanSupported;
    final needsSetup =
        capability?.source == 'arcore' &&
        {
          'services_missing',
          'services_update_required',
          'permission_denied',
        }.contains(capability?.reason);
    final tapped = selectedId == null ? null : scene?.elementById(selectedId!);
    final ready =
        capability != null &&
        capability.supported &&
        capability.reason == 'available';
    final roomName = scan.room?.name ?? context.tr(scan.location.title);
    return [
      if (scene == null) ...[
        MediaQuery.withClampedTextScaling(
          maxScaleFactor: 1.6,
          child: Semantics(
            header: true,
            child: Text(
              scan.room == null
                  ? context.tr('Scan your bathroom')
                  : context.tr('Scan {room}', {'room': roomName}),
              style: Theme.of(context).textTheme.headlineMedium,
            ),
          ),
        ),
        _modeCard(context, capability),
      ],
      if (scan.synchronization != null)
        ScanModelSyncPanel(
          scan: scan,
          enabled: enabled,
          run: run,
          confirm: confirm,
        ),
      if (notice != null) _notice(notice!),
      if (scan.notice != null) _notice(scan.notice!),
      if (earlier.isNotEmpty)
        _notice(
          earlier.length == 1
              ? context.tr(
                  '{count} earlier scan observation is still in the assessment, unchanged. Review it there.',
                  {'count': earlier.length},
                )
              : context.tr(
                  '{count} earlier scan observations are still in the assessment, unchanged. Review them there.',
                  {'count': earlier.length},
                ),
        ),
      if (scan.dirty)
        FilledButton(
          onPressed: enabled ? () => run(scan.retrySave) : null,
          child: Text(context.tr('Retry device save')),
        ),
      if (scan.busy || busy)
        LinearProgressIndicator(
          semanticsLabel: context.tr('Processing scan step'),
        ),
      if (scan.canCancelCapture)
        OutlinedButton(
          onPressed: () => scan.cancelCapture(),
          child: Text(context.tr('Cancel scan')),
        ),
      if (!scan.busy && !busy && !ready && (scene == null || !scanSupported))
        Semantics(
          liveRegion: true,
          child: Text(context.tr(_readiness(capability))),
        ),
      if (scene != null && !scanSupported)
        Text(
          context.tr(
            'Your saved model is still available to review. You can also continue with photos and measurements.',
          ),
        ),
      if (scene == null)
        SahListGroup(
          title: context.tr('Before you start'),
          children: [
            for (final (icon, title, detail) in [
              (
                Icons.light_mode_outlined,
                'Turn on the lights and open curtains',
                'Scanning needs good light.',
              ),
              (
                Icons.door_front_door_outlined,
                'Open the door and clear the floor',
                'Mirrors and glass can confuse the scan.',
              ),
              (
                Icons.directions_walk,
                scan.location == AssessmentLocation.stairs
                    ? 'Scan from a safe landing; do not walk on stairs.'
                    : 'Move slowly along the walls',
                'Stop if moving feels unsafe. Someone else can scan for you. About 1–3 minutes.',
              ),
            ])
              ListTile(
                leading: ExcludeSemantics(child: Icon(icon)),
                title: Text(context.tr(title)),
                subtitle: Text(context.tr(detail)),
              ),
          ],
        ),
      if (scene == null)
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            FilledButton.icon(
              key: const ValueKey('bathroom-start-scan'),
              onPressed: canStart ? capture : null,
              icon: const Icon(Icons.view_in_ar),
              label: Text(
                context.tr(needsSetup ? 'Set up 3D scanning' : 'Start scan'),
              ),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              key: const ValueKey('bathroom-use-manual'),
              onPressed: busy || scan.busy
                  ? null
                  : () => close(usePhotos: true),
              icon: const Icon(Icons.photo_camera_outlined),
              label: Text(context.tr('Use photos instead')),
            ),
            TextButton(
              onPressed: enabled ? () => run(scan.refreshCapabilities) : null,
              child: Text(context.tr('Check device')),
            ),
          ],
        ),
      if (scene != null) ...[
        if (scene.warnings.isNotEmpty)
          _notice(
            scene.warnings.map((code) => context.tr(_warning(code))).join('\n'),
          ),
        if (scene.source != ScanSource.roomplan)
          SahNotice(
            title: context.tr('Camera scans can’t recognise objects'),
            message: context.tr(
              'Camera-only surface model. Identify features yourself; detected patches are not full walls or clearances.',
            ),
            tone: SahNoticeTone.warning,
          ),
        BathroomModelView(
          key: ValueKey(scene.fingerprint),
          scene: scene,
          selectedId: selected?.id,
          selectedLabel: selected == null
              ? null
              : _itemName(context, scene, selected),
          markers: {
            for (var i = 0; i < scene.elements.length; i++)
              scene.elements[i].id: '${i + 1}',
          },
          onSelect: (id) => setState(() => selectedId = id),
        ),
        if (scene.source == ScanSource.arkit && scene.measurements.isNotEmpty)
          ExpansionTile(
            key: PageStorageKey('scan-distances-${scene.fingerprint}'),
            title: Text(context.tr('Estimated distances')),
            children: [
              Text(
                context.tr(
                  'These camera estimates stay on this phone. Check important measurements with a tape measure.',
                ),
              ),
              for (var i = 0; i < scene.measurements.length; i++)
                ListTile(
                  title: Text(
                    context.tr('Distance {number}: about {metres} m', {
                      'number': i + 1,
                      'metres': scene.measurements[i].metres.toStringAsFixed(2),
                    }),
                  ),
                ),
            ],
          ),
        if (scene.elements.isNotEmpty)
          SahListGroup(
            title: context.tr('In this scan'),
            children: [
              for (final element in scene.elements)
                _item(context, scene, element, element.id == tapped?.id),
            ],
          ),
        if (tapped != null) _feature(context, tapped),
        Text(
          context.tr('What would you like help with?'),
          style: Theme.of(context).textTheme.titleLarge,
        ),
        for (final difficulty in scan.availableDifficulties)
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            title: Text(context.tr(difficulty.labelFor(scan.location))),
            value: scan.review.difficulties.contains(difficulty),
            onChanged: enabled
                ? (value) => run(() => scan.setDifficulty(difficulty, value!))
                : null,
          ),
        if (widget.onAddOtherConcern != null)
          OutlinedButton.icon(
            key: const ValueKey('bathroom-other-concern'),
            onPressed: enabled ? () => close(addOther: true) : null,
            icon: const Icon(Icons.edit_note),
            label: Text(
              context.tr('Something else — add a note'),
              textAlign: TextAlign.center,
            ),
          ),
        Text(
          context.tr('Improvements to explore'),
          style: Theme.of(context).textTheme.titleLarge,
        ),
        if (prompts.length >= 20)
          Text(
            context.tr(
              'Showing the first 20 ideas. Add anything else with a photo or note.',
            ),
          ),
        if (prompts.isEmpty)
          Text(
            scan.review.difficulties.isEmpty
                ? context.tr('Choose a difficulty above to see ideas.')
                : context.tr(
                    'Nothing in the scan matched. That does not mean there is no problem. You can still add a note.',
                  ),
          )
        else
          Text(
            context.tr(
              'Keep the ideas that fit. You can change your choice later.',
            ),
          ),
        for (final suggestion in prompts) _suggestion(context, suggestion),
        ExpansionTile(
          key: const PageStorageKey('scan-options'),
          tilePadding: EdgeInsets.zero,
          title: Text(context.tr('Scan options')),
          children: [
            if (currentReviewFindingId == null)
              TextButton(
                onPressed: enabled ? close : null,
                child: Text(
                  context.tr('Finish without adding a concern'),
                  textAlign: TextAlign.center,
                ),
              ),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                key: const ValueKey('bathroom-start-scan'),
                onPressed: canStart ? capture : null,
                icon: const Icon(Icons.view_in_ar),
                label: Text(
                  context.tr(needsSetup ? 'Set up 3D scanning' : 'Scan again'),
                ),
              ),
            ),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                key: const ValueKey('bathroom-use-manual'),
                onPressed: enabled ? () => close(usePhotos: true) : null,
                icon: const Icon(Icons.photo_camera_outlined),
                label: Text(
                  context.tr('Use photos and measurements'),
                  textAlign: TextAlign.center,
                ),
              ),
            ),
            SizedBox(
              width: double.infinity,
              child: TextButton(
                onPressed: enabled ? () => run(scan.refreshCapabilities) : null,
                child: Text(context.tr('Check device')),
              ),
            ),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: enabled
                    ? () => run(() async {
                        if (await confirm(
                          context.tr('Remove the device model?'),
                          context.tr(
                            'The 3D model and feature reviews will be removed. Any observations already in the assessment remain there.',
                          ),
                          context.tr('Remove model'),
                        )) {
                          await scan.clearModel();
                          selectedId = null;
                        }
                      })
                    : null,
                icon: const Icon(Icons.delete_outline),
                label: Text(context.tr('Remove device model')),
              ),
            ),
          ],
        ),
      ],
      Text(
        context.tr(
          scan.synchronization == null
              ? 'The 3D model stays on this phone.'
              : 'Device models stay on this phone until you explicitly save a private account copy.',
        ),
      ),
    ];
  }

  Widget _modeCard(BuildContext context, BathroomScanCapabilities? capability) {
    final (title, detail) = scanModeCopy(capability);
    final camera =
        capability?.source != 'roomplan' &&
        capability?.canRequestCapture == true;
    return _card([
      Text(context.tr(title), style: Theme.of(context).textTheme.titleLarge),
      if (camera)
        SahTag(label: context.tr('Less precise'), tone: SahNoticeTone.warning),
      Text(context.tr(detail)),
    ]);
  }

  String _itemName(
    BuildContext context,
    BathroomScanScene scene,
    ScanElement element,
  ) {
    final number = scene.elements.indexOf(element) + 1;
    final label = scan.review.labels[element.id];
    if (scene.source == ScanSource.roomplan) {
      return '$number. ${context.tr((label ?? element.kind).label)}';
    }
    final surface = context.tr('Surface {number}', {'number': number});
    return label == null ? surface : '$surface: ${context.tr(label.label)}';
  }

  Widget _item(
    BuildContext context,
    BathroomScanScene scene,
    ScanElement element,
    bool selected,
  ) {
    final lidar = scene.source == ScanSource.roomplan;
    final d = element.dimensions;
    final size = [
      for (final v in [d.x, d.y, d.z])
        if (v > .05) v.toStringAsFixed(1),
    ];
    final details = [
      if (lidar && size.isNotEmpty)
        context.tr('About {size} m · estimate', {'size': size.join(' × ')}),
      if (!lidar && scan.review.labels[element.id] == null)
        context.tr('Not labelled · tap to label'),
      if (scan.review.reviewed.contains(element.id))
        context.tr('Checked by you'),
    ];
    return Semantics(
      selected: selected,
      child: SahActionTile(
        key: ValueKey('scan-item-${element.id}'),
        title: _itemName(context, scene, element),
        subtitle: details.isEmpty ? null : details.join(' · '),
        icon: selected ? Icons.radio_button_checked : Icons.circle_outlined,
        status: selected ? context.tr('Selected') : null,
        statusIcon: selected ? Icons.check : null,
        trailing: const SizedBox.shrink(),
        onTap: enabled ? () => setState(() => selectedId = element.id) : null,
      ),
    );
  }

  Widget _feature(BuildContext context, ScanElement element) {
    final label = scan.review.labels[element.id] ?? element.kind;
    final reviewed = scan.review.reviewed.contains(element.id);
    return _card([
      DropdownButtonFormField<ScanElementKind>(
        key: ValueKey('${element.id}-${label.name}'),
        initialValue: label,
        isExpanded: true,
        isDense: false,
        decoration: InputDecoration(labelText: context.tr('This feature is')),
        items: [
          for (final kind in ScanElementKind.values)
            DropdownMenuItem(value: kind, child: Text(context.tr(kind.label))),
        ],
        onChanged: enabled
            ? (kind) => run(
                () => scan.reviewElement(
                  element.id,
                  confirmed: false,
                  label: kind,
                ),
              )
            : null,
      ),
      CheckboxListTile(
        contentPadding: EdgeInsets.zero,
        controlAffinity: ListTileControlAffinity.leading,
        value: reviewed,
        title: Text(context.tr('I checked this feature’s identity')),
        onChanged: enabled
            ? (value) =>
                  run(() => scan.reviewElement(element.id, confirmed: value!))
            : null,
      ),
    ]);
  }

  Widget _suggestion(BuildContext context, ScanSuggestionCandidate suggestion) {
    final findingId = widget.importedFinding(suggestion.id);
    final added = findingId != null;
    final active =
        widget.activeImports?.call().contains(suggestion.id) ?? added;
    final kept = added && active;
    final notConcern = added
        ? !active
        : scan.review.dismissed.contains(suggestion.id);
    final reversible = !added || widget.onSetImportActive != null;
    final bool? before = kept
        ? true
        : notConcern
        ? false
        : null;
    void choose(bool keep) {
      if (keep == before) return;
      run(() async {
        if (!added && keep) {
          final confirmed = await scan.confirmImprovement(suggestion);
          latestImportedFindingId = await widget.onImport(confirmed);
        } else if (!added) {
          await scan.dismiss(suggestion.id);
        } else {
          await widget.onSetImportActive!(suggestion.id, keep);
          if (keep) latestImportedFindingId = findingId;
        }
        if (mounted) _offerUndo(suggestion.id, keep, before);
      });
    }

    return _card(key: ValueKey('scan-suggestion-${suggestion.id}'), [
      Text(
        context.tr(suggestion.title),
        style: Theme.of(context).textTheme.titleMedium,
      ),
      if (added)
        Semantics(
          liveRegion: true,
          child: Text(
            context.tr(
              busy
                  ? 'Saving this concern on your device…'
                  : active
                  ? 'Added to your plan'
                  : 'Removed from your plan',
            ),
          ),
        ),
      ChoiceButtons<bool>(
        key: ValueKey('scan-suggestion-choice-${suggestion.id}'),
        options: {true: context.tr('Keep'), false: context.tr('Not a concern')},
        selected: before,
        onSelected: enabled && !scan.dirty && reversible ? choose : null,
      ),
    ]);
  }

  void _offerUndo(String suggestionId, bool keep, bool? before) {
    final added = widget.importedFinding(suggestionId) != null;
    final restore = widget.onSetImportActive;
    if (added && restore == null) return;
    ScaffoldMessenger.maybeOf(context)
      ?..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.fixed,
          content: Text(
            context.tr(keep ? 'Concern kept' : 'Marked not a concern'),
          ),
          action: SnackBarAction(
            label: context.tr('Undo'),
            onPressed: () => run(
              () => added
                  ? restore!(suggestionId, before ?? false)
                  : scan.undismiss(suggestionId),
            ),
          ),
        ),
      );
  }

  Widget _card(List<Widget> children, {Key? key}) => Card(
    key: key,
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0) const SizedBox(height: 12),
            children[i],
          ],
        ],
      ),
    ),
  );
  Widget _notice(String text) =>
      Semantics(liveRegion: true, child: _card([Text(context.tr(text))]));
}

String _readiness(BathroomScanCapabilities? capability) {
  if (capability == null) {
    return 'Scanner availability could not be confirmed. Check device, or use photos and measurements.';
  }
  return switch (capability.reason) {
    'available' when capability.supported =>
      capability.source == 'roomplan'
          ? 'LiDAR scanning is ready on this iPhone. RoomPlan builds an approximate model for you to review.'
          : capability.source == 'arkit'
          ? 'This iPhone uses camera-only scanning. Capture surfaces and optional distance estimates.'
          : 'ARCore scanning is ready on this phone. It maps surfaces, and you name the room features.',
    'permission_denied' when capability.source != 'arcore' =>
      'Camera access is blocked. Review Camera access for Safe at Home in iPhone Settings, then return and choose Check device. Photos and manual measurements remain available.',
    'permission_denied' =>
      'Camera access is needed for 3D scanning. Choose Set up 3D scanning to continue. If access is blocked, allow Camera for Safe at Home in Settings, then check device again.',
    'services_missing' =>
      'This phone supports ARCore. Choose Set up 3D scanning to review the Google Play Services for AR installation prompt.',
    'services_update_required' =>
      'Google Play Services for AR needs an update. Choose Set up 3D scanning to review the update prompt.',
    'simulator' =>
      'The simulator cannot capture LiDAR. Use a supported physical iPhone to scan, or continue with photos and measurements.',
    'checking' =>
      'Device support is still being checked. Try Check device again, or continue with photos and measurements.',
    'unsupported_os' when capability.source == 'roomplan' =>
      'Room scanning requires iOS 16 or later on a supported LiDAR device. Photos and measurements are available here.',
    _ =>
      '3D scanning is unavailable on this phone. Continue with photos and manual measurements.',
  };
}

String _warning(String code) => switch (code) {
  'curved_surfaces_approximated' => 'Curved surfaces are only approximated.',
  'geometry_omitted' => 'Some detected geometry could not be included.',
  'depth_unavailable' =>
    'Depth was not available. This model uses surfaces only.',
  'depth_partial' => 'Depth samples cover only part of the room.',
  'tracking_limited' =>
    'Tracking was limited during part of this scan. Check positions carefully.',
  'count_limit' =>
    'The model reached a capture bound. Some geometry is omitted.',
  _ => 'This scan may be incomplete.',
};

(String, String) scanModeCopy(
  BathroomScanCapabilities? capability,
) => switch (capability) {
  null => (
    'Checking this phone',
    'You can start with photos or measurements while we check this phone.',
  ),
  BathroomScanCapabilities(source: 'roomplan', supported: true) => (
    'LiDAR 3D scan',
    'Finds walls, doors, the tub, toilet and sink. Sizes are estimates — measure anything important.',
  ),
  BathroomScanCapabilities(source: 'arkit', supported: true) => (
    'Camera-only scan',
    'This iPhone has no LiDAR. The scan finds flat surfaces only, and you label what they are. Sizes are rough.',
  ),
  BathroomScanCapabilities(source: 'arcore', canRequestCapture: true) => (
    'Camera scan with ARCore',
    'Finds surfaces and points only, and you label what they are. Sizes are rough. Google Play Services for AR may need an update first.',
  ),
  _ => (
    '3D scan isn’t available on this phone',
    'Use photos and measurements instead. They work for every room.',
  ),
};
