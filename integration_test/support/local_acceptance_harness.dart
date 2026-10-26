import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:safe_at_home/app/live_app.dart';
import 'package:safe_at_home/app/private_content_cover.dart';
import 'package:safe_at_home/app/theme.dart';
import 'package:safe_at_home/features/assessment/dev/fictional_camera.dart';
import 'package:safe_at_home/features/assessment/domain/capture/capture_adapter.dart';
import 'package:safe_at_home/features/auth/login_screen.dart';
import 'package:safe_at_home/features/cases/case_home_screen.dart';
import 'package:safe_at_home/features/settings/account_settings_screen.dart';
import 'package:safe_at_home/l10n/app_language.dart';
import 'package:safe_at_home/l10n/app_localizations.dart';
import 'package:safe_at_home/shared/services/io_matching_transport.dart';
import 'package:safe_at_home/shared/services/local_private_store.dart';
import 'package:safe_at_home/shared/services/matching_api_client.dart';
import 'package:safe_at_home/shared/services/session_service.dart';

class LocalFixtureConfig {
  LocalFixtureConfig.fromEnvironment()
    : port =
          int.tryParse(
            const String.fromEnvironment('SAH_IOS_ACCEPTANCE_PORT'),
          ) ??
          0,
      key = const String.fromEnvironment('SAH_IOS_ACCEPTANCE_KEY'),
      runId = const String.fromEnvironment('SAH_IOS_ACCEPTANCE_RUN'),
      alice = const String.fromEnvironment('SAH_IOS_ACCEPTANCE_ALICE'),
      bob = const String.fromEnvironment('SAH_IOS_ACCEPTANCE_BOB'),
      textScale = _readTextScale(),
      language = _readLanguage() {
    final uuid = RegExp(
      r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
    );
    if (!Platform.isIOS ||
        port < 1024 ||
        port > 65535 ||
        !RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(key) ||
        ![runId, alice, bob].every(uuid.hasMatch) ||
        alice == bob) {
      throw StateError(
        'Start the isolated iOS acceptance fixture and pass its private define file.',
      );
    }
  }
  final int port;
  final String key, runId, alice, bob;
  final double? textScale;
  final AppLanguage language;
  FictionalPacketText get packetText => switch (language) {
    AppLanguage.chineseSimplified => const FictionalPacketText(
      residentName: '陈美华兀兀𠮷',
      observation: '虚构观察：门槛旁需要扶手。',
      photoLabel: '门槛需复查',
      repairRequest: '虚构申请：检查门槛及扶手，Café 12。',
    ),
    AppLanguage.chineseTraditional => const FictionalPacketText(
      residentName: '陳美華兀兀𠮷',
      observation: '虛構觀察：門檻旁需要扶手。',
      photoLabel: '門檻需複查',
      repairRequest: '虛構申請：檢查門檻及扶手，Café 12。',
    ),
    _ => const FictionalPacketText(
      residentName: 'Fictional Resident',
      observation: 'Fictional threshold needs a closer look.',
      photoLabel: 'Fictional step marker',
      repairRequest: 'Fictional threshold repair request.',
    ),
  };
  static AppLanguage _readLanguage() {
    const raw = String.fromEnvironment('SAH_IOS_LANGUAGE', defaultValue: 'en');
    final language = AppLanguage.fromCode(raw);
    if (language == AppLanguage.system) {
      throw StateError(
        'Choose an explicit supported local acceptance language.',
      );
    }
    return language;
  }

  static double? _readTextScale() {
    const raw = String.fromEnvironment('SAH_IOS_TEXT_SCALE');
    if (raw.isEmpty) return null;
    final value = double.tryParse(raw);
    if (value == null || !value.isFinite || value < 1 || value > 3.2) {
      throw StateError(
        'Local acceptance text scale must be from 1 through 3.2.',
      );
    }
    return value;
  }

  Uri get loopback => Uri(scheme: 'http', host: '127.0.0.1', port: port);
  static final logicalOrigin = Uri.parse('https://ios-acceptance.invalid');
  LiveAppConfig get app => LiveAppConfig(
    apiOrigin: logicalOrigin,
    supabaseUrl: Uri.parse('https://ios-acceptance-auth.invalid'),
    publishableKey: 'sb_publishable_fictional_ios_acceptance',
  );

  Future<Map<String, Object?>> control(
    String route,
    Map<String, Object?> body,
  ) async {
    if (!{'session', 'status'}.contains(route)) {
      throw StateError('Unknown local fixture control.');
    }
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    try {
      final request = await client.postUrl(
        loopback.resolve('/__fixture/$route'),
      );
      request.followRedirects = false;
      request.headers
        ..set(HttpHeaders.contentTypeHeader, 'application/json')
        ..set('x-fictional-fixture-key', key);
      request.add(utf8.encode(jsonEncode(body)));
      final response = await request.close().timeout(
        const Duration(seconds: 10),
      );
      if (response.statusCode != 200 || response.contentLength > 64 * 1024) {
        throw StateError('Fictional fixture request rejected.');
      }
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in response.timeout(const Duration(seconds: 10))) {
        if (bytes.length + chunk.length > 64 * 1024) {
          throw StateError('Fixture response bound exceeded.');
        }
        bytes.add(chunk);
      }
      return Map<String, Object?>.from(
        jsonDecode(utf8.decode(bytes.takeBytes())) as Map,
      );
    } finally {
      client.close(force: true);
    }
  }
}

class FictionalPacketText {
  const FictionalPacketText({
    required this.residentName,
    required this.observation,
    required this.photoLabel,
    required this.repairRequest,
  });

  final String residentName, observation, photoLabel, repairRequest;
}

class FixtureTransport implements MatchingTransport {
  FixtureTransport(this.config);
  final LocalFixtureConfig config;
  final IoMatchingTransport _io = IoMatchingTransport();
  bool offline = false;
  String? loseNextSuccessfulResponse;
  final paths = <String>[];
  final responseBodies = <String, Map<String, Object?>>{};
  final pdfs = <Uint8List>[];
  Future<void> Function(String path)? beforeRequest;
  DateTime _nextRequest = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _nextHeavy = DateTime.fromMillisecondsSinceEpoch(0);
  Future<void> _tail = Future.value();

  @override
  MatchingExchange post(MatchingHttpRequest request) {
    if (request.endpoint.origin != LocalFixtureConfig.logicalOrigin.origin ||
        request.endpoint.hasQuery ||
        request.endpoint.hasFragment ||
        !RegExp(r'^/v[12]/[a-z-]{1,48}$').hasMatch(request.endpoint.path)) {
      throw StateError('Only the fictional API can use the loopback fixture.');
    }
    var cancelled = false;
    MatchingExchange? exchange;
    final response = _tail.then((_) async {
      if (cancelled || offline) {
        throw const MatchingTransportException(
          MatchingTransportFailure.network,
        );
      }
      final path = request.endpoint.path;
      final heavy = {
        '/v1/upload-evidence',
        '/v1/delete-evidence',
        '/v1/delete-case',
        '/v2/create-draft-export',
        '/v2/download-draft-export',
        '/v1/download-evidence',
      }.contains(path);
      final due = heavy && _nextHeavy.isAfter(_nextRequest)
          ? _nextHeavy
          : _nextRequest;
      final wait = due.difference(DateTime.now());
      if (wait > Duration.zero) await Future<void>.delayed(wait);
      if (cancelled || offline) {
        throw const MatchingTransportException(
          MatchingTransportFailure.network,
        );
      }
      _nextRequest = DateTime.now().add(const Duration(milliseconds: 1100));
      if (heavy) {
        _nextHeavy = DateTime.now().add(const Duration(milliseconds: 5100));
      }
      if (paths.length >= 800) {
        throw StateError('Acceptance request budget exhausted.');
      }
      paths.add(path);
      await beforeRequest?.call(path);
      exchange = _io.post(
        MatchingHttpRequest(
          endpoint: config.loopback.resolve(path),
          bearerToken: request.bearerToken,
          body: request.body,
          maxResponseBytes: request.maxResponseBytes,
          accept: request.accept,
        ),
      );
      final result = await exchange!.response;
      if (result.statusCode == 200 && loseNextSuccessfulResponse == path) {
        loseNextSuccessfulResponse = null;
        throw const MatchingTransportException(
          MatchingTransportFailure.network,
        );
      }
      if (result.statusCode == 200) {
        if (result.contentType?.startsWith('application/pdf') == true) {
          pdfs.add(Uint8List.fromList(result.body));
        } else if (result.contentType?.startsWith('application/json') == true) {
          responseBodies[path] = Map<String, Object?>.from(
            jsonDecode(utf8.decode(result.body)) as Map,
          );
        }
      }
      return result;
    });
    _tail = response.then<void>(
      (_) {},
      onError: (Object error, StackTrace stack) {},
    );
    return MatchingExchange(
      response: response,
      cancel: () {
        cancelled = true;
        exchange?.cancel();
      },
    );
  }
}

class FixtureSession extends SessionService {
  FixtureSession(this.config);
  final LocalFixtureConfig config;
  String? _owner, _token, _account;
  int _epoch = 0;
  @override
  String? get userId => _owner;
  @override
  int get epoch => _epoch;
  @override
  bool get recoveryRequired => false;
  @override
  Future<String?> accessToken() async => _token;
  @override
  Future<void> signIn(String email, String password) => authOperation(() async {
    final account = switch (email.trim()) {
      'alice@example.invalid' => 'alice',
      'bob@example.invalid' => 'bob',
      _ => throw StateError('Fictional login only.'),
    };
    final response = await config.control('session', {
      'account': account,
      'password': password,
    });
    final expected = account == 'alice' ? config.alice : config.bob;
    if (response['userId'] != expected ||
        response['authentication'] != 'fictional_provider_only' ||
        response['accessToken'] is! String) {
      throw StateError('Unexpected fictional session.');
    }
    _owner = expected;
    _token = response['accessToken'] as String;
    _account = account;
    _epoch++;
    notifyListeners();
  });

  @override
  Future<void> reauthenticate(String password) async {
    final owner = _owner, epoch = _epoch;
    if (owner == null) throw StateError('No fixture session.');
    final response = await config.control('session', {
      'account': _account,
      'password': password,
    });
    if (_owner != owner || _epoch != epoch || response['userId'] != owner) {
      throw StateError('Fixture session changed.');
    }
    _token = response['accessToken'] as String;
  }

  @override
  Future<void> signOut() async {
    _owner = null;
    _token = null;
    _account = null;
    _epoch++;
    notifyListeners();
  }

  @override
  Future<void> requestRecovery(String email) => Future.error(
    StateError('Email delivery is not part of this local fixture.'),
  );
  @override
  Future<void> updatePassword(String password) => Future.error(
    StateError('Provider password changes are not part of this local fixture.'),
  );
}

class GeneratedCapture implements CaptureAdapter {
  final outcomes = <CaptureResult>[];
  int attempts = 0;
  @override
  Future<CaptureResult> capture(CaptureRequest request) async {
    attempts++;
    if (outcomes.isNotEmpty) return outcomes.removeAt(0);
    return CaptureSucceeded(
      await drawFictionalScene(
        request.area,
        request.view,
        width: 640,
        height: 480,
      ),
      orientationNormalized: true,
    );
  }
}

class AcceptanceHarness {
  AcceptanceHarness(this.config, {GeneratedCapture? capture})
    : session = FixtureSession(config),
      transport = FixtureTransport(config),
      capture = capture ?? GeneratedCapture() {
    AppLanguageController.instance.value = config.language;
  }
  final LocalFixtureConfig config;
  final FixtureSession session;
  final FixtureTransport transport;
  final GeneratedCapture capture;
  AppServices? services;
  Directory? directory;
  Future<AppServices> open() async {
    await session.waitForAccountCleanup();
    const channel = MethodChannel('safe_at_home/private_media');
    final root = await channel.invokeMethod<String>('privateRootDirectory');
    if (root == null || session.userId == null) {
      throw StateError('Native private storage unavailable.');
    }
    directory = Directory('$root/acceptance-${config.runId}/${session.userId}');
    await directory!.create(recursive: true);
    await channel.invokeMethod('preparePrivateDirectory', {
      'path': directory!.path,
    });
    return services = AppServices(
      config: config.app,
      session: session,
      store: LocalPrivateStore(
        directory: directory!,
        accountId: session.userId!,
        secrets: DeviceSecretStore(),
      ),
      transport: transport,
      captureAdapterFactory: (_) => capture,
    );
  }

  Future<void> close({bool clear = false}) async {
    final previous = services;
    services = null;
    if (previous == null) return;
    previous.dispose();
    if (clear) {
      await previous.store.clear();
    } else {
      await previous.store.close();
    }
  }
}

class AcceptanceHost extends StatefulWidget {
  const AcceptanceHost({
    super.key,
    required this.harness,
    this.showFixtureBanner = false,
  });
  final AcceptanceHarness harness;
  final bool showFixtureBanner;
  @override
  State<AcceptanceHost> createState() => _AcceptanceHostState();
}

class _AcceptanceHostState extends State<AcceptanceHost> {
  Future<AppServices>? opening;
  String? owner;
  @override
  void initState() {
    super.initState();
    widget.harness.session.addListener(changed);
    changed();
  }

  void changed() {
    final current = widget.harness.session.userId;
    if (current != owner) {
      owner = current;
      opening = current == null ? null : widget.harness.open();
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.harness.session.removeListener(changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: AppLanguageController.instance,
    builder: (context, _) => MaterialApp(
      key: ValueKey(widget.harness.session.epoch),
      locale: AppLanguageController.instance.value.locale,
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      localeListResolutionCallback: AppLocalizations.resolveLocales,
      builder: (context, child) {
        final covered = PrivateContentCover(
          child: widget.showFixtureBanner
              ? Banner(
                  message: 'FICTIONAL LOCAL TEST',
                  location: BannerLocation.topEnd,
                  child: child!,
                )
              : child!,
        );
        final scale = widget.harness.config.textScale;
        return scale == null
            ? covered
            : MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(scale)),
                child: covered,
              );
      },
      theme: SafeAtHomeTheme.light(),
      debugShowCheckedModeBanner: false,
      home: widget.harness.session.cleaningUp
          ? const Scaffold(body: Center(child: CircularProgressIndicator()))
          : owner == null
          ? LoginScreen(
              session: widget.harness.session,
              emailDeliveryEnabled: false,
              deletionStatusScreen: DeletionReceiptScreen(
                config: widget.harness.config.app,
                transport: widget.harness.transport,
              ),
            )
          : FutureBuilder(
              future: opening,
              builder: (context, snapshot) {
                if (snapshot.hasData) {
                  return CaseHomeScreen(services: snapshot.data!);
                }
                return Scaffold(
                  body: Center(
                    child: snapshot.hasError
                        ? const Text('Native acceptance storage failed.')
                        : const CircularProgressIndicator(),
                  ),
                );
              },
            ),
    ),
  );
}
