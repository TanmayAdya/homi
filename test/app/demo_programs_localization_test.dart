import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/features/programs/demo_programs_screen.dart';
import 'package:safe_at_home/shared/models/contracts.dart';
import 'package:safe_at_home/shared/models/draft_packet.dart';
import 'package:safe_at_home/shared/services/demo_scenario_service.dart';
import 'package:safe_at_home/shared/services/packet_preparation_service.dart';
import '../packet_widget_test.dart' as fixture;
import 'program_localization_support.dart';

class _Examples implements DemoScenarioService {
  var reads = 0;
  @override
  Future<List<DemoScenario>> loadScenarios() async {
    if (reads++ == 0) throw StateError('private error must not be displayed');
    return fixture.scenarios();
  }
}

class _Packets implements PacketPreparationService {
  var reads = 0;
  final keys = <String>[];
  @override
  bool get isSavedExample => true;
  @override
  Future<DraftPacket> prepare(
    CaseSnapshot snapshot, {
    required String programId,
    required String generationKey,
    required CaseSnapshot Function() currentCase,
  }) async {
    keys.add(generationKey);
    if (reads++ == 0) throw StateError('another private service error');
    return fixture.packets().singleWhere(
      (p) => p.caseId == snapshot.caseId && p.programId == programId,
    );
  }
}

void main() {
  for (final locale in programLocales) {
    testWidgets(
      '$locale fictional examples and checklist retry remain usable at 320px/3.2x',
      (tester) async {
        largeProgramViewport(tester);
        String tr(String text, [Map<String, Object?> args = const {}]) =>
            programText(locale, text, args);
        final examples = _Examples(), packets = _Packets();
        await tester.pumpWidget(
          programTestApp(
            locale,
            DemoProgramsScreen(service: examples, packetService: packets),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text(tr('Examples unavailable')), findsOneWidget);
        expect(find.textContaining('private error'), findsNothing);
        await revealProgramControl(tester, find.text(tr('Try again')));
        await tester.tap(find.text(tr('Try again')));
        await tester.pumpAndSettle();
        expect(find.text(tr('Choose an example')), findsOneWidget);
        for (final example in fixture.scenarios()) {
          final choice = find.byKey(ValueKey('scenario-${example.id}'));
          await revealProgramControl(tester, choice);
          await tester.tap(choice);
          await tester.pumpAndSettle();
          expect(find.text(example.title), findsOneWidget);
          expect(find.text(example.description), findsOneWidget);
          final match = example.matchResponse.matches.single;
          for (final check in match.checks) {
            expect(find.text(check.explanation), findsOneWidget);
          }
          final open = find.text(tr('View draft checklist'));
          await revealProgramControl(tester, open);
          await tester.tap(open);
          await tester.pumpAndSettle();
          if (packets.reads == 1) {
            expect(find.text(tr('Checklist unavailable')), findsOneWidget);
            expect(find.textContaining('private service error'), findsNothing);
            await revealProgramControl(tester, find.text(tr('Try again')));
            await tester.tap(find.text(tr('Try again')));
            await tester.pumpAndSettle();
            expect(packets.keys[0], packets.keys[1]);
          }
          expect(
            find.text(tr('Draft only · Nothing has been submitted.')),
            findsOneWidget,
          );
          expect(find.text(tr('Fictional saved example')), findsOneWidget);
          final packet = fixture.packets().singleWhere(
            (p) => p.caseId == example.caseSnapshot.caseId,
          );
          for (final item in packet.missingItems) {
            final content = find.text(item.description);
            await revealProgramControl(tester, content);
            expect(content, findsOneWidget);
          }
          expect(tester.takeException(), isNull);
          await tester.tap(find.byType(BackButton));
          await tester.pumpAndSettle();
        }
        expect(examples.reads, 2);
        expect(packets.reads, fixture.scenarios().length + 1);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
