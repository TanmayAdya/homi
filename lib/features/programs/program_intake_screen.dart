import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import '../../app/live_app.dart';
import '../../shared/models/contracts.dart';
import '../../shared/models/program_intake.dart';
import '../../shared/presentation/sah_components.dart';
import '../../shared/presentation/draft_exit_guard.dart';
import '../../shared/services/draft_save_tracker.dart';
import '../../shared/services/matching_api_client.dart';

class ProgramIntakeScreen extends StatefulWidget {
  const ProgramIntakeScreen({
    super.key,
    required this.services,
    required this.program,
  });
  final AppServices services;
  final ProgramMatch program;
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
  ProgramIntakeResponse? _response;
  Map<String, Object?>? _restoredDraft;
  bool _busy = true, _uncertain = false, _restoring = true;
  String? _notice;
  late final String _caseId;
  late final int _generation;
  late final DraftSaveTracker _draftSaves;
  bool _leaving = false;
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
    'uncertain': _uncertain,
    'questionnaireVersion': _response?.definition.questionnaireVersion,
    'caseRevision': _response?.caseRevision,
  };
  Future<void> _persist() async {
    _screenCase();
    final value = _raw();
    await _draftSaves.track(() => widget.services.store.writeJson(_key, value));
  }

  void _stash() {
    if (_leaving || _restoring || !_current(_response?.caseRevision ?? -1)) {
      return;
    }
    if (_feedbackAtAction && _notice != null) {
      setState(() => _notice = null);
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

  Future<void> _read({bool initial = false}) async {
    if (_leaving) return;
    setState(() {
      _busy = true;
      _feedbackAtAction = false;
    });
    try {
      final opening = _screenCase();
      if (initial) _restoredDraft = await widget.services.store.readJson(_key);
      _screenCase(revision: opening.revision);
      final local = _restoredDraft;
      if (local != null) _uncertain = local['uncertain'] == true;
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
      _response = response;
      _errors.clear();
      for (final q in response.definition.questions) {
        if (q.kind != 'boolean') {
          _text.putIfAbsent(q.key, () => TextEditingController());
          _fieldAnchors.putIfAbsent(q.key, () => GlobalKey());
          _fieldFocus.putIfAbsent(q.key, () => FocusNode());
        }
      }
      if (initial || previous == null) {
        for (final answer in response.saved?.answers ?? <IntakeAnswer>[]) {
          if (_text.containsKey(answer.key)) {
            _text[answer.key]!.text = answer.value?.toString() ?? '';
          } else {
            _booleans[answer.key] = answer.value as bool?;
          }
        }
        if (local != null &&
            local['questionnaireVersion'] ==
                response.definition.questionnaireVersion) {
          final values = local['values'] as Map;
          final booleans = local['booleans'] as Map;
          for (final key in _text.keys) {
            _text[key]!.text = values[key] as String? ?? '';
          }
          for (final q in response.definition.questions.where(
            (q) => q.kind == 'boolean',
          )) {
            _booleans[q.key] = booleans[q.key] as bool?;
          }
          _notice = 'Recovered unfinished answers. Review them before saving.';
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
        await _persist();
      }
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
    if (_leaving || _busy || _uncertain || _response == null) return;
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
        _notice =
            'Reported program answers saved. Refresh the program checks to use the new case revision.';
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
      return Scaffold(
        appBar: AppBar(
          leading: BackButton(onPressed: requestExit),
          title: const Text('Program questions'),
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
                    const SahStepIndicator(
                      currentStep: 2,
                      labels: ['Details', 'Home', 'Programs', 'Draft'],
                    ),
                    SahPageHeader(
                      title: widget.program.programName,
                      description:
                          'Review the reported facts for this program. Leave anything you do not know unanswered.',
                    ),
                    const SahNotice(
                      message:
                          'These are reported facts, not a diagnosis, professional determination or funding decision. Unknown is different from No or zero.',
                    ),
                    if (_busy)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 12),
                        child: LinearProgressIndicator(
                          semanticsLabel: 'Updating program answers',
                        ),
                      ),
                    if (_notice != null && !_feedbackAtAction)
                      SahNotice(message: _notice!),
                    if (_uncertain)
                      const SahNotice(
                        title: 'Check the last save',
                        message:
                            'A save may already have succeeded. Check saved answers before another save.',
                        tone: SahNoticeTone.warning,
                      ),
                    const SizedBox(height: 8),
                    OutlinedButton(
                      key: const ValueKey('intake-reconcile'),
                      onPressed: _busy || exiting ? null : () => _read(),
                      child: const Text(
                        'Check saved answers and reconcile',
                        textAlign: TextAlign.center,
                      ),
                    ),
                    if (_response?.saved != null)
                      ExpansionTile(
                        title: const Text('Compare saved answers'),
                        children: [
                          for (final q in _response!.definition.questions)
                            ListTile(
                              title: Text(q.label),
                              subtitle: Text(_savedLabel(q.key)),
                            ),
                        ],
                      ),
                    if (_response != null)
                      SahSectionHeading(
                        title: 'Reported answers',
                        description:
                            '${_response!.definition.questions.length} questions · Unknown answers can be saved.',
                      ),
                    for (final q
                        in _response?.definition.questions ??
                            <IntakeQuestion>[])
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            ExcludeSemantics(
                              child: Text(
                                q.label,
                                key: ValueKey('intake-question-${q.key}'),
                                style: Theme.of(context).textTheme.titleMedium,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              q.description,
                              style: Theme.of(context).textTheme.bodyMedium
                                  ?.copyWith(
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.onSurfaceVariant,
                                  ),
                            ),
                            const SizedBox(height: 12),
                            if (q.kind == 'boolean')
                              DropdownButtonFormField<String>(
                                key: ValueKey('${q.key}-$_restoring'),
                                initialValue:
                                    _booleans[q.key]?.toString() ?? 'unknown',
                                isExpanded: true,
                                isDense: false,
                                itemHeight: null,
                                decoration: InputDecoration(labelText: q.label),
                                items: const [
                                  DropdownMenuItem(
                                    value: 'unknown',
                                    child: Text('Unknown'),
                                  ),
                                  DropdownMenuItem(
                                    value: 'true',
                                    child: Text('Yes'),
                                  ),
                                  DropdownMenuItem(
                                    value: 'false',
                                    child: Text('No'),
                                  ),
                                ],
                                onChanged: _busy || _uncertain || exiting
                                    ? null
                                    : (v) {
                                        if (_leaving || _busy || _uncertain) {
                                          return;
                                        }
                                        setState(
                                          () =>
                                              _booleans[q.key] = v == 'unknown'
                                              ? null
                                              : v == 'true',
                                        );
                                        _stash();
                                      },
                              )
                            else
                              TextFormField(
                                key: _fieldAnchors[q.key],
                                controller: _text[q.key],
                                focusNode: _fieldFocus[q.key],
                                forceErrorText: _errors[q.key],
                                enabled: !_busy && !_uncertain && !exiting,
                                decoration: InputDecoration(
                                  labelText: q.label,
                                  helperText: 'Blank means unknown',
                                ),
                                keyboardType: q.kind == 'money'
                                    ? const TextInputType.numberWithOptions(
                                        decimal: true,
                                      )
                                    : TextInputType.text,
                                textInputAction: TextInputAction.next,
                                maxLength: q.maxLength ?? 20,
                                onChanged: (_) {
                                  if (_leaving || _busy || _uncertain) return;
                                  if (_errors.containsKey(q.key)) {
                                    setState(() {
                                      final error = _validateQuestion(q);
                                      if (error == null) {
                                        _errors.remove(q.key);
                                      } else {
                                        _errors[q.key] = error;
                                      }
                                    });
                                  }
                                  _stash();
                                },
                              ),
                          ],
                        ),
                      ),
                    if (_errors.isNotEmpty)
                      SahActionFeedback(
                        key: const ValueKey('intake-validation-feedback'),
                        title: 'Check this answer',
                        message:
                            '${_response!.definition.questions.firstWhere((q) => q.key == _errors.keys.first).label}: ${_errors.values.first}',
                        tone: SahNoticeTone.error,
                        onReview: _reviewInvalid,
                        revealRevision: _validationAttempt,
                      ),
                    if (_feedbackAtAction && _notice != null)
                      SahActionFeedback(
                        key: const ValueKey('intake-save-feedback'),
                        message: _notice!,
                      ),
                    FilledButton(
                      key: const ValueKey('intake-save'),
                      onPressed:
                          _busy || _uncertain || _response == null || exiting
                          ? null
                          : _save,
                      child: const Text(
                        'Save these reported answers',
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
      );
    },
  );
  String _savedLabel(String key) {
    final answers = _response?.saved?.answers.where((a) => a.key == key);
    final value = answers == null || answers.isEmpty
        ? null
        : answers.single.value;
    return value == null
        ? 'Unknown'
        : value == true
        ? 'Yes'
        : value == false
        ? 'No'
        : value.toString();
  }
}
