import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:safe_at_home/l10n/app_localizations.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import '../../app/live_app.dart';
import '../../shared/models/case_draft.dart';
import '../../shared/models/contracts.dart';
import '../../shared/models/annotated_export.dart';
import '../../shared/models/evidence_annotations.dart';
import '../../shared/presentation/sah_components.dart';
import 'application_workspace_screen.dart';
import 'reviewed_photo_screen.dart';
import 'private_draft_preview.dart';
import '../../shared/models/evidence.dart';
import '../../shared/models/form_answers.dart';
import '../../shared/services/matching_api_client.dart';

class PrivateExportScreen extends StatefulWidget {
  const PrivateExportScreen({
    super.key,
    required this.services,
    required this.program,
  });
  final AppServices services;
  final ProgramMatch program;
  @override
  State<PrivateExportScreen> createState() => _PrivateExportScreenState();
}

class _PrivateExportScreenState extends State<PrivateExportScreen>
    with WidgetsBindingObserver {
  EvidenceCatalog? _catalog;
  FormAnswersResponse? _answers;
  final _selected = <String, AnnotationState>{};
  AnnotatedExportArtifact? _artifact;
  Uint8List? _pdf;
  bool _busy = false, _sharing = false;
  String? _error;
  String? _notice;
  Map<String, Object?>? _prior;
  Timer? _timer;
  late final String _caseId;
  late final int _caseGeneration;
  @override
  void initState() {
    super.initState();
    final coordinator = widget.services.coordinator;
    _caseId = coordinator.currentCase().caseId;
    _caseGeneration = coordinator.generation;
    WidgetsBinding.instance.addObserver(this);
    widget.services.coordinator.addListener(_invalidate);
    _load();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _invalidate());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _invalidate();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.services.coordinator.removeListener(_invalidate);
    _timer?.cancel();
    _pdf = null;
    super.dispose();
  }

  bool get _scopeCurrent {
    final c = widget.services.coordinator;
    return mounted &&
        c.isCurrent &&
        c.generation == _caseGeneration &&
        c.snapshot?.caseId == _caseId;
  }

  CaseSnapshot _currentCase() {
    if (!_scopeCurrent) {
      throw MatchingApiException.forCode('STALE_RESPONSE');
    }
    return widget.services.coordinator.currentCase();
  }

  bool get _current =>
      _scopeCurrent &&
      !widget.services.coordinator.hasUnsavedChanges &&
      _catalog != null &&
      widget.services.coordinator.snapshot != null &&
      _catalog!.belongsTo(widget.services.coordinator.currentCase());
  void _invalidate() {
    if (!mounted) return;
    if (!_scopeCurrent) {
      if (_catalog != null ||
          _answers != null ||
          _artifact != null ||
          _pdf != null) {
        setState(() {
          _catalog = null;
          _answers = null;
          _selected.clear();
          _artifact = null;
          _pdf = null;
          _notice = null;
          _error =
              'This case was closed or changed. Return to the case and open draft review again.';
        });
      }
      return;
    }
    if (!_current ||
        (_artifact != null &&
            !_artifact!.base.isAvailableAt(DateTime.now().toUtc()))) {
      const staleMessage =
          'The draft expired or its case changed. Reload and prepare a fresh draft.';
      if (_pdf != null ||
          _artifact != null ||
          (_catalog != null && _error != staleMessage)) {
        setState(() {
          _pdf = null;
          _artifact = null;
          _selected.clear();
          _notice = null;
          _error = staleMessage;
        });
      }
    }
  }

  Future<void> _load() async {
    if (_busy || _sharing || !_scopeCurrent) return;
    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
      _pdf = null;
      _artifact = null;
      _selected.clear();
      _catalog = null;
      _answers = null;
    });
    try {
      final catalog = await widget.services.exports.listEvidence(
        _currentCase(),
        currentCase: _currentCase,
        currentCatalog: () => _catalog,
      );
      if (!_scopeCurrent) return;
      final answers = await widget.services.answers.readAnswers(
        _currentCase(),
        programId: widget.program.programId,
        currentCase: _currentCase,
        currentProgramId: () => widget.program.programId,
        currentContext: () => _answers?.context,
      );
      if (_scopeCurrent) {
        setState(() {
          _catalog = catalog;
          _answers = answers;
        });
        await _restoreSelection();
      }
    } catch (error) {
      if (mounted) setState(() => _error = safeOperationMessage(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String get _operationKey => 'export.$_caseId.${widget.program.programId}';
  Map<String, Object?> _request(String generation) {
    if (!_current || _answers == null) {
      throw MatchingApiException.forCode('STALE_RESPONSE');
    }
    final snapshot = widget.services.coordinator.currentCase();
    return {
      'schemaVersion': '2',
      'caseId': snapshot.caseId,
      'expectedCaseRevision': snapshot.revision,
      'programId': widget.program.programId,
      'expectedFormContextId': _answers!.context.formContextId,
      'expectedAnswerRevision': _answers!.saved?.answerRevision ?? 0,
      'expectedEvidenceCatalogRevision': _catalog!.catalogRevision,
      'generationKey': generation,
      'selectedEvidence': [
        for (final entry in _selected.entries)
          {
            'evidenceId': entry.key,
            'expectedEvidenceRevision':
                entry.value.annotation['evidenceRevision'],
            'expectedAnnotationRevision': entry.value.annotationRevision,
            'reviewedForExport': true,
          },
      ],
    };
  }

  String _fingerprint() => sha256
      .convert(utf8.encode(jsonEncode(_request('fingerprint'))))
      .toString();
  bool _guard(String fingerprint) =>
      mounted &&
      _current &&
      _answers != null &&
      !widget.services.coordinator.hasUnsavedChanges &&
      _fingerprint() == fingerprint;
  Map<String, Object?> _annotationRequest(EvidenceDescriptor evidence) => {
    'schemaVersion': '2',
    'caseId': evidence.caseId,
    'expectedCaseRevision': widget.services.coordinator.currentCase().revision,
    'expectedCatalogRevision': _catalog!.catalogRevision,
    'evidenceId': evidence.evidenceId,
    'expectedEvidenceRevision': evidence.evidenceRevision,
  };
  Future<void> _restoreSelection() async {
    if (!_current || _answers == null) return;
    final fingerprint = _fingerprint();
    final prior = await widget.services.store.readJson(_operationKey);
    if (!_guard(fingerprint)) return;
    setState(() => _prior = prior);
    final request = prior?['request'];
    if (request is! Map || !_current || _answers == null) return;
    final current = _request('fingerprint');
    for (final key in [
      'caseId',
      'expectedCaseRevision',
      'programId',
      'expectedFormContextId',
      'expectedAnswerRevision',
      'expectedEvidenceCatalogRevision',
    ]) {
      if (request[key] != current[key]) return;
    }
    final selected = request['selectedEvidence'];
    if (selected is! List || selected.length > maxSelectedEvidence) return;
    final recovered = <String, AnnotationState>{};
    for (final raw in selected) {
      if (raw is! Map) return;
      final candidates = _catalog!.evidence.where(
        (item) =>
            item.evidenceId == raw['evidenceId'] &&
            item.evidenceRevision == raw['expectedEvidenceRevision'],
      );
      if (candidates.length != 1) return;
      final annotation = await widget.services.annotations.readAnnotations(
        _annotationRequest(candidates.single),
        isCurrent: () => _guard(fingerprint),
      );
      if (annotation.annotationRevision != raw['expectedAnnotationRevision'] ||
          !_reviewCurrent(annotation)) {
        return;
      }
      recovered[candidates.single.evidenceId] = annotation;
    }
    if (_guard(fingerprint)) {
      setState(() {
        _selected.addAll(recovered);
        if (prior?['completed'] != true) {
          _notice =
              'Recovered the exact reviewed selection. Prepare or recover this draft to continue.';
        }
      });
    }
  }

  bool _reviewCurrent(AnnotationState value) =>
      value.annotation['reviewState'] == 'reviewed' &&
      value.annotation['reviewedCaseRevision'] ==
          widget.services.coordinator.currentCase().revision;

  Future<void> _review(EvidenceDescriptor evidence) async {
    if (_busy || _sharing || !_current) return;
    if (_selected.containsKey(evidence.evidenceId)) {
      setState(() {
        _selected.remove(evidence.evidenceId);
        _notice = null;
        _artifact = null;
        _pdf = null;
      });
      return;
    }
    if (_selected.length >= maxSelectedEvidence) {
      setState(() => _error = 'Choose at most six reviewed photos.');
      return;
    }
    setState(() => _busy = true);
    try {
      final c = widget.services.coordinator;
      final fingerprint = _fingerprint();
      final annotations = await widget.services.annotations.readAnnotations(
        _annotationRequest(evidence),
        isCurrent: () => _guard(fingerprint),
      );
      final bytes = await widget.services.exports.downloadEvidence(
        _currentCase(),
        catalog: _catalog!,
        evidence: evidence,
        currentCase: _currentCase,
        currentCatalog: () => _catalog!,
      );
      if (!_guard(fingerprint) || !mounted) return;
      final accepted = await Navigator.of(context).push<bool>(
        MaterialPageRoute(
          builder: (_) => ReviewedPhotoScreen(
            bytes: Uint8List.fromList(bytes),
            width: evidence.width,
            height: evidence.height,
            marks: annotations.marks,
          ),
        ),
      );
      if (accepted == true && _guard(fingerprint)) {
        var reviewed = annotations;
        if (!_reviewCurrent(reviewed)) {
          final journal =
              'annotation-review.${evidence.caseId}.${evidence.evidenceId}';
          final request = annotations.saveRequest(
            marks: annotations.marks,
            reviewedForExport: true,
          );
          await widget.services.store.writeJson(journal, request);
          if (!_guard(fingerprint)) return;
          reviewed = await c.serialize(
            () => widget.services.annotations.saveAnnotations(
              request,
              isCurrent: () => _guard(fingerprint),
            ),
          );
          final catalog = await widget.services.exports.listEvidence(
            _currentCase(),
            currentCase: _currentCase,
            currentCatalog: () => null,
          );
          if (!_guard(fingerprint) ||
              catalog.catalogRevision != reviewed.catalogRevision) {
            throw MatchingApiException.forCode('STALE_RESPONSE');
          }
          _catalog = catalog;
          await widget.services.store.delete(journal);
        }
        if (!mounted || !_current) return;
        setState(() {
          _selected[evidence.evidenceId] = reviewed;
          _notice = null;
          _artifact = null;
          _pdf = null;
        });
      }
    } catch (error) {
      if (mounted) setState(() => _error = safeOperationMessage(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _prepare({bool newAttempt = false}) async {
    if (_busy || _sharing || !_current) return;
    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
      _pdf = null;
    });
    try {
      final fingerprint = _fingerprint();
      final prior = await widget.services.store.readJson(_operationKey);
      if (!_guard(fingerprint)) return;
      final generation = !newAttempt && prior?['fingerprint'] == fingerprint
          ? prior!['generation'] as String
          : newUuidV4();
      final request = _request(generation);
      final journal = <String, Object?>{
        'fingerprint': fingerprint,
        'generation': generation,
        'request': request,
      };
      await widget.services.store.writeJson(_operationKey, journal);
      _prior = journal;
      if (!_guard(fingerprint)) return;
      final artifact = await widget.services.annotatedExports.createDraftExport(
        request,
        isCurrent: () => _guard(fingerprint),
      );
      if (!_guard(fingerprint)) return;
      _artifact = artifact;
      final bytes = await widget.services.annotatedExports.downloadDraftExport(
        artifact,
        isCurrent: () => _guard(fingerprint) && identical(_artifact, artifact),
      );
      if (mounted) setState(() => _pdf = Uint8List.fromList(bytes));
      try {
        final done = {
          'fingerprint': fingerprint,
          'generation': generation,
          'request': request,
          'completed': true,
        };
        if (_guard(fingerprint)) {
          await widget.services.store.writeJson(_operationKey, done);
          _prior = done;
        }
      } catch (_) {}
    } catch (error) {
      if (mounted) {
        setState(
          () => _error =
              error is MatchingApiException &&
                  error.code == 'EXPORT_REVIEW_REQUIRED'
              ? 'The draft could not be prepared accurately. Review the text, measurements and images. The current PDF does not support all characters or layouts. Your saved information is kept; preserve the original spelling.'
              : safeOperationMessage(error),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _share(BuildContext buttonContext) async {
    if (_busy || _sharing) return;
    setState(() => _sharing = true);
    try {
      await _sharePrepared(buttonContext);
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }

  Future<void> _sharePrepared(BuildContext buttonContext) async {
    _invalidate();
    if (_pdf == null || _artifact == null || !_current) return;
    final approved = await showDialog<bool>(
      context: context,
      builder: (ctx) => Dialog(
        insetPadding: const EdgeInsets.all(16),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Semantics(
                  header: true,
                  child: Text(
                    ctx.tr('Share the draft file?'),
                    style: Theme.of(ctx).textTheme.headlineSmall,
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  ctx.tr(
                    'Sharing sends a file. It doesn’t send your application. The app or person you choose can keep a copy.',
                  ),
                ),
                const SizedBox(height: 24),
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: Text(ctx.tr('Cancel')),
                ),
                const SizedBox(height: 8),
                FilledButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: Text(ctx.tr('Open share sheet')),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (approved != true || !mounted) return;
    _invalidate();
    if (_pdf == null || _artifact == null) return;
    final sharedArtifact = _artifact;
    final sharedPdf = _pdf;
    File? temporaryShare;
    var shareRequested = false;
    try {
      const channel = MethodChannel('safe_at_home/private_media');
      final root = await channel.invokeMethod<String>('privateRootDirectory');
      if (root == null) throw StateError('Private storage unavailable.');
      final directory = Directory('$root/temporary-shares');
      await directory.create(recursive: true);
      await channel.invokeMethod('preparePrivateDirectory', {
        'path': directory.path,
      });
      final file = File('${directory.path}/draft-${newUuidV4()}.pdf');
      temporaryShare = file;
      if (!_current ||
          !identical(_artifact, sharedArtifact) ||
          sharedArtifact == null ||
          !sharedArtifact.base.isAvailableAt(DateTime.now().toUtc())) {
        return;
      }
      await file.writeAsBytes(sharedPdf!, flush: true);
      await channel.invokeMethod('preparePrivateDirectory', {
        'path': directory.path,
      });
      if (!mounted ||
          !buttonContext.mounted ||
          !_current ||
          !identical(_artifact, sharedArtifact) ||
          !sharedArtifact.base.isAvailableAt(DateTime.now().toUtc())) {
        await file.delete();
        return;
      }
      final box = buttonContext.findRenderObject() as RenderBox?;
      shareRequested = true;
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(file.path, mimeType: 'application/pdf')],
          title: context.tr('Safe at Home incomplete draft'),
          sharePositionOrigin: box == null
              ? null
              : box.localToGlobal(Offset.zero) & box.size,
        ),
      );
    } catch (error) {
      try {
        if (!shareRequested &&
            temporaryShare != null &&
            await temporaryShare.exists()) {
          await temporaryShare.delete();
        }
      } catch (_) {}
      if (mounted) await showOperationError(context, error);
    } finally {
      if (shareRequested && temporaryShare != null) {
        final file = temporaryShare;
        unawaited(
          Future<void>.delayed(const Duration(minutes: 2), () async {
            try {
              if (await file.exists()) await file.delete();
            } catch (_) {}
            try {
              await const MethodChannel(
                'safe_at_home/private_media',
              ).invokeMethod<void>('clearSharedDraftCopy', {
                'name': file.uri.pathSegments.last,
              });
            } catch (_) {}
          }),
        );
      }
    }
  }

  String _expiryLabel(BuildContext context) {
    final expires = DateTime.parse(_artifact!.base.expiresAt).toLocal();
    final local = MaterialLocalizations.of(context);
    return context.tr('{date} at {time}', {
      'date': local.formatMediumDate(expires),
      'time': local.formatTimeOfDay(TimeOfDay.fromDateTime(expires)),
    });
  }

  String? _currentFingerprint() {
    if (!_current || _answers == null) return null;
    try {
      return _fingerprint();
    } catch (_) {
      return null;
    }
  }

  bool get _worksheet => _answers?.artifactKind == 'preparation_worksheet';

  String _photoTitle(BuildContext context, EvidenceDescriptor evidence) {
    final findings = widget.services.coordinator.snapshot?.findings ?? [];
    final finding = findings.where((f) => f.id == evidence.findingId);
    if (finding.isEmpty) {
      return context.tr('Photo {number}', {
        'number': _catalog!.evidence.indexOf(evidence) + 1,
      });
    }
    return context.tr('{room} · {concern}', {
      'room': context.tr(switch (finding.single.room) {
        'bathroom' => 'Bathroom',
        'entrance' => 'Entrance',
        _ => 'Other area',
      }),
      'concern': finding.single.observation,
    });
  }

  bool _photoAllowed(EvidenceDescriptor evidence) {
    final findings = widget.services.coordinator.snapshot?.findings ?? [];
    final finding = findings.where((f) => f.id == evidence.findingId);
    return finding.isEmpty || finding.single.reviewState == 'confirmed';
  }

  @override
  Widget build(BuildContext context) {
    final fingerprint = _currentFingerprint();
    final prior = _prior;
    final interrupted =
        _pdf == null &&
        prior != null &&
        prior['completed'] != true &&
        fingerprint != null &&
        prior['fingerprint'] == fingerprint;
    final outdated =
        _pdf == null &&
        prior != null &&
        prior['completed'] == true &&
        fingerprint != null &&
        prior['fingerprint'] != fingerprint;
    final reopen =
        _pdf == null &&
        prior != null &&
        prior['completed'] == true &&
        fingerprint != null &&
        prior['fingerprint'] == fingerprint;
    final createLabel = context.tr(
      interrupted
          ? 'Finish draft'
          : outdated
          ? 'Update draft'
          : reopen
          ? 'Open draft PDF'
          : _worksheet
          ? 'Create worksheet'
          : 'Create draft PDF',
    );
    final short = programShortName(widget.program);
    final photos = <Widget>[
      SahSectionHeading(
        title: context.tr('Photos and measurements'),
        description: context.tr(
          'Only photos linked to a confirmed concern can be included.',
        ),
      ),
      if (_catalog != null && _catalog!.evidence.isEmpty)
        SahNotice(
          message: context.tr(
            'No saved photos. You can prepare a draft without them.',
          ),
          icon: Icons.photo_outlined,
        ),
      if (_catalog != null)
        for (final evidence in _catalog!.evidence)
          SahActionTile(
            key: ValueKey('export-photo-${evidence.evidenceId}'),
            title: _photoTitle(context, evidence),
            subtitle: _selected.containsKey(evidence.evidenceId)
                ? context.tr('Included · {number}', {
                    'number':
                        _selected.keys.toList().indexOf(evidence.evidenceId) +
                        1,
                  })
                : _photoAllowed(evidence)
                ? context.tr('Not included')
                : context.tr('Confirm the concern first'),
            icon: _selected.containsKey(evidence.evidenceId)
                ? Icons.check_circle_outline_rounded
                : Icons.photo_outlined,
            enabled:
                !_busy &&
                !_sharing &&
                _current &&
                (_photoAllowed(evidence) ||
                    _selected.containsKey(evidence.evidenceId)),
            onTap: () => _review(evidence),
          ),
    ];
    return Scaffold(
      appBar: AppBar(
        title: Text(context.tr(_worksheet ? 'Worksheet' : 'Draft PDF')),
      ),
      body: SafeArea(
        child: SahContent(
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              SahPageHeader(title: short),
              Wrap(
                spacing: 12,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  SahOutputLabel(
                    kind: _worksheet
                        ? SahOutputKind.preparationWorksheet
                        : programOutputKind(widget.program),
                  ),
                  SahTag(
                    key: const ValueKey('export-status'),
                    label: context.tr('Draft · not sent'),
                    tone: SahNoticeTone.warning,
                  ),
                ],
              ),
              const SizedBox(height: 8),
              if (Localizations.localeOf(context).languageCode != 'en')
                SahNotice(
                  message: context.tr(
                    'Program information and official forms may remain in English. Your saved answers are not translated.',
                  ),
                ),
              if (_busy)
                LinearProgressIndicator(
                  semanticsLabel: context.tr('Preparing your private draft'),
                ),
              if (_error != null)
                SahNotice(
                  message: context.tr(_error!),
                  tone: SahNoticeTone.error,
                ),
              if (_notice != null) SahNotice(message: context.tr(_notice!)),
              if (_pdf != null) ...[
                widget.services.pdfPreviewBuilder?.call(_pdf!) ??
                    PrivateDraftPreview(bytes: _pdf!),
                const SizedBox(height: 16),
                Builder(
                  builder: (ctx) => FilledButton.icon(
                    key: const ValueKey('export-share'),
                    onPressed: _busy || _sharing ? null : () => _share(ctx),
                    icon: const Icon(Icons.ios_share),
                    label: Text(
                      _sharing
                          ? context.tr('Opening sharing…')
                          : context.tr('Share draft file'),
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  context.tr(
                    'Sharing sends a file. It doesn’t send your application.',
                  ),
                  textAlign: TextAlign.center,
                ),
                SahNextStepCard(
                  label: context.tr('Next'),
                  title: _worksheet
                      ? context.tr('Contact {program}', {'program': short})
                      : context.tr('Send it to {program} yourself', {
                          'program': short,
                        }),
                  message: context.tr(
                    'The app can’t send it. When you have, record it under Updates.',
                  ),
                  secondary: Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: OutlinedButton(
                      key: const ValueKey('export-done'),
                      onPressed: () => Navigator.of(context).maybePop(),
                      child: Text(context.tr('Done')),
                    ),
                  ),
                ),
              ],
              if (_pdf == null) ...[
                if (interrupted)
                  SahNotice(
                    key: const ValueKey('export-interrupted'),
                    title: context.tr('The draft wasn’t finished'),
                    message: context.tr(
                      'The app closed while making it. Nothing was shared.',
                    ),
                    tone: SahNoticeTone.warning,
                  ),
                if (outdated)
                  SahNotice(
                    key: const ValueKey('export-outdated'),
                    title: context.tr(
                      'Something changed after this draft was made',
                    ),
                    message: context.tr(
                      'Answers or concerns changed. Update the draft so it matches before you share or send it.',
                    ),
                    tone: SahNoticeTone.warning,
                  ),
                ...photos,
                if (_error != null)
                  TextButton.icon(
                    onPressed: _busy || _sharing ? null : _load,
                    icon: const Icon(Icons.refresh_rounded),
                    label: Text(
                      context.tr('Reload current evidence and answers'),
                    ),
                  ),
                const SizedBox(height: 12),
                FilledButton.icon(
                  key: const ValueKey('export-create'),
                  onPressed: _busy || _sharing || !_current || _answers == null
                      ? null
                      : () => _prepare(),
                  icon: const Icon(Icons.description_outlined),
                  label: Text(createLabel),
                ),
                if (_error != null)
                  TextButton(
                    onPressed: _busy || _sharing || !_current
                        ? null
                        : () => _prepare(newAttempt: true),
                    child: Text(
                      context.tr('Start a newly reviewed draft attempt'),
                    ),
                  ),
              ],
              if (_artifact != null) ...[
                const SizedBox(height: 12),
                Text(
                  context.tr(
                    _artifact!.base.missingItems.length == 1
                        ? '1 item still needed. Nothing has been submitted.'
                        : '{count} items still needed. Nothing has been submitted.',
                    {'count': _artifact!.base.missingItems.length},
                  ),
                ),
                if (_artifact!.base.warnings.any(
                  (w) => w != 'INCOMPLETE_DRAFT' && w != 'NOT_SUBMITTED',
                ))
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      context.tr(
                        'Program availability or requirements still need confirmation.',
                      ),
                    ),
                  ),
                const SizedBox(height: 8),
                Text(
                  context.tr('Download expires {expiry}.', {
                    'expiry': _expiryLabel(context),
                  }),
                ),
                ExpansionTile(
                  key: const ValueKey('draft-unresolved-items'),
                  tilePadding: EdgeInsets.zero,
                  title: Text(context.tr('Unresolved draft items')),
                  subtitle: Text(
                    context.tr(
                      _artifact!.base.missingItems.length == 1
                          ? '1 item to review'
                          : '{count} items to review',
                      {'count': _artifact!.base.missingItems.length},
                    ),
                  ),
                  children: [
                    for (final item in _artifact!.base.missingItems)
                      Padding(
                        key: ValueKey('draft-unresolved-${item.id}'),
                        padding: const EdgeInsets.only(bottom: 16),
                        child: Text(item.description),
                      ),
                  ],
                ),
              ],
              if (_pdf != null) ...photos,
            ],
          ),
        ),
      ),
    );
  }
}
