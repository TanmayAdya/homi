import 'package:flutter/material.dart';

import '../../l10n/app_language.dart';
import '../../l10n/app_localizations.dart';

class LanguageSection extends StatelessWidget {
  const LanguageSection({super.key, this.controller});
  final AppLanguageController? controller;

  @override
  Widget build(BuildContext context) {
    final languages = controller ?? AppLanguageController.instance;
    return ListenableBuilder(
      listenable: languages,
      builder: (context, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DropdownButtonFormField<AppLanguage>(
            key: const ValueKey('language-selection'),
            initialValue: languages.value,
            isExpanded: true,
            isDense: false,
            itemHeight: null,
            decoration: InputDecoration(labelText: context.tr('Language')),
            onChanged: (value) {
              if (value != null) languages.choose(value);
            },
            items: [
              for (final language in AppLanguage.values)
                DropdownMenuItem<AppLanguage>(
                  value: language,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Text(
                      language == AppLanguage.system
                          ? context.tr(language.nativeName)
                          : language.nativeName,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            context.tr(
              'Changes apply immediately and stay on this device after sign-out.',
            ),
          ),
          if (languages.saveFailed)
            Text(
              context.tr(
                'Language changed for now. This device could not save the preference; try again.',
              ),
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          if (languages.saveFailed)
            TextButton(
              key: const ValueKey('language-retry-save'),
              onPressed: () => languages.choose(languages.value),
              child: Text(context.tr('Retry saving language')),
            ),
          const SizedBox(height: 8),
          Text(
            context.tr(
              'Program information and official forms may remain in English. Your saved answers are not translated.',
            ),
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

class LanguageButton extends StatelessWidget {
  const LanguageButton({super.key, this.controller});
  final AppLanguageController? controller;

  @override
  Widget build(BuildContext context) => IconButton(
    key: const ValueKey('choose-language'),
    tooltip: context.tr('Choose language'),
    icon: const Icon(Icons.translate_rounded),
    onPressed: () => showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => FractionallySizedBox(
        heightFactor: .88,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 12, 24, 16),
          child: Column(
            children: [
              Expanded(
                child: SingleChildScrollView(
                  child: LanguageSection(controller: controller),
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () => Navigator.pop(context),
                  child: Text(context.tr('Done')),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
