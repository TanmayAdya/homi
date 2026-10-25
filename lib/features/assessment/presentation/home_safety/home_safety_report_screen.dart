import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import '../../../../app/live_app.dart';
import '../../../../l10n/app_localizations.dart';
import '../../../../shared/models/case_draft.dart';
import '../../../../shared/services/home_safety_api_client.dart';
import '../../../../shared/presentation/sah_components.dart';
import '../../application/home_safety/home_safety_session.dart';
import '../../../requests/private_draft_preview.dart';

class HomeSafetyReportScreen extends StatefulWidget {
  const HomeSafetyReportScreen({
    super.key,
    required this.services,
    required this.session,
  });
  final AppServices services;
  final HomeSafetySession session;
  @override
  State<HomeSafetyReportScreen> createState() => _HomeSafetyReportScreenState();
}

class _HomeSafetyReportScreenState extends State<HomeSafetyReportScreen>
    with WidgetsBindingObserver {
  HomeSafetyReport? report;
  bool busy = false, notes = false, evidence = false;
  String? error;
  int epoch = 0;
  bool get current =>
      mounted &&
      widget.session.isCurrent &&
      !widget.session.hasPending &&
      !widget.session.caseWriteBlocked;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.services.coordinator.addListener(invalidate);
  }

  void invalidate() {
    if (mounted &&
        (!current ||
            (report != null &&
                report!.caseRevision !=
                    widget.services.coordinator.snapshot?.revision))) {
      setState(() {
        report = null;
        epoch++;
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed && mounted) {
      setState(() {
        report = null;
        epoch++;
      });
    }
  }

  @override
  void dispose() {
    epoch++;
    report = null;
    WidgetsBinding.instance.removeObserver(this);
    widget.services.coordinator.removeListener(invalidate);
    super.dispose();
  }

  Future<int> refresh() async {
    await widget.session.refresh();
    widget.session.guard();
    if (!current) throw StateError('Checklist changed.');
    final catalog = await widget.services.exports.listEvidence(
      widget.session.snapshot,
      currentCase: () {
        widget.session.guard();
        return widget.session.snapshot;
      },
      currentCatalog: () => null,
    );
    if (!current) throw StateError('Checklist changed.');
    return catalog.catalogRevision;
  }

  Future<void> generate() async {
    if (busy || !current) return;
    setState(() {
      busy = true;
      error = null;
      report = null;
    });
    final version = epoch;
    try {
      final catalog = await refresh();
      final s = widget.session;
      final result = await s.api.exportReport(
        s.baseline,
        catalog,
        includeNotes: notes,
        includeEvidenceReferences: evidence,
        isCurrent: () => current && epoch == version,
      );
      if (current && epoch == version) setState(() => report = result);
    } catch (_) {
      if (mounted) {
        setState(
          () => error =
              'The checklist report could not be prepared. Refresh and try again. Some text or report sizes may not be supported.',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> share(BuildContext origin) async {
    if (busy || !current || report == null) return;
    final shareTitle = context.tr('Room and checklist report');
    final accepted = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        scrollable: true,
        title: Text(ctx.tr('Share the checklist report?')),
        content: Text(
          ctx.tr(
            'The selected app or person can keep this copy. Sharing does not verify repairs, submit an application, or grant access to your plan.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(ctx.tr('Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(ctx.tr('Open share sheet')),
          ),
        ],
      ),
    );
    if (accepted != true || !current || report == null) return;
    setState(() => busy = true);
    final selected = report!, version = epoch;
    File? temporary;
    var dispatched = false;
    try {
      final catalog = await refresh();
      if (!current ||
          epoch != version ||
          widget.session.snapshot.revision != selected.caseRevision ||
          widget.session.baseline.revision != selected.safetyRevision ||
          catalog != selected.catalogRevision) {
        throw StateError('Report changed.');
      }
      const channel = MethodChannel('safe_at_home/private_media');
      final root = await channel.invokeMethod<String>('privateRootDirectory');
      if (root == null) throw StateError('Private storage unavailable.');
      final dir = Directory('$root/temporary-shares');
      await dir.create(recursive: true);
      await channel.invokeMethod('preparePrivateDirectory', {'path': dir.path});
      temporary = File('${dir.path}/draft-${newUuidV4()}.pdf');
      await temporary.writeAsBytes(selected.bytes, flush: true);
      await channel.invokeMethod('preparePrivateDirectory', {'path': dir.path});
      if (!current || epoch != version || !origin.mounted) {
        throw StateError('Report changed.');
      }
      final box = origin.findRenderObject() as RenderBox?;
      dispatched = true;
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(temporary.path, mimeType: 'application/pdf')],
          title: shareTitle,
          sharePositionOrigin: box == null
              ? null
              : box.localToGlobal(Offset.zero) & box.size,
        ),
      );
    } catch (_) {
      if (mounted) {
        setState(() {
          report = null;
          error =
              'The report changed or could not be shared. Prepare a fresh report and try again.';
        });
      }
    } finally {
      final file = temporary;
      if (file != null) {
        Future<void> cleanup() async {
          try {
            if (await file.exists()) await file.delete();
          } catch (_) {}
          try {
            await const MethodChannel(
              'safe_at_home/private_media',
            ).invokeMethod('clearSharedDraftCopy', {
              'name': file.uri.pathSegments.last,
            });
          } catch (_) {}
        }

        if (dispatched) {
          unawaited(Future<void>.delayed(const Duration(minutes: 2), cleanup));
        } else {
          await cleanup();
        }
      }
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(context.tr('Room and checklist report'))),
    body: SafeArea(
      child: ListView(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                Text(
                  context.tr(
                    'Report labels are in English. Your room names and notes are preserved. This educational report is not a safety certification or application.',
                  ),
                ),
                CheckboxListTile(
                  value: notes,
                  onChanged: busy
                      ? null
                      : (v) => setState(() {
                          notes = v!;
                          report = null;
                        }),
                  title: Text(context.tr('Include question notes')),
                ),
                CheckboxListTile(
                  value: evidence,
                  onChanged: busy
                      ? null
                      : (v) => setState(() {
                          evidence = v!;
                          report = null;
                        }),
                  title: Text(
                    context.tr('Include photo references (no images)'),
                  ),
                ),
                if (error != null) SahNotice(message: context.tr(error!)),
                Wrap(
                  spacing: 8,
                  children: [
                    FilledButton(
                      onPressed: busy || !current ? null : generate,
                      child: Text(context.tr('Prepare checklist report')),
                    ),
                    Builder(
                      builder: (origin) => TextButton(
                        onPressed: busy || report == null || !current
                            ? null
                            : () => share(origin),
                        child: Text(context.tr('Open share sheet')),
                      ),
                    ),
                  ],
                ),
                if (busy) const LinearProgressIndicator(),
              ],
            ),
          ),
          if (report != null)
            SizedBox(
              height: 600,
              child:
                  widget.services.pdfPreviewBuilder?.call(report!.bytes) ??
                  PrivateDraftPreview(bytes: report!.bytes),
            ),
        ],
      ),
    ),
  );
}
