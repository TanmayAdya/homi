import '../../app/live_app.dart';
import '../../shared/models/contracts.dart';
import '../../shared/navigation/homi_destination.dart';
import '../assessment/application/home_safety/home_safety_session.dart';
import 'assistant_context_v2.dart';

/// Build chat context from loaded, authorized app state
AssistantContextV2 assistantAppContext(
  AppServices services, {
  required HomiDestination destination,
  HomeSafetySession? rooms,
  MatchResponse? matches,
}) {
  final c = services.coordinator;
  final caseId = c.draft?.caseId;
  final snapshot = c.snapshot;
  final settled =
      !c.hasUnsavedChanges &&
      !c.hasUndurableEdits &&
      !c.busy &&
      !c.uncertain &&
      !c.conflict;
  final roomsReady =
      rooms != null &&
      rooms.isCurrent &&
      rooms.initialized &&
      rooms.caseId == caseId &&
      rooms.snapshot.revision == snapshot?.revision &&
      !rooms.busy &&
      !rooms.hasPending &&
      !rooms.needsReconcile &&
      rooms.conflict == null &&
      !rooms.localSaveFailed;
  final progress = services.progress;
  final tasks =
      progress?.current == true &&
          progress?.feedback == null &&
          progress?.pending.containsKey(caseId) != true
      ? progress?.cached[caseId]
      : null;
  return AssistantContextV2.fromAuthorizedRecords(
    scopeKey: '${c.session.epoch}:${c.generation}:${services.store.accountId}',
    authorized: c.isCurrent,
    access: const AssistantRecordAccess.owner(),
    destination: destination,
    caseId: caseId,
    caseRevision: caseId == null ? null : snapshot?.revision ?? 0,
    settled: settled,
    snapshot: snapshot,
    rooms: roomsReady ? rooms.document : null,
    roomsCaseId: roomsReady ? rooms.caseId : null,
    roomsRevision: roomsReady ? rooms.baseline.revision : null,
    progress: tasks,
    matches: matches,
    capabilities: {
      HomiDestination.plan: FeatureAvailability.supported,
      HomiDestination.settings: FeatureAvailability.supported,
      HomiDestination.rooms: snapshot == null
          ? FeatureAvailability.temporarilyUnavailable
          : FeatureAvailability.supported,
      HomiDestination.help: snapshot == null
          ? FeatureAvailability.temporarilyUnavailable
          : FeatureAvailability.supported,
      HomiDestination.tasks: !services.config.trackingEnabled
          ? FeatureAvailability.configuredOff
          : snapshot == null || tasks == null
          ? FeatureAvailability.temporarilyUnavailable
          : FeatureAvailability.supported,
    },
  );
}
