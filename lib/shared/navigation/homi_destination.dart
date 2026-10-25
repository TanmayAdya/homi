enum HomiDestination { plan, rooms, help, tasks, settings }

class HomiTarget {
  const HomiTarget(
    this.destination, {
    this.caseId,
    this.roomId,
    this.findingId,
    this.programId,
    this.taskId,
  });
  final HomiDestination destination;
  final String? caseId, roomId, findingId, programId, taskId;
}

enum FeatureAvailability {
  configuredOff,
  supported,
  unsupportedDevice,
  backendUnavailable,
  temporarilyUnavailable,
}
