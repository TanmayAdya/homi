import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:safe_at_home/features/assessment/domain/annotation/box_annotation.dart';

const _image = AnnotatedImage(
  evidenceId: 'evidence-1',
  version: 'local:staged-1',
  width: 1200,
  height: 900,
);

void main() {
  late AnnotationStore store;
  var next = 0;

  setUp(() {
    next = 0;
    store = AnnotationStore(newId: () => 'box-${++next}');
  });

  BoxAnnotation addBox({ImageRect? rect}) =>
      store.add(findingId: 'finding-1', image: _image, rect: rect);

  group('adding', () {
    test('a default box is centred and a third of the image', () {
      final BoxAnnotation box = addBox();
      expect(box.rect, const ImageRect(400, 300, 400, 300));
      expect(box.revision, 1);
      expect(box.stale, isFalse);
    });

    test('a box outside the image is pulled inside it', () {
      final BoxAnnotation box = addBox(
        rect: const ImageRect(-50, 800, 2000, 300),
      );
      expect(box.rect, const ImageRect(0, 600, 1200, 300));
    });

    test('a repeated ID is refused', () {
      store = AnnotationStore(newId: () => 'same');
      addBox();
      expect(addBox, throwsStateError);
    });
  });

  group('editing', () {
    test('move keeps the size and stops at the edges', () {
      final String id = addBox().id;
      expect(
        store.move(id, 100, -50)!.rect,
        const ImageRect(500, 250, 400, 300),
      );
      expect(
        store.move(id, 5000, 5000)!.rect,
        const ImageRect(800, 600, 400, 300),
      );
      expect(store.move(id, -5000, 0)!.rect.left, 0);
    });

    test('resize grows around the centre and stays inside the image', () {
      final String id = addBox().id;
      expect(
        store.resize(id, 100, 100)!.rect,
        const ImageRect(350, 250, 500, 400),
      );
      final ImageRect huge = store.resize(id, 10000, 10000)!.rect;
      expect(huge, const ImageRect(0, 0, 1200, 900));
    });

    test('a box cannot shrink below the minimum size', () {
      final String id = addBox().id;
      final ImageRect tiny = store.resize(id, -10000, -10000)!.rect;
      expect(tiny.width, 900 * AnnotationStore.minSizeFraction);
      expect(tiny.height, 900 * AnnotationStore.minSizeFraction);
    });

    test('each change increases the revision; no-ops do not', () {
      final String id = addBox().id;
      expect(store.move(id, 1, 0)!.revision, 2);
      expect(store.move(id, 0, 0)!.revision, 2);
      expect(store.setLabel(id, ' raised edge ')!.label, 'raised edge');
      expect(store[id]!.revision, 3);
    });

    test('hide keeps the box', () {
      final String id = addBox().id;
      expect(store.setHidden(id, true)!.hidden, isTrue);
      expect(store.on(_image), hasLength(1));
    });

    test('unknown IDs return null', () {
      expect(store.move('nope', 1, 1), isNull);
      expect(store.remove('nope'), isFalse);
    });
  });

  group('image changes', () {
    const replacement = AnnotatedImage(
      evidenceId: 'evidence-1',
      version: 'local:staged-2',
      width: 1200,
      height: 900,
    );

    test('replacement marks boxes stale even with the same size', () {
      final String id = addBox().id;
      expect(store.imageChanged('evidence-1', replacement), 1);
      expect(store[id]!.stale, isTrue);
      expect(store.on(replacement), isEmpty);
      expect(store.on(_image), isEmpty);
      expect(store.staleFor('evidence-1').single.id, id);
    });

    test('stale boxes cannot be edited, only hidden or removed', () {
      final String id = addBox().id;
      store.imageChanged('evidence-1', replacement);
      expect(store.move(id, 10, 10), isNull);
      expect(store.resize(id, 10, 10), isNull);
      expect(store.setLabel(id, 'x'), isNull);
      expect(store.setHidden(id, true)!.hidden, isTrue);
      expect(store.remove(id), isTrue);
    });

    test('the same image does not invalidate its boxes', () {
      final String id = addBox().id;
      expect(store.imageChanged('evidence-1', _image), 0);
      expect(store[id]!.stale, isFalse);
    });

    test('a different hash or size counts as a change', () {
      addBox();
      expect(
        store.imageChanged(
          'evidence-1',
          const AnnotatedImage(
            evidenceId: 'evidence-1',
            version: 'local:staged-1',
            width: 900,
            height: 1200,
          ),
        ),
        1,
      );
    });

    test('other evidence is unaffected', () {
      addBox();
      expect(store.imageChanged('evidence-2', null), 0);
    });

    test('removing a photo or a finding removes its boxes', () {
      addBox();
      store.add(
        findingId: 'finding-2',
        image: const AnnotatedImage(
          evidenceId: 'evidence-2',
          version: 'v',
          width: 10,
          height: 10,
        ),
      );
      expect(store.removeForEvidence('evidence-1'), 1);
      expect(store.removeForFinding('finding-2'), 1);
      expect(store.all, isEmpty);
    });
  });

  test('the local record uses image pixels and a named convention', () {
    final Map<String, Object?> json = addBox().toLocalJson();
    expect(json['coordinates'], annotationCoordinateConvention);
    expect(json['rect'], [400.0, 300.0, 400.0, 300.0]);
    expect(json['imageWidth'], 1200);
    expect(() => jsonEncode(json), returnsNormally);
  });

  group('viewport', () {
    test('contain-fit maps image pixels to the view and back', () {
      final viewport = ImageViewport(
        imageWidth: 1200,
        imageHeight: 900,
        viewWidth: 400,
        viewHeight: 400,
      );
      expect(viewport.scale, 400 / 1200);
      expect(viewport.offsetX, 0);
      expect(viewport.offsetY, 50);
      expect(viewport.toView(600, 450), (200.0, 200.0));
      expect(viewport.toImage(200, 200), (600.0, 450.0));
      expect(viewport.toImageDistance(10), 30);
      expect(
        viewport.rectToView(const ImageRect(0, 0, 1200, 900)),
        const ImageRect(0, 50, 400, 300),
      );
    });

    test('a tall image is letterboxed horizontally', () {
      final viewport = ImageViewport(
        imageWidth: 900,
        imageHeight: 1200,
        viewWidth: 400,
        viewHeight: 400,
      );
      expect(viewport.offsetX, 50);
      expect(viewport.offsetY, 0);
    });
  });
}
