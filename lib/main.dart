import 'package:flutter/material.dart';
import 'package:safe_at_home/l10n/app_language.dart';
import 'package:safe_at_home/l10n/app_localizations.dart';
import 'app/appearance.dart';
import 'app/live_app.dart';
import 'app/safe_at_home_app.dart';
import 'app/theme.dart';
import 'features/settings/language_section.dart';
import 'shared/presentation/sah_components.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Future.wait([
    AppAppearance.instance.load(),
    AppLanguageController.instance.load(),
  ]);
  const live = bool.fromEnvironment('SAH_LIVE_BACKEND');
  runApp(live ? const LiveAppBootstrap() : const DemoEntry());
}

class DemoEntry extends StatelessWidget {
  const DemoEntry({super.key});
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([
      AppAppearance.instance,
      AppLanguageController.instance,
    ]),
    builder: (context, _) => MaterialApp(
      title: 'Safe at Home',
      theme: SafeAtHomeTheme.light(),
      darkTheme: SafeAtHomeTheme.dark(),
      themeMode: AppAppearance.instance.value,
      locale: AppLanguageController.instance.value.locale,
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      localeListResolutionCallback: AppLocalizations.resolveLocales,
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        appBar: AppBar(
          title: const Text('Safe at Home'),
          actions: const [LanguageButton()],
        ),
        body: SafeArea(
          child: Builder(
            builder: (context) => SahContent(
              maxWidth: 600,
              child: ListView(
                padding: const EdgeInsets.all(24),
                children: [
                  const SahHomeIllustration(height: 160),
                  const SizedBox(height: 16),
                  SahPageHeader(
                    eyebrow: context.tr('A LITTLE SUPPORT, AT HOME'),
                    title: context.tr('A safer home starts here.'),
                    description: context.tr(
                      'Review your space, explore possible support, and prepare your next steps.',
                    ),
                  ),
                  SahNotice(
                    title: context.tr('Fictional demonstration'),
                    message: context.tr(
                      'Live account access is not enabled in this build. The examples below use bundled fictional information and do not send data to a server.',
                    ),
                    icon: Icons.science_outlined,
                  ),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const SafeAtHomeApp(),
                      ),
                    ),
                    icon: const Icon(Icons.arrow_forward_rounded),
                    label: Text(context.tr('Open fictional examples')),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
