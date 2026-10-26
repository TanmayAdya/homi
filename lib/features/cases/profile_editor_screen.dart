import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:safe_at_home/l10n/app_localizations.dart';
import '../../app/live_app.dart';
import '../local_help/referral_geography.dart';
import '../local_help/zip_states.dart';
import 'profile_suggestion_field.dart';
import 'profile_suggestions.dart';
import 'profile_response_state.dart';
import '../../shared/models/case_draft.dart';
import '../../shared/models/contracts.dart';
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
  bool _responsesUnavailable = false;
  bool _automaticSaving = false;
  Completer<void>? _localPromotion;
  bool _leaving = false;
  late final DraftSaveTracker _draftSaves;
  VoidCallback? _requestExit;
  String? _notice;
  String? _countyAutofillCity;
  String? _stateHelp;
  bool _confirmingCounty = false;
  late final String _caseId;
  late final int _generation;
  late int? _baseRevision;
  late Map<String, Object?> _baseProfile;
  late String _baseFingerprint;
  Timer? _autosaveTimer;
  Future<void>? _journalWrite;
  bool _needsLocalPromotion = false;
  Completer<void>? _onlineSave;
  String? _sentProfileFingerprint;
  int? _sentRevision;
  bool _syncFailed = false, _syncRequested = false;
  int _editVersion = 0;
  String? _pendingProfileFingerprint;
  Map<String, Object?>? _recovered;
  ProfileResponseState _responses = const ProfileResponseState();
  ProfileResponseState _baseResponses = const ProfileResponseState();
  String get _editKey => 'profile-edit.$_caseId';
  static const labels = {
    'healthPlan': 'Health plan',
    'city': 'City',
    'county': 'County',
    'ageYears': 'Age in years',
    'householdSize': 'People in household',
    'annualIncomeUsd': 'Annual household income (USD)',
  };

  static const _locationLabels = {'zip': 'ZIP code', 'stateCode': 'State'};
  static final _zipPattern = RegExp(r'^[0-9]{5}$');
  String _labelOf(String key) => labels[key] ?? _locationLabels[key]!;
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
    _fields['zip'] = TextEditingController();
    _fieldAnchors['zip'] = GlobalKey();
    _fieldFocus['zip'] = FocusNode();
    _tenure = p['tenure'] as String?;
    _consent = p['ownerConsentReported'] as bool?;
    c.addListener(_caseChanged);
    _restore();
  }

  @override
  void dispose() {
    widget.services.coordinator.removeListener(_caseChanged);
    _cancelAutosave();
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

  bool get _selected => mounted && _scopeCurrent;

  bool get _scopeCurrent {
    final c = widget.services.coordinator;
    return c.isCurrent &&
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
      (!_saving || _automaticSaving) &&
      !_restoring &&
      !_responsesUnavailable &&
      !_leaving &&
      _recovered == null &&
      _sameBase;

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
    final c = widget.services.coordinator;
    if (_scopeCurrent &&
        _onlineSave != null &&
        _sentRevision != null &&
        !c.uncertain &&
        !c.conflict &&
        c.snapshot?.revision == _sentRevision! + 1 &&
        _fingerprint(c.currentCase().profile.toJson()) ==
            _sentProfileFingerprint) {
      final current = _fingerprint(c.currentDraft().profile.toJson());
      if (current == _baseFingerprint ||
          current == _pendingProfileFingerprint) {
        _baseRevision = c.snapshot!.revision;
      }
    }
    if (mounted) setState(() {});
    if (_syncRequested && _onlineSave == null) {
      scheduleMicrotask(() => unawaited(_saveOnline()));
    }
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
    final responses = saved['responses'] == null
        ? const ProfileResponseState()
        : ProfileResponseState.fromJson(saved['responses']);
    final zip = values['zip'];
    if (zip != null && (zip is! String || zip.length > 5)) {
      throw const FormatException('Invalid private profile value.');
    }
    restored['zip'] = zip ?? responses.zip ?? '';
    return {
      'values': restored,
      'tenure': saved['tenure'],
      'consent': saved['consent'],
      'responses': responses.toJson(),
    };
  }

  void _applyEdits(Map<String, Object?> value) {
    final values = value['values'] as Map;
    for (final key in [...labels.keys, 'zip']) {
      _fields[key]!.text = values[key] as String;
    }
    _tenure = value['tenure'] as String?;
    _consent = value['consent'] as bool?;
    _responses = ProfileResponseState.fromJson(value['responses']);
  }

  Map<String, Object?> _journal([Map<String, Object?>? edits]) => {
    'version': 2,
    'caseId': _caseId,
    'baseCaseRevision': _baseRevision,
    'baseProfileFingerprint': _baseFingerprint,
    ...?edits,
    if (edits == null) ...{
      'values': {
        for (final key in labels.keys) key: _fields[key]!.text,
        'zip': _fields['zip']!.text,
      },
      'tenure': _tenure,
      'consent': _consent,
      'responses': _responses.toJson(),
    },
  };

  Future<void> _restore() async {
    var responsesLoaded = false;
    try {
      _responses = await widget.services.profileResponses.read(
        _caseId,
        CaseProfile.fromJson(_baseProfile),
      );
      _requireBase();
      _baseResponses = _responses;
      _fields['zip']!.text = _responses.zip ?? '';
      responsesLoaded = true;
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
          _needsLocalPromotion = true;
          _notice = 'Recovered unfinished edits from this device.';
        } else {
          _recovered = edits;
          _notice =
              'Unfinished edits need comparison before continuing. Neither set of details has been replaced.';
        }
      }
    } catch (_) {
      if (mounted) {
        _responsesUnavailable = !responsesLoaded;
        _notice = _responsesUnavailable
            ? 'Saved response choices could not be opened. Retry before changing resident details.'
            : 'Unfinished edits could not be restored. The current case details are shown; check them before continuing.';
      }
    }
    if (mounted) {
      setState(() => _restoring = false);
      if (_needsLocalPromotion && _editable) _scheduleAutosave();
    }
  }

  void _stash() {
    if (!_editable) return;
    _editVersion++;
    _needsLocalPromotion = true;
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
    _scheduleAutosave();
  }

  void _cancelAutosave() {
    _autosaveTimer?.cancel();
    _autosaveTimer = null;
  }

  void _scheduleAutosave() {
    _cancelAutosave();
    final version = _editVersion;
    _autosaveTimer = Timer(const Duration(milliseconds: 800), () async {
      _autosaveTimer = null;
      if (_confirmingCounty || version != _editVersion || !_sameBase) return;
      await _flushEdits();
    });
  }

  Future<void> _flushEdits() async {
    _cancelAutosave();
    if (_automaticSaving) await _localPromotion?.future;
    if (!_needsLocalPromotion || _saving || _draftSaves.failed || !_sameBase) {
      return;
    }
    try {
      await _journalWrite;
    } catch (_) {
      return;
    }
    if (_needsLocalPromotion && _sameBase) await _save(automatic: true);
  }

  Future<void> _persistJournal([Map<String, Object?>? edits]) {
    final value = Map<String, Object?>.from(
      jsonDecode(jsonEncode(_journal(edits))) as Map,
    );
    final key = _editKey;
    final write = _draftSaves.track(() {
      _requireBase();
      return widget.services.store.writeJson(key, value);
    });
    _journalWrite = write;
    return write;
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

  String? _validateZip() {
    final text = _fields['zip']!.text.trim();
    return text.isEmpty || _zipPattern.hasMatch(text)
        ? null
        : 'Enter a 5-digit ZIP code.';
  }

  ProfileResponseState _withLocation(String? stateCode, String? zip) =>
      ProfileResponseState(
        coverage: _responses.coverage,
        tenureNotSure: _responses.tenureNotSure,
        consentNotSure: _responses.consentNotSure,
        stateCode: stateCode,
        zip: zip,
      );

  void _zipChanged(String value) {
    if (!_editable) return;
    final zip = value.trim();
    final complete = _zipPattern.hasMatch(zip);
    final inferred = complete ? stateForZip(zip) : null;
    setState(() {
      _stateHelp = !complete
          ? null
          : inferred == null
          ? 'Choose the state. This ZIP code doesn’t tell us which one.'
          : 'Filled from ZIP code {zip}. You can change it.';
      _responses = _withLocation(
        inferred ?? _responses.stateCode,
        complete ? zip : null,
      );
      if (_errors.containsKey('zip')) {
        final error = _validateZip();
        if (error == null) {
          _errors.remove('zip');
        } else {
          _errors['zip'] = error;
        }
      }
    });
    _stash();
  }

  Widget _locationFields() {
    final help = _stateHelp;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          key: const ValueKey('profile-field-zip'),
          padding: const EdgeInsets.only(bottom: 16),
          child: TextFormField(
            key: _fieldAnchors['zip'],
            controller: _fields['zip'],
            focusNode: _fieldFocus['zip'],
            forceErrorText: _errors['zip'] == null
                ? null
                : context.tr(_errors['zip']!),
            errorBuilder: (context, error) => Text(error),
            enabled: _editable,
            onChanged: _zipChanged,
            keyboardType: TextInputType.number,
            textInputAction: TextInputAction.next,
            inputFormatters: [
              FilteringTextInputFormatter.digitsOnly,
              LengthLimitingTextInputFormatter(5),
            ],
            decoration: InputDecoration(labelText: context.tr('ZIP code')),
          ),
        ),
        Padding(
          key: const ValueKey('profile-field-stateCode'),
          padding: const EdgeInsets.only(bottom: 8),
          child: DropdownButtonFormField<String?>(
            key: const ValueKey('profile-state'),
            initialValue: _responses.stateCode,
            isExpanded: true,
            itemHeight: null,
            decoration: InputDecoration(
              labelText: context.tr('State'),
              helper: help == null
                  ? null
                  : Text(
                      context.tr(help, {'zip': _fields['zip']!.text.trim()}),
                      key: const ValueKey('profile-state-help'),
                    ),
            ),
            items: [
              DropdownMenuItem(child: Text(context.tr('Not answered'))),
              for (final state in [...usStates, ...usTerritories])
                DropdownMenuItem(value: state.code, child: Text(state.name)),
            ],
            onChanged: _editable
                ? (value) {
                    setState(() {
                      _stateHelp = null;
                      _responses = _withLocation(value, _responses.zip);
                    });
                    _stash();
                  }
                : null,
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: Text(
            context.tr(
              'Saved on this phone. ZIP code and state help find local help near the resident; they are not synced with the plan.',
            ),
            key: const ValueKey('profile-location-device-note'),
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      ],
    );
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

  Future<void> _save({bool automatic = false}) async {
    if (automatic) {
      if (_saving ||
          _restoring ||
          _responsesUnavailable ||
          _recovered != null ||
          !_sameBase) {
        return;
      }
    } else {
      if (!_editable || _saving) return;
      _cancelAutosave();
    }
    final errors = <String, String>{};
    for (final key in labels.keys) {
      final error = _validateField(key);
      if (error != null) errors[key] = error;
    }
    final zipError = _validateZip();
    if (zipError != null) errors['zip'] = zipError;
    setState(() {
      _validationAttempt++;
      _errors
        ..clear()
        ..addAll(errors);
    });
    if (errors.isNotEmpty) return;
    final editVersion = _editVersion;
    final responses = _responses;
    final promotion = Completer<void>();
    _localPromotion = promotion;
    setState(() {
      _saving = true;
      _automaticSaving = automatic;
    });
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
      final changedProfile = _pendingProfileFingerprint != _baseFingerprint;
      await _draftSaves.track(() async {
        _requireExactDraft({beforeFingerprint, changedFingerprint});
        if (beforeFingerprint != changedFingerprint || c.hasUndurableEdits) {
          await c.updateDraft(changed);
        }
        _requireExactDraft({changedFingerprint});
        await widget.services.profileResponses.write(
          _caseId,
          changed.profile,
          responses,
        );
        _requireExactDraft({changedFingerprint});
        if (_editVersion == editVersion) {
          await widget.services.store.delete(_editKey);
        }
      });
      _requireBase();
      _baseProfile = changed.profile.toJson();
      _baseResponses = responses.forProfile(changed.profile);
      _baseFingerprint = _fingerprint(_baseProfile);
      _pendingProfileFingerprint = null;
      _needsLocalPromotion = _editVersion != editVersion;
      if (_needsLocalPromotion) await _persistJournal();
      _notice = null;
      if (changedProfile) {
        _syncRequested = true;
        unawaited(_saveOnline());
      }
      if (!automatic &&
          mounted &&
          _selected &&
          ModalRoute.of(context)?.isCurrent == true) {
        _requestExit?.call();
      }
    } catch (error) {
      if (mounted) {
        if (automatic) {
          setState(() => _notice = safeOperationMessage(error));
        } else {
          await showOperationError(context, error);
        }
      }
    } finally {
      if (identical(_localPromotion, promotion)) _localPromotion = null;
      promotion.complete();
      if (mounted) {
        setState(() {
          _saving = false;
          _automaticSaving = false;
        });
        if (_needsLocalPromotion && _editable && !_draftSaves.failed) {
          _scheduleAutosave();
        }
      }
    }
  }

  Future<void> _saveOnline() async {
    final c = widget.services.coordinator;
    if (!_scopeCurrent ||
        _onlineSave != null ||
        c.busy ||
        c.hasUndurableEdits ||
        c.uncertain ||
        c.conflict ||
        c.snapshot?.revision != _baseRevision ||
        _fingerprint(c.currentDraft().profile.toJson()) != _baseFingerprint ||
        !c.hasUnsavedChanges) {
      return;
    }
    final sentProfile = _baseFingerprint;
    final sentRevision = _baseRevision ?? 0;
    final finished = Completer<void>();
    _onlineSave = finished;
    _sentProfileFingerprint = sentProfile;
    _sentRevision = sentRevision;
    _syncRequested = false;
    _syncFailed = false;
    try {
      await c.save();
      if (_scopeCurrent) _notice = null;
    } catch (error) {
      if (_scopeCurrent) {
        _syncFailed = true;
        _notice = safeOperationMessage(error);
      }
    } finally {
      if (_scopeCurrent &&
          !c.uncertain &&
          !c.conflict &&
          c.snapshot?.revision == sentRevision + 1) {
        final currentProfile = _fingerprint(c.currentDraft().profile.toJson());
        if ((currentProfile == _baseFingerprint ||
                currentProfile == _pendingProfileFingerprint) &&
            _fingerprint(c.currentCase().profile.toJson()) == sentProfile) {
          _baseRevision = c.snapshot!.revision;
          if (mounted && _needsLocalPromotion && !_saving) {
            unawaited(_persistJournal().catchError((Object _) {}));
          }
        }
      }
      if (identical(_onlineSave, finished)) {
        _onlineSave = null;
        _sentProfileFingerprint = null;
        _sentRevision = null;
      }
      finished.complete();
      if (mounted) setState(() {});
      if (_syncRequested && !_syncFailed && _scopeCurrent) {
        unawaited(_saveOnline());
      }
    }
  }

  String get _saveStatus {
    final c = widget.services.coordinator;
    if (_restoring) return context.tr('Opening resident details…');
    if (_recovered != null) {
      return context.tr('Compare the two copies before continuing.');
    }
    if (!_sameBase && _onlineSave == null) {
      return context.tr('Review the changed case.');
    }
    if (_responsesUnavailable || _draftSaves.failed || c.localSaveFailed) {
      return context.tr(
        'Device save needs attention. Your entries are still here.',
      );
    }
    if (_errors.isNotEmpty) {
      return context.tr(
        'Entries kept on this device. Correct the highlighted answer to sync.',
      );
    }
    if (_draftSaves.pending || _saving) {
      return context.tr('Saving changes on this device…');
    }
    if (_onlineSave != null) {
      return context.tr('Saved on this device · syncing online…');
    }
    if (c.conflict || c.uncertain) {
      return context.tr(
        'Saved on this device · check saved state from your case.',
      );
    }
    if (_syncFailed || c.hasUnsavedChanges) {
      return context.tr('Saved on this device.');
    }
    return _responses.coverage != null ||
            _responses.tenureNotSure ||
            _responses.consentNotSure
        ? context.tr('Saved on this device.')
        : context.tr('Saved online');
  }

  String _display(
    Object? value, {
    bool housing = false,
    bool notSure = false,
    bool planChosen = false,
  }) => switch (value) {
    null when notSure => context.tr('Not sure'),
    String text when text.trim().isEmpty && notSure => context.tr('Not sure'),
    null when planChosen => context.tr('Has a health plan'),
    String text when text.trim().isEmpty && planChosen => context.tr(
      'Has a health plan',
    ),
    null => context.tr('Unknown'),
    true => context.tr('Yes'),
    false => context.tr('No'),
    'owner' when housing => context.tr('Own'),
    'renter' when housing => context.tr('Rent'),
    String text when text.trim().isEmpty => context.tr('Unknown'),
    _ => value.toString(),
  };

  Widget _comparison() {
    final edits = _recovered!;
    final recoveredResponses = ProfileResponseState.fromJson(
      edits['responses'],
    );
    bool notSure(String key, ProfileResponseState state) => switch (key) {
      'healthPlan' => state.coverage == ProfileCoverageChoice.notSure,
      'tenure' => state.tenureNotSure,
      'ownerConsentReported' => state.consentNotSure,
      _ => false,
    };
    String? stateName(String? code) => referralState(code)?.name;
    final values = <String, Object?>{
      ...Map<String, Object?>.from(edits['values'] as Map),
      'stateCode': stateName(recoveredResponses.stateCode),
      'tenure': edits['tenure'],
      'ownerConsentReported': edits['consent'],
    };
    final current = <String, Object?>{
      ..._baseProfile,
      'zip': _baseResponses.zip,
      'stateCode': stateName(_baseResponses.stateCode),
    };
    return Column(
      key: const ValueKey('profile-recovery-comparison'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SahSectionHeading(
          title: context.tr('Compare unfinished edits'),
          description: context.tr(
            'Choose which details to review. This does not save anything online.',
          ),
        ),
        for (final entry in {
          ...labels,
          ..._locationLabels,
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
                  context.tr(entry.value),
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 4),
                Text(
                  context.tr('Current: {value}', {
                    'value': _display(
                      current[entry.key],
                      housing: entry.key == 'tenure',
                      notSure: notSure(entry.key, _baseResponses),
                      planChosen:
                          entry.key == 'healthPlan' &&
                          _baseResponses.coverage == ProfileCoverageChoice.plan,
                    ),
                  }),
                ),
                Text(
                  context.tr('Unfinished: {value}', {
                    'value': _display(
                      values[entry.key],
                      housing: entry.key == 'tenure',
                      notSure: notSure(entry.key, recoveredResponses),
                      planChosen:
                          entry.key == 'healthPlan' &&
                          recoveredResponses.coverage ==
                              ProfileCoverageChoice.plan,
                    ),
                  }),
                ),
              ],
            ),
          ),
        OutlinedButton(
          key: const ValueKey('profile-keep-current'),
          onPressed: _saving || _leaving || !_sameBase
              ? null
              : () => _chooseRecovery(useRecovered: false),
          child: Text(
            context.tr('Keep current details'),
            textAlign: TextAlign.center,
          ),
        ),
        const SizedBox(height: 12),
        FilledButton(
          key: const ValueKey('profile-review-recovered'),
          onPressed: _saving || _leaving || !_sameBase
              ? null
              : () => _chooseRecovery(useRecovered: true),
          child: Text(
            context.tr('Review recovered edits'),
            textAlign: TextAlign.center,
          ),
        ),
        const SizedBox(height: 24),
      ],
    );
  }

  void _fieldChanged(String key) {
    if (!_editable) return;
    if (_errors.containsKey(key) ||
        key == 'healthPlan' ||
        (_countyAutofillCity != null && (key == 'city' || key == 'county'))) {
      setState(() {
        if (key == 'city' || key == 'county') _countyAutofillCity = null;
        final error = _validateField(key);
        if (error == null) {
          _errors.remove(key);
        } else {
          _errors[key] = error;
        }
      });
    }
    _stash();
  }

  void _applySuggestionValues(
    Map<String, String> values, {
    String? countyCity,
  }) {
    if (!_editable) return;
    for (final entry in values.entries) {
      _fields[entry.key]!.value = TextEditingValue(
        text: entry.value,
        selection: TextSelection.collapsed(offset: entry.value.length),
      );
    }
    setState(() {
      if (values.containsKey('city') || values.containsKey('county')) {
        _countyAutofillCity = countyCity;
      }
      for (final key in values.keys) {
        if (!_errors.containsKey(key)) continue;
        final error = _validateField(key);
        if (error == null) {
          _errors.remove(key);
        } else {
          _errors[key] = error;
        }
      }
    });
    _stash();
  }

  Future<void> _selectSuggestion(
    String key,
    ProfileSuggestion suggestion,
  ) async {
    if (!_editable || _confirmingCounty) return;
    final county = key == 'city' ? suggestion.county : null;
    final currentCounty = _fields['county']!.text;
    if (county == null) {
      _applySuggestionValues({key: suggestion.value});
      return;
    }
    if (currentCounty.trim().isEmpty) {
      _applySuggestionValues({
        'city': suggestion.value,
        'county': county,
      }, countyCity: suggestion.value);
      return;
    }
    _applySuggestionValues({'city': suggestion.value});
    if (canonicalProfileCounty(currentCounty) == county) return;
    _confirmingCounty = true;
    try {
      final replace = await showDialog<bool>(
        context: context,
        builder: (context) => Dialog(
          insetPadding: const EdgeInsets.all(16),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Semantics(
                    header: true,
                    child: Text(
                      context.tr('Update county?'),
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    context.tr(
                      '{city} is in {county} County. Replace your current county, “{currentCounty}”, with “{county}”?',
                      {
                        'city': suggestion.value,
                        'county': county,
                        'currentCounty': currentCounty,
                      },
                    ),
                  ),
                  const SizedBox(height: 20),
                  FilledButton(
                    key: const ValueKey('profile-use-city-county'),
                    onPressed: () => Navigator.of(context).pop(true),
                    child: Text(
                      context.tr('Use {county}', {'county': county}),
                      textAlign: TextAlign.center,
                    ),
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton(
                    key: const ValueKey('profile-keep-existing-county'),
                    onPressed: () => Navigator.of(context).pop(false),
                    child: Text(
                      context.tr('Keep current county'),
                      textAlign: TextAlign.center,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      if (replace == true &&
          _editable &&
          _fields['city']!.text == suggestion.value &&
          _fields['county']!.text == currentCounty) {
        _applySuggestionValues({
          'county': county,
        }, countyCity: suggestion.value);
      }
    } finally {
      _confirmingCounty = false;
      if (_needsLocalPromotion && _editable) _scheduleAutosave();
    }
  }

  Widget _profileField(String key) {
    final field = TextFormField(
      key: _fieldAnchors[key],
      controller: _fields[key],
      focusNode: _fieldFocus[key],
      forceErrorText: _errors[key] == null ? null : context.tr(_errors[key]!),
      errorBuilder: (context, error) => Text(error),
      enabled: _editable,
      onChanged: (_) => _fieldChanged(key),
      decoration: InputDecoration(
        labelText: context.tr(labels[key]!),
        helper: key == 'county' && _countyAutofillCity != null
            ? Text(
                context.tr('Filled from {city}. You can change it.', {
                  'city': _countyAutofillCity,
                }),
              )
            : _suggestionCoverage[key] == null || _errors[key] != null
            ? null
            : Text(
                context.tr(_suggestionCoverage[key]!),
                key: ValueKey('profile-suggestion-coverage-$key'),
              ),
      ),
      textInputAction: TextInputAction.next,
      keyboardType:
          ['ageYears', 'householdSize', 'annualIncomeUsd'].contains(key)
          ? TextInputType.numberWithOptions(decimal: key == 'annualIncomeUsd')
          : TextInputType.text,
    );
    final input = !['city', 'county', 'healthPlan'].contains(key)
        ? field
        : ProfileSuggestionField(
            field: key,
            controller: _fields[key]!,
            focusNode: _fieldFocus[key]!,
            enabled: _editable,
            onSelected: (suggestion) => _selectSuggestion(key, suggestion),
            child: field,
          );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (key == 'healthPlan') _coverageChoices(),
        if (key != 'healthPlan' || _coverage() == _Coverage.plan) ...[
          if (key == 'annualIncomeUsd' ||
              MediaQuery.textScalerOf(context).scale(16) > 24)
            _fullFieldLabel(labels[key]!, key),
          input,
        ],
      ],
    );
  }

  static const _suggestionCoverage = {
    'healthPlan':
        'Suggestions cover some California plans only. You can type any plan name.',
  };

  bool _answered(String key) => switch (key) {
    'coverage' => _coverage() != null,
    'tenure' => _tenure != null || _responses.tenureNotSure,
    'consent' => _consent != null || _responses.consentNotSure,
    _ => _fields[key]!.text.trim().isNotEmpty,
  };

  static const _sections = {
    'Health coverage': ['coverage'],
    'Home': ['tenure', 'consent'],
    'Location': ['city', 'county'],
    'Household': ['ageYears', 'householdSize', 'annualIncomeUsd'],
  };

  String _answeredText(List<String> keys) => context.tr(
    '{answered} of {total} answered',
    {'answered': keys.where(_answered).length, 'total': keys.length},
  );

  Widget _sectionHeading(String title) => ListenableBuilder(
    listenable: Listenable.merge(_fields.values),
    builder: (context, _) => SahSectionHeading(
      key: ValueKey('profile-section-$title'),
      title: context.tr(title),
      description: _answeredText(_sections[title]!),
    ),
  );

  Widget _answerState(String key) {
    final answered = _answered(key);
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Text(
        context.tr(answered ? 'Answered' : 'Not answered'),
        key: ValueKey('profile-answer-state-$key'),
        style: theme.textTheme.bodySmall?.copyWith(
          color: answered
              ? theme.colorScheme.onSurfaceVariant
              : theme.colorScheme.tertiary,
          fontWeight: answered ? null : FontWeight.w600,
        ),
      ),
    );
  }

  Widget _whyWeAsk(String key, String text) => SahMoreInfo(
    key: ValueKey('profile-why-$key'),
    label: context.tr('Why we ask'),
    details: [context.tr(text)],
  );

  static final _noCoverageAnswers = {
    for (final locale in AppLocalizations.supportedLocales)
      AppLocalizations(locale).text('No health coverage'),
  };

  _Coverage? _coverage() {
    final text = _fields['healthPlan']!.text.trim();
    if (_noCoverageAnswers.contains(text)) return _Coverage.none;
    if (text.isNotEmpty) return _Coverage.plan;
    return switch (_responses.coverage) {
      ProfileCoverageChoice.plan => _Coverage.plan,
      ProfileCoverageChoice.none => _Coverage.none,
      ProfileCoverageChoice.notSure => _Coverage.unknown,
      null => null,
    };
  }

  Widget _coverageChoices() {
    final current = _coverage();
    void choose(_Coverage choice) {
      if (!_editable) return;
      final focus = _fieldFocus['healthPlan']!;
      final field = _fields['healthPlan']!;
      setState(() {
        _responses = ProfileResponseState(
          coverage: switch (choice) {
            _Coverage.plan => ProfileCoverageChoice.plan,
            _Coverage.none => ProfileCoverageChoice.none,
            _Coverage.unknown => ProfileCoverageChoice.notSure,
          },
          tenureNotSure: _responses.tenureNotSure,
          consentNotSure: _responses.consentNotSure,
          stateCode: _responses.stateCode,
          zip: _responses.zip,
        );
      });
      if (choice == _Coverage.plan) {
        if (current == _Coverage.none) {
          _applySuggestionValues({'healthPlan': ''});
        } else {
          _stash();
        }
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          focus.requestFocus();
          field.selection = TextSelection(
            baseOffset: 0,
            extentOffset: field.text.length,
          );
        });
        return;
      }
      focus.unfocus();
      _applySuggestionValues({
        'healthPlan': choice == _Coverage.none
            ? context.tr('No health coverage')
            : '',
      });
    }

    Widget option(_Coverage choice, String key, String label) =>
        RadioListTile<_Coverage>(
          key: ValueKey(key),
          value: choice,
          enabled: _editable,
          contentPadding: EdgeInsets.zero,
          title: Text(context.tr(label)),
        );
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: RadioGroup<_Coverage>(
        key: const ValueKey('profile-coverage-group'),
        groupValue: current,
        onChanged: (choice) {
          if (choice != null) choose(choice);
        },
        child: Column(
          children: [
            option(
              _Coverage.plan,
              'profile-has-health-plan',
              'Has a health plan',
            ),
            option(
              _Coverage.none,
              'profile-no-health-coverage',
              'No health coverage',
            ),
            option(
              _Coverage.unknown,
              'profile-unknown-health-coverage',
              'Not sure',
            ),
          ],
        ),
      ),
    );
  }

  Widget _questionCard(String key, String title, Widget child) => Card.outlined(
    key: ValueKey('profile-$key-card'),
    margin: const EdgeInsets.only(bottom: 16),
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            header: true,
            child: Text(
              context.tr(title),
              key: ValueKey('profile-full-label-$key'),
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          const SizedBox(height: 8),
          child,
        ],
      ),
    ),
  );

  Widget _responseChoices({
    required String key,
    required String? value,
    required Map<String, String> options,
    required ValueChanged<String> onChanged,
  }) => RadioGroup<String>(
    key: ValueKey('profile-$key-group'),
    groupValue: value,
    onChanged: (choice) {
      if (!_editable || choice == null) return;
      FocusManager.instance.primaryFocus?.unfocus();
      setState(() => onChanged(choice));
      _stash();
    },
    child: Column(
      children: [
        for (final entry in options.entries)
          RadioListTile<String>(
            key: ValueKey('profile-$key-${entry.key}'),
            value: entry.key,
            enabled: _editable,
            contentPadding: EdgeInsets.zero,
            title: Text(context.tr(entry.value)),
          ),
      ],
    ),
  );

  Widget _housingChoices() => _responseChoices(
    key: 'tenure',
    value: _tenure ?? (_responses.tenureNotSure ? 'notSure' : null),
    options: const {'owner': 'Own', 'renter': 'Rent', 'notSure': 'Not sure'},
    onChanged: (choice) {
      _tenure = choice == 'notSure' ? null : choice;
      _responses = ProfileResponseState(
        coverage: _responses.coverage,
        tenureNotSure: choice == 'notSure',
        consentNotSure: _responses.consentNotSure,
        stateCode: _responses.stateCode,
        zip: _responses.zip,
      );
    },
  );

  Widget _consentChoices() => _responseChoices(
    key: 'consent',
    value: _consent == null
        ? (_responses.consentNotSure ? 'notSure' : null)
        : (_consent! ? 'yes' : 'no'),
    options: const {'yes': 'Yes', 'no': 'No', 'notSure': 'Not sure'},
    onChanged: (choice) {
      _consent = switch (choice) {
        'yes' => true,
        'no' => false,
        _ => null,
      };
      _responses = ProfileResponseState(
        coverage: _responses.coverage,
        tenureNotSure: _responses.tenureNotSure,
        consentNotSure: choice == 'notSure',
        stateCode: _responses.stateCode,
        zip: _responses.zip,
      );
    },
  );

  Widget _fullFieldLabel(String label, String key) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: ExcludeSemantics(
      child: Text(
        context.tr(label),
        key: ValueKey('profile-full-label-$key'),
        style: Theme.of(context).textTheme.bodyLarge,
      ),
    ),
  );

  Widget _statusText() => LayoutBuilder(
    builder: (context, constraints) {
      final style = Theme.of(context).textTheme.bodySmall;
      var height = 0.0;
      for (final status in [
        'Saving changes on this device…',
        'Saved on this device · syncing online…',
        'Saved online',
      ]) {
        final painter = TextPainter(
          text: TextSpan(text: context.tr(status), style: style),
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
        )..layout(maxWidth: constraints.maxWidth);
        if (painter.height > height) height = painter.height;
        painter.dispose();
      }
      return ConstrainedBox(
        constraints: BoxConstraints(minHeight: height),
        child: Text(
          _saveStatus,
          key: const ValueKey('profile-save-status'),
          style: style,
        ),
      );
    },
  );

  @override
  Widget build(BuildContext context) => DraftExitGuard(
    tracker: _draftSaves,
    beforeExit: _flushEdits,
    builder: (context, requestExit, exiting) {
      _leaving = exiting;
      _requestExit = requestExit;
      return SahKeyboardDismissal(
        child: Scaffold(
          appBar: AppBar(
            leading: Navigator.of(context).canPop()
                ? BackButton(onPressed: requestExit)
                : null,
            title: Text(context.tr('Resident details')),
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
                      Padding(
                        padding: const EdgeInsets.only(bottom: 20),
                        child: ListenableBuilder(
                          listenable: _draftSaves,
                          builder: (context, _) => _statusText(),
                        ),
                      ),
                      if (_notice != null)
                        SahNotice(message: context.tr(_notice!)),
                      if (_responsesUnavailable && _sameBase)
                        OutlinedButton(
                          key: const ValueKey('profile-retry-responses'),
                          onPressed: _restoring
                              ? null
                              : () {
                                  setState(() {
                                    _restoring = true;
                                    _responsesUnavailable = false;
                                  });
                                  unawaited(_restore());
                                },
                          child: Text(context.tr('Retry')),
                        ),
                      if (!_sameBase && !_restoring && !_saving)
                        SahNotice(
                          title: context.tr('This case changed'),
                          message: context.tr(
                            'Return to the case and reopen Resident details to compare your unfinished work with its current details.',
                          ),
                          tone: SahNoticeTone.warning,
                        ),
                      if (_restoring)
                        LinearProgressIndicator(
                          semanticsLabel: context.tr('Restoring private edits'),
                        ),
                      if (_recovered != null) _comparison(),
                      Text(
                        context.tr(
                          'Skip anything you don’t know. “Not sure” counts as an answer; a blank question is not answered yet.',
                        ),
                      ),
                      ListenableBuilder(
                        listenable: Listenable.merge(_fields.values),
                        builder: (context, _) {
                          final keys = [
                            for (final section in _sections.values) ...section,
                          ];
                          final missing =
                              keys.length - keys.where(_answered).length;
                          return Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: Text(
                              [
                                _answeredText(keys),
                                if (missing > 0)
                                  context.tr('{count} not answered', {
                                    'count': missing,
                                  }),
                              ].join(' · '),
                              key: const ValueKey('profile-answered-total'),
                              style: Theme.of(context).textTheme.titleSmall,
                            ),
                          );
                        },
                      ),
                      _sectionHeading('Health coverage'),
                      _questionCard(
                        'coverage',
                        'What health coverage does the resident have?',
                        Padding(
                          key: const ValueKey('profile-field-healthPlan'),
                          padding: EdgeInsets.zero,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              _profileField('healthPlan'),
                              _answerState('coverage'),
                            ],
                          ),
                        ),
                      ),
                      _sectionHeading('Home'),
                      _questionCard(
                        'tenure',
                        'Do you own or rent?',
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [_housingChoices(), _answerState('tenure')],
                        ),
                      ),
                      _questionCard(
                        'consent',
                        'Owner permission reported?',
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _consentChoices(),
                            _answerState('consent'),
                            _whyWeAsk(
                              'consent',
                              'Some home repair programs need the owner’s permission before work can start. Saying it was reported is not the owner’s signature or consent.',
                            ),
                          ],
                        ),
                      ),
                      for (final key in labels.keys.where(
                        (key) => key != 'healthPlan',
                      )) ...[
                        if (key == 'city') ...[
                          _sectionHeading('Location'),
                          _locationFields(),
                        ],
                        if (key == 'ageYears') _sectionHeading('Household'),
                        Padding(
                          key: ValueKey('profile-field-$key'),
                          padding: const EdgeInsets.only(bottom: 16),
                          child: key != 'annualIncomeUsd'
                              ? _profileField(key)
                              : Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    _profileField(key),
                                    _whyWeAsk(
                                      'income',
                                      'Some programs have income limits. If you leave this blank, it stays unknown. It is never treated as zero or as a reason to say no.',
                                    ),
                                  ],
                                ),
                        ),
                      ],
                      const SizedBox(height: 24),
                      if (_errors.isNotEmpty)
                        SahActionFeedback(
                          key: const ValueKey('profile-validation-feedback'),
                          title: context.tr('Check this answer'),
                          message: context.tr('{field}: {error}', {
                            'field': context.tr(_labelOf(_errors.keys.first)),
                            'error': context.tr(_errors.values.first),
                          }),
                          tone: SahNoticeTone.error,
                          onReview: _reviewInvalid,
                          revealRevision: _validationAttempt,
                        ),
                      if (_syncFailed &&
                          _sameBase &&
                          !widget.services.coordinator.uncertain &&
                          !widget.services.coordinator.conflict)
                        OutlinedButton(
                          key: const ValueKey('profile-retry-online'),
                          onPressed: _onlineSave == null ? _saveOnline : null,
                          child: Text(context.tr('Retry sync')),
                        ),
                      FilledButton(
                        key: const ValueKey('profile-keep-edits'),
                        onPressed: _editable && !_saving ? _save : null,
                        child: Text(
                          context.tr('Done'),
                          textAlign: TextAlign.center,
                        ),
                      ),
                      const SizedBox(height: 72),
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
}

enum _Coverage { plan, none, unknown }
