import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:safe_at_home/app/theme.dart';
import 'package:safe_at_home/features/assessment/application/bathroom_scan_adapter.dart';
import 'package:safe_at_home/features/assessment/application/bathroom_scan_session.dart';
import 'package:safe_at_home/features/assessment/domain/scan/bathroom_scan_scene.dart';
import 'package:safe_at_home/features/assessment/presentation/bathroom_scan_screen.dart';
import 'package:safe_at_home/shared/services/local_private_store.dart';

const _media = MethodChannel('safe_at_home/private_media');
const _account = 'fictional-synthetic-scan-preview';
const _caseId = '0e7ce06d-ae19-4565-ae28-f082353a04dd';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (!kDebugMode) {
    throw UnsupportedError('The synthetic scan preview is debug-only.');
  }
  final root = await _media.invokeMethod<String>('privateRootDirectory');
  if (root == null) throw StateError('Private preview storage is unavailable.');
  final path = '$root/synthetic-scan-preview';
  await _media.invokeMethod<String>('preparePrivateDirectory', {'path': path});
  runApp(_Preview(directory: Directory(path)));
}

class _Preview extends StatefulWidget {
  const _Preview({required this.directory});
  final Directory directory;
  @override
  State<_Preview> createState() => _PreviewState();
}

class _PreviewState extends State<_Preview> {
  late LocalPrivateStore store = _store();
  final imported = <String, String>{};
  bool clearing = false;

  LocalPrivateStore _store() => LocalPrivateStore(
    directory: widget.directory,
    accountId: _account,
    secrets: DeviceSecretStore(),
  );

  @override
  Widget build(BuildContext context) => MaterialApp(
    theme: SafeAtHomeTheme.light(),
    builder: (context, child) => Column(
      children: [
        Material(
          color: const Color(0xFFFFDE59),
          child: SafeArea(
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: Text(
                'SYNTHETIC 3D PREVIEW\nNo camera · No network · Fictional geometry only',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.black,
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
        ),
        Expanded(child: child!),
      ],
    ),
    home: Builder(
      builder: (context) => Scaffold(
        appBar: AppBar(title: const Text('Bathroom review preview')),
        body: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            const Text(
              'Inspect the actual bathroom review screen with a fictional room. The Scan bathroom button loads synthetic geometry; it never opens the camera.',
            ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: clearing
                  ? null
                  : () async {
                      final session = BathroomScanSession(
                        store: store,
                        caseId: _caseId,
                        isCurrent: () => mounted,
                        adapter: const _SyntheticScanner(),
                      );
                      await Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => BathroomScanScreen(
                            session: session,
                            importedFinding: (id) => imported[id],
                            onImport: (suggestion) async {
                              final id =
                                  'synthetic-observation-${imported.length + 1}';
                              imported[suggestion.id] = id;
                              return id;
                            },
                          ),
                        ),
                      );
                      if (mounted) setState(() {});
                    },
              child: const Text('Open synthetic review'),
            ),
            const SizedBox(height: 16),
            Text(
              '${imported.length} fictional observations confirmed in this preview session.',
            ),
            const SizedBox(height: 16),
            OutlinedButton(
              onPressed: clearing
                  ? null
                  : () async {
                      setState(() => clearing = true);
                      try {
                        await store.clear();
                        await _media.invokeMethod<String>(
                          'preparePrivateDirectory',
                          {'path': widget.directory.path},
                        );
                        store = _store();
                        imported.clear();
                      } finally {
                        if (mounted) setState(() => clearing = false);
                      }
                    },
              child: const Text('Clear synthetic device data'),
            ),
          ],
        ),
      ),
    ),
  );
}

class _SyntheticScanner implements BathroomScanAdapter {
  const _SyntheticScanner();
  @override
  Future<BathroomScanCapabilities> capabilities() async =>
      const BathroomScanCapabilities(
        supported: true,
        source: 'roomplan',
        reason: 'available',
        depthSupported: true,
      );
  @override
  Future<void> cancel(String scanId) async {}
  @override
  Future<BathroomScanScene> start(String scanId) async {
    Map<String, Object?> element(
      String id,
      String kind,
      List<double> size,
      double x,
      double y,
      double z, [
      double yaw = 0,
    ]) => {
      'id': id,
      'kind': kind,
      'nativeCategory': kind,
      'dimensions': size,
      'classificationConfidence': 'high',
      'transform': [
        math.cos(yaw),
        0,
        -math.sin(yaw),
        0,
        0,
        1,
        0,
        0,
        math.sin(yaw),
        0,
        math.cos(yaw),
        0,
        x,
        y,
        z,
        1,
      ],
    };
    return BathroomScanScene.fromJson({
      'schemaVersion': 1,
      'scanId': scanId,
      'source': 'roomplan',
      'sourceVersion': 'SYNTHETIC visual fixture; no RoomPlan capture',
      'capturedAt': DateTime.now().toUtc().toIso8601String(),
      'units': 'm',
      'coordinateSystem': 'right_handed_y_up',
      'coverage': 'partial',
      'truncated': false,
      'warnings': <String>[],
      'points': <List<double>>[],
      'elements': [
        element('door-1', 'door', [.9, 2.0, 0], -.25, 1, 1.8),
        element('back-wall', 'wall', [3, 2.4, 0], 0, 1.2, -1.8),
        element('left-wall', 'wall', [3.6, 2.4, 0], -1.5, 1.2, 0, math.pi / 2),
        element('right-wall', 'wall', [3.6, 2.4, 0], 1.5, 1.2, 0, math.pi / 2),
        element('front-wall-left', 'wall', [.8, 2.4, 0], -1.1, 1.2, 1.8),
        element('front-wall-right', 'wall', [1.3, 2.4, 0], .85, 1.2, 1.8),
        element('floor', 'floor', [3, 0, 3.6], 0, 0, 0),
        element('bath', 'bathtub', [.8, .6, 1.6], -.9, .3, -.7),
        element('toilet', 'toilet', [.5, .7, .7], .9, .35, -.95),
        element('sink', 'sink', [.6, .9, .5], .9, .45, .4),
      ],
    });
  }
}
