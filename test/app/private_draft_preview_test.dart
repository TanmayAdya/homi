import 'dart:ui' show SemanticsAction;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/app/theme.dart';
import 'package:safe_at_home/features/requests/private_draft_preview.dart';

void main() {
  testWidgets(
    'PDF navigation exposes semantic actions and respects page bounds',
    (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        var page = 1;
        late StateSetter update;
        await tester.pumpWidget(
          MaterialApp(
            theme: SafeAtHomeTheme.light(),
            home: Scaffold(
              body: StatefulBuilder(
                builder: (context, setState) {
                  update = setState;
                  return PrivatePdfPageNavigation(
                    page: page,
                    pageCount: 2,
                    ready: true,
                    busy: false,
                    onPrevious: () => update(() => page--),
                    onNext: () => update(() => page++),
                  );
                },
              ),
            ),
          ),
        );
        final previous = find.byKey(const ValueKey('private-pdf-previous'));
        final next = find.byKey(const ValueKey('private-pdf-next'));
        expect(tester.widget<OutlinedButton>(previous).onPressed, isNull);
        final nextNode = tester.getSemantics(next);
        expect(
          nextNode.getSemanticsData().hasAction(SemanticsAction.tap),
          isTrue,
        );
        nextNode.owner!.performAction(nextNode.id, SemanticsAction.tap);
        await tester.pump();
        expect(find.text('Page 2 of 2'), findsOneWidget);
        expect(tester.widget<OutlinedButton>(next).onPressed, isNull);
        await tester.tap(previous);
        await tester.pump();
        expect(find.text('Page 1 of 2'), findsOneWidget);
      } finally {
        semantics.dispose();
      }
    },
  );

  testWidgets('PDF navigation disables unavailable and moving pages', (
    tester,
  ) async {
    var calls = 0;
    for (final state in [
      (false, false, false),
      (true, true, false),
      (false, false, true),
    ]) {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PrivatePdfPageNavigation(
              page: 2,
              pageCount: 3,
              ready: state.$1,
              busy: state.$2,
              failed: state.$3,
              onPrevious: () => calls++,
              onNext: () => calls++,
            ),
          ),
        ),
      );
      for (final key in ['private-pdf-previous', 'private-pdf-next']) {
        expect(
          tester.widget<OutlinedButton>(find.byKey(ValueKey(key))).onPressed,
          isNull,
        );
      }
    }
    expect(find.text('PDF pages unavailable'), findsOneWidget);
    expect(calls, 0);
  });

  for (final size in [const Size(320, 568), const Size(932, 430)]) {
    testWidgets(
      'PDF controls wrap and reflowed text scrolls completely at 3.2x in $size',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = size;
        tester.platformDispatcher.textScaleFactorTestValue = 3.2;
        addTearDown(() {
          tester.view.resetDevicePixelRatio();
          tester.view.resetPhysicalSize();
          tester.platformDispatcher.clearTextScaleFactorTestValue();
        });
        await tester.pumpWidget(
          MaterialApp(
            theme: SafeAtHomeTheme.light(),
            home: Scaffold(
              body: SingleChildScrollView(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: PrivatePdfPageNavigation(
                    page: 2,
                    pageCount: 12,
                    ready: true,
                    busy: false,
                    onPrevious: () {},
                    onNext: () {},
                  ),
                ),
              ),
            ),
          ),
        );
        final next = find.byKey(const ValueKey('private-pdf-next'));
        await tester.ensureVisible(next);
        await tester.pumpAndSettle();
        expect(next.hitTestable(), findsOneWidget);
        expect(tester.getSize(next).height, greaterThanOrEqualTo(48));
        expect(tester.takeException(), isNull);
        final fullText =
            '${List.filled(40, 'A fictional complete paragraph with all its words.').join('\n')}\nFinal page sentence.';
        await tester.pumpWidget(
          MaterialApp(
            theme: SafeAtHomeTheme.light(),
            home: Scaffold(
              body: SizedBox(
                height: 360,
                child: PrivatePdfPageText(
                  loading: false,
                  text: fullText,
                  error: null,
                  onRetry: () {},
                ),
              ),
            ),
          ),
        );
        expect(find.text(fullText), findsOneWidget);
        expect(
          find.text(
            'Text view does not show photo markings. Review the page image too.',
          ),
          findsOneWidget,
        );
        final scroll = tester.state<ScrollableState>(find.byType(Scrollable));
        expect(scroll.position.maxScrollExtent, greaterThan(360));
        scroll.position.jumpTo(scroll.position.maxScrollExtent);
        await tester.pumpAndSettle();
        expect(scroll.position.extentAfter, 0);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('PDF text fallback stays explicit and retry is accessible', (
    tester,
  ) async {
    var retries = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: SafeAtHomeTheme.light(),
        home: Scaffold(
          body: SizedBox(
            height: 360,
            child: PrivatePdfPageText(
              loading: false,
              text: null,
              error: 'Text could not be read.',
              onRetry: () => retries++,
            ),
          ),
        ),
      ),
    );
    await tester.ensureVisible(find.text('Retry page text'));
    await tester.tap(find.text('Retry page text'));
    expect(retries, 1);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PrivatePdfPageText(
            loading: false,
            text: '',
            error: null,
            onRetry: () {},
          ),
        ),
      ),
    );
    expect(find.textContaining('No readable text was found'), findsOneWidget);
    expect(find.text('Retry page text'), findsNothing);
  });
}
