part of 'sharing_screens.dart';

class SensitiveSharingScreen extends StatefulWidget {
  const SensitiveSharingScreen({
    super.key,
    required this.services,
    required this.membership,
    required this.ownerView,
  });
  final AppServices services;
  final CaseMembership membership;
  final bool ownerView;
  @override
  State<SensitiveSharingScreen> createState() => _SensitiveSharingState();
}

class _SensitiveSharingState extends _OnlineState<SensitiveSharingScreen> {
  @override
  AppServices get services => widget.services;
  SensitiveResponse? view, preview, report;
  MemoryImage? photo;
  final photos = <String>{},
      measurements = <String>{},
      answers = <String>{},
      reviewedPhotos = <String>{};
  bool allowPdf = false,
      pdfReviewed = false,
      published = false,
      uncertain = false;
  int days = 7;
  late int permission;
  String? parentExpiresAt;
  Map<String, Object?>? pending;
  Timer? timer;
  @override
  void initState() {
    super.initState();
    permission = widget.membership.revision;
    parentExpiresAt = widget.membership.expiresAt;
    unawaited(reload());
    timer = Timer.periodic(const Duration(seconds: 20), (_) {
      if (current && !widget.ownerView && !busy) unawaited(reload());
    });
  }

  void clearMedia() {
    final old = photo;
    photo = null;
    if (old != null) unawaited(old.evict());
    report = null;
    pdfReviewed = false;
  }

  @override
  void clearContent() {
    clearMedia();
    view = null;
    preview = null;
    photos.clear();
    measurements.clear();
    answers.clear();
    reviewedPhotos.clear();
    pending = null;
    uncertain = false;
    published = false;
    allowPdf = false;
  }

  @override
  void dispose() {
    timer?.cancel();
    clearMedia();
    super.dispose();
  }

  Map<String, Object?> get binding => {
    'membershipId': widget.membership.id,
    'expectedPermissionRevision': permission,
  };
  Future<SensitiveResponse> request(
    String route,
    Map<String, Object?> fields,
    bool Function() valid,
  ) => services.sharing.sensitive(
    route,
    fields,
    isCurrent: valid,
    expectedCaseId: widget.membership.caseId,
  );
  @override
  Future<void> reload() => run((valid) async {
    final metadata = await call(
      widget.ownerView ? 'list-sharing' : 'list-shared-cases',
      widget.ownerView ? {'caseId': widget.membership.caseId} : {},
      valid,
    );
    if (!valid()) return;
    final grant =
        (widget.ownerView
                ? metadata.shares.map((s) => s.membership)
                : metadata.memberships)
            .firstWhere((g) => g.id == widget.membership.id);
    if (grant.role != 'helper' || grant.state != 'active') {
      throw const FormatException();
    }
    permission = grant.revision;
    parentExpiresAt = grant.expiresAt;
    final next = await request(
      widget.ownerView ? 'list-sensitive-options' : 'read-sensitive-sharing',
      binding,
      valid,
    );
    if (valid()) {
      setState(() {
        if (view?.sourceHash != next.sourceHash || widget.ownerView) {
          clearContent();
        }
        view = next;
      });
    }
  });
  SensitiveSelection get selection => SensitiveSelection(
    photoIds: photos.toList(),
    measurementIds: measurements.toList(),
    answerIds: answers.toList(),
  );
  void changed(void Function() edit) => setState(() {
    edit();
    preview = null;
    published = false;
    clearMedia();
  });
  Future<void> prepare() => run((valid) async {
    final expiry = DateTime.now().toUtc().add(Duration(days: days));
    final parentExpiry = DateTime.tryParse(parentExpiresAt ?? '');
    final until = parentExpiry != null && parentExpiry.isBefore(expiry)
        ? parentExpiry
        : expiry;
    final result = await request('preview-sensitive-sharing', {
      ...binding,
      'expectedCaseRevision': view!.caseRevision,
      'expectedCatalogRevision': view!.catalogRevision,
      'selection': selection.toJson(),
      'allowPdf': allowPdf,
      'expiresAt': DateTime.fromMillisecondsSinceEpoch(
        until.millisecondsSinceEpoch,
        isUtc: true,
      ).toIso8601String(),
    }, valid);
    if (valid()) {
      setState(() {
        preview = result;
        clearMedia();
      });
    }
  });
  Map<String, Object?> previewFields() => {
    ...binding,
    'expectedCaseRevision': preview!.caseRevision,
    'expectedCatalogRevision': preview!.catalogRevision,
    'selection': preview!.selection!.toJson(),
    'allowPdf': preview!.allowPdf,
    'expiresAt': preview!.expiresAt,
    'previewHash': preview!.sourceHash,
  };
  Future<void> publish() => run((valid) async {
    pending ??= {...previewFields(), 'mutationId': newUuidV4()};
    try {
      final result = await request(
        'publish-sensitive-sharing',
        pending!,
        valid,
      );
      if (valid()) {
        setState(() {
          permission = result.permissionRevision;
          preview = null;
          published = true;
          pending = null;
          uncertain = false;
          clearMedia();
        });
      }
    } on MatchingApiException catch (e) {
      if (e.code == 'SHARING_SAVE_UNCERTAIN' && valid()) {
        setState(() {
          uncertain = true;
          error =
              'The save could not be confirmed. Retry the same save before changing selections.';
        });
      } else {
        rethrow;
      }
    }
  });
  Future<void> openPhoto(EvidenceDescriptor item) => run((valid) async {
    final result = await request(
      widget.ownerView ? 'preview-sensitive-photo' : 'read-sensitive-photo',
      {
        ...binding,
        'evidenceId': item.evidenceId,
        'expectedEvidenceRevision': item.evidenceRevision,
        if (widget.ownerView) ...{
          'expectedCaseRevision': view!.caseRevision,
          'expectedCatalogRevision': view!.catalogRevision,
        } else
          'sourceHash': view!.sourceHash,
      },
      valid,
    );
    if (valid()) {
      setState(() {
        clearMedia();
        photo = MemoryImage(result.bytes!);
        reviewedPhotos.add(item.evidenceId);
      });
    }
  });
  Future<void> openReport() => run((valid) async {
    final result = await request(
      widget.ownerView ? 'preview-sensitive-report' : 'read-sensitive-report',
      widget.ownerView
          ? previewFields()
          : {...binding, 'sourceHash': view!.sourceHash},
      valid,
    );
    if (valid()) {
      setState(() {
        clearMedia();
        report = result;
      });
    }
  });
  String answerText(Object? value) => value == null
      ? context.tr('Unknown')
      : value is bool
      ? context.tr(value ? 'Yes' : 'No')
      : value.toString();
  String category(String value) => switch (value) {
    'health' => context.tr('Health answers'),
    'financial' => context.tr('Financial answers'),
    _ => context.tr('Other private answers'),
  };
  List<Widget> content(
    SelectedSensitiveContent data, {
    required bool selecting,
  }) => [
    Text(
      context.tr('Selected photos'),
      style: Theme.of(context).textTheme.titleMedium,
    ),
    for (final (i, p) in data.photos.indexed)
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ListTile(
            leading: selecting
                ? Checkbox(
                    semanticLabel: context.tr('Photo {number}', {
                      'number': i + 1,
                    }),
                    value: photos.contains(p.evidenceId),
                    onChanged: busy || uncertain
                        ? null
                        : (v) => changed(() {
                            v == true
                                ? photos.add(p.evidenceId)
                                : photos.remove(p.evidenceId);
                          }),
                  )
                : const Icon(Icons.photo_outlined),
            title: Text(context.tr('Photo {number}', {'number': i + 1})),
            subtitle: selecting
                ? Text(
                    context.tr(
                      'Preview each selected photo before publishing.',
                    ),
                  )
                : null,
          ),
          Align(
            alignment: AlignmentDirectional.centerEnd,
            child: TextButton(
              onPressed: busy || uncertain ? null : () => openPhoto(p),
              child: Text(context.tr('Preview')),
            ),
          ),
        ],
      ),
    Text(
      context.tr('Selected measurements'),
      style: Theme.of(context).textTheme.titleMedium,
    ),
    for (final m in data.measurements)
      ListTile(
        leading: selecting
            ? Checkbox(
                semanticLabel: '${context.tr('Select measurement')}: ${m.type}',
                value: measurements.contains(m.id),
                onChanged: busy || uncertain
                    ? null
                    : (v) => changed(() {
                        v == true
                            ? measurements.add(m.id)
                            : measurements.remove(m.id);
                      }),
              )
            : const Icon(Icons.straighten),
        title: Text('${m.type.replaceAll('_', ' ')}: ${m.value} ${m.unit}'),
        subtitle: Text(
          '${context.tr(m.method == 'manual' ? 'Manual measurement' : 'Estimated measurement')} · ${context.tr(m.confirmed ? 'Confirmed' : 'Needs review')}',
        ),
      ),
    for (final group in ['financial', 'health', 'private']) ...[
      Text(category(group), style: Theme.of(context).textTheme.titleMedium),
      for (final a in data.answers.where((v) => v.category == group))
        ListTile(
          leading: selecting
              ? Checkbox(
                  semanticLabel: '${context.tr('Select answer')}: ${a.label}',
                  value: answers.contains(a.id),
                  onChanged: busy || uncertain
                      ? null
                      : (v) => changed(() {
                          v == true ? answers.add(a.id) : answers.remove(a.id);
                        }),
                )
              : null,
          title: Text(a.label),
          subtitle: Text(
            '${_programNames(context, services, widget.membership.caseId, [a.programId])[a.programId]}: ${answerText(a.value)}',
          ),
        ),
    ],
  ];
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(context.tr('Detailed helper access')),
      actions: [
        IconButton(
          tooltip: context.tr('Refresh access'),
          onPressed: busy || uncertain ? null : reload,
          icon: const Icon(Icons.refresh),
        ),
      ],
    ),
    body: SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text(
            context.tr(
              'Only explicitly selected information is shared. Changed information requires a new review.',
            ),
          ),
          Text(
            context.tr(
              'Reports contain selected measurements and answers. Photo bytes and full application packets are excluded.',
            ),
          ),
          Text(
            context.tr(
              'Labels and answers keep their source language. Viewed information and screenshots cannot be recalled.',
            ),
          ),
          ...status(),
          if (view != null) ...[
            ...content(view!.content!, selecting: widget.ownerView),
            if (widget.ownerView) ...[
              CheckboxListTile(
                value: allowPdf,
                onChanged: busy || uncertain
                    ? null
                    : (v) => changed(() {
                        allowPdf = v == true;
                      }),
                title: Text(
                  context.tr(
                    'Allow a filtered PDF of selected measurements and answers',
                  ),
                ),
              ),
              DropdownButtonFormField<int>(
                isExpanded: true,
                itemHeight: null,
                initialValue: days,
                decoration: InputDecoration(
                  labelText: context.tr('Access duration'),
                ),
                items: [
                  for (final d in [1, 7, 30])
                    DropdownMenuItem(
                      value: d,
                      child: Text(context.tr('{count} days', {'count': d})),
                    ),
                ],
                onChanged: busy || uncertain
                    ? null
                    : (v) => changed(() {
                        days = v!;
                      }),
              ),
              FilledButton(
                onPressed: busy || uncertain ? null : prepare,
                child: Text(context.tr('Review selected information')),
              ),
              if (preview != null) ...[
                const Divider(),
                Text(
                  context.tr('Review before publishing'),
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                ...content(preview!.content!, selecting: false),
                Text('${context.tr('Access expires')}: ${preview!.expiresAt}'),
                if (preview!.allowPdf)
                  OutlinedButton(
                    onPressed: busy ? null : openReport,
                    child: Text(context.tr('Preview filtered PDF')),
                  ),
              ],
            ] else if (view!.allowPdf)
              OutlinedButton(
                onPressed: busy ? null : openReport,
                child: Text(context.tr('Preview filtered PDF')),
              ),
          ],
          if (photo != null)
            Image(
              image: photo!,
              height: 300,
              fit: BoxFit.contain,
              semanticLabel: context.tr('Selected shared photo'),
            ),
          if (report != null)
            SizedBox(
              height: 600,
              child:
                  services.pdfPreviewBuilder?.call(report!.bytes!) ??
                  PrivateDraftPreview(bytes: report!.bytes!),
            ),
          if (widget.ownerView && preview != null) ...[
            if (preview!.allowPdf && report != null)
              CheckboxListTile(
                value: pdfReviewed,
                onChanged: busy
                    ? null
                    : (v) => setState(() {
                        pdfReviewed = v == true;
                      }),
                title: Text(
                  context.tr('I reviewed every page of the filtered PDF'),
                ),
              ),
            Text(
              context.tr(
                'Publishing replaces detailed access. Clear all selections to remove detailed access.',
              ),
            ),
            FilledButton(
              onPressed:
                  busy ||
                      uncertain ||
                      !photos.every(reviewedPhotos.contains) ||
                      preview!.allowPdf && !pdfReviewed
                  ? null
                  : publish,
              child: Text(
                context.tr('Confirm and publish selected information'),
              ),
            ),
          ],
          if (uncertain)
            FilledButton(
              onPressed: busy ? null : publish,
              child: Text(context.tr('Retry the same save')),
            ),
          if (published) Text(context.tr('Selected information published.')),
        ],
      ),
    ),
  );
}
