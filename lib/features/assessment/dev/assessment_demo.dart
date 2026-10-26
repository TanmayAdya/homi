import 'package:flutter/material.dart';

import '../../../shared/models/case_draft.dart';
import '../../../shared/models/contracts.dart';
import '../application/assessment_controller.dart';
import '../application/assessment_flow.dart';
import '../application/assessment_sync.dart';
import '../application/export_review.dart';
import '../application/fictional_scenarios.dart';
import '../application/local_evidence_index.dart';
import '../domain/annotation/box_annotation.dart';
import '../domain/capture/capture_adapter.dart';
import '../domain/capture/photo_capture_coordinator.dart';
import '../domain/capture/staging_store.dart';
import '../domain/ids/id_factory.dart';
import '../domain/review/finding_review_state.dart';
import '../presentation/assessment_copy.dart';
import '../presentation/assessment_flow_screen.dart';
import '../presentation/export_review_screen.dart';
import '../presentation/save_status_card.dart';
import 'fictional_camera.dart';
import 'in_memory_case_server.dart';

class AssessmentDemoApp extends StatefulWidget {
  const AssessmentDemoApp({super.key, this.camera});

  final CaptureAdapter? camera;

  @override
  State<AssessmentDemoApp> createState() => _AssessmentDemoAppState();
}

class _AssessmentDemoAppState extends State<AssessmentDemoApp> {
  final GlobalKey<NavigatorState> _navigator = GlobalKey();
  late final InMemoryStagingStore _staging = InMemoryStagingStore();
  late final LocalEvidenceIndex _evidence = LocalEvidenceIndex();
  late final AssessmentController _controller = AssessmentController(
    ids: _UuidIdFactory(),
  );
  late final AnnotationStore _annotations = AnnotationStore(newId: newUuidV4);
  late final InMemoryCaseServer _server = InMemoryCaseServer(_emptyCase());
  late final AssessmentSync _sync = AssessmentSync(
    gateway: _server,
    controller: _controller,
    evidence: _evidence,
    staging: _staging,
    savedCase: _server.serverCase,
  );
  late final AssessmentFlow _flow = AssessmentFlow(
    controller: _controller,
    capture: PhotoCaptureCoordinator(
      adapter:
          widget.camera ?? FictionalCameraAdapter(navigatorKey: _navigator),
      staging: _staging,
    ),
    staging: _staging,
    evidence: _evidence,
    annotations: _annotations,
  );
  late final ExportReview _export = ExportReview(
    gateway: _server,
    currentCase: () => _sync.savedCase,
  );

  @override
  void dispose() {
    _flow.dispose();
    _sync.dispose();
    _export.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: _navigator,
      title: 'Assessment demo',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF176456)),
        useMaterial3: true,
      ),
      home: Builder(builder: _home),
    );
  }

  Widget _home(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Assessment demo')),
      body: ListenableBuilder(
        listenable: _controller,
        builder: (context, _) => SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Card(
                child: Padding(
                  padding: EdgeInsets.all(12),
                  child: Text(
                    'Development demo. Fictional data only. The camera draws '
                    'a scene, and "saving" goes to a temporary in-memory '
                    'stand-in that does not clean images or keep anything.',
                  ),
                ),
              ),
              SaveStatusCard(sync: _sync),
              const SizedBox(height: 8),
              for (final FindingDraft d in _controller.drafts)
                Card(
                  child: ListTile(
                    title: Text(
                      d.observation.trim().isEmpty
                          ? '${AssessmentCopy.areaTitle(d.area)} · no observation yet'
                          : d.observation.trim(),
                    ),
                    subtitle: Text(
                      '${AssessmentCopy.areaTitle(d.area)} · '
                      '${AssessmentCopy.reviewState(_controller.reviewOf(d.id)?.state ?? FindingReviewState.needsReview)} · '
                      '${d.evidence.length} photo(s) · '
                      '${d.measurements.length} measurement(s)',
                    ),
                  ),
                ),
              const SizedBox(height: 8),
              FilledButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => AssessmentFlowScreen(flow: _flow),
                  ),
                ),
                child: const Text('Add or continue a finding'),
              ),
              const SizedBox(height: 8),
              OutlinedButton(
                onPressed: () {
                  addFictionalBathroomScenario(_controller);
                  addFictionalEntranceScenario(_controller);
                },
                child: const Text('Add the fictional scenarios'),
              ),
              const SizedBox(height: 8),
              OutlinedButton(
                onPressed: () {
                  _export.clear();
                  Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (route) => ExportReviewScreen(
                        review: _export,
                        savedCase: () => _sync.savedCase,
                        onDone: (selection) {
                          Navigator.of(route).pop();
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(
                                '${selection.length} photo(s) would be passed '
                                'to the draft export. Nothing was sent.',
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  );
                },
                child: const Text('Choose photos for the draft'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static CaseSnapshot _emptyCase() => CaseDraft.fromJson({
    'schemaVersion': '1',
    'caseId': newUuidV4(),
    'profile': {
      'city': null,
      'county': null,
      'healthPlan': null,
      'tenure': null,
      'ageYears': null,
      'householdSize': null,
      'annualIncomeUsd': null,
      'ownerConsentReported': null,
    },
    'unresolvedFields': <String>[],
    'findings': <Object>[],
  }).atRevision(1);
}

class _UuidIdFactory implements IdFactory {
  @override
  String newFindingId() => newUuidV4();

  @override
  String newEvidenceId() => newUuidV4();
}
