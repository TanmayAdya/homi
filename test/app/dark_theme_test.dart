import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/app/appearance.dart';
import 'package:safe_at_home/app/theme.dart';
import 'package:safe_at_home/features/settings/appearance_section.dart';
import 'package:safe_at_home/shared/presentation/sah_components.dart';
import 'app_design_test.dart' show contrast;

void main() {
  test('dark text, notice and button colors meet normal-text contrast', () {
    final theme = SafeAtHomeTheme.dark();
    final scheme = theme.colorScheme;
    expect(theme.brightness, Brightness.dark);
    for (final pair in [
      (scheme.onSurface, theme.scaffoldBackgroundColor),
      (scheme.onSurfaceVariant, theme.scaffoldBackgroundColor),
      (scheme.onSurfaceVariant, scheme.surfaceContainerLow),
      (scheme.primary, theme.scaffoldBackgroundColor),
      (scheme.onPrimary, scheme.primary),
      (scheme.onPrimaryContainer, scheme.primaryContainer),
      (scheme.onTertiaryContainer, scheme.tertiaryContainer),
      (scheme.onErrorContainer, scheme.errorContainer),
      (scheme.error, scheme.surface),
      (scheme.onInverseSurface, scheme.inverseSurface),
    ]) {
      expect(contrast(pair.$1, pair.$2), greaterThanOrEqualTo(4.5));
    }
  });

  test('dark input and outlined-button boundaries meet nontext contrast', () {
    final theme = SafeAtHomeTheme.dark();
    final input = theme.inputDecorationTheme.enabledBorder!;
    final button = theme.outlinedButtonTheme.style!.side!.resolve({})!;
    expect(
      contrast(input.borderSide.color, theme.inputDecorationTheme.fillColor!),
      greaterThanOrEqualTo(3),
    );
    expect(
      contrast(button.color, theme.scaffoldBackgroundColor),
      greaterThanOrEqualTo(3),
    );
  });

  testWidgets('shared components stay readable when the phone is dark', (
    tester,
  ) async {
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    await tester.pumpWidget(
      MaterialApp(
        theme: SafeAtHomeTheme.light(),
        darkTheme: SafeAtHomeTheme.dark(),
        home: Scaffold(
          body: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              const SahPageHeader(title: 'Your case', description: 'Check.'),
              const SahStatusBadge(
                label: 'Saved online · revision 1',
                tone: SahNoticeTone.success,
              ),
              SahFeaturePanel(
                eyebrow: 'NEXT STEP',
                title: 'Assess the home',
                description: 'Photos and measurements.',
                action: FilledButton(
                  onPressed: () {},
                  child: const Text('Open assessment'),
                ),
              ),
              for (final tone in SahNoticeTone.values)
                SahNotice(title: tone.name, message: 'Status in words.'),
              SahActionTile(
                title: 'Resident details',
                status: '3 of 8 answered',
                icon: Icons.person_outline_rounded,
                onTap: () {},
              ),
            ],
          ),
        ),
      ),
    );
    expect(
      Theme.of(tester.element(find.text('Your case'))).scaffoldBackgroundColor,
      SafeAtHomeTheme.darkBackground,
    );
    await expectLater(tester, meetsGuideline(textContrastGuideline));
    expect(tester.takeException(), isNull);
  });

  test(
    'the appearance choice is saved and read back, unknown means system',
    () async {
      final dir = await Directory.systemTemp.createTemp('sah-appearance-');
      addTearDown(() => dir.delete(recursive: true));
      Future<File> file() async => File('${dir.path}/appearance');
      final first = AppAppearance(file: file);
      await first.load();
      expect(first.value, ThemeMode.system);
      await first.choose(ThemeMode.dark);
      final reopened = AppAppearance(file: file);
      await reopened.load();
      expect(reopened.value, ThemeMode.dark);
      await (await file()).writeAsString('sepia');
      await reopened.load();
      expect(reopened.value, ThemeMode.system);
    },
  );

  testWidgets('choosing Dark in settings switches the app at once', (
    tester,
  ) async {
    final appearance = AppAppearance(
      file: () async => throw const FileSystemException('unavailable'),
    );
    addTearDown(appearance.dispose);
    await tester.pumpWidget(
      ListenableBuilder(
        listenable: appearance,
        builder: (context, _) => MaterialApp(
          theme: SafeAtHomeTheme.light(),
          darkTheme: SafeAtHomeTheme.dark(),
          themeMode: appearance.value,
          home: Scaffold(
            body: ListView(
              children: [AppearanceSection(appearance: appearance)],
            ),
          ),
        ),
      ),
    );
    Color background() => Theme.of(
      tester.element(find.text('Appearance')),
    ).scaffoldBackgroundColor;
    expect(background(), SafeAtHomeTheme.ivory);
    await tester.tap(find.byKey(const ValueKey('appearance-selection')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Dark').last);
    await tester.pumpAndSettle();
    expect(appearance.value, ThemeMode.dark);
    expect(background(), SafeAtHomeTheme.darkBackground);
    await tester.tap(find.byKey(const ValueKey('appearance-selection')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Light').last);
    await tester.pumpAndSettle();
    expect(background(), SafeAtHomeTheme.ivory);
    await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
    await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
    expect(tester.takeException(), isNull);
  });

  test(
    'appearance writes keep the latest choice and stale loads cannot replace it',
    () async {
      final dir = await Directory.systemTemp.createTemp('sah-appearance-race-');
      addTearDown(() => dir.delete(recursive: true));
      final saved = File('${dir.path}/appearance');
      await saved.writeAsString('dark');
      final gate = Completer<File>();
      var reads = 0;
      final appearance = AppAppearance(
        file: () => reads++ == 0 ? gate.future : Future.value(saved),
      );
      addTearDown(appearance.dispose);
      final loading = appearance.load();
      await Future.wait([
        appearance.choose(ThemeMode.dark),
        appearance.choose(ThemeMode.light),
        appearance.choose(ThemeMode.system),
      ]);
      gate.complete(saved);
      await loading;
      expect(appearance.value, ThemeMode.system);
      expect(await saved.readAsString(), 'system');
      expect(await File('${saved.path}.next').exists(), false);
    },
  );

  test(
    'failed appearance writes apply temporarily and retry can persist',
    () async {
      final dir = await Directory.systemTemp.createTemp(
        'sah-appearance-retry-',
      );
      addTearDown(() => dir.delete(recursive: true));
      var fail = true;
      final appearance = AppAppearance(
        file: () async {
          if (fail) throw const FileSystemException('Fictional failure');
          return File('${dir.path}/appearance');
        },
      );
      addTearDown(appearance.dispose);
      await appearance.choose(ThemeMode.dark);
      expect(appearance.value, ThemeMode.dark);
      expect(appearance.saveFailed, isTrue);
      fail = false;
      await appearance.choose(appearance.value);
      expect(appearance.saveFailed, isFalse);
      final reopened = AppAppearance(
        file: () async => File('${dir.path}/appearance'),
      );
      addTearDown(reopened.dispose);
      await reopened.load();
      expect(reopened.value, ThemeMode.dark);
    },
  );
}
