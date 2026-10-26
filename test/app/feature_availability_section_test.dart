import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/shared/presentation/feature_availability_section.dart';
import 'package:safe_at_home/shared/services/matching_api_client.dart';
import 'case_coordinator_test.dart' show FakeTransport;
import 'live_workflows_test.dart' show MemoryPrivateStore, services;
import '../services/case_evidence_api_client_test.dart' as http;

void main() {
  testWidgets(
    'recheck clears stale service claims and recovers after plan change',
    (tester) async {
      Completer<MatchingHttpResponse>? pending;
      var fail = false;
      final app = services(
        MemoryPrivateStore(),
        FakeTransport((_) async {
          if (pending != null) return pending.future;
          if (fail) throw StateError('service unavailable');
          return http.jsonResponse({
            'schemaVersion': '1',
            'features': {
              'structuredRooms': true,
              'tracking': true,
              'scanSync': false,
              'permissionSharing': false,
              'sensitiveSharing': false,
              'simpleInvitations': false,
            },
          });
        }),
      );
      addTearDown(app.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: FeatureAvailabilitySection(services: app),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Feature availability'));
      await tester.pumpAndSettle();
      final photos = find.ancestor(
        of: find.text('Room photos and measurements'),
        matching: find.byType(ListTile),
      );
      final named = find.ancestor(
        of: find.text('Named rooms and checklists'),
        matching: find.byType(ListTile),
      );
      expect(
        find.descendant(
          of: photos,
          matching: find.text('Enabled in this build'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: named,
          matching: find.text('Disabled in this build'),
        ),
        findsOneWidget,
      );
      expect(find.text('Rooms'), findsNothing);
      final check = find.text('Check service availability');
      await tester.ensureVisible(check);
      await tester.tap(check);
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Available on this service'),
        findsNWidgets(2),
      );
      fail = true;
      await tester.ensureVisible(check);
      await tester.tap(check);
      await tester.pumpAndSettle();
      expect(find.textContaining('Available on this service'), findsNothing);
      pending = Completer<MatchingHttpResponse>();
      await tester.ensureVisible(check);
      await tester.tap(check);
      await tester.pump();
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      await app.coordinator.createDraft();
      pending.complete(
        http.jsonResponse({'schemaVersion': '1', 'features': {}}),
      );
      await tester.pumpAndSettle();
      expect(find.byType(LinearProgressIndicator), findsNothing);
      expect(
        tester.widget<TextButton>(find.byType(TextButton)).onPressed,
        isNotNull,
      );
      expect(find.textContaining('Available on this service'), findsNothing);
    },
  );
}
