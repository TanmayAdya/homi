import 'export_contract_values.dart';

class DeletionCounts {
  const DeletionCounts({
    required this.cases,
    required this.evidence,
    required this.exports,
    required this.storedBytes,
  });
  final int cases, evidence, exports, storedBytes;
  factory DeletionCounts.fromJson(Object? json) {
    final value = ExportContractValues.object(json, {
      'cases',
      'evidence',
      'exports',
      'storedBytes',
    });
    int count(String name) => ExportContractValues.integer(value[name], min: 0);
    return DeletionCounts(
      cases: count('cases'),
      evidence: count('evidence'),
      exports: count('exports'),
      storedBytes: count('storedBytes'),
    );
  }
  Map<String, Object?> toJson() => {
    'cases': cases,
    'evidence': evidence,
    'exports': exports,
    'storedBytes': storedBytes,
  };
}

class AccountDeletionPreview {
  const AccountDeletionPreview._(
    this.deletionToken,
    this.expiresAt,
    this.counts,
  );
  final String deletionToken, expiresAt;
  final DeletionCounts counts;
  factory AccountDeletionPreview.fromJson(Object? json) {
    final value = ExportContractValues.object(json, {
      'schemaVersion',
      'deletionToken',
      'expiresAt',
      'counts',
    });
    if (value['schemaVersion'] != '1') ExportContractValues.invalid();
    return AccountDeletionPreview._(
      ExportContractValues.digest(value['deletionToken']),
      ExportContractValues.instant(value['expiresAt']),
      DeletionCounts.fromJson(value['counts']),
    );
  }
  Map<String, Object?> toJson() => {
    'schemaVersion': '1',
    'deletionToken': deletionToken,
    'expiresAt': expiresAt,
    'counts': counts.toJson(),
  };
  @override
  String toString() => 'AccountDeletionPreview([private receipt])';
}

class AccountDeletionState {
  const AccountDeletionState._(
    this.status,
    this.applicationDataDeleted,
    this.providerIdentityDeleted,
  );
  final String status;
  final bool applicationDataDeleted, providerIdentityDeleted;
  bool get complete => status == 'complete';
  factory AccountDeletionState.fromJson(Object? json) {
    final value = ExportContractValues.object(json, {
      'schemaVersion',
      'status',
      'applicationDataDeleted',
      'providerIdentityDeleted',
    });
    if (value['schemaVersion'] != '1') ExportContractValues.invalid();
    final flags = switch (value['status']) {
      'awaiting_confirmation' => (false, false),
      'auth_pending' => (true, false),
      'complete' => (true, true),
      _ => ExportContractValues.invalid(),
    };
    if (value['applicationDataDeleted'] != flags.$1 ||
        value['providerIdentityDeleted'] != flags.$2) {
      ExportContractValues.invalid();
    }
    return AccountDeletionState._(
      value['status'] as String,
      flags.$1,
      flags.$2,
    );
  }
}
