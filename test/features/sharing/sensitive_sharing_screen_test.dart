import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/app/live_app.dart';
import 'package:safe_at_home/features/sharing/sharing_screens.dart';
import 'package:safe_at_home/shared/models/sharing.dart';
import 'package:safe_at_home/shared/services/matching_api_client.dart';
import 'package:safe_at_home/l10n/app_localizations.dart';
import '../../app/case_coordinator_test.dart' show FakeSession, FakeTransport;
import '../../app/live_workflows_test.dart' show MemoryPrivateStore;
import '../../services/case_evidence_api_client_test.dart' as http;
import 'sensitive_sharing_contract_test.dart' show sensitiveFixture;
import 'sharing_contract_test.dart' show sharedFixture;

const helperId = '22222222-2222-4222-8222-222222222222';

class _Store extends MemoryPrivateStore {
  _Store(this.owner);
  final bool owner;
  @override
  String get accountId => owner ? 'fictional-owner' : helperId;
}

Map<String, Object?> copy(Object value) =>
    Map<String, Object?>.from(jsonDecode(jsonEncode(value)) as Map);
Map<String, Object?> grant() =>
    copy(sharedFixture()['membership']!)
      ..['scope'] = {
        'findingIds': ['fictional-finding'],
        'programIds': ['scfhp-eaa'],
        'allowHelperNotes': true,
      };

class _Server {
  bool denied = false, loseSave = false;
  final writes = <Map<String, Object?>>[];
  Completer<MatchingHttpResponse>? latePhoto;
  Map<String, Object?> selected(Map<String, Object?> body) {
    final response = copy(sensitiveFixture('preview-sensitive-sharing'));
    final s = body['selection'] as Map;
    final data = copy(response['content']!);
    for (final pair in [
      ('photos', 'photoIds'),
      ('measurements', 'measurementIds'),
      ('answers', 'answerIds'),
    ]) {
      data[pair.$1] = (data[pair.$1] as List)
          .where(
            (row) => (s[pair.$2] as List).contains(
              row[pair.$1 == 'photos' ? 'evidenceId' : 'id'],
            ),
          )
          .toList();
    }
    return {
      ...response,
      'content': data,
      'selection': s,
      'allowPdf': body['allowPdf'],
      'expiresAt': body['expiresAt'],
    };
  }

  Future<MatchingHttpResponse> handle(MatchingHttpRequest r) async {
    final body = http.requestJson(r), route = r.endpoint.path.split('/').last;
    if (denied) {
      return http.jsonResponse({
        'schemaVersion': '3',
        'error': {
          'code': 'SHARING_NOT_FOUND',
          'message': 'Fictional revoked access',
        },
      }, status: 404);
    }
    switch (route) {
      case 'list-sharing':
        return http.jsonResponse({
          'schemaVersion': '3',
          'availableProgramIds': ['scfhp-eaa'],
          'shares': [
            {
              ...grant(),
              'projection': sharedFixture()['projection'],
              'notes': [],
              'audit': [],
            },
          ],
        });
      case 'list-shared-cases':
        return http.jsonResponse({
          'schemaVersion': '3',
          'memberships': [grant()],
        });
      case 'list-sensitive-options':
        return http.jsonResponse(sensitiveFixture(route));
      case 'read-sensitive-sharing':
        return http.jsonResponse(sensitiveFixture(route));
      case 'preview-sensitive-sharing':
        return http.jsonResponse(selected(body));
      case 'publish-sensitive-sharing':
        writes.add(copy(body));
        if (loseSave) {
          loseSave = false;
          throw const MatchingTransportException(
            MatchingTransportFailure.network,
          );
        }
        return http.jsonResponse({
          ...selected(body),
          'permissionRevision': 3,
          'acknowledgedMutationId': body['mutationId'],
        });
      case 'preview-sensitive-photo':
      case 'read-sensitive-photo':
        return latePhoto?.future ?? http.jsonResponse(sensitiveFixture(route));
      case 'preview-sensitive-report':
      case 'read-sensitive-report':
        return http.jsonResponse(sensitiveFixture(route));
      default:
        throw StateError('Unexpected fictional route: $route');
    }
  }
}

Future<AppServices> _mount(
  WidgetTester tester,
  _Server server, {
  bool owner = true,
  Locale locale = const Locale('en'),
  double scale = 1,
}) async {
  final session = FakeSession()..owner = owner ? 'fictional-owner' : helperId;
  final app = AppServices(
    config: LiveAppConfig(
      apiOrigin: Uri.parse('https://fictional.example'),
      supabaseUrl: Uri.parse('https://fictional.supabase.co'),
      publishableKey: 'fictional',
      permissionSharingEnabled: true,
      sensitiveSharingEnabled: true,
    ),
    session: session,
    store: _Store(owner),
    transport: FakeTransport(server.handle),
    pdfPreviewBuilder: (_) => const Text('Fictional native PDF placeholder'),
  );
  addTearDown(() {
    app.dispose();
    session.dispose();
  });
  await tester.pumpWidget(
    MaterialApp(
      locale: locale,
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      home: SensitiveSharingScreen(
        services: app,
        membership: CaseMembership.fromJson(grant()),
        ownerView: owner,
      ),
    ),
  );
  await tester.pumpAndSettle();
  return app;
}

Future<void> tap(WidgetTester tester, Finder finder) async {
  await tester.scrollUntilVisible(
    finder,
    160,
    scrollable: find.byType(Scrollable).first,
    maxScrolls: 300,
  );
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<void> end(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'owner starts with no private selections and only explicit preview/confirmation publishes one measurement',
    (tester) async {
      final server = _Server();
      final app = await _mount(tester, server);
      expect(
        tester
            .widgetList<Checkbox>(find.byType(Checkbox))
            .every((w) => w.value == false),
        true,
      );
      expect(server.writes, isEmpty);
      await tap(
        tester,
        find.byWidgetPredicate(
          (w) =>
              w is Checkbox &&
              (w.semanticLabel ?? '').startsWith('Select measurement'),
        ),
      );
      await tap(tester, find.text('Review selected information'));
      expect(server.writes, isEmpty);
      await tap(tester, find.text('Confirm and publish selected information'));
      expect(server.writes.length, 1);
      final selection = server.writes.single['selection'] as Map;
      expect(selection['photoIds'], isEmpty);
      expect(selection['answerIds'], isEmpty);
      expect(selection['measurementIds'], hasLength(1));
      expect(server.writes.single['allowPdf'], false);
      expect(
        (app.store as _Store).records.keys.where(
          (k) => k.contains('sensitive'),
        ),
        isEmpty,
      );
      await end(tester);
    },
  );
  testWidgets(
    'uncertain publication retries the identical mutation and never silently enables more fields',
    (tester) async {
      final server = _Server()..loseSave = true;
      await _mount(tester, server);
      await tap(tester, find.text('Review selected information'));
      await tap(tester, find.text('Confirm and publish selected information'));
      expect(server.writes, hasLength(1));
      await tap(tester, find.text('Retry the same save'));
      expect(server.writes, hasLength(2));
      expect(server.writes[0], server.writes[1]);
      await end(tester);
    },
  );
  testWidgets(
    'helper media clears on background and revoked foreground access has no offline copy',
    (tester) async {
      final server = _Server();
      final app = await _mount(tester, server, owner: false);
      expect(find.byType(Checkbox), findsNothing);
      await tap(tester, find.text('Preview').first);
      expect(find.bySemanticsLabel('Selected shared photo'), findsOneWidget);
      await tap(tester, find.text('Preview filtered PDF'));
      expect(find.text('Fictional native PDF placeholder'), findsOneWidget);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      expect(find.text('Fictional native PDF placeholder'), findsNothing);
      expect(find.bySemanticsLabel('Selected shared photo'), findsNothing);
      server.denied = true;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(find.text('Estimated project cost'), findsNothing);
      expect(
        (app.store as _Store).records.keys.where(
          (k) => k.contains('sensitive'),
        ),
        isEmpty,
      );
      await end(tester);
    },
  );
  testWidgets(
    'a photo response arriving after sign-out cannot repopulate the helper view',
    (tester) async {
      final server = _Server()..latePhoto = Completer<MatchingHttpResponse>();
      final app = await _mount(tester, server, owner: false);
      await tester.tap(find.text('Preview').first);
      await tester.pump();
      await app.session.signOut();
      await tester.pump();
      server.latePhoto!.complete(
        http.jsonResponse(sensitiveFixture('read-sensitive-photo')),
      );
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel('Selected shared photo'), findsNothing);
      expect(find.text('Estimated project cost'), findsNothing);
      await end(tester);
    },
  );
  for (final locale in AppLocalizations.supportedLocales) {
    testWidgets(
      'selected-data controls remain reachable at 320px/3.2x in ${locale.toLanguageTag()}',
      (tester) async {
        tester.view.physicalSize = const Size(320, 700);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await _mount(tester, _Server(), locale: locale, scale: 3.2);
        await tap(
          tester,
          find.text(
            AppLocalizations(locale).text('Review selected information'),
          ),
        );
        await tester.scrollUntilVisible(
          find.text(
            AppLocalizations(
              locale,
            ).text('Confirm and publish selected information'),
          ),
          180,
          scrollable: find.byType(Scrollable).first,
          maxScrolls: 300,
        );
        expect(tester.takeException(), isNull);
        await end(tester);
      },
    );
  }
}
