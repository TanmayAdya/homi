import '../../shared/services/case_coordinator.dart';
import 'local_help_record.dart';
import 'referral_directory.dart';

class LocalHelpRepository {
  LocalHelpRepository(
    this.coordinator, {
    this.directory = const OfficialReferralDirectory(),
  }) : caseId = coordinator.currentDraft().caseId,
       generation = coordinator.generation;
  final CaseCoordinator coordinator;
  final ReferralDirectory directory;
  final String caseId;
  final int generation;
  String get key => 'local-help.$caseId';
  bool get isCurrent =>
      coordinator.isCurrent &&
      coordinator.generation == generation &&
      coordinator.draft?.caseId == caseId;
  void _guard() {
    if (!isCurrent) throw StateError('The selected plan changed.');
    if (coordinator.hasUndurableEdits) {
      throw StateError('Save the plan on this device first.');
    }
  }

  Future<LocalHelpRecord> _read() async {
    _guard();
    final raw = await coordinator.store.readJson(key);
    _guard();
    final record = raw == null
        ? LocalHelpRecord(caseId: caseId)
        : LocalHelpRecord.fromJson(raw);
    if (record.caseId != caseId) {
      throw const FormatException('Local help scope mismatch.');
    }
    return record;
  }

  Future<LocalHelpRecord> load() => coordinator.serialize(_read);
  Future<LocalHelpRecord> _update(
    LocalHelpRecord Function(LocalHelpRecord) change,
  ) => coordinator.serialize(() async {
    final previous = await _read();
    final next = change(previous);
    _guard();
    await coordinator.store.writeJson(key, next.toJson());
    _guard();
    return next;
  });
  LocalHelpRecord _next(
    LocalHelpRecord r, {
    HelpLocation? location,
    List<SavedHelpContact>? contacts,
    List<HelpFollowUp>? tasks,
  }) => LocalHelpRecord(
    caseId: caseId,
    revision: r.revision + 1,
    location: location ?? r.location,
    contacts: contacts ?? r.contacts,
    tasks: tasks ?? r.tasks,
  );
  Future<LocalHelpRecord> confirmLocation(HelpLocation location) =>
      _update((r) => _next(r, location: location));
  Future<LocalHelpRecord> saveContact(String providerId, String note) =>
      _update((r) {
        if (directory.provider(providerId) == null) {
          throw StateError('Unknown referral.');
        }
        final old = r.contacts
            .where((c) => c.providerId == providerId)
            .firstOrNull;
        final contact = SavedHelpContact(
          providerId: providerId,
          note: note.trim(),
          savedAt: old?.savedAt ?? DateTime.now().toUtc().toIso8601String(),
        );
        return _next(
          r,
          contacts: [
            ...r.contacts.where((c) => c.providerId != providerId),
            contact,
          ],
        );
      });
  Future<LocalHelpRecord> removeContact(String providerId) => _update(
    (r) => _next(
      r,
      contacts: r.contacts.where((c) => c.providerId != providerId).toList(),
    ),
  );
  Future<LocalHelpRecord> saveTask(HelpFollowUp task) => _update((r) {
    if (directory.provider(task.providerId) == null) {
      throw StateError('Unknown referral.');
    }
    return _next(r, tasks: [...r.tasks.where((t) => t.id != task.id), task]);
  });
  Future<LocalHelpRecord> completeTask(String id, bool completed) => _update(
    (r) => _next(
      r,
      tasks: [
        for (final t in r.tasks)
          if (t.id != id)
            t
          else
            HelpFollowUp.fromJson({
              ...t.toJson(),
              'completedAt': completed
                  ? DateTime.now().toUtc().toIso8601String()
                  : null,
            }),
      ],
    ),
  );
  Future<LocalHelpRecord> removeTask(String id) => _update(
    (r) => _next(r, tasks: r.tasks.where((t) => t.id != id).toList()),
  );
}
