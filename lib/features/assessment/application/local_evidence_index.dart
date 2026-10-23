import '../domain/capture/staging_store.dart';

class LocalEvidenceIndex {
  final Map<String, StagedImage> _byEvidenceId = {};

  StagedImage? operator [](String evidenceId) => _byEvidenceId[evidenceId];

  void put(String evidenceId, StagedImage image) =>
      _byEvidenceId[evidenceId] = image;

  StagedImage? remove(String evidenceId) => _byEvidenceId.remove(evidenceId);

  Iterable<String> get evidenceIds => List.unmodifiable(_byEvidenceId.keys);

  void clear() => _byEvidenceId.clear();
}

String localEvidenceVersion(StagingKey key) => 'local:${key.value}';
