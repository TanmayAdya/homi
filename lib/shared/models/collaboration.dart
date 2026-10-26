import 'export_contract_values.dart';
import 'request_tracking.dart';

const collaborationRoutes = {
  'read-collaboration',
  'configure-collaboration',
  'update-shared-task',
  'propose-shared-status',
  'review-shared-status',
};
const sharedTaskStates = [
  'pending',
  'in_progress',
  'blocked',
  'completed',
  'cancelled',
];
Map<String, Object?> _object(Object? v, Set<String> keys) =>
    ExportContractValues.object(v, keys);
List<Object?> _list(Object? v, int max) {
  if (v is! List || v.length > max) throw const FormatException();
  return v.cast<Object?>();
}

String _id(Object? v) => ExportContractValues.id(v);
String? _nullableId(Object? v) => v == null ? null : _id(v);
String _time(Object? v) {
  final s = _id(v);
  if (!s.endsWith('Z') || DateTime.tryParse(s) == null) {
    throw const FormatException();
  }
  return s;
}

int _revision(Object? v, {bool zero = false}) =>
    ExportContractValues.integer(v, min: zero ? 0 : 1);

class CollaborationScope {
  const CollaborationScope({
    this.taskIds = const [],
    this.allowTaskProgress = false,
    this.allowStatusProposals = false,
  });
  final List<String> taskIds;
  final bool allowTaskProgress, allowStatusProposals;
  factory CollaborationScope.fromJson(Object? v) {
    final j = _object(v, {
      'taskIds',
      'allowTaskProgress',
      'allowStatusProposals',
    });
    if (j['allowTaskProgress'] is! bool || j['allowStatusProposals'] is! bool) {
      throw const FormatException();
    }
    final ids = _list(j['taskIds'], 32).map(_id).toList();
    if (ids.toSet().length != ids.length) throw const FormatException();
    return CollaborationScope(
      taskIds: List.unmodifiable(ids),
      allowTaskProgress: j['allowTaskProgress'] as bool,
      allowStatusProposals: j['allowStatusProposals'] as bool,
    );
  }
  Map<String, Object?> toJson() => {
    'taskIds': taskIds,
    'allowTaskProgress': allowTaskProgress,
    'allowStatusProposals': allowStatusProposals,
  };
}

class SharedTask {
  SharedTask._(
    this.id,
    this.programId,
    this.findingId,
    this.title,
    this.kind,
    this.state,
    this.responsiblePerson,
    this.dueOn,
    this.revision,
    this.assigneeUserId,
    this.needsReview,
  );
  final String id, title, kind, state;
  final String? programId, findingId, responsiblePerson, dueOn, assigneeUserId;
  final int revision;
  final bool needsReview;
  factory SharedTask.fromJson(Object? v) {
    final j = _object(v, {
      'id',
      'programId',
      'findingId',
      'title',
      'kind',
      'state',
      'responsiblePerson',
      'dueOn',
      'revision',
      'assigneeUserId',
      'needsReview',
    });
    if (!sharedTaskStates.contains(j['state']) ||
        !{
          'profile',
          'room_review',
          'documents',
          'contact',
          'draft_review',
          'follow_up',
          'other',
        }.contains(j['kind']) ||
        j['needsReview'] is! bool) {
      throw const FormatException();
    }
    final title = _id(j['title']);
    if (title.length > 200) throw const FormatException();
    return SharedTask._(
      _id(j['id']),
      _nullableId(j['programId']),
      _nullableId(j['findingId']),
      title,
      j['kind'] as String,
      j['state'] as String,
      _nullableId(j['responsiblePerson']),
      _nullableId(j['dueOn']),
      _revision(j['revision']),
      _nullableId(j['assigneeUserId']),
      j['needsReview'] as bool,
    );
  }
}

class SharedStatusProposal {
  SharedStatusProposal._(
    this.id,
    this.membershipId,
    this.permissionRevision,
    this.caseRevision,
    this.programId,
    this.update,
    this.proposedBy,
    this.proposedAt,
    this.state,
    this.reviewedBy,
    this.reviewedAt,
  );
  final String id, membershipId, programId, proposedBy, proposedAt, state;
  final String? reviewedBy, reviewedAt;
  final int permissionRevision, caseRevision;
  final RequestUpdate update;
  factory SharedStatusProposal.fromJson(Object? v) {
    final j = _object(v, {
      'id',
      'membershipId',
      'permissionRevision',
      'caseRevision',
      'programId',
      'update',
      'proposedBy',
      'proposedAt',
      'state',
      'reviewedBy',
      'reviewedAt',
    });
    if (!{'pending', 'accepted', 'rejected'}.contains(j['state'])) {
      throw const FormatException();
    }
    if (j['state'] == 'pending'
        ? (j['reviewedBy'] != null || j['reviewedAt'] != null)
        : (j['reviewedBy'] == null || j['reviewedAt'] == null)) {
      throw const FormatException();
    }
    return SharedStatusProposal._(
      _id(j['id']),
      _id(j['membershipId']),
      _revision(j['permissionRevision']),
      _revision(j['caseRevision']),
      _id(j['programId']),
      RequestUpdate.fromJson(j['update']),
      _id(j['proposedBy']),
      _time(j['proposedAt']),
      j['state'] as String,
      _nullableId(j['reviewedBy']),
      j['reviewedAt'] == null ? null : _time(j['reviewedAt']),
    );
  }
}

class CollaborationState {
  CollaborationState._(
    this.caseId,
    this.membershipId,
    this.caseRevision,
    this.permissionRevision,
    this.progressRevision,
    this.revision,
    this.canManage,
    this.scope,
    this.tasks,
    this.proposals,
    this.acknowledgement,
  );
  final String caseId, membershipId;
  final int caseRevision, permissionRevision, progressRevision, revision;
  final bool canManage;
  final CollaborationScope scope;
  final List<SharedTask> tasks;
  final List<SharedStatusProposal> proposals;
  final String? acknowledgement;
  factory CollaborationState.fromJson(Object? v) {
    final j = _object(v, {
      'schemaVersion',
      'caseId',
      'membershipId',
      'caseRevision',
      'permissionRevision',
      'progressRevision',
      'collaborationRevision',
      'canManage',
      'scope',
      'tasks',
      'proposals',
      'acknowledgedMutationId',
    });
    if (j['schemaVersion'] != '3' || j['canManage'] is! bool) {
      throw const FormatException();
    }
    final scope = CollaborationScope.fromJson(j['scope']),
        tasks = _list(j['tasks'], 128).map(SharedTask.fromJson).toList(),
        proposals = _list(
          j['proposals'],
          64,
        ).map(SharedStatusProposal.fromJson).toList();
    if (tasks.map((v) => v.id).toSet().length != tasks.length ||
        proposals.map((v) => v.id).toSet().length != proposals.length) {
      throw const FormatException();
    }
    if (j['canManage'] == false &&
        tasks.any((t) => !scope.taskIds.contains(t.id))) {
      throw const FormatException();
    }
    final membership = _id(j['membershipId']);
    if (proposals.any((p) => p.membershipId != membership)) {
      throw const FormatException();
    }
    return CollaborationState._(
      _id(j['caseId']),
      membership,
      _revision(j['caseRevision']),
      _revision(j['permissionRevision']),
      _revision(j['progressRevision'], zero: true),
      _revision(j['collaborationRevision'], zero: true),
      j['canManage'] as bool,
      scope,
      List.unmodifiable(tasks),
      List.unmodifiable(proposals),
      _nullableId(j['acknowledgedMutationId']),
    );
  }
}
