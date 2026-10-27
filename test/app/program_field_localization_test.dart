import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/features/programs/program_intake_screen.dart';
import 'package:safe_at_home/features/programs/program_field_localization.dart';
import 'package:safe_at_home/features/requests/form_review_screen.dart';
import 'package:safe_at_home/shared/models/form_answers.dart';
import 'package:safe_at_home/shared/models/program_intake.dart';
import '../contracts/form_answers_test.dart' as forms;
import '../services/case_evidence_api_client_test.dart' as http;
import 'case_coordinator_test.dart' show FakeTransport;
import 'live_workflows_test.dart'
    show MemoryPrivateStore, services, program, input;
import 'program_localization_support.dart';

List<Map<String, dynamic>> intakeDefinitions() =>
    (jsonDecode(File('test/fixtures/program-intake-ui.json').readAsStringSync())
            as List)
        .cast<Map<String, dynamic>>();
List<Map<String, dynamic>> formDefinitions() =>
    (jsonDecode(File('test/fixtures/program-form-ui.json').readAsStringSync())
            as List)
        .cast<Map<String, dynamic>>();

void main() {
  for (final locale in programLocales) {
    String tr(String text) => programText(locale, text);
    for (final definition in intakeDefinitions()) {
      testWidgets(
        '$locale ${definition['programId']} current questions, help and inputs fit at 320px/3.2x',
        (tester) async {
          largeProgramViewport(tester);
          Map<String, Object?>? server;
          final transport = FakeTransport((request) async {
            final body = http.requestJson(request);
            if (request.endpoint.path == '/v1/create-case') {
              server = {...body, 'revision': 1};
              return http.jsonResponse(server);
            }
            expect(request.endpoint.path, '/v2/read-program-intake');
            return http.jsonResponse({
              'schemaVersion': '2',
              'caseId': server!['caseId'],
              'caseRevision': 1,
              'definition': definition,
              'saved': null,
              'isCurrent': false,
            });
          });
          final app = services(MemoryPrivateStore(), transport);
          addTearDown(() {
            app.dispose();
            app.session.dispose();
          });
          await app.coordinator.createDraft();
          await app.coordinator.save();
          await tester.pumpWidget(
            programTestApp(
              locale,
              ProgramIntakeScreen(
                services: app,
                program: program(programId: definition['programId'] as String),
              ),
            ),
          );
          await tester.pumpAndSettle();
          for (final question in definition['questions'] as List) {
            final label = tr(question['label'] as String);
            final full = find.byKey(
              ValueKey('intake-question-${question['key']}'),
            );
            await revealProgramControl(tester, full);
            expect(tester.widget<Text>(full).data, label);
            expect(tester.widget<Text>(full).maxLines, isNull);
            expect(find.text(question['label'] as String), findsNothing);
            expect(
              question['kind'] == 'boolean'
                  ? find.byKey(ValueKey('intake-choices-${question['key']}'))
                  : input(label),
              findsOneWidget,
            );
            expect(find.text(tr('About this question')), findsNothing);
            expect(tester.takeException(), isNull);
          }
          final save = find.byKey(const ValueKey('intake-save'));
          await revealProgramControl(tester, save);
          expect(save.hitTestable(), findsOneWidget);
          expect(transport.requests, hasLength(2));
        },
      );
    }

    testWidgets(
      '$locale all current administrative labels wrap and original field identifiers remain stable',
      (tester) async {
        largeProgramViewport(tester);
        final definitions = formDefinitions();
        final transport = FakeTransport((request) async {
          final body = http.requestJson(request);
          if (request.endpoint.path == '/v1/create-case') {
            return http.jsonResponse({...body, 'revision': 1});
          }
          expect(request.endpoint.path, '/v2/read-form-answers');
          return http.jsonResponse({
            ...forms.responseJson(),
            'schemaVersion': '2',
            'caseId': body['caseId'],
            'caseRevision': 1,
            'saved': null,
            'isCurrent': false,
            'fieldDefinitions': definitions,
            'artifactKind': 'official_form_draft',
          });
        });
        final app = services(MemoryPrivateStore(), transport);
        addTearDown(() {
          app.dispose();
          app.session.dispose();
        });
        await app.coordinator.createDraft();
        await app.coordinator.save();
        await tester.pumpWidget(
          programTestApp(
            locale,
            FormReviewScreen(
              services: app,
              program: program(programId: 'scfhp-eaa'),
            ),
          ),
        );
        await tester.pumpAndSettle();
        for (final definition in definitions) {
          final key = definition['key'] as String,
              label = tr(definition['label'] as String);
          final full = find.byKey(ValueKey('form-label-$key'));
          await revealProgramControl(tester, full);
          final text = tester.widget<Text>(full);
          expect(text.data, label);
          expect(text.maxLines, isNull);
          expect(
            find.ancestor(of: full, matching: find.byType(ExcludeSemantics)),
            findsOneWidget,
          );
          expect(find.byKey(ValueKey('form-field-$key')), findsOneWidget);
          expect(find.byKey(ValueKey('form-review-$key')), findsNothing);
          expect(find.text(definition['label'] as String), findsNothing);
          expect(tester.takeException(), isNull);
        }
        final save = find.byKey(const ValueKey('form-save'));
        await revealProgramControl(tester, save);
        expect(save.hitTestable(), findsOneWidget);
        expect(transport.requests, hasLength(3));
      },
    );

    testWidgets(
      '$locale altered or unknown definitions fall back exactly without translating arbitrary text',
      (tester) async {
        late BuildContext context;
        await tester.pumpWidget(
          programTestApp(
            locale,
            Builder(
              builder: (value) {
                context = value;
                return const SizedBox();
              },
            ),
          ),
        );
        await tester.pumpAndSettle();
        final original = intakeDefinitions().first;
        final known = IntakeDefinition.fromJson(original);
        expect(
          programQuestionLabel(context, known, known.questions.first),
          tr(known.questions.first.label),
        );
        for (final change in [
          'version',
          'program',
          'label',
          'description',
          'kind',
          'order',
          'extra',
        ]) {
          final json = jsonDecode(jsonEncode(original)) as Map<String, dynamic>;
          final questions = json['questions'] as List;
          switch (change) {
            case 'version':
              json['questionnaireVersion'] = forms.digest;
            case 'program':
              json['programId'] = 'future-program';
            case 'label':
              questions[0]['label'] = 'Yes';
            case 'description':
              questions[0]['description'] = 'Next action';
            case 'kind':
              questions[0]['kind'] = 'money';
            case 'order':
              json['questions'] = questions.reversed.toList();
            case 'extra':
              questions.add({
                ...questions.first as Map,
                'key': 'future-question',
              });
          }
          final altered = IntakeDefinition.fromJson(json);
          for (final q in altered.questions) {
            expect(
              programQuestionLabel(context, altered, q),
              q.label,
              reason: change,
            );
            expect(
              programQuestionDescription(context, altered, q),
              q.description,
              reason: change,
            );
          }
        }
        final field = FormAnswerFieldDefinition.fromJson(
          formDefinitions().first,
        );
        expect(
          administrativeFieldLabel(context, 'scfhp-eaa', field),
          tr(field.label),
        );
        expect(
          administrativeFieldLabel(context, 'hpsm-eaa', field),
          tr(field.label),
        );
        expect(
          administrativeFieldLabel(context, 'rtp-home-repair', field),
          tr(field.label),
        );
        expect(
          administrativeFieldLabel(context, 'future-program', field),
          field.label,
        );
        final altered = FormAnswerFieldDefinition.fromJson({
          ...field.toJson(),
          'label': 'Next action',
        });
        expect(
          administrativeFieldLabel(context, 'scfhp-eaa', altered),
          'Next action',
        );
        expect(tester.takeException(), isNull);
      },
    );
  }
}
