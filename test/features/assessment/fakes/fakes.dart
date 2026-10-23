import 'dart:collection';
import 'dart:typed_data';

import 'package:safe_at_home/features/assessment/domain/capture/capture_adapter.dart';
import 'package:safe_at_home/features/assessment/domain/capture/staging_store.dart';
import 'package:safe_at_home/features/assessment/domain/ids/id_factory.dart';
import 'package:safe_at_home/features/assessment/domain/image/image_validator.dart';

class SequentialIdFactory implements IdFactory {
  int _findings = 0;
  int _evidence = 0;

  @override
  String newFindingId() => 'finding-${++_findings}';

  @override
  String newEvidenceId() => 'evidence-${++_evidence}';
}

class ScriptedCaptureAdapter implements CaptureAdapter {
  final Queue<Future<CaptureResult> Function()> _queue = Queue();
  final List<CaptureRequest> requests = [];

  void enqueue(CaptureResult result) => _queue.add(() => Future.value(result));

  void enqueueFuture(Future<CaptureResult> future) => _queue.add(() => future);

  void enqueueError() =>
      _queue.add(() => Future.error(StateError('fake adapter failure')));

  @override
  Future<CaptureResult> capture(CaptureRequest request) {
    requests.add(request);
    if (_queue.isEmpty) {
      throw StateError('ScriptedCaptureAdapter: no result queued');
    }
    return _queue.removeFirst()();
  }
}

class FailingStagingStore implements StagingStore {
  @override
  Future<StagedImage> put(Uint8List bytes, ImageAccepted info) async =>
      throw StateError('fake staging failure');

  @override
  Future<Uint8List?> read(StagingKey key) async => null;

  @override
  Future<bool> discard(StagingKey key) async => false;

  @override
  Future<int> discardAll() async => 0;

  @override
  Future<List<StagingKey>> keys() async => const [];
}

const CaptureRequest bathroomOverview = CaptureRequest(
  area: AssessmentArea.bathroom,
  view: CaptureView.overview,
  promptId: 'bathroom-overview',
);
