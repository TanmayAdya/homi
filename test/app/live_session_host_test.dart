import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart' as hashing;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/app/live_app.dart';
import 'package:safe_at_home/features/auth/login_screen.dart';
import 'package:safe_at_home/features/cases/case_home_screen.dart';
import 'package:safe_at_home/shared/presentation/startup_error_screen.dart';
import '../services/case_evidence_api_client_test.dart' as http;
import 'case_coordinator_test.dart' show FakeSession, FakeTransport;

class _HostSession extends FakeSession {
  Completer<void>? logoutGate;
  bool rejectLogout = false;
  int providerLogouts = 0;

  Future<void> holdAuth(Future<void> work) => authOperation(() => work);

  void changeOwner(String value) {
    owner = value;
    generation++;
    notifyListeners();
  }

  @override
  Future<void> signOut() async {
    providerLogouts++;
    await logoutGate?.future;
    if (rejectLogout) throw StateError('Fictional secret provider detail');
    await super.signOut();
  }
}

class _PrivateHostFiles {
  final root = Directory.systemTemp.createTempSync('sah-host-scope-test-');
  bool denyPrepare = false, rejectCleanup = false;
  int clears = 0;
  final prepared = <String>[];
  final cleanupGates = <Completer<void>>[];

  String accountPath(String owner) =>
      '${root.path}/${hashing.sha256.convert(utf8.encode(owner))}';

  File retained(String owner) {
    final file = File('${accountPath(owner)}/retained-fictional.enc');
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync([91, 42, 8, 19]);
    return file;
  }

  Future<Object?> handle(MethodCall call) async {
    switch (call.method) {
      case 'privateRootDirectory':
        return root.path;
      case 'preparePrivateDirectory':
        final path = (call.arguments as Map)['path'] as String;
        prepared.add(path);
        if (denyPrepare) {
          throw PlatformException(code: 'FICTIONAL_STORAGE_LOCKED');
        }
        return path;
      case 'clearTemporaryMedia':
        final index = clears++;
        if (index < cleanupGates.length) {
          await cleanupGates[index].future;
        }
        if (rejectCleanup) {
          throw PlatformException(code: 'FICTIONAL_CLEANUP_FAILURE');
        }
        return null;
      default:
        throw StateError('Unexpected private-media method: ${call.method}');
    }
  }
}

const _feedback =
    'Sign-out could not be confirmed. Try again, or unlock your phone and restart the app.';

Future<void> _until(WidgetTester tester, bool Function() condition) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 3)),
    );
    await tester.pump(const Duration(milliseconds: 30));
    if (condition()) return;
  }
  fail('The expected local host state did not become ready.');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('safe_at_home/private_media');
  late _PrivateHostFiles files;
  late _HostSession session;
  late FakeTransport transport;
  var scenario = 0;
  late String authHost;

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    authHost = 'fictional-host-${++scenario}.supabase.co';
    files = _PrivateHostFiles();
    session = _HostSession();
    transport = FakeTransport((request) async {
      expect(request.endpoint.path, '/v1/list-cases');
      return http.jsonResponse({
        'schemaVersion': '1',
        'cases': [],
        'nextAfterCaseId': null,
      });
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, files.handle);
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    if (files.root.existsSync()) files.root.deleteSync(recursive: true);
  });

  Future<void> open(WidgetTester tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(
      LiveSessionHost(
        config: LiveAppConfig(
          apiOrigin: Uri.parse('https://example.org'),
          supabaseUrl: Uri.parse('https://$authHost'),
          publishableKey: 'fictional',
        ),
        session: session,
        transport: transport,
      ),
    );
    await _until(
      tester,
      () => find
          .byType(files.denyPrepare ? StartupErrorScreen : CaseHomeScreen)
          .evaluate()
          .isNotEmpty,
    );
  }

  Future<void> exit(WidgetTester tester) async {
    final button = find.byKey(const ValueKey('startup-sign-out'));
    await tester.ensureVisible(button);
    await tester.pumpAndSettle();
    await tester.tap(button);
    await tester.pump();
  }

  testWidgets('failed unavailable-storage exit survives its cleanup spinner', (
    tester,
  ) async {
    files.denyPrepare = true;
    final retained = files.retained(session.userId!);
    session.logoutGate = Completer<void>();
    session.rejectLogout = true;
    await open(tester);
    expect(
      find.textContaining('Encrypted drafts will remain on this device'),
      findsOneWidget,
    );
    final action = tester
        .widget<OutlinedButton>(find.byKey(const ValueKey('startup-sign-out')))
        .onPressed!;
    action();
    action();
    await _until(tester, () => session.providerLogouts == 1);
    expect(session.cleaningUp, true);
    expect(find.byType(StartupErrorScreen), findsNothing);
    session.logoutGate!.complete();
    await _until(tester, () => find.text(_feedback).evaluate().isNotEmpty);
    await tester.pumpAndSettle();
    expect(session.providerLogouts, 1);
    expect(session.userId, 'fictional-owner');
    expect(find.textContaining('secret provider detail'), findsNothing);
    expect(
      tester
          .widget<OutlinedButton>(
            find.byKey(const ValueKey('startup-sign-out')),
          )
          .onPressed,
      isNotNull,
    );
    expect(retained.readAsBytesSync(), [91, 42, 8, 19]);
    expect(transport.requests, isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('unavailable-storage exit retains ciphertext and clears shares', (
    tester,
  ) async {
    files.denyPrepare = true;
    final retained = files.retained(session.userId!);
    final share = File('${files.root.path}/temporary-shares/fictional.pdf');
    share.parent.createSync(recursive: true);
    share.writeAsStringSync('Fictional temporary plaintext');
    await open(tester);
    await exit(tester);
    await _until(
      tester,
      () =>
          find.byType(LoginScreen).evaluate().isNotEmpty &&
          files.clears == 1 &&
          !share.existsSync(),
    );
    expect(session.providerLogouts, 1);
    expect(session.userId, isNull);
    expect(retained.readAsBytesSync(), [91, 42, 8, 19]);
    expect(transport.requests, isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('queued stale storage exit cannot sign out a replacement owner', (
    tester,
  ) async {
    files.denyPrepare = true;
    final authGate = Completer<void>();
    final queued = session.holdAuth(authGate.future);
    await open(tester);
    await exit(tester);
    expect(session.cleaningUp, true);
    session.changeOwner('replacement-fictional-owner');
    authGate.complete();
    await queued;
    await _until(
      tester,
      () =>
          find.byType(StartupErrorScreen).evaluate().isNotEmpty &&
          files.prepared.contains(
            files.accountPath('replacement-fictional-owner'),
          ),
    );
    expect(session.providerLogouts, 0);
    expect(session.userId, 'replacement-fictional-owner');
    expect(find.text(_feedback), findsNothing);
    expect(transport.requests, isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'departed-owner transient cleanup blocks every replacement open',
    (tester) async {
      final retained = files.retained(session.userId!);
      final first = Completer<void>(), second = Completer<void>();
      files.cleanupGates.addAll([first, second]);
      await open(tester);
      final initialPrepared = files.prepared.single;
      session.changeOwner('middle-fictional-owner');
      await _until(tester, () => files.clears == 1);
      session.changeOwner('latest-fictional-owner');
      await tester.pump();
      expect(files.prepared, [initialPrepared]);
      expect(find.byType(CaseHomeScreen), findsNothing);
      first.complete();
      await _until(tester, () => files.clears == 2);
      expect(files.prepared, [initialPrepared]);
      second.complete();
      await _until(
        tester,
        () =>
            find.byType(CaseHomeScreen).evaluate().isNotEmpty &&
            files.prepared.length == 2,
      );
      expect(files.prepared.last, files.accountPath('latest-fictional-owner'));
      expect(
        files.prepared,
        isNot(contains(files.accountPath('middle-fictional-owner'))),
      );
      expect(retained.readAsBytesSync(), [91, 42, 8, 19]);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('failed transient cleanup keeps the replacement account closed', (
    tester,
  ) async {
    final retained = files.retained(session.userId!);
    await open(tester);
    final initialPrepared = files.prepared.single;
    files.rejectCleanup = true;
    session.changeOwner('replacement-fictional-owner');
    await _until(
      tester,
      () => find.byType(StartupErrorScreen).evaluate().isNotEmpty,
    );
    expect(files.clears, 1);
    expect(files.prepared, [initialPrepared]);
    expect(find.byType(CaseHomeScreen), findsNothing);
    expect(retained.readAsBytesSync(), [91, 42, 8, 19]);
    expect(find.textContaining('FICTIONAL_CLEANUP_FAILURE'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('host cleanup waits for an existing explicit account cleanup', (
    tester,
  ) async {
    await open(tester);
    final accountCleanup = Completer<void>();
    final logout = session.signOutAndClear(() => accountCleanup.future);
    await _until(tester, () => session.userId == null);
    expect(files.clears, 0);
    expect(session.cleaningUp, true);
    accountCleanup.complete();
    await logout;
    await _until(tester, () => files.clears == 1);
    expect(session.cleaningUp, false);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
