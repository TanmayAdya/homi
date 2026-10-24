import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart' as hashing;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'theme.dart';
import 'private_content_cover.dart';
import '../features/assessment/domain/capture/capture_adapter.dart';
import '../features/auth/login_screen.dart';
import '../features/cases/case_home_screen.dart';
import '../features/settings/account_settings_screen.dart';
import '../shared/presentation/startup_error_screen.dart';
import '../shared/services/annotated_export_api_client.dart';
import '../shared/services/evidence_annotations_api_client.dart';
import '../shared/services/case_coordinator.dart';
import '../shared/services/case_discovery_api_client.dart';
import '../shared/services/case_evidence_api_client.dart';
import '../shared/services/draft_export_api_client.dart';
import '../shared/services/form_answers_api_client.dart';
import '../shared/services/io_matching_transport.dart';
import '../shared/services/local_private_store.dart';
import '../shared/services/lifecycle_api_client.dart';
import '../shared/services/matching_api_client.dart';
import '../shared/services/packet_api_client.dart';
import '../shared/services/program_intake_api_client.dart';
import '../shared/services/request_tracking_api_client.dart';
import '../shared/services/session_service.dart';

class LiveAppConfig {
  LiveAppConfig({
    required this.apiOrigin,
    required this.supabaseUrl,
    required this.publishableKey,
    this.emailDeliveryEnabled = false,
  }) {
    for (final uri in [apiOrigin, supabaseUrl]) {
      if (uri.scheme != 'https' ||
          uri.host.isEmpty ||
          uri.userInfo.isNotEmpty ||
          uri.hasQuery ||
          uri.hasFragment ||
          (uri.path.isNotEmpty && uri.path != '/')) {
        throw const FormatException(
          'Live configuration requires HTTPS origins.',
        );
      }
    }
    if (publishableKey.isEmpty) {
      throw const FormatException('Supabase publishable key is missing.');
    }
  }
  final Uri apiOrigin, supabaseUrl;
  final String publishableKey;
  final bool emailDeliveryEnabled;
  Uri get callback => Uri.parse('safeathome://auth/callback');
  bool acceptsCallback(Uri uri) => acceptsAuthCallback(uri, callback);
  static LiveAppConfig fromEnvironment() => LiveAppConfig(
    apiOrigin: Uri.parse(const String.fromEnvironment('SAH_API_URL')),
    supabaseUrl: Uri.parse(const String.fromEnvironment('SUPABASE_URL')),
    publishableKey: const String.fromEnvironment('SUPABASE_PUBLISHABLE_KEY'),
    emailDeliveryEnabled: const bool.fromEnvironment(
      'SAH_EMAIL_DELIVERY_ENABLED',
    ),
  );
}

class AppServices {
  AppServices({
    required this.config,
    required this.session,
    required this.store,
    MatchingTransport? transport,
    this.pdfPreviewBuilder,
    this.captureAdapterFactory,
  }) : transport = transport ?? IoMatchingTransport() {
    Future<String?> token() async {
      final epoch = session.epoch;
      final value = await session.accessToken();
      if (session.epoch != epoch || session.userId != store.accountId) {
        throw MatchingApiException.forCode('UNAUTHENTICATED');
      }
      return value;
    }

    Uri endpoint(String name) => config.apiOrigin.resolve('/v1/$name');
    cases = CaseEvidenceApiClient(
      createCaseEndpoint: endpoint('create-case'),
      saveCaseEndpoint: endpoint('save-case'),
      caseEndpoint: endpoint('read-case'),
      uploadEvidenceEndpoint: endpoint('upload-evidence'),
      deleteEvidenceEndpoint: endpoint('delete-evidence'),
      tokenProvider: token,
      transport: this.transport,
    );
    discovery = CaseDiscoveryApiClient(
      listCasesEndpoint: endpoint('list-cases'),
      caseEndpoint: endpoint('read-case'),
      tokenProvider: token,
      transport: this.transport,
    );
    exports = DraftExportApiClient(
      evidenceEndpoint: endpoint('list-evidence'),
      evidenceDownloadEndpoint: endpoint('download-evidence'),
      exportEndpoint: endpoint('create-draft-export'),
      exportDownloadEndpoint: endpoint('download-draft-export'),
      tokenProvider: token,
      transport: this.transport,
    );
    lifecycle = LifecycleApiClient(
      apiBaseUrl: config.apiOrigin,
      tokenProvider: token,
      transport: this.transport,
    );
    intake = ProgramIntakeApiClient(
      baseUri: config.apiOrigin,
      tokenProvider: token,
      transport: this.transport,
    );
    annotatedExports = AnnotatedExportApiClient(
      baseUri: config.apiOrigin,
      tokenProvider: token,
      transport: this.transport,
    );
    annotations = EvidenceAnnotationsApiClient(
      baseUri: config.apiOrigin,
      tokenProvider: token,
      transport: this.transport,
    );
    matching = MatchingApiClient(
      endpoint: endpoint('match-case'),
      tokenProvider: token,
      transport: this.transport,
    );
    packets = PacketApiClient(
      endpoint: endpoint('prepare-packet'),
      tokenProvider: token,
      transport: this.transport,
    );
    answers = FormAnswersApiClient(
      protocolVersion: '2',
      readEndpoint: config.apiOrigin.resolve('/v2/read-form-answers'),
      saveEndpoint: config.apiOrigin.resolve('/v2/save-form-answers'),
      caseEndpoint: endpoint('read-case'),
      tokenProvider: token,
      transport: this.transport,
    );
    history = RequestTrackingApiClient(
      readHistoryEndpoint: endpoint('read-request-history'),
      appendUpdateEndpoint: endpoint('append-request-update'),
      tokenProvider: token,
      transport: this.transport,
    );
    coordinator = CaseCoordinator(
      session: session,
      store: store,
      cases: cases,
      discovery: discovery,
    );
  }
  final LiveAppConfig config;
  final SessionService session;
  final LocalPrivateStore store;
  final MatchingTransport transport;

  final CaptureAdapter Function(BuildContext Function() context)?
  captureAdapterFactory;

  final Widget Function(Uint8List bytes)? pdfPreviewBuilder;
  late final CaseEvidenceApiClient cases;
  late final CaseDiscoveryApiClient discovery;
  late final DraftExportApiClient exports;
  late final AnnotatedExportApiClient annotatedExports;
  late final ProgramIntakeApiClient intake;
  late final LifecycleApiClient lifecycle;
  late final EvidenceAnnotationsApiClient annotations;
  late final MatchingApiClient matching;
  late final PacketApiClient packets;
  late final FormAnswersApiClient answers;
  late final RequestTrackingApiClient history;
  late final CaseCoordinator coordinator;
  Future<void> signOut() => session.signOutAndClear(
    () async {
      try {
        await _clearPersistedAuth(config);
      } finally {
        try {
          await store.clear();
        } finally {
          await _clearTransientMedia();
        }
      }
    },
    isCurrent: () => session.userId == store.accountId && coordinator.isCurrent,
  );

  void dispose() => coordinator.dispose();
}

Future<void> _clearPersistedAuth(LiveAppConfig config) async {
  final secrets = DeviceSecretStore();
  final namespace = 'sah.auth.${config.supabaseUrl.host}';
  try {
    await SecureSessionStorage(secrets, namespace).removePersistedSession();
  } finally {
    await SecurePkceStorage(secrets, namespace).clear();
  }
}

Future<void> _clearTransientMedia() async {
  const channel = MethodChannel('safe_at_home/private_media');
  try {
    await channel.invokeMethod<void>('clearTemporaryMedia');
  } finally {
    final root = await channel.invokeMethod<String>('privateRootDirectory');
    if (root != null) {
      final shares = Directory('$root/temporary-shares');
      if (await shares.exists()) await shares.delete(recursive: true);
    }
  }
}

class LiveAppBootstrap extends StatefulWidget {
  const LiveAppBootstrap({super.key});
  @override
  State<LiveAppBootstrap> createState() => _LiveAppBootstrapState();
}

class _LiveAppBootstrapState extends State<LiveAppBootstrap> {
  late final Future<(LiveAppConfig, SessionService)> _ready = _initialize();
  Future<(LiveAppConfig, SessionService)> _initialize() async {
    final config = LiveAppConfig.fromEnvironment();
    final secrets = DeviceSecretStore();
    final namespace = 'sah.auth.${config.supabaseUrl.host}';
    const channel = MethodChannel('safe_at_home/private_media');
    final root = await channel.invokeMethod<String>('privateRootDirectory');
    if (root == null) throw StateError('Private storage unavailable.');
    await Directory(root).create(recursive: true);
    await channel.invokeMethod('preparePrivateDirectory', {'path': root});
    final marker = File('$root/installation-v1');
    if (!await marker.exists()) {
      await SecureSessionStorage(secrets, namespace).removePersistedSession();
      await SecurePkceStorage(secrets, namespace).clear();
      await marker.writeAsString('1', flush: true);
    }
    await _clearTransientMedia();
    final sessionReady = Completer<SupabaseSessionService>();
    final persistedSessionStorage = SecureSessionStorage(secrets, namespace);
    await Supabase.initialize(
      url: config.supabaseUrl.toString(),
      publishableKey: config.publishableKey,
      debug: false,
      authOptions: FlutterAuthClientOptions(
        authFlowType: AuthFlowType.pkce,
        localStorage: persistedSessionStorage,
        pkceAsyncStorage: SecurePkceStorage(secrets, namespace),
        detectSessionInUriPredicate: (uri) {
          if (config.acceptsCallback(uri)) {
            unawaited(
              sessionReady.future.then(
                (service) => service.handleCallback(uri),
              ),
            );
          }
          return false;
        },
      ),
    );
    final session = SupabaseSessionService(
      Supabase.instance.client,
      callback: config.callback,
      emailDeliveryEnabled: config.emailDeliveryEnabled,
      persistedSessionStorage: persistedSessionStorage,
      reauthenticationClient: () => GoTrueClient(
        url: '${config.supabaseUrl}/auth/v1',
        headers: {'apikey': config.publishableKey},
        autoRefreshToken: false,
      ),
    );
    sessionReady.complete(session);
    return (config, session);
  }

  @override
  Widget build(BuildContext context) => FutureBuilder(
    future: _ready,
    builder: (context, state) {
      if (state.hasData) {
        return LiveSessionHost(config: state.data!.$1, session: state.data!.$2);
      }
      return MaterialApp(
        theme: SafeAtHomeTheme.light(),
        debugShowCheckedModeBanner: false,
        home: state.hasError
            ? const StartupErrorScreen.startup()
            : const Scaffold(
                body: SafeArea(
                  child: Center(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: CircularProgressIndicator(
                        semanticsLabel: 'Opening secure session',
                      ),
                    ),
                  ),
                ),
              ),
      );
    },
  );
}

class LiveSessionHost extends StatefulWidget {
  const LiveSessionHost({
    super.key,
    required this.config,
    required this.session,
    this.transport,
  });
  final LiveAppConfig config;
  final SessionService session;
  final MatchingTransport? transport;
  @override
  State<LiveSessionHost> createState() => _LiveSessionHostState();
}

class _LiveSessionHostState extends State<LiveSessionHost> {
  String? _owner;
  int _ownerEpoch = -1, _openGeneration = 0;
  Future<AppServices>? _services;
  AppServices? _opened;
  Future<void> _cleanup = Future.value();
  bool _cleanupRecoveryPending = false;
  bool _storageExitBusy = false;
  String? _storageExitError;
  @override
  void initState() {
    super.initState();
    widget.session.addListener(_changed);
    _changed();
  }

  void _changed() {
    if (widget.session.cleanupRequired) {
      _cleanupRecoveryPending = true;
    } else if (_cleanupRecoveryPending && !widget.session.cleaningUp) {
      _cleanupRecoveryPending = false;
      _cleanup = _cleanup.catchError((Object _) => _clearTransientMedia());
      unawaited(_cleanup.catchError((Object _) {}));
    }
    final owner = widget.session.userId;
    final epoch = widget.session.epoch;
    if (owner != _owner || epoch != _ownerEpoch) {
      final departingOwner = _owner;
      _ownerEpoch = epoch;
      _openGeneration++;
      _storageExitBusy = false;
      _storageExitError = null;
      final previous = _opened;
      if (departingOwner != null) {
        _cleanup = _cleanup.then((_) async {
          try {
            await previous?.store.close();
          } finally {
            await widget.session.waitForAccountCleanup();
            await _clearTransientMedia();
          }
        });
        unawaited(_cleanup.catchError((Object _) {}));
      }
      _opened?.dispose();
      _opened = null;
      _owner = owner;
      _services = owner == null ? null : _open(owner, epoch, _openGeneration);
    }
    if (mounted) setState(() {});
  }

  Future<AppServices> _open(String owner, int epoch, int generation) async {
    bool current() =>
        mounted &&
        widget.session.userId == owner &&
        widget.session.epoch == epoch &&
        _openGeneration == generation &&
        !widget.session.cleaningUp &&
        !widget.session.cleanupRequired;
    await widget.session.waitForAccountCleanup();
    await _cleanup;
    if (!current()) throw MatchingApiException.forCode('STALE_RESPONSE');
    const channel = MethodChannel('safe_at_home/private_media');
    final root = await channel.invokeMethod<String>('privateRootDirectory');
    if (root == null) throw StateError('Private storage unavailable.');
    final directory = Directory(
      '$root/${hashing.sha256.convert(utf8.encode(owner))}',
    );
    await directory.create(recursive: true);
    await channel.invokeMethod('preparePrivateDirectory', {
      'path': directory.path,
    });
    final store = LocalPrivateStore(
      directory: directory,
      accountId: owner,
      secrets: DeviceSecretStore(),
    );
    if (!current()) {
      await store.close();
      throw MatchingApiException.forCode('STALE_RESPONSE');
    }
    return _opened = AppServices(
      config: widget.config,
      session: widget.session,
      store: store,
      transport: widget.transport,
    );
  }

  Future<void> _leaveUnavailableStorage(
    String owner,
    int epoch,
    int generation,
  ) async {
    bool current() =>
        mounted &&
        widget.session.userId == owner &&
        widget.session.epoch == epoch &&
        _owner == owner &&
        _ownerEpoch == epoch &&
        _openGeneration == generation &&
        _opened == null;
    if (_storageExitBusy || !current()) return;
    setState(() {
      _storageExitBusy = true;
      _storageExitError = null;
    });
    try {
      await widget.session.signOutAndClear(
        () => _clearPersistedAuth(widget.config),
        isCurrent: current,
      );
    } catch (_) {
      if (current()) {
        setState(() {
          _storageExitError =
              'Sign-out could not be confirmed. Try again, or unlock your phone and restart the app.';
        });
      }
    } finally {
      if (current()) setState(() => _storageExitBusy = false);
    }
  }

  Future<void> _retryCleanup(int revision) async {
    try {
      await widget.session.retryAccountCleanup(expectedRevision: revision);
    } catch (_) {
      // ignore: empty_catches
    }
  }

  Widget _cleanupRecoveryScreen() {
    final revision = widget.session.cleanupRevision;
    return StartupErrorScreen.cleanup(onRetry: () => _retryCleanup(revision));
  }

  @override
  void dispose() {
    widget.session.removeListener(_changed);
    _openGeneration++;
    if (_opened != null) unawaited(_opened!.store.close());
    _opened?.dispose();
    widget.session.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    key: ValueKey(widget.session.epoch),
    title: 'Safe at Home',
    debugShowCheckedModeBanner: false,
    builder: (context, child) => PrivateContentCover(child: child!),
    theme: SafeAtHomeTheme.light(),
    home: widget.session.cleaningUp
        ? const Scaffold(
            body: Center(
              child: CircularProgressIndicator(
                semanticsLabel: 'Finishing private account cleanup',
              ),
            ),
          )
        : widget.session.cleanupRequired
        ? _cleanupRecoveryScreen()
        : widget.session.userId == null || widget.session.recoveryRequired
        ? LoginScreen(
            session: widget.session,
            emailDeliveryEnabled: widget.config.emailDeliveryEnabled,
            deletionStatusScreen: DeletionReceiptScreen(config: widget.config),
          )
        : FutureBuilder(
            future: _services,
            builder: (context, state) {
              if (state.hasData) return CaseHomeScreen(services: state.data!);
              if (state.hasError) {
                final owner = _owner!;
                final epoch = _ownerEpoch, generation = _openGeneration;
                return StartupErrorScreen.storage(
                  onSignOut: () =>
                      _leaveUnavailableStorage(owner, epoch, generation),
                  signingOut: _storageExitBusy,
                  error: _storageExitError,
                );
              }
              return Scaffold(
                appBar: AppBar(title: const Text('Private storage')),
                body: const Center(child: CircularProgressIndicator()),
              );
            },
          ),
  );
}

String safeOperationMessage(Object error) => error is MatchingApiException
    ? error.message
    : 'This action could not be confirmed. Keep your local work and check saved state before trying again.';
Future<void> showOperationError(BuildContext context, Object error) async {
  if (!context.mounted) return;
  ScaffoldMessenger.of(
    context,
  ).showSnackBar(SnackBar(content: Text(safeOperationMessage(error))));
}
