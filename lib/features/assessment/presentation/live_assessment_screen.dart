import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../../local_help/local_help_screen.dart';
import 'package:safe_at_home/l10n/app_localizations.dart';

import '../../../app/live_app.dart';
import '../../../shared/services/matching_api_client.dart';
import '../application/live_assessment_session.dart';
import '../application/bathroom_scan_adapter.dart';
import '../application/bathroom_scan_availability.dart';
import 'assessment_scan_entry.dart';
import '../application/bathroom_scan_session.dart';
import 'assessment_flow_screen.dart';
import 'assessment_copy.dart';
import 'bathroom_scan_screen.dart';
import 'save_status_card.dart';
import 'home_safety/home_safety_screen.dart';
import '../domain/home_safety/home_safety.dart';
import '../application/assessment_sync.dart';
import '../application/assessment_flow.dart';
import '../domain/assessment_location.dart';
import '../domain/local_place_rooms.dart';
import 'room_capture_cards.dart';
import 'whole_home_screen.dart';
import '../../../shared/presentation/sah_components.dart';
import 'recovery_photo_review_card.dart';

class LiveAssessmentScreen extends StatefulWidget {
  const LiveAssessmentScreen({
    super.key,
    required this.services,
    this.initialFindingId,
    this.scanRoom,
    this.startWithRoomScan = false,
    this.legacyScan = false,
    this.initialManualPhoto = true,
    this.embedded = false,
  });
  final String? initialFindingId;
  final RoomInstance? scanRoom;
  final bool startWithRoomScan, legacyScan;
  final bool initialManualPhoto;
  final bool embedded;
  final AppServices services;
  @override
  State<LiveAssessmentScreen> createState() => LiveAssessmentScreenState();
}

class LiveAssessmentScreenState extends State<LiveAssessmentScreen>
    with WidgetsBindingObserver {
  late final LiveAssessmentSession session = LiveAssessmentSession(
    services: widget.services,
    context: () => context,
  );
  late final BathroomScanAvailability scanAvailability =
      BathroomScanAvailability(
        adapter:
            widget.services.bathroomScanAdapter ??
            const NativeBathroomScanAdapter(),
        isCurrent: () => mounted && session.isCurrent,
      );
  late final Future<void> ready;
  bool busy = false, canPop = false, initialized = false;
  bool _measurementRequested = false;
  String? notice;
  final saveStatusKey = GlobalKey();
  Uint8List? recoveredPhoto;
  SavedScanState savedScan = SavedScanState.loading;
  int _scanEpoch = 0;
  bool get _placeList => widget.scanRoom == null && !widget.legacyScan;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    ready = session.initialize().then((_) async {
      await refreshSavedScan();
      initialized = true;
      final findingId = widget.initialFindingId;
      if (findingId != null && session.controller.draftOf(findingId) != null) {
        session.flow.openFinding(findingId);
      }
      if (mounted) scanAvailability.refresh();
      if (widget.scanRoom != null &&
          !widget.startWithRoomScan &&
          findingId == null) {
        openManualConcern(photo: widget.initialManualPhoto);
      }
      if (widget.startWithRoomScan) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted &&
              session.isCurrent &&
              ModalRoute.of(context)?.isCurrent == true) {
            unawaited(openBathroomScan());
          }
        });
      }
    });
  }

  bool get canLeave =>
      !busy &&
      (!initialized || (!session.flow.isBusy && !session.localSaveFailed));

  Future<bool> prepareToLeave() async {
    if (!canLeave) return false;
    if (!initialized) return true;
    try {
      await session.flush();
    } catch (_) {
      return false;
    }
    return mounted && canLeave;
  }

  bool handleBack() {
    if (!canLeave) return true;
    if (initialized && session.flow.canGoBack) {
      session.flow.back();
      return true;
    }
    return false;
  }

  Widget _page({required Widget body, AppBar? appBar}) => widget.embedded
      ? body
      : Scaffold(
          appBar: appBar,
          body: SafeArea(child: body),
        );

  static final _scanSource = RegExp(
    r' Source: (?:iPhone RoomPlan|Android ARCore|iPhone ARKit camera) partial scan ',
  );

  Future<void> refreshSavedScan() async {
    SavedScanState next;
    try {
      final review = await BathroomScanSession.readSaved(
        widget.services.store,
        session.caseId,
        room: widget.scanRoom,
      );
      next = review?.scene == null
          ? session.controller.drafts.any(
                  (d) => _scanSource.hasMatch(d.observation),
                )
                ? SavedScanState.otherDevice
                : SavedScanState.none
          : review!.difficulties.isEmpty &&
                review.reviewed.isEmpty &&
                review.dismissed.isEmpty &&
                session.activeScanImports.isEmpty
          ? SavedScanState.unreviewed
          : SavedScanState.reviewed;
    } catch (_) {
      next = SavedScanState.unreviewed;
    }
    if (mounted && session.isCurrent) setState(() => savedScan = next);
  }

  bool get _hasSavedModel =>
      savedScan == SavedScanState.unreviewed ||
      savedScan == SavedScanState.reviewed;

  void chooseLocation(AssessmentLocation location) {
    session.flow.chooseLocation(location);
  }

  bool get _canOpenScan =>
      !busy &&
      !session.flow.isBusy &&
      !session.localConflict &&
      session.sync.canSave;

  Future<void> run(Future<void> Function() action) async {
    if (busy || session.flow.isBusy) return;
    setState(() {
      busy = true;
      notice = null;
    });
    try {
      await action();
    } on MatchingApiException catch (error) {
      if (mounted) setState(() => notice = error.message);
    } catch (_) {
      if (mounted) {
        setState(
          () => notice =
              'This step could not finish. Your local edits are retained. Check saved state before trying again.',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> close() => run(() async {
    final route = ModalRoute.of(context);
    try {
      await ready;
    } catch (_) {
      // ignore: empty_catches
    }
    if (initialized) await session.flush();
    if (!mounted ||
        route?.isCurrent != true ||
        !identical(route, ModalRoute.of(context))) {
      return;
    }
    setState(() => canPop = true);
    Navigator.of(context).pop();
  });

  Future<void> continueToCase() async {
    final route = ModalRoute.of(context);
    await run(() async {
      await session.save();
      await session.flush();
      session.guard();
      if (session.localConflict ||
          session.localSaveFailed ||
          session.sync.phase != SyncPhase.idle ||
          session.sync.hasUnsavedWork ||
          session.pendingRequest != null ||
          session.annotationConflictId != null ||
          session.photoMarksUnsaved != false) {
        return;
      }
      if (!mounted ||
          route?.isCurrent != true ||
          !identical(route, ModalRoute.of(context))) {
        return;
      }
      if (widget.embedded) {
        session.flow.startAnother();
      } else {
        setState(() => canPop = true);
        Navigator.of(context).pop();
      }
    });
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted ||
        canPop ||
        route?.isCurrent != true ||
        !identical(route, ModalRoute.of(context))) {
      return;
    }
    final statusContext = saveStatusKey.currentContext;
    if (statusContext != null && statusContext.mounted) {
      await Scrollable.ensureVisible(statusContext, alignment: 0);
    }
  }

  void openManualConcern({required bool photo, AssessmentLocation? location}) {
    session.guard();
    if (session.flow.step == AssessmentStep.review) {
      session.flow.startAnother();
    }
    if (session.flow.step != AssessmentStep.chooseArea) {
      setState(() {
        notice =
            'Finish the open concern before starting another room. Your unfinished work is still here.';
      });
      return;
    }
    _measurementRequested = !photo;
    session.flow.chooseLocation(
      location ?? widget.scanRoom?.type ?? AssessmentLocation.bathroom,
    );
    if (!photo) session.flow.continueWithoutPhoto();
  }

  Future<void> openBathroomScan({
    RoomInstance? room,
    bool forceLegacy = false,
  }) async {
    final targetRoom = room ?? widget.scanRoom;
    if (widget.scanRoom == null &&
        room == null &&
        !forceLegacy &&
        !widget.legacyScan &&
        widget.services.config.homeSafetyEnabled) {
      await run(() async {
        await session.flush();
        session.guard();
        if (!mounted || ModalRoute.of(context)?.isCurrent != true) return;
        unawaited(
          Navigator.of(context).pushReplacement(
            MaterialPageRoute<void>(
              builder: (_) =>
                  HomeSafetyScreen(services: widget.services, scansFirst: true),
            ),
          ),
        );
      });
      return;
    }
    var finish = false;
    await run(() async {
      session.guard();
      await session.flush();
      session.guard();
      if (!mounted) return;
      final scanner = BathroomScanSession(
        syncApi: LocalPlaceRooms.contains(targetRoom)
            ? null
            : widget.services.scanModels,
        caseRevision: () => widget.services.coordinator.currentCase().revision,
        store: widget.services.store,
        caseId: session.caseId,
        room: targetRoom,
        isCurrent: () => session.isCurrent,
        adapter:
            widget.services.bathroomScanAdapter ??
            const NativeBathroomScanAdapter(),
      );
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => BathroomScanScreen(
            session: scanner,
            scope: session,
            importedFinding: (id) => session.localSaveFailed
                ? null
                : session.importedScanFinding(id),
            activeImports: () =>
                session.activeScanImportsForRoom(targetRoom?.id),
            onImport: session.importScanObservation,
            onSetImportActive: session.setScanImportActive,
            onContinue: (_) {
              session.guard();
              finish = true;
            },
            onAddOtherConcern: () =>
                openManualConcern(photo: false, location: targetRoom?.type),
            onUsePhotos: () =>
                openManualConcern(photo: true, location: targetRoom?.type),
          ),
        ),
      );
      session.guard();
      await session.flush();
      scanAvailability.refresh();
      await refreshSavedScan();
      if (mounted) setState(() => _scanEpoch++);
    });
    if (finish && mounted) await continueToCase();
  }

  Future<void> openConnectedPlaces() => run(() async {
    await session.flush();
    session.guard();
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => WholeHomeScreen(
          services: widget.services,
          rooms: () => LocalPlaceRooms.all,
          isCurrent: () => mounted && session.isCurrent,
          scope: session,
          localPlaces: true,
        ),
      ),
    );
    if (mounted && session.isCurrent) setState(() => _scanEpoch++);
  });

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed &&
        initialized &&
        !busy &&
        ModalRoute.of(context)?.isCurrent == true) {
      scanAvailability.refresh();
    }
    if (initialized &&
        (state == AppLifecycleState.inactive ||
            state == AppLifecycleState.paused)) {
      Future<void>.sync(session.flush).catchError((Object _) {});
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    scanAvailability.dispose();
    session.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: widget.embedded || canPop,
    onPopInvokedWithResult: (didPop, result) {
      if (!widget.embedded && !didPop) close();
    },
    child: FutureBuilder<void>(
      future: ready,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          void leaveUnopenedAssessment() {
            setState(() => canPop = true);
            Navigator.of(context).pop();
          }

          return _page(
            appBar: AppBar(
              title: Text(context.tr('Home assessment')),
              leading: BackButton(onPressed: leaveUnopenedAssessment),
            ),
            body: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 680),
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        context.tr(
                          'The saved assessment could not be opened. Your private draft has been kept. Check your connection and open this case again.',
                        ),
                      ),
                      SizedBox(height: 24),
                      if (!widget.embedded)
                        FilledButton(
                          key: const ValueKey('assessment-error-back'),
                          onPressed: leaveUnopenedAssessment,
                          child: Text(context.tr('Back to case')),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          );
        }
        if (snapshot.connectionState != ConnectionState.done) {
          return _page(
            body: Center(
              child: CircularProgressIndicator(
                semanticsLabel: context.tr('Opening assessment'),
              ),
            ),
          );
        }
        return ListenableBuilder(
          listenable: Listenable.merge([session, scanAvailability]),
          builder: (context, _) {
            final bool? marksUnsaved =
                session.annotationNotice != null ||
                    session.annotationConflictId != null
                ? null
                : session.photoMarksUnsaved;
            return AssessmentFlowScreen(
              roomCards: _placeList
                  ? RoomCaptureCards(
                      key: ValueKey(
                        'place-scans-${session.caseId}-$_scanEpoch',
                      ),
                      store: widget.services.store,
                      caseId: session.caseId,
                      rooms: LocalPlaceRooms.all,
                      availability: scanAvailability,
                      isCurrent: () => mounted && session.isCurrent,
                      enabled: _canOpenScan,
                      mergeLegacyBathroom: true,
                      onScan: (room) => openBathroomScan(
                        room: room,
                        forceLegacy: room == null,
                      ),
                      onOpenRoom: (room) => chooseLocation(room.type),
                      onConnected: openConnectedPlaces,
                    )
                  : null,
              embedded: widget.embedded,
              expandMeasurements: _measurementRequested,
              flow: session.flow,
              onContinue: continueToCase,
              scanFindingIds: session.activeScanImports
                  .map(session.importedScanFinding)
                  .whereType<String>()
                  .toSet(),
              keptOnDevice: !session.localSaveFailed,
              enabled:
                  !busy &&
                  (!session.localConflict || session.caseWriteBlocked) &&
                  session.sync.recoveryConflict == null,
              actions: [
                LocalHelpButton(
                  services: widget.services,
                  findingId: session.flow.findingId,
                ),
                if (widget.embedded && _placeList)
                  TextButton.icon(
                    onPressed: busy ? null : history,
                    icon: const Icon(Icons.history),
                    label: Text(context.tr('Saved review history')),
                  )
                else
                  IconButton(
                    onPressed: busy ? null : history,
                    tooltip: context.tr('Saved review history'),
                    icon: const Icon(Icons.history),
                  ),
                if (!widget.embedded)
                  IconButton(
                    onPressed: busy || session.flow.isBusy ? null : close,
                    tooltip: context.tr('Save on device and close'),
                    icon: const Icon(Icons.close),
                  ),
              ],
              areaToolsFirst:
                  _placeList || scanAvailability.prefersScan || _hasSavedModel,
              onChooseLocation: chooseLocation,
              locationStatus: {
                if (_hasSavedModel)
                  widget.scanRoom?.type ?? AssessmentLocation.bathroom:
                      '3D scan saved',
              },
              areaTools: _placeList
                  ? Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: OutlinedButton.icon(
                        key: const ValueKey('open-whole-home-model'),
                        onPressed: _canOpenScan ? openConnectedPlaces : null,
                        icon: const Icon(Icons.home_work_outlined),
                        label: Text(context.tr('Scan connected rooms')),
                      ),
                    )
                  : _hasSavedModel &&
                        widget.scanRoom == null &&
                        (!widget.services.config.homeSafetyEnabled ||
                            widget.legacyScan)
                  ? null
                  : AssessmentScanEntry(
                      rooms:
                          widget.scanRoom == null &&
                          !widget.legacyScan &&
                          widget.services.config.homeSafetyEnabled,
                      roomTitle:
                          widget.scanRoom?.name ??
                          (widget.scanRoom == null
                              ? null
                              : context.tr(widget.scanRoom!.type.title)),
                      availability: scanAvailability,
                      saved: savedScan,
                      onCheck: busy || !session.isCurrent
                          ? null
                          : scanAvailability.refresh,
                      onOpen: _canOpenScan ? openBathroomScan : null,
                    ),
              status: Column(
                key: saveStatusKey,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (notice != null)
                    SahNotice(
                      message: context.tr(notice!),
                      tone: SahNoticeTone.warning,
                    ),
                  if (session.resumeNotice != null)
                    SahNotice(
                      message: context.tr(session.resumeNotice!),
                      icon: Icons.cloud_off_outlined,
                    ),
                  if (session.caseWriteNotice != null)
                    SahNotice(
                      message: context.tr(session.caseWriteNotice!),
                      tone: SahNoticeTone.warning,
                    ),
                  if (session.localSaveFailed)
                    SahNotice(
                      title: context.tr('Not saved on this device'),
                      message: context.tr(
                        'The private device save failed. Keep this screen open and free some device space before leaving.',
                      ),
                      tone: SahNoticeTone.error,
                    ),
                  if (session.localConflict) ...[
                    SahNotice(
                      title: context.tr(
                        'This device and the saved assessment differ',
                      ),
                      message: context.tr(
                        'Keeping this device’s findings will replace the saved assessment when you explicitly save. Other profile details stay from the latest saved case.\n\nDevice: {deviceCount} findings. Saved: {savedCount} findings.',
                        {
                          'deviceCount': session.controller.findings.length,
                          'savedCount':
                              session.state?.caseSnapshot.findings.length ?? 0,
                        },
                      ),
                      tone: SahNoticeTone.warning,
                    ),
                    OutlinedButton(
                      onPressed:
                          busy ||
                              session.flow.isBusy ||
                              session.caseWriteBlocked
                          ? null
                          : () => run(
                              () =>
                                  session.resolveLocalConflict(keepLocal: true),
                            ),
                      child: Text(
                        context.tr('Keep this device’s findings for review'),
                        textAlign: TextAlign.center,
                      ),
                    ),
                    TextButton(
                      onPressed:
                          busy ||
                              session.flow.isBusy ||
                              session.caseWriteBlocked
                          ? null
                          : () => run(
                              () => session.resolveLocalConflict(
                                keepLocal: false,
                              ),
                            ),
                      child: Text(
                        context.tr(
                          'Discard device edits and use saved assessment',
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ),
                    SizedBox(height: 8),
                  ],
                  if (session.sync.recoveryConflict != null)
                    RecoveryPhotoReviewCard(
                      bytes: recoveredPhoto,
                      busy: busy,
                      onShowSaved: () => run(() async {
                        setState(() => recoveredPhoto = null);
                        final bytes = await session.sync
                            .showRecoveredEvidence();
                        if (mounted) setState(() => recoveredPhoto = bytes);
                      }),
                      onKeepSaved: () => run(() async {
                        await session.sync.acceptRecoveredEvidence();
                        await session.flow.refreshSavedImages();
                        await session.flush();
                        recoveredPhoto = null;
                      }),
                      onKeepDevice: () => run(() async {
                        session.sync.keepLocalEvidence();
                        await session.flush();
                        recoveredPhoto = null;
                      }),
                    )
                  else if (!session.localConflict && !session.caseWriteBlocked)
                    SaveStatusCard(
                      sync: session.sync,
                      durableLocal: !session.localSaveFailed,
                      undescribedDraftOpen: session
                          .controller
                          .incompleteFindingIds
                          .any(
                            (id) => !session.sync.savedCase.findings.any(
                              (f) => f.id == id,
                            ),
                          ),
                      photoMarksUnsaved: marksUnsaved,
                      enabled: !busy && !session.flow.isBusy,
                      onSave: () => run(session.save),
                      onRecover: () => run(session.recover),
                    ),
                  if (session.annotationNotice != null)
                    SahNotice(
                      message: context.tr(session.annotationNotice!),
                      tone: SahNoticeTone.warning,
                    ),
                  if (session.annotationConflictId != null)
                    TextButton(
                      onPressed: busy || session.flow.isBusy
                          ? null
                          : () => run(session.reloadConflictingMarks),
                      child: Text(
                        context.tr(
                          'Discard device marks for this photo and reload saved marks',
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  if (!session.localConflict &&
                      session.sync.recoveryConflict == null &&
                      session.sync.phase == SyncPhase.idle &&
                      !session.sync.hasUnsavedWork &&
                      marksUnsaved != true &&
                      session.controller.findings.any(
                        (f) => f.evidenceIds.isNotEmpty,
                      ))
                    Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: TextButton.icon(
                        key: const ValueKey('assessment-save-online'),
                        onPressed:
                            busy ||
                                session.flow.isBusy ||
                                session.caseWriteBlocked
                            ? null
                            : () => run(session.save),
                        icon: const Icon(Icons.cloud_upload_outlined),
                        label: Text(
                          context.tr('Save findings and photo marks online'),
                        ),
                      ),
                    ),
                  SizedBox(height: 8),
                ],
              ),
            );
          },
        );
      },
    ),
  );

  void history() {
    final events = session.state?.history.reversed.toList() ?? [];
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.tr('Saved assessment history')),
        content: SizedBox(
          width: 560,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: events.isEmpty
                  ? [
                      Text(
                        context.tr(
                          'No online assessment corrections have been saved yet.',
                        ),
                      ),
                    ]
                  : [
                      for (final event in events)
                        ExpansionTile(
                          title: Text(
                            DateTime.tryParse(
                                  event['recordedAt'] as String? ?? '',
                                )?.toLocal().toString() ??
                                context.tr('Saved review'),
                          ),
                          subtitle: Text(
                            context.tr('Recorded by the signed-in account'),
                          ),
                          children: [
                            for (final change in event['changes'] as List)
                              Padding(
                                padding: const EdgeInsets.all(8),
                                child: Text(
                                  context.tr(
                                    '{change}\nBefore: {before}\nAfter: {after}',
                                    {
                                      'change': context.tr(
                                        _changeName((change as Map)['path']),
                                      ),
                                      'before': assessmentHistoryValue(
                                        context,
                                        change['before'],
                                      ),
                                      'after': assessmentHistoryValue(
                                        context,
                                        change['after'],
                                      ),
                                    },
                                  ),
                                ),
                              ),
                          ],
                        ),
                    ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(context.tr('Close')),
          ),
        ],
      ),
    );
  }
}

String _changeName(Object? path) {
  final text = path.toString();
  if (text.contains('measurement')) return 'Measurement details';
  if (text.contains('review')) return 'Review decision';
  if (text.contains('finding')) return 'Finding details';
  return 'Assessment details';
}
