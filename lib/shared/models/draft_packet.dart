import 'contracts.dart';

class DraftPacket {
  DraftPacket._({
    required this.schemaVersion,
    required this.packetId,
    required this.caseId,
    required this.caseRevision,
    required this.programId,
    required this.ruleVersion,
    required this.formVersion,
    required this.mappingVersion,
    required this.status,
    required this.isDemo,
    required this.generatedAt,
    required this.recheckAfter,
    required this.storageReference,
    required this.attachments,
    required this.missingItems,
  });

  factory DraftPacket.fromJson(Object? json) {
    final value = _object(json, {
      'schemaVersion',
      'packetId',
      'caseId',
      'caseRevision',
      'programId',
      'ruleVersion',
      'formVersion',
      'mappingVersion',
      'status',
      'isDemo',
      'generatedAt',
      'recheckAfter',
      'storageReference',
      'attachments',
      'missingItems',
    });
    if (value['schemaVersion'] != '1' || value['status'] != 'draft') {
      _invalid('Unsupported packet schema or draft status.');
    }
    final revision = value['caseRevision'];
    if (revision is! num ||
        !revision.isFinite ||
        revision < 1 ||
        (revision is double && revision != revision.truncateToDouble())) {
      _invalid('Packet case revision must be a positive integer.');
    }
    final isDemo = value['isDemo'];
    if (isDemo is! bool) _invalid('Packet demo marker must be a boolean.');
    final attachments = _objects(
      value['attachments'],
      PacketAttachment.fromJson,
    );
    final missingItems = _objects(
      value['missingItems'],
      PacketMissingItem.fromJson,
    );
    _unique(attachments.map((item) => item.evidenceId));
    _unique(missingItems.map((item) => item.id));
    return DraftPacket._(
      schemaVersion: '1',
      packetId: _text(value['packetId']),
      caseId: _text(value['caseId']),
      caseRevision: revision.toInt(),
      programId: _text(value['programId']),
      ruleVersion: _text(value['ruleVersion']),
      formVersion: _optionalText(value['formVersion']),
      mappingVersion: _optionalText(value['mappingVersion']),
      status: 'draft',
      isDemo: isDemo,
      generatedAt: _instant(value['generatedAt']),
      recheckAfter: value['recheckAfter'] == null
          ? null
          : _instant(value['recheckAfter']),
      storageReference: value['storageReference'] == null
          ? null
          : _privateReference(value['storageReference']),
      attachments: attachments,
      missingItems: missingItems,
    );
  }

  final String schemaVersion;
  final String packetId;
  final String caseId;
  final int caseRevision;
  final String programId;
  final String ruleVersion;
  final String? formVersion;
  final String? mappingVersion;
  final String status;
  final bool isDemo;
  final String generatedAt;
  final String? recheckAfter;
  final String? storageReference;
  final List<PacketAttachment> attachments;
  final List<PacketMissingItem> missingItems;

  bool isFreshFor(
    CaseSnapshot snapshot, {
    required String programId,
    required String ruleVersion,
    required String? formVersion,
    required String? mappingVersion,
    required DateTime now,
  }) {
    final deadline = recheckAfter;
    return caseId == snapshot.caseId &&
        caseRevision == snapshot.revision &&
        this.programId == programId &&
        this.ruleVersion == ruleVersion &&
        this.formVersion == formVersion &&
        this.mappingVersion == mappingVersion &&
        deadline != null &&
        !now.isBefore(DateTime.parse(generatedAt)) &&
        now.isBefore(DateTime.parse(deadline));
  }
}

class PacketAttachment {
  PacketAttachment._(this.evidenceId, this.findingId, this.storageReference);

  factory PacketAttachment.fromJson(Object? json) {
    final value = _object(json, {
      'evidenceId',
      'findingId',
      'storageReference',
    });
    return PacketAttachment._(
      _text(value['evidenceId']),
      _text(value['findingId']),
      _privateReference(value['storageReference']),
    );
  }

  final String evidenceId;
  final String findingId;
  final String storageReference;
}

class PacketMissingItem {
  PacketMissingItem._(this.id, this.description, this.resolvedBy);

  factory PacketMissingItem.fromJson(Object? json) {
    final value = _object(json, {'id', 'description', 'resolvedBy'});
    final resolvedBy = value['resolvedBy'];
    if (!{'resident', 'program', 'professional'}.contains(resolvedBy)) {
      _invalid('Packet checklist responsibility is invalid.');
    }
    return PacketMissingItem._(
      _text(value['id']),
      _text(value['description']),
      resolvedBy as String,
    );
  }

  final String id;
  final String description;
  final String resolvedBy;
}

Never _invalid(String message) => throw FormatException(message);

Map<String, Object?> _object(Object? json, Set<String> fields) {
  if (json is! Map ||
      json.length != fields.length ||
      json.keys.any((key) => key is! String || !fields.contains(key))) {
    _invalid('Packet object contains missing or unexpected fields.');
  }
  return Map<String, Object?>.from(json);
}

String _text(Object? value) {
  if (value is! String || value.trim().isEmpty) {
    _invalid('Packet text must be a nonblank string.');
  }
  return value;
}

String? _optionalText(Object? value) => value == null ? null : _text(value);

List<T> _objects<T>(Object? value, T Function(Object?) parse) {
  if (value is! List) _invalid('Packet collection must be an array.');
  return List.unmodifiable(value.map(parse));
}

void _unique(Iterable<String> values) {
  final seen = <String>{};
  if (values.any((value) => !seen.add(value))) {
    _invalid('Packet collection contains duplicate identifiers.');
  }
}

String _instant(Object? value) {
  final text = _text(value);
  if (!RegExp(
    r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,6})?Z$',
  ).hasMatch(text)) {
    _invalid('Packet timestamp must be UTC and end in Z.');
  }
  final parsed = DateTime.tryParse(text);
  if (parsed == null ||
      parsed.year != int.parse(text.substring(0, 4)) ||
      parsed.month != int.parse(text.substring(5, 7)) ||
      parsed.day != int.parse(text.substring(8, 10)) ||
      parsed.hour != int.parse(text.substring(11, 13)) ||
      parsed.minute != int.parse(text.substring(14, 16)) ||
      parsed.second != int.parse(text.substring(17, 19))) {
    _invalid('Packet timestamp contains an invalid calendar date or time.');
  }
  return text;
}

String _privateReference(Object? value) {
  final text = _text(value);
  final uri = Uri.tryParse(text);
  if (uri == null ||
      uri.hasScheme ||
      uri.hasAuthority ||
      uri.hasQuery ||
      uri.hasFragment ||
      text.startsWith('/') ||
      text.contains('\\') ||
      text.contains('%') ||
      RegExp(r'[\s\x00-\x1f\x7f]').hasMatch(text) ||
      text
          .split('/')
          .any(
            (segment) => segment.isEmpty || segment == '.' || segment == '..',
          )) {
    _invalid('Packet storage reference must be a private object identifier.');
  }
  return text;
}
