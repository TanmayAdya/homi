import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:safe_at_home/app/live_app.dart';
import 'package:safe_at_home/app/private_content_cover.dart';
import 'package:safe_at_home/app/theme.dart';
import 'package:safe_at_home/features/cases/case_workspace_screen.dart';
import 'package:safe_at_home/l10n/app_localizations.dart';
import 'package:safe_at_home/shared/models/contracts.dart';
import 'package:safe_at_home/shared/services/local_private_store.dart';

import '../test/app/case_coordinator_test.dart' show FakeSession, FakeTransport;
import '../test/features/local_help/referral_test_support.dart'
    show ReferralServer;

Future<AppServices> _open() async {
  if (!const bool.fromEnvironment('SAH_HELP_ISOLATED_APP')) {
    throw StateError('Use the isolated device-check runner.');
  }
  const channel = MethodChannel('safe_at_home/private_media');
  final root = await channel.invokeMethod<String>('privateRootDirectory');
  if (root == null) throw StateError('Native private storage is unavailable.');
  final directory = Directory('$root/help-manual-fixture-v1');
  await directory.create(recursive: true);
  await channel.invokeMethod('preparePrivateDirectory', {
    'path': directory.path,
  });
  const owner = 'help-device-fictional-owner-v1';
  final store = LocalPrivateStore(
    directory: directory,
    accountId: owner,
    secrets: DeviceSecretStore(),
  );
  final backend = ReferralServer();
  final saved = await store.readJson('fixture-backend.v1');
  if (saved != null) {
    if (saved['schemaVersion'] != '1') throw const FormatException();
    backend.snapshot = CaseSnapshot.fromJson(saved['case']);
    for (final raw in saved['tasks'] as List) {
      final task = Map<String, Object?>.from(raw as Map);
      backend.tasks[task['id'] as String] = task;
    }
    backend.mutations.addAll((saved['mutations'] as List).cast<String>());
  }
  final session = FakeSession()..owner = owner;
  final app = AppServices(
    config: LiveAppConfig(
      apiOrigin: Uri.parse('https://help-device-check.invalid'),
      supabaseUrl: Uri.parse('https://help-device-check.invalid'),
      publishableKey: 'fictional',
      localHelpEnabled: true,
      trackingEnabled: true,
    ),
    session: session,
    store: store,
    transport: FakeTransport((request) async {
      final response = await backend.handle(request);
      if (request.endpoint.path == '/v1/create-case' ||
          request.endpoint.path == '/v3/save-progress') {
        await store.writeJson('fixture-backend.v1', {
          'schemaVersion': '1',
          'case': backend.snapshot.toJson(),
          'tasks': backend.tasks.values.toList(),
          'mutations': backend.mutations.toList(),
        });
      }
      return response;
    }),
  );
  await app.progressReady;
  if (saved == null) {
    await app.coordinator.createDraft();
    await app.coordinator.save();
  } else {
    await app.coordinator.restoreLocal(backend.snapshot.caseId);
  }
  return app;
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final opening = _open();
  runApp(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      locale: const Locale('en'),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      theme: SafeAtHomeTheme.light(),
      builder: (context, child) => Banner(
        message: 'FICTIONAL CHECK',
        location: BannerLocation.topEnd,
        child: PrivateContentCover(child: child!),
      ),
      home: FutureBuilder<AppServices>(
        future: opening,
        builder: (context, state) {
          if (state.hasError) {
            return const Scaffold(
              body: SafeArea(
                child: Text('Fictional device fixture could not open.'),
              ),
            );
          }
          if (!state.hasData) {
            return const Scaffold(
              body: Center(child: CircularProgressIndicator()),
            );
          }
          return CaseWorkspaceScreen(services: state.data!);
        },
      ),
    ),
  );
}
