import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import '../../app/live_app.dart';
import '../../shared/models/case_draft.dart';
import '../../shared/presentation/draft_exit_guard.dart';
import '../../shared/presentation/sah_components.dart';
import '../../shared/services/draft_save_tracker.dart';
import '../../shared/services/matching_api_client.dart';

class ProfileEditorScreen extends StatefulWidget {
  const ProfileEditorScreen({super.key, required this.services});
  final AppServices services;
  @override
  State<ProfileEditorScreen> createState() => _ProfileEditorScreenState();
}

class _ProfileEditorScreenState extends State<ProfileEditorScreen> {
  final _form = GlobalKey<FormState>();
  final _scroll = ScrollController();
  final _fields = <String, TextEditingController>{};
  final _fieldAnchors = <String, GlobalKey>{};
  final _fieldFocus = <String, FocusNode>{};
  final _errors = <String, String>{};
  int _validationAttempt = 0;
  String? _tenure;
  bool? _consent;
  bool _saving = false, _restoring = true;
  bool _leaving = false;
  late final DraftSaveTracker _draftSaves;
  VoidCallback? _requestExit;
  String? _notice;
  late final String _caseId;
  late final int _generation;
  late final int? _baseRevision;
  late final Map<String, Object?> _baseProfile;
  late final String _baseFingerprint;
  String? _pendingProfileFingerprint;
  Map<String, Object?>? _recovered;
  int _fieldVersion = 0;
  String get _editKey => 'profile-edit.$_caseId';
  static const labels = {
    'city': 'City',
    'county': 'County',
    'healthPlan': 'Health plan',
    'ageYears': 'Age in years',
    'householdSize': 'People in household',
    'annualIncomeUsd': 'Annual household income (USD)',
  };
  @override
  void initState() {
    super.initState();
    final c = widget.services.coordinator;
    _caseId = c.currentDraft().caseId;
    _generation = c.generation;
    _baseRevision = c.snapshot?.revision;
    _baseProfile = c.currentDraft().profile.toJson();
    _baseFingerprint = _fingerprint(_baseProfile);
    _draftSaves = DraftSaveTracker(isCurrent: () => _sameBase);
    final p = _baseProfile;
    for (final key in labels.keys) {
      _fields[key] = TextEditingController(text: p[key]?.toString() ?? '');
      _fieldAnchors[key] = GlobalKey();
      _fieldFocus[key] = FocusNode();
    }
    _tenure = p['tenure'] as String?;
    _consent = p['ownerConsentReported'] as bool?;
    c.addListener(_caseChanged);
    _restore();
  }

  @override
  void dispose() {
    widget.services.coordinator.removeListener(_caseChanged);
    _draftSaves.dispose();
    _scroll.dispose();
    for (final field in _fields.values) {
      field.dispose();
    }
    for (final focus in _fieldFocus.values) {
      focus.dispose();
    }
    super.dispose();
  }

  String _fingerprint(Map<String, Object?> profile) {
    final entries = profile.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    return sha256
        .convert(utf8.encode(jsonEncode(Map.fromEntries(entries))))
        .toString();
  }

  bool get _selected {
    final c = widget.services.coordinator;
    return mounted &&
        c.isCurrent &&
        c.generation == _generation &&
        c.draft?.caseId == _caseId;
  }

  bool get _sameBase {
    final c = widget.services.coordinator;
    if (!_selected || c.snapshot?.revision != _baseRevision) return false;
    final fingerprint = _fingerprint(c.draft!.profile.toJson());
    return fingerprint == _baseFingerprint ||
        fingerprint == _pendingProfileFingerprint;
  }

  bool get _editable =>
      !_saving && !_restoring && !_leaving && _recovered == null && _sameBase;

  void _requireBase() {
    if (!_sameBase) throw MatchingApiException.forCode('STALE_RESPONSE');
  }

  void _requireExactDraft(Set<String> allowedFingerprints) {
    _requireBase();
    final current = widget.services.coordinator.currentDraft();
    if (!allowedFingerprints.contains(_fingerprint(current.toJson()))) {
      setState(() {
        _notice =
            'The case changed while these edits were being saved. Your unfinished entries are still here. Review the current case before trying to keep them again.';
      });
      throw MatchingApiException.forCode('STALE_RESPONSE');
    }
  }

  void _caseChanged() {
    if (mounted) setState(() {});
  }

  Map<String, Object?> _parseEdits(Map<String, Object?> saved) {
    final values = saved['values'];
    if (values is! Map ||
        !{null, 'owner', 'renter'}.contains(saved['tenure']) ||
        saved['consent'] != null && saved['consent'] is! bool) {
      throw const FormatException('Invalid private profile edits.');
    }
    final restored = <String, Object?>{};
    for (final key in labels.keys) {
      final value = values[key];
      if (value != null && value is! String) {
        throw const FormatException('Invalid private profile value.');
      }
      restored[key] = value ?? '';
    }
    return {
      'values': restored,
      'tenure': saved['tenure'],
      'consent': saved['consent'],
    };
  }

  void _applyEdits(Map<String, Object?> value) {
    final values = value['values'] as Map;
    for (final key in labels.keys) {
      _fields[key]!.text = values[key] as String;
    }
    _tenure = value['tenure'] as String?;
    _consent = value['consent'] as bool?;
    _fieldVersion++;
  }

  Map<String, Object?> _journal([Map<String, Object?>? edits]) => {
    'version': 2,
    'caseId': _caseId,
    'baseCaseRevision': _baseRevision,
    'baseProfileFingerprint': _baseFingerprint,
    ...?edits,
    if (edits == null) ...{
      'values': {for (final key in labels.keys) key: _fields[key]!.text},
      'tenure': _tenure,
      'consent': _consent,
    },
  };

  Future<void> _restore() async {
    try {
      final saved = await widget.services.store.readJson(_editKey);
      _requireBase();
      if (saved != null) {
        if (saved['version'] == 2 && saved['caseId'] != _caseId) {
          throw const FormatException('Profile edits belong to another case.');
        }
        final edits = _parseEdits(saved);
        if (saved['version'] == 2 &&
            saved['caseId'] == _caseId &&
            saved['baseCaseRevision'] == _baseRevision &&
            saved['baseProfileFingerprint'] == _baseFingerprint) {
          _applyEdits(edits);
          _notice = 'Recovered unfinished edits from this device.';
        } else {
          _recovered = edits;
          _notice =
              'Unfinished edits need comparison before continuing. Neither set of details has been replaced.';
        }
      }
    } catch (_) {
      if (mounted) {
        _notice =
            'Unfinished edits could not be restored. The current case details are shown; check them before continuing.';
      }
    }
    if (mounted) setState(() => _restoring = false);
  }

  void _stash() {
    if (!_editable) return;
    unawaited(
      _persistJournal().catchError((Object _) {
        if (_selected) {
          setState(
            () => _notice =
                'Edits could not be saved on this device. Keep this screen open and retry.',
          );
        }
      }),
    );
  }

  Future<void> _persistJournal([Map<String, Object?>? edits]) {
    final value = Map<String, Object?>.from(
      jsonDecode(jsonEncode(_journal(edits))) as Map,
    );
    final key = _editKey;
    return _draftSaves.track(() {
      _requireBase();
      return widget.services.store.writeJson(key, value);
    });
  }

  Future<void> _chooseRecovery({required bool useRecovered}) async {
    if (_saving || _restoring || _leaving || _recovered == null || !_sameBase) {
      return;
    }
    final recovered = _recovered!;
    setState(() => _saving = true);
    try {
      _requireBase();
      if (useRecovered) {
        await _persistJournal(recovered);
      } else {
        final c = widget.services.coordinator;
        final chosen = c.currentDraft();
        final chosenFingerprint = _fingerprint(chosen.toJson());
        await _draftSaves.track(() async {
          _requireExactDraft({chosenFingerprint});
          if (c.localSaveFailed || c.localWritePending) {
            await c.updateDraft(chosen);
            _requireExactDraft({chosenFingerprint});
          }
          await widget.services.store.delete(_editKey);
        });
      }
      _requireBase();
      if (useRecovered) _applyEdits(recovered);
      _recovered = null;
      _notice = useRecovered
          ? 'Recovered edits are ready to review. Check the fields before keeping them in this case.'
          : 'Current case details kept. The unfinished edits were removed from this device.';
      if (_scroll.hasClients) _scroll.jumpTo(0);
    } catch (error) {
      if (_selected) _notice = safeOperationMessage(error);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  String? _validateField(String key) {
    final text = _fields[key]!.text.trim();
    if (text.isEmpty) return null;
    if (['ageYears', 'householdSize'].contains(key)) {
      final n = int.tryParse(text);
      if (n == null ||
          n < (key == 'householdSize' ? 1 : 0) ||
          n > 9007199254740991) {
        return 'Enter a whole number in the supported range.';
      }
    }
    if (key == 'annualIncomeUsd') {
      final n = num.tryParse(text);
      if (n == null || !n.isFinite || n < 0) {
        return 'Enter a nonnegative amount.';
      }
    }
    if (text.length > 200) return 'Use at most 200 characters.';
    return null;
  }

  void _reviewInvalid() {
    if (!_editable || _errors.isEmpty) return;
    final key = _errors.keys.first;
    _fieldFocus[key]!.requestFocus();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_editable) return;
      final target = _fieldAnchors[key]!.currentContext;
      if (target != null) {
        Scrollable.ensureVisible(target, alignment: 0.1);
      }
    });
  }

  Future<void> _save() async {
    if (!_editable) return;
    final errors = <String, String>{};
    for (final key in labels.keys) {
      final error = _validateField(key);
      if (error != null) errors[key] = error;
    }
    setState(() {
      _validationAttempt++;
      _errors
        ..clear()
        ..addAll(errors);
    });
    if (errors.isNotEmpty) return;
    setState(() => _saving = true);
    try {
      _requireBase();
      final c = widget.services.coordinator;
      final value = c.currentDraft().toJson();
      final beforeFingerprint = _fingerprint(value);
      final p = <String, Object?>{};
      for (final key in labels.keys) {
        final text = _fields[key]!.text.trim();
        p[key] = text.isEmpty
            ? null
            : switch (key) {
                'ageYears' || 'householdSize' => int.parse(text),
                'annualIncomeUsd' => num.parse(text),
                _ => text,
              };
      }
      p['tenure'] = _tenure;
      p['ownerConsentReported'] = _consent;
      value['profile'] = p;
      final changed = CaseDraft.fromJson(value);
      final changedFingerprint = _fingerprint(changed.toJson());
      _pendingProfileFingerprint = _fingerprint(changed.profile.toJson());
      await _draftSaves.track(() async {
        _requireExactDraft({beforeFingerprint, changedFingerprint});
        await c.updateDraft(changed);
        _requireExactDraft({changedFingerprint});
        await widget.services.store.delete(_editKey);
      });
      if (mounted && _selected && ModalRoute.of(context)?.isCurrent == true) {
        _requestExit?.call();
      }
    } catch (error) {
      if (mounted) await showOperationError(context, error);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  String _display(Object? value, {bool housing = false}) => switch (value) {
    null => 'Unknown',
    true => 'Yes',
    false => 'No',
    'owner' when housing => 'Own',
    'renter' when housing => 'Rent',
    String text when text.trim().isEmpty => 'Unknown',
    _ => value.toString(),
  };

  Widget _comparison() {
    final edits = _recovered!;
    final values = <String, Object?>{
      ...Map<String, Object?>.from(edits['values'] as Map),
      'tenure': edits['tenure'],
      'ownerConsentReported': edits['consent'],
    };
    return Column(
      key: const ValueKey('profile-recovery-comparison'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SahSectionHeading(
          title: 'Compare unfinished edits',
          description:
              'Choose which details to review. This does not save anything online.',
        ),
        for (final entry in {
          ...labels,
          'tenure': 'Own or rent',
          'ownerConsentReported': 'Owner permission reported',
        }.entries)
          Padding(
            key: ValueKey('profile-comparison-${entry.key}'),
            padding: const EdgeInsets.only(bottom: 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  entry.value,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 4),
                Text(
                  'Current: ${_display(_baseProfile[entry.key], housing: entry.key == 'tenure')}',
                ),
                Text(
                  'Unfinished: ${_display(values[entry.key], housing: entry.key == 'tenure')}',
                ),
              ],
            ),
          ),
        OutlinedButton(
          key: const ValueKey('profile-keep-current'),
          onPressed: _saving || _leaving || !_sameBase
              ? null
              : () => _chooseRecovery(useRecovered: false),
          child: const Text(
            'Keep current details',
            textAlign: TextAlign.center,
          ),
        ),
        const SizedBox(height: 12),
        FilledButton(
          key: const ValueKey('profile-review-recovered'),
          onPressed: _saving || _leaving || !_sameBase
              ? null
              : () => _chooseRecovery(useRecovered: true),
          child: const Text(
            'Review recovered edits',
            textAlign: TextAlign.center,
          ),
        ),
        const SizedBox(height: 24),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => DraftExitGuard(
    tracker: _draftSaves,
    builder: (context, requestExit, exiting) {
      _leaving = exiting;
      _requestExit = requestExit;
      return Scaffold(
        appBar: AppBar(
          leading: Navigator.of(context).canPop()
              ? BackButton(onPressed: requestExit)
              : null,
          title: const Text('Resident details'),
        ),
        body: SafeArea(
          child: Form(
            key: _form,
            child: SahContent(
              child: SingleChildScrollView(
                controller: _scroll,
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const SahStepIndicator(
                      currentStep: 0,
                      labels: ['Details', 'Home', 'Programs', 'Draft'],
                    ),
                    const SahPageHeader(
                      title: 'Start with what you know',
                      description:
                          'These details help check which assistance programs may be relevant.',
                    ),
                    const SahNotice(
                      message:
                          'Leave an answer blank if you do not know. Zero and No are separate answers.',
                    ),
                    if (_notice != null) SahNotice(message: _notice!),
                    if (!_sameBase && !_restoring && !_saving)
                      const SahNotice(
                        title: 'This case changed',
                        message:
                            'Return to the case and reopen Resident details to compare your unfinished work with its current details.',
                        tone: SahNoticeTone.warning,
                      ),
                    if (_restoring)
                      const LinearProgressIndicator(
                        semanticsLabel: 'Restoring private edits',
                      ),
                    if (_recovered != null) _comparison(),
                    for (final key in labels.keys) ...[
                      if (key == 'city')
                        const SahSectionHeading(title: 'Location'),
                      if (key == 'healthPlan')
                        const SahSectionHeading(title: 'Health coverage'),
                      if (key == 'ageYears')
                        const SahSectionHeading(
                          title: 'Household',
                          description:
                              'Only reported information belongs here.',
                        ),
                      Padding(
                        padding: const EdgeInsets.only(bottom: 16),
                        child: TextFormField(
                          key: _fieldAnchors[key],
                          controller: _fields[key],
                          focusNode: _fieldFocus[key],
                          forceErrorText: _errors[key],
                          enabled: _editable,
                          onChanged: (_) {
                            if (!_editable) return;
                            if (_errors.containsKey(key)) {
                              setState(() {
                                final error = _validateField(key);
                                if (error == null) {
                                  _errors.remove(key);
                                } else {
                                  _errors[key] = error;
                                }
                              });
                            }
                            _stash();
                          },
                          decoration: InputDecoration(
                            labelText: labels[key],
                            helperText: key == 'annualIncomeUsd'
                                ? 'Optional · yearly household total in US dollars'
                                : 'Optional',
                          ),
                          textInputAction: TextInputAction.next,
                          keyboardType:
                              [
                                'ageYears',
                                'householdSize',
                                'annualIncomeUsd',
                              ].contains(key)
                              ? TextInputType.numberWithOptions(
                                  decimal: key == 'annualIncomeUsd',
                                )
                              : TextInputType.text,
                        ),
                      ),
                    ],
                    const SahSectionHeading(title: 'Housing'),
                    DropdownButtonFormField<String>(
                      key: ValueKey(
                        'tenure-$_restoring${_fieldVersion == 0 ? '' : '-$_fieldVersion'}',
                      ),
                      initialValue: _tenure,
                      isExpanded: true,
                      isDense: false,
                      itemHeight: null,
                      decoration: const InputDecoration(
                        labelText: 'Do you own or rent?',
                      ),
                      items: const [
                        DropdownMenuItem(
                          value: null,
                          child: Text('Not provided'),
                        ),
                        DropdownMenuItem(value: 'owner', child: Text('Own')),
                        DropdownMenuItem(value: 'renter', child: Text('Rent')),
                      ],
                      onChanged: !_editable
                          ? null
                          : (v) => setState(() {
                              _tenure = v;
                              _stash();
                            }),
                    ),
                    const SizedBox(height: 16),
                    DropdownButtonFormField<bool>(
                      key: ValueKey(
                        'consent-$_restoring${_fieldVersion == 0 ? '' : '-$_fieldVersion'}',
                      ),
                      initialValue: _consent,
                      isExpanded: true,
                      isDense: false,
                      itemHeight: null,
                      decoration: const InputDecoration(
                        labelText: 'Owner permission reported?',
                      ),
                      items: const [
                        DropdownMenuItem(value: null, child: Text('Not known')),
                        DropdownMenuItem(value: true, child: Text('Yes')),
                        DropdownMenuItem(value: false, child: Text('No')),
                      ],
                      onChanged: !_editable
                          ? null
                          : (v) => setState(() {
                              _consent = v;
                              _stash();
                            }),
                    ),
                    Padding(
                      padding: EdgeInsets.symmetric(vertical: 16),
                      child: Text(
                        'A reported answer is not a signed owner authorization.',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                    if (_errors.isNotEmpty)
                      SahActionFeedback(
                        key: const ValueKey('profile-validation-feedback'),
                        title: 'Check this answer',
                        message:
                            '${labels[_errors.keys.first]}: ${_errors.values.first}',
                        tone: SahNoticeTone.error,
                        onReview: _reviewInvalid,
                        revealRevision: _validationAttempt,
                      ),
                    FilledButton(
                      key: const ValueKey('profile-keep-edits'),
                      onPressed: _editable ? _save : null,
                      child: const Text(
                        'Keep edits on this device',
                        textAlign: TextAlign.center,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'You can save these edits online from the case overview.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    },
  );
}
