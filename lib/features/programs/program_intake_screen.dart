import 'dart:async';
import 'dart:convert';
import 'program_field_localization.dart';
import 'package:flutter/material.dart';
import 'package:safe_at_home/l10n/app_localizations.dart';
import '../../app/live_app.dart';
import '../../shared/models/contracts.dart';
import '../../shared/models/program_intake.dart';
import '../../shared/presentation/sah_components.dart';
import '../../shared/presentation/draft_exit_guard.dart';
import '../../shared/services/draft_save_tracker.dart';
import '../../shared/services/matching_api_client.dart';
import '../requests/application_workspace_screen.dart';

class ProgramIntakeScreen extends StatefulWidget {
  const ProgramIntakeScreen({
    super.key,
    required this.services,
    required this.program,
    this.onNext,
  });
  final AppServices services;
  final ProgramMatch program;

  final VoidCallback? onNext;
  @override
  State<ProgramIntakeScreen> createState() => _ProgramIntakeScreenState();
}

class _ProgramIntakeScreenState extends State<ProgramIntakeScreen> {
  final _form = GlobalKey<FormState>();
  final _text = <String, TextEditingController>{};
  final _fieldAnchors = <String, GlobalKey>{};
  final _fieldFocus = <String, FocusNode>{};
  final _errors = <String, String>{};
  int _validationAttempt = 0;
  bool _feedbackAtAction = false;
  final _booleans = <String, bool?>{};
  final _notSure = <String>{};
  final _unmappedAnswers = <String, Object?>{};
  ProgramIntakeResponse? _response;
  Map<String, Object?>? _restoredDraft;
  bool _busy = true, _uncertain = false, _restoring = true;
  String? _notice;
  late final String _caseId;
  late final int _generation;
  late final DraftSaveTracker _draftSaves;
  bool _leaving = false;
  bool _justSaved = false;
  bool _onlineContext = false;
  String get _key => 'intake.$_caseId.${widget.program.programId}';
  @override
  void initState() {
    super.initState();
    _caseId = widget.services.coordinator.currentCase().caseId;
    _generation = widget.services.coordinator.generation;
    _draftSaves = DraftSaveTracker(isCurrent: () => _scopeCurrent);
    _read(initial: true);
  }

  @override
  void dispose() {
    _draftSaves.dispose();
    for (final controller in _text.values) {
      controller.dispose();
    }
    for (final focus in _fieldFocus.values) {
      focus.dispose();
    }
    super.dispose();
  }

  bool get _scopeCurrent {
    final c = widget.services.coordinator;
    return mounted &&
        c.isCurrent &&
        c.generation == _generation &&
        c.snapshot?.caseId == _caseId &&
        !c.hasUnsavedChanges;
  }

  bool _current(int revision) =>
      _scopeCurrent &&
      widget.services.coordinator.snapshot?.revision == revision;

  CaseSnapshot _screenCase({int? revision}) {
    final snapshot = widget.services.coordinator.snapshot;
    if (snapshot == null || !_current(revision ?? snapshot.revision)) {
      throw MatchingApiException.forCode('STALE_RESPONSE');
    }
    return snapshot;
  }

  Map<String, Object?> _raw() => {
    'values': {for (final entry in _text.entries) entry.key: entry.value.text},
    'booleans': Map<String, bool?>.of(_booleans),
    'notSure': [
      for (final key in _notSure)
        if (_booleans[key] == null) key,
    ],
    'uncertain': _uncertain,
    'questionnaireVersion': _response?.definition.questionnaireVersion,
    'caseRevision': _response?.caseRevision,
    'response': _response?.toJson(),
    'unmappedAnswers': Map<String, Object?>.of(_unmappedAnswers),
  };
  Future<void> _persist() async {
    _screenCase();
    final value = _raw();
    if (!_onlineContext) _restoredDraft = value;
    await _draftSaves.track(() => widget.services.store.writeJson(_key, value));
  }

  void _stash() {
    if (_leaving ||
        _restoring ||
        !_scopeCurrent ||
        (_onlineContext && !_current(_response?.caseRevision ?? -1))) {
      return;
    }
    if ((_feedbackAtAction && _notice != null) || _justSaved) {
      setState(() {
        _notice = null;
        _justSaved = false;
      });
    }
    unawaited(
      _persist().catchError((Object _) {
        if (mounted) {
          setState(
            () => _notice =
                'Unfinished answers could not be saved on this device. Keep this screen open and retry.',
          );
        }
      }),
    );
  }

  List<IntakeAnswer> _answers() => [
    for (final q in _response!.definition.questions)
      IntakeAnswer.fromJson({
        'key': q.key,
        'value': _value(q),
        'reviewState': _value(q) == null ? 'unknown' : 'reported',
      }, _response!.definition),
  ];
  Object? _value(IntakeQuestion q) {
    if (q.kind == 'boolean') return _booleans[q.key];
    final value = _text[q.key]!.text.trim();
    return value.isEmpty
        ? null
        : q.kind == 'money'
        ? num.parse(value)
        : value;
  }

  void _restoreCached(Map<String, Object?> local) {
    final raw = local['response'];
    if (raw == null) return;
    final response = ProgramIntakeResponse.fromJson(raw);
    if (response.caseId != _caseId ||
        response.definition.programId != widget.program.programId ||
        response.caseRevision > _screenCase().revision) {
      throw const FormatException('Private questions do not match this plan.');
    }
    final values = local['values'] as Map;
    final booleans = local['booleans'] as Map;
    for (final q in response.definition.questions) {
      final value = q.kind == 'boolean' ? booleans[q.key] : values[q.key];
      if (q.kind == 'boolean') {
        if (value != null && value is! bool) throw const FormatException();
        _booleans[q.key] = value as bool?;
      } else {
        if (value != null && value is! String) throw const FormatException();
        _text.putIfAbsent(q.key, () => TextEditingController()).text =
            value as String? ?? '';
        _fieldAnchors.putIfAbsent(q.key, () => GlobalKey());
        _fieldFocus.putIfAbsent(q.key, () => FocusNode());
      }
    }
    _response = response;
  }

  Future<void> _read({bool initial = false}) async {
    if (_leaving) return;
    setState(() {
      _busy = true;
      _feedbackAtAction = false;
      _onlineContext = false;
    });
    try {
      final opening = _screenCase();
      if (initial) _restoredDraft = await widget.services.store.readJson(_key);
      _screenCase(revision: opening.revision);
      final local = _restoredDraft;
      if (local != null) {
        if (initial) _restoreCached(local);
        if (local['unmappedAnswers'] is Map) {
          _unmappedAnswers.addAll(
            Map<String, Object?>.from(local['unmappedAnswers'] as Map),
          );
        }
        _uncertain = local['uncertain'] == true;
        final notSure = local['notSure'];
        if (notSure is List) _notSure.addAll(notSure.whereType<String>());
      }
      final c = widget.services.coordinator;
      if (!initial || _uncertain) {
        final remote = await widget.services.answers.reloadCase(
          _caseId,
          currentCase: () => _screenCase(revision: opening.revision),
        );
        await c.adoptRemoteSnapshot(remote);
        _screenCase(revision: remote.revision);
      }
      final snapshot = _screenCase();
      final response = await widget.services.intake.readIntake(
        snapshot,
        programId: widget.program.programId,
        isCurrent: () => _current(snapshot.revision),
      );
      if (!_current(snapshot.revision)) return;
      final previous = _response;
      final changed =
          previous != null &&
          previous.definition.questionnaireVersion !=
              response.definition.questionnaireVersion;
      final restored = local ?? (changed ? _raw() : null);
      _response = response;
      _onlineContext = true;
      _errors.clear();
      for (final q in response.definition.questions) {
        if (q.kind != 'boolean') {
          _text.putIfAbsent(q.key, () => TextEditingController());
          _fieldAnchors.putIfAbsent(q.key, () => GlobalKey());
          _fieldFocus.putIfAbsent(q.key, () => FocusNode());
        }
      }
      if (initial || previous == null || changed) {
        final saved = {
          for (final answer in response.saved?.answers ?? <IntakeAnswer>[])
            answer.key: answer.value,
        };
        for (final question in response.definition.questions) {
          if (question.kind != 'boolean') {
            _text[question.key]!.text = saved[question.key]?.toString() ?? '';
          } else {
            _booleans[question.key] = saved[question.key] as bool?;
          }
        }
        if (restored != null) {
          final values = restored['values'] as Map;
          final booleans = restored['booleans'] as Map;
          final sameVersion =
              restored['questionnaireVersion'] ==
              response.definition.questionnaireVersion;
          final oldQuestions =
              previous?.definition.questions ??
              (sameVersion
                  ? response.definition.questions
                  : <IntakeQuestion>[]);
          final oldKinds = {
            for (final question in oldQuestions) question.key: question.kind,
          };
          final newKinds = {
            for (final question in response.definition.questions)
              question.key: question.kind,
          };
          for (final key in {...values.keys, ...booleans.keys}) {
            final kind = oldKinds[key];
            final source =
                kind == 'boolean' || (kind == null && !values.containsKey(key))
                ? booleans
                : values;
            if (!source.containsKey(key)) continue;
            if (kind == null || newKinds[key] != kind) {
              _unmappedAnswers['${restored['questionnaireVersion']}:$key'] = {
                'key': key,
                'kind': kind ?? 'unknown',
                'value': source[key],
              };
            }
          }
          for (final question in response.definition.questions) {
            if (oldKinds[question.key] != question.kind) continue;
            if (question.kind == 'boolean') {
              if (booleans.containsKey(question.key)) {
                _booleans[question.key] = booleans[question.key] as bool?;
              }
            } else if (values.containsKey(question.key)) {
              _text[question.key]!.text = values[question.key] as String? ?? '';
            }
          }
          _notice = sameVersion
              ? 'Recovered unfinished answers. Review them before saving.'
              : 'The questionnaire changed. Review all questions before saving.';
        }
      }
      _restoredDraft = null;
      if (_uncertain || !initial) {
        var same = false;
        try {
          final saved = {
            for (final a in response.saved?.answers ?? <IntakeAnswer>[])
              a.key: a.toJson(),
          };
          same = _answers().every(
            (a) => jsonEncode(a.toJson()) == jsonEncode(saved[a.key]),
          );
        } catch (_) {
          // ignore: empty_catches
        }
        _uncertain = false;
        _notice = !response.isCurrent && response.saved != null
            ? 'Saved answers are from an earlier case version. Your values remain below; review them before saving again.'
            : same && response.isCurrent
            ? 'The submitted answers are confirmed saved.'
            : 'Saved state reloaded. Compare the saved answers below with your local entries before another explicit save.';
        if (previous != null &&
            previous.definition.questionnaireVersion !=
                response.definition.questionnaireVersion) {
          _notice =
              'The questionnaire changed. Review all questions before saving.';
        }
      }
      await _persist();
    } catch (error) {
      if (mounted) _notice = safeOperationMessage(error);
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _restoring = false;
        });
      }
    }
  }

  String? _validateQuestion(IntakeQuestion question) {
    try {
      final value = _value(question);
      IntakeAnswer.fromJson({
        'key': question.key,
        'value': value,
        'reviewState': value == null ? 'unknown' : 'reported',
      }, _response!.definition);
      return null;
    } catch (_) {
      return question.kind == 'money'
          ? 'Enter a nonnegative amount with at most two decimal places, or leave blank.'
          : 'Check this answer or leave it blank.';
    }
  }

  void _reviewInvalid() {
    if (_busy || _uncertain || _errors.isEmpty) return;
    final key = _errors.keys.first;
    _fieldFocus[key]?.requestFocus();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _busy || _uncertain) return;
      final target = _fieldAnchors[key]?.currentContext;
      if (target != null) {
        Scrollable.ensureVisible(target, alignment: 0.1);
      }
    });
  }

  Future<void> _save() async {
    if (_leaving ||
        !_onlineContext ||
        _busy ||
        _uncertain ||
        _response == null) {
      return;
    }
    final errors = <String, String>{};
    for (final question in _response!.definition.questions) {
      final error = _validateQuestion(question);
      if (error != null) errors[question.key] = error;
    }
    setState(() {
      _validationAttempt++;
      _errors
        ..clear()
        ..addAll(errors);
      _feedbackAtAction = true;
      _notice = null;
    });
    if (errors.isNotEmpty) return;
    setState(() => _busy = true);
    try {
      final c = widget.services.coordinator;
      final saved = _screenCase(revision: _response!.caseRevision);
      final definition = _response!.definition;
      final expectedIntakeRevision = _response!.saved?.intakeRevision ?? 0;
      final answers = _answers();
      _uncertain = true;
      await _persist();
      _screenCase(revision: saved.revision);
      await c.serialize(() async {
        _screenCase(revision: saved.revision);
        final response = await widget.services.intake.saveIntake(
          saved,
          definition: definition,
          expectedIntakeRevision: expectedIntakeRevision,
          answers: answers,
          isCurrent: () => _current(saved.revision),
        );
        await c.adoptRemoteSnapshot(
          CaseSnapshot.fromJson({
            ...saved.toJson(),
            'revision': response.caseRevision,
          }),
        );
        _screenCase(revision: response.caseRevision);
        _response = response;
        _uncertain = false;
        await _persist();
      });
      if (mounted) {
        _notice = 'Answers saved. Program checks update on their own.';
        _justSaved = true;
      }
    } catch (error) {
      if (mounted) _notice = safeOperationMessage(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => DraftExitGuard(
    tracker: _draftSaves,
    builder: (context, requestExit, exiting) {
      _leaving = exiting;
      return SahKeyboardDismissal(
        child: Scaffold(
          appBar: AppBar(
            leading: BackButton(onPressed: requestExit),
            title: Text(context.tr('Program questions')),
          ),
          body: SafeArea(
            child: Form(
              key: _form,
              child: SahContent(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SahPageHeader(
                        title: programShortName(widget.program),
                        description: _response == null
                            ? null
                            : context.tr('{answered} of {total} answered', {
                                'answered': _response!.definition.questions
                                    .where(
                                      (q) =>
                                          _value(q) != null ||
                                          _notSure.contains(q.key),
                                    )
                                    .length,
                                'total': _response!.definition.questions.length,
                              }),
                      ),
                      if (!_onlineContext && _response != null)
                        SahNotice(
                          key: const ValueKey('intake-offline-context'),
                          message: context.tr(
                            'These answers are kept on this device. Reconnect and reload before saving online.',
                          ),
                        ),
                      if (Localizations.localeOf(context).languageCode != 'en')
                        SahNotice(
                          message: context.tr(
                            'Program information and official forms may remain in English. Your saved answers are not translated.',
                          ),
                        ),

                      if (_busy)
                        Padding(
                          padding: EdgeInsets.symmetric(vertical: 12),
                          child: LinearProgressIndicator(
                            semanticsLabel: context.tr(
                              'Updating program answers',
                            ),
                          ),
                        ),
                      if (_notice != null && !_feedbackAtAction) _noticeBody(),
                      if (_uncertain)
                        SahNotice(
                          title: context.tr('Check the last save'),
                          message: context.tr(
                            'A save may already have succeeded. Check saved answers before another save.',
                          ),
                          tone: SahNoticeTone.warning,
                        ),
                      if (_needsReconcile) ...[
                        const SizedBox(height: 8),
                        TextButton(
                          key: const ValueKey('intake-reconcile'),
                          onPressed: _busy || exiting ? null : () => _read(),
                          child: Text(
                            context.tr('Check saved answers and reconcile'),
                            textAlign: TextAlign.center,
                          ),
                        ),
                        if (_response?.saved != null)
                          ExpansionTile(
                            title: Text(context.tr('Compare saved answers')),
                            children: [
                              for (final q in _response!.definition.questions)
                                ListTile(
                                  title: Text(
                                    programQuestionLabel(
                                      context,
                                      _response!.definition,
                                      q,
                                    ),
                                  ),
                                  subtitle: Text(_savedLabel(q.key)),
                                ),
                            ],
                          ),
                      ],
                      if (_response != null)
                        SahSectionHeading(
                          title: context.tr('Reported answers'),
                          description: context.tr(
                            'Answer what you know. “Not sure” leaves it for the program to confirm.',
                          ),
                        ),
                      for (final q
                          in _response?.definition.questions ??
                              <IntakeQuestion>[])
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Semantics(
                                header: true,
                                child: Text(
                                  programQuestionLabel(
                                    context,
                                    _response!.definition,
                                    q,
                                  ),
                                  key: ValueKey('intake-question-${q.key}'),
                                  style: Theme.of(
                                    context,
                                  ).textTheme.titleMedium,
                                ),
                              ),
                              const SizedBox(height: 8),
                              if (q.kind == 'boolean')
                                RadioGroup<String>(
                                  key: ValueKey('intake-choices-${q.key}'),
                                  groupValue: switch (_booleans[q.key]) {
                                    true => 'true',
                                    false => 'false',
                                    null =>
                                      _notSure.contains(q.key)
                                          ? 'notSure'
                                          : null,
                                  },
                                  onChanged: (v) {
                                    if (v == null ||
                                        _leaving ||
                                        _busy ||
                                        _uncertain ||
                                        exiting) {
                                      return;
                                    }
                                    setState(() {
                                      _booleans[q.key] = v == 'notSure'
                                          ? null
                                          : v == 'true';
                                      if (v == 'notSure') {
                                        _notSure.add(q.key);
                                      } else {
                                        _notSure.remove(q.key);
                                      }
                                    });
                                    _stash();
                                  },
                                  child: Column(
                                    children: [
                                      for (final (value, label) in const [
                                        ('true', 'Yes'),
                                        ('false', 'No'),
                                        ('notSure', 'Not sure'),
                                      ])
                                        RadioListTile<String>(
                                          key: ValueKey('${q.key}-$value'),
                                          value: value,
                                          enabled:
                                              !_busy && !_uncertain && !exiting,
                                          contentPadding: EdgeInsets.zero,
                                          title: Text(context.tr(label)),
                                        ),
                                    ],
                                  ),
                                )
                              else
                                MergeSemantics(
                                  child: Semantics(
                                    label: programQuestionLabel(
                                      context,
                                      _response!.definition,
                                      q,
                                    ),
                                    child: TextFormField(
                                      key: _fieldAnchors[q.key],
                                      controller: _text[q.key],
                                      focusNode: _fieldFocus[q.key],
                                      forceErrorText: _errors[q.key] == null
                                          ? null
                                          : context.tr(_errors[q.key]!),
                                      enabled:
                                          !_busy && !_uncertain && !exiting,
                                      keyboardType: q.kind == 'money'
                                          ? const TextInputType.numberWithOptions(
                                              decimal: true,
                                            )
                                          : TextInputType.text,
                                      textInputAction: TextInputAction.next,
                                      maxLength: q.maxLength ?? 20,
                                      onChanged: (_) {
                                        if (_leaving || _busy || _uncertain) {
                                          return;
                                        }
                                        if (_errors.containsKey(q.key)) {
                                          setState(() {
                                            final error = _validateQuestion(q);
                                            if (error == null) {
                                              _errors.remove(q.key);
                                            } else {
                                              _errors[q.key] = error;
                                            }
                                          });
                                        } else {
                                          setState(() {});
                                        }
                                        _stash();
                                      },
                                    ),
                                  ),
                                ),
                              if (q.kind == 'money')
                                Align(
                                  alignment: AlignmentDirectional.centerStart,
                                  child: ChoiceChip(
                                    key: ValueKey('intake-unknown-${q.key}'),
                                    label: Text(context.tr('Not known yet')),
                                    selected: _text[q.key]!.text.trim().isEmpty,
                                    onSelected: _busy || _uncertain || exiting
                                        ? null
                                        : (_) {
                                            setState(() {
                                              _text[q.key]!.clear();
                                              _errors.remove(q.key);
                                            });
                                            _stash();
                                          },
                                  ),
                                ),
                            ],
                          ),
                        ),
                      if (_errors.isNotEmpty)
                        SahActionFeedback(
                          key: const ValueKey('intake-validation-feedback'),
                          title: context.tr('Check this answer'),
                          message: context.tr('{field}: {message}', {
                            'field': programQuestionLabel(
                              context,
                              _response!.definition,
                              _response!.definition.questions.firstWhere(
                                (q) => q.key == _errors.keys.first,
                              ),
                            ),
                            'message': context.tr(_errors.values.first),
                          }),
                          tone: SahNoticeTone.error,
                          onReview: _reviewInvalid,
                          revealRevision: _validationAttempt,
                        ),
                      if (_feedbackAtAction && _notice != null && _savedOnline)
                        _noticeBody(),
                      if (_feedbackAtAction && _notice != null && !_savedOnline)
                        SahActionFeedback(
                          key: const ValueKey('intake-save-feedback'),
                          message: context.tr(_notice!),
                        ),
                      FilledButton(
                        key: const ValueKey('intake-save'),
                        onPressed:
                            _busy ||
                                !_onlineContext ||
                                _uncertain ||
                                _response == null ||
                                exiting
                            ? null
                            : () async {
                                await _save();
                                if (mounted && _justSaved) {
                                  (widget.onNext ?? requestExit)();
                                }
                              },
                        child: Text(
                          context.tr(
                            widget.onNext == null
                                ? 'Save'
                                : 'Save and continue',
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ),
                      const SizedBox(height: 16),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    },
  );
  bool get _needsReconcile =>
      !_busy &&
      (_uncertain ||
          _response == null ||
          !_onlineContext ||
          (_response!.saved != null && !_response!.isCurrent) ||
          (_notice != null && !_savedOnline));

  bool get _savedOnline =>
      _notice == 'Answers saved. Program checks update on their own.' ||
      _notice == 'The submitted answers are confirmed saved.';

  Widget _noticeBody() => _savedOnline
      ? _IntakeSavedFeedback(
          key: const ValueKey('intake-save-feedback'),
          title: context.tr('Saved online'),
          message: context.tr(_notice!),
        )
      : SahNotice(message: context.tr(_notice!));

  String _savedLabel(String key) {
    final answers = _response?.saved?.answers.where((a) => a.key == key);
    final value = answers == null || answers.isEmpty
        ? null
        : answers.single.value;
    return value == null
        ? context.tr('Unknown')
        : value == true
        ? context.tr('Yes')
        : value == false
        ? context.tr('No')
        : value.toString();
  }
}

class _IntakeSavedFeedback extends StatefulWidget {
  const _IntakeSavedFeedback({
    super.key,
    required this.title,
    required this.message,
  });
  final String title, message;

  @override
  State<_IntakeSavedFeedback> createState() => _IntakeSavedFeedbackState();
}

class _IntakeSavedFeedbackState extends State<_IntakeSavedFeedback> {
  final _anchor = GlobalKey();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || ModalRoute.of(context)?.isCurrent == false) return;
      final target = _anchor.currentContext;
      if (target != null) {
        Scrollable.ensureVisible(
          target,
          alignment: 0.1,
          duration: MediaQuery.disableAnimationsOf(context)
              ? Duration.zero
              : const Duration(milliseconds: 180),
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(key: _anchor, height: 1),
        Semantics(
          liveRegion: true,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [Text(widget.title), Text(widget.message)],
          ),
        ),
      ],
    ),
  );
}
