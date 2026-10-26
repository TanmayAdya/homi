import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'app_language.dart';
import 'catalogs/common.dart';
import 'catalogs/homi_core.dart';
import 'catalogs/settings.dart';
import 'catalogs/account_access.dart';
import 'catalogs/invitations.dart';
import 'catalogs/assistant.dart';
import 'catalogs/assistant_context.dart';
import 'catalogs/android_features.dart';
import 'catalogs/plan_workspace.dart';
import 'catalogs/sharing.dart';
import 'catalogs/sensitive_sharing.dart';
import 'catalogs/tracking.dart';
import 'catalogs/local_help.dart';
import 'catalogs/nationwide_help.dart';
import 'catalogs/federal_preparation.dart';
import 'catalogs/nationwide_records.dart';
import 'catalogs/referral_coverage.dart';
import 'catalogs/home_safety.dart';
import 'catalogs/core.dart';
import 'catalogs/errors.dart';
import 'catalogs/assessment.dart';
import 'catalogs/journey.dart';
import 'catalogs/lifecycle.dart';
import 'catalogs/native_scan.dart';
import 'catalogs/scan_sync.dart';
import 'catalogs/room_scans.dart';
import 'catalogs/room_actions.dart';
import 'catalogs/whole_home.dart';
import 'catalogs/home_model_sync.dart';
import 'catalogs/room_lifecycle.dart';
import 'catalogs/programs.dart';
import 'catalogs/redesign.dart';
import 'catalogs/redesign_shell.dart';
import 'catalogs/redesign_rooms.dart';
import 'catalogs/redesign_help.dart';
import 'catalogs/redesign_applications.dart';
import 'catalogs/redesign_tasks.dart';
import 'catalogs/redesign_account.dart';
import 'catalogs/scan.dart';
import 'catalogs/system.dart';

class AppLocalizations {
  const AppLocalizations(this.locale);
  final Locale locale;

  static final supportedLocales = AppLanguage.values
      .map((language) => language.locale)
      .whereType<Locale>()
      .toList(growable: false);
  static const localizationsDelegates = <LocalizationsDelegate<dynamic>>[
    _AppLocalizationsDelegate(),
    GlobalMaterialLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
  ];
  static const catalogs = [
    homiCoreTranslations,
    settingsTranslations,
    accountAccessTranslations,
    assistantTranslations,
    assistantContextTranslations,
    androidFeatureTranslations,
    planWorkspaceTranslations,
    scanSyncTranslations,
    sharingTranslations,
    invitationTranslations,
    sensitiveSharingTranslations,
    trackingTranslations,
    localHelpTranslations,
    nationwideHelpTranslations,
    federalPreparationTranslations,
    nationwideRecordsTranslations,
    referralCoverageTranslations,
    homeSafetyTranslations,
    coreTranslations,
    assessmentTranslations,
    programsTranslations,
    errorsTranslations,
    scanTranslations,
    systemTranslations,
    journeyTranslations,
    redesignTranslations,
    redesignShellTranslations,
    redesignRoomsTranslations,
    redesignHelpTranslations,
    redesignApplicationsTranslations,
    redesignTasksTranslations,
    redesignAccountTranslations,
    lifecycleTranslations,
    nativeScanTranslations,
    roomScanTranslations,
    roomActionTranslations,
    wholeHomeTranslations,
    homeModelSyncTranslations,
    roomLifecycleTranslations,
    commonTranslations,
  ];
  static final Map<String, Map<String, String>> translations = {
    for (final catalog in catalogs) ...catalog,
  };

  static AppLocalizations of(BuildContext context) =>
      Localizations.of<AppLocalizations>(context, AppLocalizations) ??
      const AppLocalizations(Locale('en'));

  static Locale resolveLocales(
    List<Locale>? preferred,
    Iterable<Locale> supported,
  ) {
    return AppLanguage.forPreferredLocales(preferred ?? const []).locale!;
  }

  String text(String english, [Map<String, Object?> arguments = const {}]) {
    final code = AppLanguage.forLocale(locale).code;
    final template = code == 'en'
        ? english
        : translations[english]?[code] ?? english;
    return template.replaceAllMapped(RegExp(r'\{([A-Za-z][A-Za-z0-9_]*)\}'), (
      match,
    ) {
      final key = match[1]!;
      return arguments.containsKey(key) ? '${arguments[key] ?? ''}' : match[0]!;
    });
  }
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();
  @override
  bool isSupported(Locale locale) => AppLocalizations.supportedLocales.any(
    (supported) => supported.languageCode == locale.languageCode,
  );
  @override
  Future<AppLocalizations> load(Locale locale) =>
      SynchronousFuture(AppLocalizations(locale));
  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

extension AppTranslation on BuildContext {
  String tr(String english, [Map<String, Object?> arguments = const {}]) =>
      AppLocalizations.of(this).text(english, arguments);
}
