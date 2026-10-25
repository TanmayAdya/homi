import 'collaboration.dart';
import 'export_contract_values.dart';

typedef Json = Map<String, Object?>;
Json _object(Object? v, Set<String> keys) =>
    ExportContractValues.object(v, keys);
List<Object?> _list(Object? v, int max) {
  if (v is! List || v.length > max) throw const FormatException();
  return v.cast<Object?>();
}

String _text(Object? v, [int max = 500]) {
  if (v is! String || v.isEmpty || v.length > max) {
    throw const FormatException();
  }
  return v;
}

int _revision(Object? v) {
  if (v is! int || v < 1) throw const FormatException();
  return v;
}

String _id(Object? v) => ExportContractValues.id(v);

/// Check owner-entered labels for length and control characters
bool validSharingLabel(String v) =>
    v.isNotEmpty &&
    v.trim() == v &&
    v.runes.length <= 80 &&
    !RegExp(
      r'[\u0000-\u001f\u007f-\u009f\u2028\u2029\u202a-\u202e\u2066-\u2069]',
    ).hasMatch(v);

String? _label(Json j, String key) {
  if (!j.containsKey(key)) return null;
  final v = j[key];
  if (v is! String || !validSharingLabel(v)) throw const FormatException();
  return v;
}

const _labelKeys = {'recipientLabel', 'ownerLabel'};
String _time(Object? v) {
  final s = _text(v, 40);
  if (DateTime.tryParse(s) == null || !s.endsWith('Z')) {
    throw const FormatException();
  }
  return s;
}

class ShareScope {
  const ShareScope({
    this.findingIds = const [],
    this.programIds = const [],
    this.allowHelperNotes = false,
  });
  final List<String> findingIds, programIds;
  final bool allowHelperNotes;
  factory ShareScope.fromJson(Object? v) {
    final j = _object(v, {'findingIds', 'programIds', 'allowHelperNotes'});
    if (j['allowHelperNotes'] is! bool) throw const FormatException();
    final findings = _list(j['findingIds'], 32).map(_id).toList(),
        programs = _list(j['programIds'], 4).map(_id).toList();
    if (findings.toSet().length != findings.length ||
        programs.toSet().length != programs.length) {
      throw const FormatException();
    }
    return ShareScope(
      findingIds: List.unmodifiable(findings),
      programIds: List.unmodifiable(programs),
      allowHelperNotes: j['allowHelperNotes'] as bool,
    );
  }
  Json toJson() => {
    'findingIds': findingIds,
    'programIds': programIds,
    'allowHelperNotes': allowHelperNotes,
  };
}

class CaseMembership {
  CaseMembership._(
    this.id,
    this.caseId,
    this.recipientId,
    this.grantorId,
    this.role,
    this.scope,
    this.revision,
    this.expiresAt,
    this.invitationExpiresAt,
    this.state,
    this.recipientLabel,
    this.ownerLabel,
  );
  final String id,
      caseId,
      recipientId,
      grantorId,
      role,
      invitationExpiresAt,
      state;
  final String? expiresAt;

  final String? recipientLabel;

  final String? ownerLabel;
  final ShareScope scope;
  final int revision;

  factory CaseMembership.fromJson(Object? v, {bool ownerView = false}) {
    final j = _object(v, {
      'membershipId',
      'caseId',
      'recipientId',
      'grantorId',
      'role',
      'scope',
      'permissionRevision',
      'expiresAt',
      'invitationExpiresAt',
      'state',
      if (v is Map && v.containsKey('ownerLabel')) 'ownerLabel',
      if (ownerView && v is Map && v.containsKey('recipientLabel'))
        'recipientLabel',
    });
    if (!{'viewer', 'helper'}.contains(j['role']) ||
        !{'pending', 'active', 'expired', 'revoked'}.contains(j['state'])) {
      throw const FormatException();
    }
    final scope = ShareScope.fromJson(j['scope']);
    if (j['role'] == 'viewer' && scope.allowHelperNotes) {
      throw const FormatException();
    }
    return CaseMembership._(
      _id(j['membershipId']),
      _id(j['caseId']),
      _id(j['recipientId']),
      _id(j['grantorId']),
      j['role'] as String,
      scope,
      _revision(j['permissionRevision']),
      j['expiresAt'] == null ? null : _time(j['expiresAt']),
      _time(j['invitationExpiresAt']),
      j['state'] as String,
      _label(j, 'recipientLabel'),
      _label(j, 'ownerLabel'),
    );
  }
}

class SharedFinding {
  SharedFinding._(this.id, this.room, this.observation, this.reviewState);
  final String id, room, observation, reviewState;
  factory SharedFinding.fromJson(Object? v) {
    final j = _object(v, {'id', 'room', 'observation', 'reviewState'});
    if (!{'bathroom', 'entrance', 'other'}.contains(j['room']) ||
        !{
          'confirmed',
          'needs_review',
          'dismissed',
        }.contains(j['reviewState'])) {
      throw const FormatException();
    }
    return SharedFinding._(
      _id(j['id']),
      j['room'] as String,
      _text(j['observation'], 2000),
      j['reviewState'] as String,
    );
  }
}

class SharedProgram {
  SharedProgram._(this.id, this.status, this.occurredOn);
  final String id;
  final String? status, occurredOn;
  factory SharedProgram.fromJson(Object? v) {
    final j = _object(v, {'programId', 'status', 'occurredOn', 'provenance'});
    if (j['provenance'] != 'user_reported' ||
        (j['status'] == null) != (j['occurredOn'] == null)) {
      throw const FormatException();
    }
    return SharedProgram._(
      _id(j['programId']),
      j['status'] == null ? null : _text(j['status'], 40),
      j['occurredOn'] == null ? null : _text(j['occurredOn'], 10),
    );
  }
}

class SharedCaseProjection {
  SharedCaseProjection._(
    this.caseId,
    this.revision,
    this.publishedAt,
    this.stale,
    this.findings,
    this.programs,
  );
  final String caseId, publishedAt;
  final int revision;
  final bool stale;
  final List<SharedFinding> findings;
  final List<SharedProgram> programs;
  factory SharedCaseProjection.fromJson(Object? v) {
    final j = _object(v, {
      'schemaVersion',
      'caseId',
      'sourceRevision',
      'publishedAt',
      'stale',
      'summary',
      'findings',
      'programs',
    });
    if (j['schemaVersion'] != '3' ||
        j['stale'] is! bool ||
        j['summary'] != 'Selected home safety information') {
      throw const FormatException();
    }
    return SharedCaseProjection._(
      _id(j['caseId']),
      _revision(j['sourceRevision']),
      _time(j['publishedAt']),
      j['stale'] as bool,
      List.unmodifiable(_list(j['findings'], 32).map(SharedFinding.fromJson)),
      List.unmodifiable(_list(j['programs'], 4).map(SharedProgram.fromJson)),
    );
  }
}

class SharedNote {
  SharedNote._(this.id, this.authorId, this.text, this.recordedAt);
  final String id, authorId, text, recordedAt;
  factory SharedNote.fromJson(Object? v) {
    final j = _object(v, {'mutationId', 'authorId', 'note', 'recordedAt'});
    return SharedNote._(
      _id(j['mutationId']),
      _id(j['authorId']),
      _text(j['note']),
      _time(j['recordedAt']),
    );
  }
}

class OwnerShare {
  OwnerShare._(
    this.membership,
    this.projection,
    this.notes,
    this.audit,
    this.invitedEmail,
  );
  final CaseMembership membership;
  final SharedCaseProjection? projection;
  final List<SharedNote> notes;
  final List<Json> audit;
  final String? invitedEmail;
  factory OwnerShare.fromJson(Object? v) {
    final j = _object(v, {
      'membershipId',
      'caseId',
      'recipientId',
      'grantorId',
      'role',
      'scope',
      'permissionRevision',
      'expiresAt',
      'invitationExpiresAt',
      'state',
      'projection',
      'notes',
      'audit',
      if (v is Map && v.containsKey('invitedEmail')) 'invitedEmail',
      for (final key in _labelKeys)
        if (v is Map && v.containsKey(key)) key,
    });
    final email = j['invitedEmail'];
    if (email != null &&
        (email is! String ||
            email.length > 254 ||
            !RegExp(
              r'^[a-z0-9._%+-]+@[a-z0-9-]+(?:\.[a-z0-9-]+)+$',
            ).hasMatch(email))) {
      throw const FormatException();
    }
    final member = Map<String, Object?>.of(j)
      ..remove('projection')
      ..remove('notes')
      ..remove('audit');
    member.remove('invitedEmail');
    final audit = _list(j['audit'], 100).map((v) {
      final a = _object(v, {'type', 'actorId', 'at'});
      _id(a['actorId']);
      _time(a['at']);
      if (!{
        'invited',
        'accepted',
        'changed',
        'revoked',
        'read',
        'note',
      }.contains(a['type'])) {
        throw const FormatException();
      }
      return a;
    }).toList();
    return OwnerShare._(
      CaseMembership.fromJson(member, ownerView: true),
      j['projection'] == null
          ? null
          : SharedCaseProjection.fromJson(j['projection']),
      _list(j['notes'], 50).map(SharedNote.fromJson).toList(),
      audit,
      email as String?,
    );
  }
}

class SharingResponse {
  SharingResponse._({
    this.membership,
    this.projection,
    this.availableProgramIds = const [],
    this.memberships = const [],
    this.shares = const [],
    this.notes = const [],
    this.invitationCode,
    this.collaboration,
  });
  final List<String> availableProgramIds;
  final CaseMembership? membership;
  final SharedCaseProjection? projection;
  final List<CaseMembership> memberships;
  final List<OwnerShare> shares;
  final List<SharedNote> notes;
  final String? invitationCode;
  final CollaborationState? collaboration;
  factory SharingResponse.fromJson(Object? value, String route) {
    if (collaborationRoutes.contains(route)) {
      return SharingResponse._(
        collaboration: CollaborationState.fromJson(value),
      );
    }
    final keys = <String>{
      'schemaVersion',
      ...switch (route) {
        'preview-sharing' => {'projection'},
        'list-sharing' ||
        'list-email-sharing' => {'shares', 'availableProgramIds'},
        'list-shared-cases' => {'memberships'},
        'create-invitation' || 'create-email-invitation' => {
          'membership',
          'created',
          'invitationCode',
        },
        'read-shared-case' ||
        'add-shared-note' => {'membership', 'projection', 'notes'},
        _ => {'membership'},
      },
    };
    final j = _object(value, keys);
    if (j['schemaVersion'] != '3') throw const FormatException();
    if ({'create-invitation', 'create-email-invitation'}.contains(route) &&
        (j['created'] is! bool ||
            ((j['created'] == true) != (j['invitationCode'] != null)))) {
      throw const FormatException();
    }
    final grant = j['membership'] == null
        ? null
        : CaseMembership.fromJson(j['membership']);
    final p = j['projection'] == null
        ? null
        : SharedCaseProjection.fromJson(j['projection']);
    if (grant != null &&
        p != null &&
        (grant.caseId != p.caseId ||
            p.findings.any((f) => !grant.scope.findingIds.contains(f.id)) ||
            p.programs.any((v) => !grant.scope.programIds.contains(v.id)))) {
      throw const FormatException();
    }
    return SharingResponse._(
      availableProgramIds: j['availableProgramIds'] == null
          ? const []
          : _list(j['availableProgramIds'], 36).map(_id).toList(),
      membership: grant,
      projection: p,
      invitationCode: j['invitationCode'] == null
          ? null
          : _text(j['invitationCode'], 43),
      memberships: j['memberships'] == null
          ? const []
          : _list(j['memberships'], 1024).map(CaseMembership.fromJson).toList(),
      shares: j['shares'] == null
          ? const []
          : _list(j['shares'], 16).map(OwnerShare.fromJson).toList(),
      notes: j['notes'] == null
          ? const []
          : _list(j['notes'], 50).map(SharedNote.fromJson).toList(),
    );
  }
}
