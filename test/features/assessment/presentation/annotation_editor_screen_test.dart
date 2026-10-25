import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/features/assessment/domain/annotation/box_annotation.dart';
import 'package:safe_at_home/features/assessment/presentation/annotation_editor_screen.dart';

import '../fakes/image_bytes.dart';
import '../fakes/decodable_photo.dart';

const _image = AnnotatedImage(
  evidenceId: 'evidence-1',
  version: 'local:staged-1',
  width: 1200,
  height: 900,
);

void main() {
  late AnnotationStore store;

  setUp(() {
    var n = 0;
    store = AnnotationStore(newId: () => 'box-${++n}');
  });

  Future<void> pumpEditor(
    WidgetTester tester, {
    VoidCallback? onChanged,
    bool invalid = false,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: AnnotationEditorScreen(
          store: store,
          findingId: 'finding-1',
          image: _image,
          bytes: invalid ? pngHeader(width: 1200, height: 900) : fictionalPng(),
          observation: 'I notice a raised threshold.',
          onChanged: onChanged,
        ),
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();
  }

  Future<void> tap(WidgetTester tester, Finder finder) async {
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  BoxAnnotation box() => store.on(_image).single;

  testWidgets('each edit signals durable saving before the editor closes', (
    tester,
  ) async {
    final saved = <List<Object?>>[];
    await pumpEditor(tester, onChanged: () => saved.add(store.toLocalJson()));
    await tap(tester, find.text('Add a box'));
    expect(saved, hasLength(1));
    await tester.enterText(
      find.byKey(const ValueKey('annotation-label')),
      'fictional threshold',
    );
    expect(saved, hasLength(2));
    expect((saved.last.single as Map)['label'], 'fictional threshold');
    await tap(tester, find.byTooltip('Move right'));
    await tap(tester, find.text('Hide the box'));
    expect(saved, hasLength(4));
    expect((saved.last.single as Map)['hidden'], isTrue);
    await tap(tester, find.text('Remove the box'));
    expect(saved.last, isEmpty);
    expect(find.text('Done'), findsOneWidget);
  });

  testWidgets(
    'failed decoding disables marks and retains existing annotations',
    (tester) async {
      await pumpEditor(tester, invalid: true);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Add a box'),
            )
            .onPressed,
        isNull,
      );
      store.add(findingId: 'finding-1', image: _image);
      final before = store.toLocalJson();
      await pumpEditor(tester, invalid: true);
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Existing marks are retained'),
        findsOneWidget,
      );
      expect(
        tester
            .widget<OutlinedButton>(
              find.widgetWithText(OutlinedButton, 'Remove the box'),
            )
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('annotation-label')))
            .enabled,
        isFalse,
      );
      expect(store.toLocalJson(), before);
      await pumpEditor(tester);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<OutlinedButton>(
              find.widgetWithText(OutlinedButton, 'Remove the box'),
            )
            .onPressed,
        isNotNull,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('shows the observation in plain text', (tester) async {
    await pumpEditor(tester);
    expect(
      find.text('Your observation: I notice a raised threshold.'),
      findsOneWidget,
    );
  });

  testWidgets('buttons add, move, resize, label, hide and remove', (
    tester,
  ) async {
    await pumpEditor(tester);
    await tap(tester, find.text('Add a box'));
    expect(box().rect, const ImageRect(400, 300, 400, 300));

    await tap(tester, find.byTooltip('Move right'));
    expect(box().rect.left, 460);
    await tap(tester, find.byTooltip('Move down'));
    expect(box().rect.top, 345);
    await tap(tester, find.byTooltip('Make bigger'));
    expect(box().rect.width, 460);

    await tester.enterText(
      find.byKey(const ValueKey('annotation-label')),
      'raised edge',
    );
    expect(box().label, 'raised edge');

    await tap(tester, find.text('Hide the box'));
    expect(box().hidden, isTrue);
    expect(find.byKey(const ValueKey('annotation-box')), findsNothing);
    await tap(tester, find.text('Show the box'));
    expect(find.byKey(const ValueKey('annotation-box')), findsOneWidget);

    await tap(tester, find.text('Remove the box'));
    expect(store.all, isEmpty);
    expect(find.text('Add a box'), findsOneWidget);
  });

  testWidgets('dragging moves the box in image pixels, not screen pixels', (
    tester,
  ) async {
    await pumpEditor(tester);
    await tap(tester, find.text('Add a box'));
    final Finder boxFinder = find.byKey(const ValueKey('annotation-box'));
    await tester.ensureVisible(boxFinder);
    await tester.pumpAndSettle();

    final double viewWidth = tester.getSize(find.byType(AspectRatio)).width;
    final double scale = viewWidth / 1200;
    final ImageRect before = box().rect;

    await tester.drag(boxFinder, const Offset(60, 0));
    await tester.pumpAndSettle();

    expect(box().rect.left - before.left, closeTo(60 / scale, 1));
    expect(box().rect.width, before.width);
  });

  testWidgets('stale marks are explained and can be removed', (tester) async {
    store.add(findingId: 'finding-1', image: _image);
    store.imageChanged('evidence-1', null);
    await pumpEditor(tester);

    expect(
      find.textContaining('earlier mark no longer applies'),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('annotation-box')), findsNothing);
    await tap(tester, find.text('Remove old marks'));
    expect(store.all, isEmpty);
  });

  testWidgets('controls meet tap-target and label guidelines', (tester) async {
    final SemanticsHandle handle = tester.ensureSemantics();
    await pumpEditor(tester);
    await tap(tester, find.text('Add a box'));
    await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
    await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
    handle.dispose();
  });
}
