import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../shared/models/contracts.dart';
import '../local_help/referral_geography.dart';

enum ProfileCoverageChoice { plan, none, notSure }

/// Keep explicit unknown answers and routing details on this device
class ProfileResponseState {
  const ProfileResponseState({
    this.coverage,
    this.tenureNotSure = false,
    this.consentNotSure = false,
    this.stateCode,
    this.zip,
  });

  final ProfileCoverageChoice? coverage;
  final bool tenureNotSure;
  final bool consentNotSure;
  final String? stateCode;
  final String? zip;

  ProfileResponseState get locationOnly =>
      ProfileResponseState(stateCode: stateCode, zip: zip);

  factory ProfileResponseState.fromJson(Object? value) {
    if (value is! Map ||
        value.keys.any(
          (key) => !{
            'coverage',
            'tenureNotSure',
            'consentNotSure',
            'stateCode',
            'zip',
          }.contains(key),
        ) ||
        value['tenureNotSure'] is! bool ||
        value['consentNotSure'] is! bool) {
      throw const FormatException('Invalid private profile response state.');
    }
    final stateCode = value['stateCode'], zip = value['zip'];
    if (stateCode != null &&
        (stateCode is! String ||
            stateCode != stateCode.toUpperCase() ||
            referralState(stateCode) == null)) {
      throw const FormatException('Invalid private resident state.');
    }
    if (zip != null &&
        (zip is! String || !RegExp(r'^[0-9]{5}$').hasMatch(zip))) {
      throw const FormatException('Invalid private resident ZIP.');
    }
    final choice = value['coverage'];
    if (choice != null &&
        !ProfileCoverageChoice.values.any((item) => item.name == choice)) {
      throw const FormatException('Invalid private coverage response.');
    }
    return ProfileResponseState(
      coverage: choice == null
          ? null
          : ProfileCoverageChoice.values.firstWhere(
              (item) => item.name == choice,
            ),
      tenureNotSure: value['tenureNotSure'] as bool,
      consentNotSure: value['consentNotSure'] as bool,
      stateCode: stateCode as String?,
      zip: zip as String?,
    );
  }

  Map<String, Object?> toJson() => {
    'coverage': coverage?.name,
    'tenureNotSure': tenureNotSure,
    'consentNotSure': consentNotSure,
    if (stateCode != null) 'stateCode': stateCode,
    if (zip != null) 'zip': zip,
  };

  int answeredCount(CaseProfile profile) =>
      profile.toJson().values.where((value) => value != null).length +
      (profile.healthPlan == null && coverage != null ? 1 : 0) +
      (profile.tenure == null && tenureNotSure ? 1 : 0) +
      (profile.ownerConsentReported == null && consentNotSure ? 1 : 0);

  ProfileResponseState forProfile(CaseProfile profile) => ProfileResponseState(
    coverage:
        profile.healthPlan != null && coverage == ProfileCoverageChoice.notSure
        ? null
        : coverage,
    tenureNotSure: profile.tenure == null && tenureNotSure,
    consentNotSure: profile.ownerConsentReported == null && consentNotSure,
    stateCode: stateCode,
    zip: zip,
  );

  static String placeFingerprint(CaseProfile profile) => sha256
      .convert(utf8.encode(jsonEncode([profile.city, profile.county])))
      .toString();

  static String fingerprint(CaseProfile profile) {
    final entries = profile.toJson().entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    return sha256
        .convert(utf8.encode(jsonEncode(Map.fromEntries(entries))))
        .toString();
  }
}
