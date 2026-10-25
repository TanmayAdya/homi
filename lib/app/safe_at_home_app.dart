import 'package:flutter/material.dart';
import 'package:safe_at_home/l10n/app_language.dart';
import 'package:safe_at_home/l10n/app_localizations.dart';
import 'appearance.dart';
import 'theme.dart';

import '../features/programs/demo_programs_screen.dart';
import '../shared/services/demo_scenario_service.dart';
import '../shared/services/packet_preparation_service.dart';

class SafeAtHomeApp extends StatelessWidget {
  const SafeAtHomeApp({super.key, this.scenarioService, this.packetService});

  final DemoScenarioService? scenarioService;
  final PacketPreparationService? packetService;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([
        AppAppearance.instance,
        AppLanguageController.instance,
      ]),
      builder: (context, _) => MaterialApp(
        title: 'Safe at Home',
        debugShowCheckedModeBanner: false,
        theme: SafeAtHomeTheme.light(),
        darkTheme: SafeAtHomeTheme.dark(),
        themeMode: AppAppearance.instance.value,
        locale: AppLanguageController.instance.value.locale,
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        localeListResolutionCallback: AppLocalizations.resolveLocales,
        home: DemoProgramsScreen(
          service: scenarioService ?? AssetDemoScenarioService(),
          packetService: packetService ?? AssetDemoPacketService(),
        ),
      ),
    );
  }
}
