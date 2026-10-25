import 'package:flutter/material.dart';
import 'package:safe_at_home/l10n/app_localizations.dart';

import '../../app/appearance.dart';

class AppearanceSection extends StatelessWidget {
  const AppearanceSection({super.key, AppAppearance? appearance})
    : _appearance = appearance;
  final AppAppearance? _appearance;

  @override
  Widget build(BuildContext context) {
    final appearance = _appearance ?? AppAppearance.instance;
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: appearance,
      builder: (context, mode, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DropdownButtonFormField<ThemeMode>(
            key: const ValueKey('appearance-selection'),
            initialValue: mode,
            isExpanded: true,
            isDense: false,
            itemHeight: null,
            decoration: InputDecoration(labelText: context.tr('Appearance')),
            onChanged: (value) {
              if (value != null) appearance.choose(value);
            },
            items: [
              for (final value in ThemeMode.values)
                DropdownMenuItem<ThemeMode>(
                  value: value,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Text(
                      context.tr(switch (value) {
                        ThemeMode.system => 'Match phone setting',
                        ThemeMode.light => 'Light',
                        ThemeMode.dark => 'Dark',
                      }),
                    ),
                  ),
                ),
            ],
          ),
          if (appearance.saveFailed) ...[
            const SizedBox(height: 8),
            Text(
              context.tr(
                'Appearance changed for now. This device could not save the preference; try again.',
              ),
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
            TextButton(
              key: const ValueKey('appearance-retry-save'),
              onPressed: () => appearance.choose(appearance.value),
              child: Text(context.tr('Retry saving appearance')),
            ),
          ],
        ],
      ),
    );
  }
}
