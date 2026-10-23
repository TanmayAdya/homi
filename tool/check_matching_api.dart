import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:safe_at_home/shared/models/contracts.dart';
import 'package:safe_at_home/shared/services/io_matching_transport.dart';
import 'package:safe_at_home/shared/services/matching_api_client.dart';
import 'package:safe_at_home/shared/services/packet_api_client.dart';

Future<void> main(List<String> arguments) async {
  if (arguments.isNotEmpty &&
      (arguments.length != 2 || arguments.first != '--backend')) {
    stderr.writeln(
      'Usage: dart run tool/check_matching_api.dart [--backend PATH]',
    );
    exitCode = 1;
    return;
  }
  final backend = Directory(
    arguments.isEmpty ? 'backend' : arguments[1],
  ).absolute;
  final serverFile = File('${backend.path}/src/api/demo-server.ts');
  final fixtures = File('contracts/v1/fixtures/scenarios.json').absolute;
  if (!serverFile.existsSync() || !fixtures.existsSync()) {
    stderr.writeln(
      'Run from the Flutter root and provide the backend directory with --backend if it is in another worktree.',
    );
    exitCode = 1;
    return;
  }

  Process? process;
  StreamSubscription<String>? output;
  StreamSubscription<List<int>>? errors;
  try {
    process = await Process.start('node', [
      serverFile.path,
      '--fixtures',
      fixtures.path,
      '--port',
      '0',
      '--machine',
    ], workingDirectory: backend.path);
    final ready = Completer<Map<String, dynamic>>();
    output = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          (line) {
            try {
              final message = jsonDecode(line);
              if (message is Map<String, dynamic> &&
                  message['type'] == 'demo-ready' &&
                  !ready.isCompleted) {
                ready.complete(message);
              }
            } catch (_) {
              if (!ready.isCompleted) {
                ready.completeError(
                  StateError('Invalid local server startup response.'),
                );
              }
            }
          },
          onDone: () {
            if (!ready.isCompleted) {
              ready.completeError(
                StateError('Local server exited before it was ready.'),
              );
            }
          },
        );
    errors = process.stderr.listen((_) {});
    final configuration = await ready.future.timeout(
      const Duration(seconds: 10),
    );
    final endpoint = Uri.parse(configuration['endpoint'] as String);
    MatchingApiClient client(String token) => MatchingApiClient(
      endpoint: endpoint,
      tokenProvider: () async => token,
      transport: IoMatchingTransport(),
      allowInsecureLoopback: true,
    );
    final alice = client(configuration['alice'] as String);
    final bob = client(configuration['bob'] as String);
    final scenarios =
        jsonDecode(await fixtures.readAsString()) as List<dynamic>;
    for (final scenario in scenarios) {
      final snapshot = CaseSnapshot.fromJson(scenario['case']);
      final actual = await alice.matchCase(
        snapshot,
        currentCase: () => snapshot,
      );
      final expected = MatchResponse.fromJson(scenario['match']);
      require(
        actual.caseId == snapshot.caseId &&
            actual.caseRevision == snapshot.revision,
        'Result identity changed.',
      );
      require(
        actual.matches.single.status == expected.matches.single.status,
        'Scenario ${scenario['id']} has a different result.',
      );
      require(
        actual.matches.every((match) => match.isDemo),
        'Local API must only return fictional routes.',
      );
      require(
        actual.isFreshFor(snapshot, now: DateTime.now().toUtc()),
        'Local demo response is unexpectedly stale.',
      );
    }
    stdout.writeln(
      'PASS: all 3 shared cases travel through the Dart client and HTTP matcher.',
    );

    final caseJson = Map<String, dynamic>.from(scenarios.first['case'] as Map);
    final snapshot = CaseSnapshot.fromJson(caseJson);
    await expectCode(
      () => bob.matchCase(snapshot, currentCase: () => snapshot),
      'CASE_NOT_FOUND',
    );
    final bobSnapshot = CaseSnapshot.fromJson({
      ...caseJson,
      'caseId': configuration['caseIds']['bob'],
    });
    await bob.matchCase(bobSnapshot, currentCase: () => bobSnapshot);
    stdout.writeln(
      'PASS: each session can match its own case; cross-user access is denied.',
    );

    await expectCode(
      () => client(
        'invalid-demo-token',
      ).matchCase(snapshot, currentCase: () => snapshot),
      'UNAUTHENTICATED',
    );
    final newer = CaseSnapshot.fromJson({
      ...caseJson,
      'revision': snapshot.revision + 1,
    });
    await expectCode(
      () => alice.matchCase(newer, currentCase: () => newer),
      'CASE_REVISION_MISMATCH',
    );
    var reads = 0;
    await expectCode(
      () => alice.matchCase(
        snapshot,
        currentCase: () => ++reads == 1 ? snapshot : newer,
      ),
      'STALE_RESPONSE',
    );
    stdout.writeln(
      'PASS: invalid tokens, stale saved revisions and late responses are rejected.',
    );

    final packetEndpoint = Uri.parse(configuration['packetEndpoint'] as String);
    PacketApiClient packetClient(String token) => PacketApiClient(
      endpoint: packetEndpoint,
      tokenProvider: () async => token,
      transport: IoMatchingTransport(),
      allowInsecureLoopback: true,
    );
    final alicePackets = packetClient(configuration['alice'] as String);
    final bobPackets = packetClient(configuration['bob'] as String);
    for (final scenario in scenarios) {
      final input = CaseSnapshot.fromJson(scenario['case']);
      final programId = MatchResponse.fromJson(
        scenario['match'],
      ).matches.single.programId;
      final key = 'smoke-${scenario['id']}';
      final packet = await alicePackets.preparePacket(
        input,
        programId: programId,
        generationKey: key,
        currentCase: () => input,
      );
      final retry = await alicePackets.preparePacket(
        input,
        programId: programId,
        generationKey: key,
        currentCase: () => input,
      );
      require(
        packet.packetId == retry.packetId &&
            packet.generatedAt == retry.generatedAt,
        'Retry created a different packet.',
      );
      require(
        packet.caseId == input.caseId &&
            packet.caseRevision == input.revision &&
            packet.programId == programId &&
            packet.status == 'draft' &&
            packet.isDemo,
        'Draft identity or state changed.',
      );
      require(
        packet.formVersion == null &&
            packet.mappingVersion == null &&
            packet.storageReference == null &&
            packet.attachments.isEmpty,
        'Unverified forms or evidence must not be fabricated.',
      );
      require(
        packet.missingItems.any((item) => item.id == 'official-form'),
        'Unverified official form must stay on the checklist.',
      );
      require(
        packet.isFreshFor(
          input,
          programId: programId,
          ruleVersion: MatchResponse.fromJson(
            scenario['match'],
          ).matches.single.ruleVersion,
          formVersion: null,
          mappingVersion: null,
          now: DateTime.now().toUtc(),
        ),
        'The live demo draft is unexpectedly stale.',
      );
      if (scenario['id'] == 'unknown') {
        require(
          packet.missingItems.any(
            (item) => item.id == 'check:plan' && item.resolvedBy == 'resident',
          ),
          'Missing plan confirmation lost its next step.',
        );
      }
    }
    const programId = 'demo-home-support';
    await expectCode(
      () => bobPackets.preparePacket(
        snapshot,
        programId: programId,
        generationKey: 'smoke-matched',
        currentCase: () => snapshot,
      ),
      'CASE_NOT_FOUND',
    );
    final bobDraft = await bobPackets.preparePacket(
      bobSnapshot,
      programId: programId,
      generationKey: 'smoke-matched',
      currentCase: () => bobSnapshot,
    );
    require(
      bobDraft.caseId == bobSnapshot.caseId,
      'Another user received the wrong draft.',
    );
    await expectCode(
      () => packetClient('invalid-demo-token').preparePacket(
        snapshot,
        programId: programId,
        generationKey: 'smoke-auth',
        currentCase: () => snapshot,
      ),
      'UNAUTHENTICATED',
    );
    await expectCode(
      () => alicePackets.preparePacket(
        newer,
        programId: programId,
        generationKey: 'smoke-revision',
        currentCase: () => newer,
      ),
      'CASE_REVISION_MISMATCH',
    );
    await expectCode(
      () => alicePackets.preparePacket(
        snapshot,
        programId: 'missing-program',
        generationKey: 'smoke-missing',
        currentCase: () => snapshot,
      ),
      'PROGRAM_NOT_FOUND',
    );
    reads = 0;
    await expectCode(
      () => alicePackets.preparePacket(
        snapshot,
        programId: programId,
        generationKey: 'smoke-late',
        currentCase: () => ++reads == 1 ? snapshot : newer,
      ),
      'STALE_RESPONSE',
    );
    stdout.writeln(
      'PASS: all 3 cases return draft checklists with stable retry IDs and unresolved official forms.',
    );
    stdout.writeln(
      'PASS: draft authorization, invalid sessions, missing programs, revision mismatches and late responses.',
    );
  } catch (_) {
    stderr.writeln(
      'Matching/packet API integration check failed. Run the backend and Dart tests for diagnostics; no credentials are logged here.',
    );
    exitCode = 1;
  } finally {
    if (process != null) {
      process.kill(ProcessSignal.sigterm);
      try {
        await process.exitCode.timeout(const Duration(seconds: 5));
      } on TimeoutException {
        process.kill(ProcessSignal.sigkill);
        await process.exitCode;
      }
    }
    await output?.cancel();
    await errors?.cancel();
  }
}

void require(bool condition, String message) {
  if (!condition) throw StateError(message);
}

Future<void> expectCode(
  Future<Object?> Function() operation,
  String code,
) async {
  try {
    await operation();
  } on MatchingApiException catch (error) {
    require(error.code == code, 'Unexpected safe API error code.');
    return;
  }
  throw StateError('Expected the request to be rejected.');
}
