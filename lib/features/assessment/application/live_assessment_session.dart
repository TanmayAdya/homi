import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';

import '../../../app/live_app.dart';
import '../../../shared/models/assessment.dart';
import '../../../shared/models/case_draft.dart';
import '../../../shared/models/contracts.dart';
import '../../../shared/models/evidence.dart';
import '../../../shared/models/evidence_annotations.dart';
import '../../../shared/services/assessment_api_client.dart';
import '../../../shared/services/evidence_annotations_api_client.dart';
import '../../../shared/services/matching_api_client.dart';
import '../domain/annotation/box_annotation.dart';
import '../domain/capture/photo_capture_coordinator.dart';
import '../domain/ids/id_factory.dart';
import 'assessment_controller.dart';
import 'assessment_flow.dart';
import 'assessment_sync.dart';
import 'case_evidence_gateway.dart';
import 'encrypted_staging_store.dart';
import 'local_evidence_index.dart';
import 'native_capture_adapter.dart';

class _Ids implements IdFactory {
  @override
  String newFindingId() => newUuidV4();
  @override
  String newEvidenceId() => newUuidV4();
}

String _canonical(Object? value) {
  Object? sort(Object? v) {
    if (v is Map) {
      return SplayTreeMap<String, Object?>.from({
        for (final e in v.entries) e.key as String: sort(e.value),
      });
    }
    if (v is List) return v.map(sort).toList();
    if (v is double && v == v.truncateToDouble()) return v.toInt();
    return v;
  }

  return jsonEncode(sort(value));
}

class LiveAssessmentSession extends ChangeNotifier {
  LiveAssessmentSession({
    required this.services,
    required BuildContext Function() context,
    MatchingTransport? transport,
  }) {
    caseId = services.coordinator.currentCase().caseId;
    _generation = services.coordinator.generation;
    staging = EncryptedStagingStore(
      services.store,
      caseId: caseId,
      deferDeletion: true,
    );
    controller = AssessmentController(ids: _Ids());
    annotations = AnnotationStore(newId: newUuidV4);
    transport ??= services.transport;
    Future<String?> token() async {
      guard();
      final token = await services.session.accessToken();
      guard();
      return token;
    }

    api = AssessmentApiClient(
      baseUri: services.config.apiOrigin,
      tokenProvider: token,
      transport: transport,
    );
    annotationApi = EvidenceAnnotationsApiClient(
      baseUri: services.config.apiOrigin,
      tokenProvider: token,
      transport: transport,
    );
    _gateway = _AssessmentGateway(session: this);
    flow = AssessmentFlow(
      controller: controller,
      evidence: evidence,
      staging: staging,
      capture: PhotoCaptureCoordinator(
        adapter:
            services.captureAdapterFactory?.call(context) ??
            NativeCaptureAdapter(context: context, isCurrent: () => isCurrent),
        staging: staging,
      ),
      annotations: annotations,
      loadSavedImage: loadSavedImage,
      captureTimeForEvidence: (id) => _savedEvidence[id]?.capturedAt,
      allowStagedAnnotations: false,
      isCurrent: () => isCurrent,
      checkpoint: () async {
        await flush();
        guard();
      },
    );
    sync = AssessmentSync(
      gateway: _gateway,
      controller: controller,
      evidence: evidence,
      staging: staging,
      savedCase: services.coordinator.currentCase(),
      onCaseSaved: (saved) async {
        guardWritable();
        await services.coordinator.adoptRemoteSnapshot(saved);
      },
      beforeWrite: flush,
      metadataNeedsSave: () =>
          state != null &&
          _canonical(metadataFor(sync.replacementFindings)) !=
              _canonical(state!.metadata),
    );
    services.coordinator.addListener(_coordinatorChanged);
  }
  final AppServices services;
  late final String caseId;
  late final int _generation;
  late final AssessmentController controller;
  late final AnnotationStore annotations;
  late final AssessmentFlow flow;
  late final AssessmentSync sync;
  late final EncryptedStagingStore staging;
  late final AssessmentApiClient api;
  late final EvidenceAnnotationsApiClient annotationApi;
  late final _AssessmentGateway _gateway;
  final LocalEvidenceIndex evidence = LocalEvidenceIndex();
  final Map<String, AnnotationState> _annotationStates = {};
  final Map<String, EvidenceDescriptor> _savedEvidence = {};
  AssessmentState? state;
  String? annotationNotice;
  String? resumeNotice;
  String? annotationConflictId;
  Map<String, Object?>? pendingRequest;
  bool localConflict = false,
      localSaveFailed = false,
      _ready = false,
      _disposed = false;
  Future<void> _writes = Future.value();
  bool _replacingLocal = false;
  String get localKey => 'assessment:$caseId:draft';
  bool get isCurrent =>
      !_disposed &&
      services.coordinator.isCurrent &&
      services.coordinator.generation == _generation;
  bool get caseWriteBlocked =>
      services.coordinator.hasUnsavedChanges ||
      services.coordinator.uncertain ||
      services.coordinator.conflict;
  String? get caseWriteNotice => caseWriteBlocked
      ? 'Resident details have device-only changes or an unresolved save. You can keep taking photos and measurements here; they are saved privately on this device. Return to the case, check saved state and resolve or save those details before saving this assessment online.'
      : null;
  void guardWritable() {
    guard();
    if (flow.isBusy) {
      throw StateError('Finish the current photo step before saving online.');
    }
    if (caseWriteBlocked) {
      throw StateError(
        'Reconcile resident details before saving assessment changes online.',
      );
    }
  }

  void _coordinatorChanged() {
    if (!_disposed) notifyListeners();
  }

  void guard() {
    if (!isCurrent) throw MatchingApiException.forCode('STALE_RESPONSE');
  }

  Future<void> initialize() async {
    final encodedLocal = await services.store.readBytes(localKey);
    if (encodedLocal != null && encodedLocal.length > 512 * 1024) {
      throw const FormatException('Assessment draft exceeds its storage bound');
    }
    final local = encodedLocal == null
        ? null
        : Map<String, Object?>.from(
            jsonDecode(utf8.decode(encodedLocal)) as Map,
          );
    guard();
    if (local != null && (local['version'] != 1 || local['caseId'] != caseId)) {
      throw const FormatException('Invalid local assessment draft');
    }
    var online = true;
    try {
      state = await api.readAssessment(caseId, isCurrent: () => isCurrent);
      guard();
    } on MatchingApiException catch (error) {
      if (!{
        'SERVICE_UNAVAILABLE',
        'NETWORK_ERROR',
        'TIMEOUT',
      }.contains(error.code)) {
        rethrow;
      }
      state = local?['assessmentState'] == null
          ? null
          : AssessmentState.fromJson(local!['assessmentState']);
      online = false;
      resumeNotice =
          'Working from this device’s saved case. Photos and measurements stay encrypted here until you connect and save online. Previously saved photos need a connection to open.';
    }
    if (local != null && local['version'] == 1 && local['caseId'] == caseId) {
      pendingRequest = local['pendingRequest'] == null
          ? null
          : Map<String, Object?>.from(local['pendingRequest'] as Map);
      controller.restoreLocal(
        Map<String, Object?>.from(local['controller'] as Map),
      );
      evidence.restoreLocal(
        Map<String, Object?>.from(local['evidence'] as Map),
      );
      annotations.restoreLocal((local['annotations'] as List).cast<Object?>());
      for (final entry in (local['annotationStates'] as Map? ?? {}).entries) {
        _annotationStates[entry.key as String] = AnnotationState.fromJson(
          entry.value,
        );
      }
      flow.restoreLocal(Map<String, Object?>.from(local['flow'] as Map));
      sync.restoreLocal(Map<String, Object?>.from(local['sync'] as Map));
      staging.restoreDiscardIntents(local['discardedPhotos']);
      localConflict =
          online &&
          sync.savedCase.revision != state!.caseSnapshot.revision &&
          !_pendingReceiptAtCurrentHead(state!);
      if (online && !caseWriteBlocked && _pendingReceiptAtCurrentHead(state!)) {
        await sync.recover();
      }
    } else {
      final saved = state?.caseSnapshot ?? services.coordinator.currentCase();
      EvidenceCatalog? catalog;
      if (online) {
        try {
          catalog = await _catalog(saved);
        } on MatchingApiException catch (error) {
          if (!{
            'SERVICE_UNAVAILABLE',
            'NETWORK_ERROR',
            'TIMEOUT',
          }.contains(error.code)) {
            rethrow;
          }
          resumeNotice =
              'Saved photos could not be loaded. You can keep taking photos and measurements privately on this device; connect before saving online.';
        }
      }
      controller.hydrate(
        saved,
        evidenceVersions: {
          for (final item in catalog?.evidence ?? <EvidenceDescriptor>[])
            item.evidenceId: 'server:${item.evidenceRevision}:${item.sha256}',
        },
        metadata: _boundMetadata(state),
      );
      sync.reset(saved);
    }
    if (await NativeCaptureAdapter.discardInterruptedImport()) {
      resumeNotice =
          'An interrupted photo import was discarded. Your saved measurements and staged photos are retained; choose the imported photo again.';
    }
    guard();
    _ready = true;
    controller.addListener(_changed);
    flow.addListener(_changed);
    sync.addListener(_changed);
    await flush();
    guard();
  }

  void _hydrate(AssessmentState saved, EvidenceCatalog catalog) {
    controller.hydrate(
      saved.caseSnapshot,
      evidenceVersions: {
        for (final item in catalog.evidence)
          item.evidenceId: 'server:${item.evidenceRevision}:${item.sha256}',
      },
      metadata: _boundMetadata(saved),
    );
    sync.reset(saved.caseSnapshot);
  }

  Map<String, Object?>? _boundMetadata(AssessmentState? saved) =>
      saved != null && saved.boundCaseRevision == saved.caseSnapshot.revision
      ? saved.metadata
      : null;

  Future<void> resolveLocalConflict({required bool keepLocal}) =>
      services.coordinator.serialize(() async {
        guardWritable();
        final fresh = await api.readAssessment(
          caseId,
          isCurrent: () => isCurrent,
        );
        final catalog = await _catalog(fresh.caseSnapshot);
        guardWritable();
        if (!keepLocal) {
          await staging.discardAll();
          guardWritable();
        }
        _replacingLocal = true;
        try {
          state = fresh;
          pendingRequest = null;
          if (!keepLocal) {
            evidence.clear();
            annotations.clear();
            _annotationStates.clear();
            _savedEvidence.clear();
            annotationConflictId = null;
            annotationNotice = null;
            _hydrate(fresh, catalog);
            flow.restoreLocal({
              'step': 'chooseArea',
              'area': null,
              'findingId': null,
              'view': 'overview',
              'previewEvidenceId': null,
              'observation': '',
              'entries': <String, Object?>{},
            });
          } else {
            sync.reset(fresh.caseSnapshot);
          }
        } finally {
          _replacingLocal = false;
        }
        await services.coordinator.adoptRemoteSnapshot(fresh.caseSnapshot);
        localConflict = false;
        await flush();
        guard();
        notifyListeners();
      });

  Future<EvidenceCatalog> _catalog(CaseSnapshot saved) =>
      services.exports.listEvidence(
        saved,
        currentCase: () {
          guard();
          return saved;
        },
        currentCatalog: () => null,
      );

  Future<({Uint8List bytes, AnnotatedImage image})?> loadSavedImage(
    String evidenceId,
  ) async {
    final saved = sync.savedCase;
    final catalog = await _catalog(saved);
    final item = catalog.evidence
        .where((e) => e.evidenceId == evidenceId)
        .firstOrNull;
    if (item == null) return null;
    _savedEvidence[evidenceId] = item;
    final bytes = await services.exports.downloadEvidence(
      saved,
      catalog: catalog,
      evidence: item,
      currentCase: () {
        guard();
        return sync.savedCase;
      },
      currentCatalog: () => catalog,
    );
    guard();
    final image = AnnotatedImage(
      evidenceId: evidenceId,
      version: 'server:${item.evidenceRevision}:${item.sha256}',
      width: item.width,
      height: item.height,
      sha256: item.sha256,
    );
    final remote = await annotationApi.readAnnotations(
      _annotationRead(saved, catalog, item),
      isCurrent: () => isCurrent,
    );
    guard();
    final baseline = _annotationStates[evidenceId];
    if (baseline == null ||
        baseline.annotation['imageSha256'] != item.sha256 ||
        baseline.annotation['evidenceRevision'] != item.evidenceRevision) {
      final preserved = annotations.all
          .where((b) => b.image.evidenceId != evidenceId)
          .map((b) => b.toLocalJson())
          .toList();
      for (final mark in remote.marks) {
        final r = (mark['rect'] as List).cast<num>();
        preserved.add({
          'id': mark['id'],
          'findingId': item.findingId,
          'evidenceId': evidenceId,
          'evidenceVersion': image.version,
          'imageSha256': item.sha256,
          'imageWidth': item.width,
          'imageHeight': item.height,
          'coordinates': annotationCoordinateConvention,
          'rect': [
            r[0] * item.width / 1000000,
            r[1] * item.height / 1000000,
            r[2] * item.width / 1000000,
            r[3] * item.height / 1000000,
          ],
          'label': mark['label'],
          'revision': remote.annotationRevision + 1,
          'stale': false,
          'hidden': false,
        });
      }
      annotations.restoreLocal(preserved);
      _annotationStates[evidenceId] = remote;
    }
    return (bytes: Uint8List.fromList(bytes), image: image);
  }

  Map<String, Object?> _annotationRead(
    CaseSnapshot saved,
    EvidenceCatalog catalog,
    EvidenceDescriptor item,
  ) => {
    'schemaVersion': '2',
    'caseId': caseId,
    'expectedCaseRevision': saved.revision,
    'expectedCatalogRevision': catalog.catalogRevision,
    'evidenceId': item.evidenceId,
    'expectedEvidenceRevision': item.evidenceRevision,
  };

  Future<void> save() => services.coordinator.serialize(() async {
    guardWritable();
    if (localConflict) {
      throw StateError('Resolve the saved/local difference first');
    }
    if (flow.step == AssessmentStep.details && !flow.saveDetails()) {
      await flush();
      guard();
      notifyListeners();
      return;
    }
    final latest = await api.readAssessment(caseId, isCurrent: () => isCurrent);
    guardWritable();
    if (_canonical(latest.caseSnapshot.toJson()) !=
        _canonical(sync.savedCase.toJson())) {
      state = latest;
      localConflict = true;
      await flush();
      guard();
      notifyListeners();
      return;
    }
    state = latest;
    final report = await sync.save();
    if (report.errorCode != null) {
      await flush();
      guard();
      notifyListeners();
      return;
    }
    await flow.refreshSavedImages();
    await _saveAnnotations();
    state = await api.readAssessment(caseId, isCurrent: () => isCurrent);
    await flush();
    guard();
    notifyListeners();
  });

  Future<void> _saveAnnotations() async {
    final saved = sync.savedCase;
    for (final evidenceId in _annotationStates.keys.toList()) {
      final catalog = await _catalog(saved);
      final item = catalog.evidence
          .where((e) => e.evidenceId == evidenceId)
          .firstOrNull;
      if (item == null) continue;
      final current = await annotationApi.readAnnotations(
        _annotationRead(saved, catalog, item),
        isCurrent: () => isCurrent,
      );
      final marks = marksFor(item);
      if (_canonical(marks) == _canonical(current.marks)) {
        _annotationStates[evidenceId] = current;
        continue;
      }
      if (_annotationStates[evidenceId]!.annotationRevision !=
          current.annotationRevision) {
        annotationConflictId = evidenceId;
        annotationNotice =
            'The saved marks differ from this device. Open the saved photo, then reload saved marks before making new changes.';
        await flush();
        guard();
        notifyListeners();
        throw StateError('Annotation conflict');
      }
      try {
        await flush();
        _annotationStates[evidenceId] = await annotationApi.saveAnnotations(
          current.saveRequest(marks: marks, reviewedForExport: false),
          isCurrent: () => isCurrent && !caseWriteBlocked,
        );
        annotationNotice = null;
        await flush();
      } catch (_) {
        if (!isCurrent) rethrow;
        annotationNotice ??=
            'Saving photo marks could not be confirmed. The marks are retained on this device. Save again to compare with the current saved marks first.';
        notifyListeners();
        rethrow;
      }
    }
  }

  List<Map<String, Object?>> marksFor(EvidenceDescriptor item) {
    final image = AnnotatedImage(
      evidenceId: item.evidenceId,
      version: 'server:${item.evidenceRevision}:${item.sha256}',
      width: item.width,
      height: item.height,
      sha256: item.sha256,
    );
    return [
      for (final box in annotations.on(image).where((b) => !b.hidden))
        {
          'id': box.id,
          'label': box.label,
          'rect': [
            (box.rect.left / item.width * 1000000).round(),
            (box.rect.top / item.height * 1000000).round(),
            (box.rect.right / item.width * 1000000).round() -
                (box.rect.left / item.width * 1000000).round(),
            (box.rect.bottom / item.height * 1000000).round() -
                (box.rect.top / item.height * 1000000).round(),
          ],
        },
    ];
  }

  Map<String, Object?> metadataFor(List<Finding> replacement) {
    final local = controller.metadataFor(replacement);
    final savedMeasurements = state?.metadata['measurements'] as List? ?? [];
    final savedReviews = state?.metadata['reviews'] as List? ?? [];
    final metadataIsBound =
        state != null &&
        state!.boundCaseRevision == state!.caseSnapshot.revision;
    Finding? savedFinding(String id) =>
        state?.caseSnapshot.findings.where((f) => f.id == id).firstOrNull;
    Finding? replacementFinding(String id) =>
        replacement.where((f) => f.id == id).firstOrNull;
    Map<String, Object?> measurement(Map raw) {
      final id = raw['findingId'] as String, type = raw['type'] as String;
      final prior = savedMeasurements
          .where((e) => (e as Map)['findingId'] == id && e['type'] == type)
          .firstOrNull;
      final before = savedFinding(
        id,
      )?.measurements.where((m) => m.type == type).firstOrNull;
      final after = replacementFinding(
        id,
      )?.measurements.where((m) => m.type == type).firstOrNull;
      final unchangedUnknown =
          raw['source'] == 'legacy_unknown' &&
          metadataIsBound &&
          before != null &&
          after != null &&
          before.value == after.value &&
          before.method == after.method;
      return Map<String, Object?>.from(
        prior != null && (controller.draftOf(id) == null || unchangedUnknown)
            ? prior as Map
            : raw,
      );
    }

    Map<String, Object?> review(Map raw) {
      final id = raw['findingId'] as String;
      final prior = savedReviews
          .where((e) => (e as Map)['findingId'] == id)
          .firstOrNull;
      final unchanged =
          metadataIsBound &&
          raw['note'] == null &&
          _canonical(savedFinding(id)?.toJson()) ==
              _canonical(replacementFinding(id)?.toJson());
      return Map<String, Object?>.from(
        prior != null && (controller.draftOf(id) == null || unchanged)
            ? prior as Map
            : raw,
      );
    }

    return {
      'measurements': [
        for (final raw in local['measurements'] as List)
          measurement(raw as Map),
      ],
      'reviews': [
        for (final raw in local['reviews'] as List) review(raw as Map),
      ],
    };
  }

  Future<void> reloadConflictingMarks() =>
      services.coordinator.serialize(() async {
        final id = annotationConflictId;
        if (id == null) return;
        _annotationStates.remove(id);
        annotations.restoreLocal(
          annotations.all
              .where((b) => b.image.evidenceId != id)
              .map((b) => b.toLocalJson())
              .toList(),
        );
        await loadSavedImage(id);
        annotationConflictId = null;
        annotationNotice = null;
        await flush();
        guard();
        notifyListeners();
      });

  Future<void> recover() => services.coordinator.serialize(() async {
    guardWritable();
    await sync.recover();
    await flush();
    guard();
    notifyListeners();
  });

  Map<String, Object?>? _pendingReceipt(AssessmentState saved) {
    final pending = pendingRequest;
    if (pending == null) return null;
    final digest = sha256.convert(utf8.encode(_canonical(pending))).toString();
    return saved.history
        .where(
          (e) =>
              e['mutationId'] == pending['mutationId'] &&
              e['requestHash'] == digest,
        )
        .firstOrNull;
  }

  bool _pendingReceiptAtCurrentHead(AssessmentState saved) =>
      _pendingReceipt(saved)?['caseRevision'] == saved.caseSnapshot.revision;

  void _changed() {
    if (!_ready || !isCurrent || _replacingLocal || flow.isMutatingSnapshot) {
      return;
    }
    flush().catchError((Object _) {
      if (!_disposed) {
        localSaveFailed = true;
        notifyListeners();
      }
    });
    notifyListeners();
  }

  Future<void> flush() {
    if (!_ready) return Future.value();
    guard();
    final value = {
      'version': 1,
      'caseId': caseId,
      'controller': controller.toLocalJson(),
      'flow': flow.toLocalJson(),
      'sync': sync.toLocalJson(),
      'evidence': evidence.toLocalJson(),
      'discardedPhotos': staging.discardIntents,
      'annotations': annotations.toLocalJson(),
      'annotationStates': {
        for (final e in _annotationStates.entries) e.key: e.value.toJson(),
      },
      'assessmentState': state?.toJson(),
      'pendingRequest': pendingRequest,
    };
    final bytes = Uint8List.fromList(utf8.encode(jsonEncode(value)));
    if (bytes.length > 512 * 1024) {
      return Future.error(
        const FormatException('Assessment draft exceeds its storage bound'),
      );
    }
    final persisted = services.store.writeBytes(localKey, bytes);
    persisted.ignore();
    final next = _writes.then((_) async {
      await persisted;
      if (!isCurrent) return;
      final savedIndex = value['evidence'] as Map<String, Object?>;
      final retained = <String>{
        for (final item in savedIndex.values) (item as Map)['key'] as String,
      };
      final pending = (value['sync'] as Map)['pendingUpload'] as Map?;
      final pendingVersion = pending?['version'] as String?;
      if (pendingVersion != null && pendingVersion.startsWith('local:')) {
        retained.add(pendingVersion.substring('local:'.length));
      }
      await staging.commitDiscardIntents(
        persistedIntents: (value['discardedPhotos'] as List).cast<String>(),
        retainedKeys: retained,
      );
    });
    _writes = next.then<void>((_) {
      if (isCurrent) localSaveFailed = false;
    }, onError: (Object _, StackTrace _) {});
    return next;
  }

  @override
  void dispose() {
    _disposed = true;
    services.coordinator.removeListener(_coordinatorChanged);
    controller.removeListener(_changed);
    flow.removeListener(_changed);
    sync.removeListener(_changed);
    flow.dispose();
    sync.dispose();
    controller.dispose();
    super.dispose();
  }
}

class _AssessmentGateway extends ApiCaseEvidenceGateway {
  _AssessmentGateway({required this.session})
    : super(
        cases: session.services.cases,
        exports: session.services.exports,
        writeGuard: session.guardWritable,
      );
  final LiveAssessmentSession session;

  @override
  Future<CaseSnapshot> saveCase(
    CaseSnapshot saved, {
    required CaseDraft replacement,
    required CaseSnapshot Function() currentCase,
    required CaseDraft Function() currentDraft,
  }) async {
    session.guardWritable();
    final latest = await session.api.readAssessment(
      saved.caseId,
      isCurrent: () => session.isCurrent,
    );
    if (_canonical(latest.caseSnapshot.toJson()) !=
            _canonical(saved.toJson()) ||
        _canonical(currentCase().toJson()) != _canonical(saved.toJson())) {
      throw MatchingApiException.forCode('CASE_REVISION_MISMATCH');
    }
    session.guardWritable();
    session.state = latest;
    final request = latest.saveRequest(
      draft: replacement,
      metadata: session.metadataFor(replacement.findings),
      mutationId: newUuidV4(),
    );
    session.pendingRequest = request;
    await session.flush();
    final response = await session.api.saveAssessment(
      request,
      isCurrent: () => session.isCurrent && !session.caseWriteBlocked,
    );
    session.state = response;
    session.pendingRequest = null;
    await session.flush();
    return response.caseSnapshot;
  }

  @override
  Future<CaseSnapshot> reloadCase(
    String caseId, {
    required String Function() currentCaseId,
    required CaseSnapshot? Function() currentCase,
  }) async {
    if (currentCaseId() != caseId) {
      throw MatchingApiException.forCode('STALE_RESPONSE');
    }
    final latest = await session.api.readAssessment(
      caseId,
      isCurrent: () => session.isCurrent,
    );
    session.state = latest;
    final previous = currentCase();
    if (session.pendingRequest == null &&
        previous != null &&
        latest.caseSnapshot.revision != previous.revision) {
      session.localConflict = true;
      throw MatchingApiException.forCode('CASE_REVISION_MISMATCH');
    }
    if (session.pendingRequest != null) {
      final receipt = session._pendingReceipt(latest);
      if (receipt != null && !session._pendingReceiptAtCurrentHead(latest) ||
          receipt == null &&
              latest.caseSnapshot.revision !=
                  session.pendingRequest!['expectedCaseRevision']) {
        session.localConflict = true;
        throw MatchingApiException.forCode('CASE_REVISION_MISMATCH');
      }
      session.pendingRequest = null;
    }
    return latest.caseSnapshot;
  }
}
