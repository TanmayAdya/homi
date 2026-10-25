import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pdfrx_engine/pdfrx_engine.dart';

import '../pdf_document_ref.dart';
import '../utils/fixed_overscroll_physics.dart';
import '../utils/platform.dart';
import 'pdf_viewer.dart';
import 'pdf_viewer_scroll_thumb.dart';
import 'scroll_interaction/pdf_viewer_scroll_interaction_delegate.dart';
import 'scroll_interaction/pdf_viewer_scroll_interaction_delegate_instant.dart';
import 'scroll_interaction/pdf_viewer_scroll_interaction_delegate_physics.dart';
import 'sizing/pdf_viewer_size_delegate.dart';
import 'sizing/pdf_viewer_size_delegate_legacy.dart';
import 'zoom_steps/pdf_viewer_zoom_steps_delegate.dart';
import 'zoom_steps/pdf_viewer_zoom_steps_delegate_default.dart';

@immutable
/// Configures [PdfViewerScrollThumb] and [PdfViewerScrollInteractionDelegateProviderPhysics]
class PdfViewerParams {
  const PdfViewerParams({
    this.margin = 8.0,
    this.backgroundColor = Colors.grey,
    this.layoutPages,
    this.normalizeMatrix,
    @Deprecated('Use sizeDelegateProvider: PdfViewerSizeDelegateProviderLegacy(maxScale: ...) instead') this.maxScale,
    @Deprecated('Use sizeDelegateProvider: PdfViewerSizeDelegateProviderLegacy(minScale: ...) instead') this.minScale,
    @Deprecated(
      'Use sizeDelegateProvider: PdfViewerSizeDelegateProviderLegacy(useAlternativeFitScaleAsMinScale: ...) instead',
    )
    this.useAlternativeFitScaleAsMinScale,
    this.panAxis = PanAxis.free,
    this.boundaryMargin,
    this.annotationRenderingMode = PdfAnnotationRenderingMode.annotationAndForms,
    this.limitRenderingCache = true,
    this.pageAnchor = PdfPageAnchor.top,
    this.underflowAnchor,
    this.pageAnchorEnd = PdfPageAnchor.bottom,
    @Deprecated(
      'Use sizeDelegateProvider: PdfViewerSizeDelegateProviderLegacy(onePassRenderingScaleThreshold: ...) instead',
    )
    this.onePassRenderingScaleThreshold,
    this.onePassRenderingSizeThreshold = 2000,
    this.textSelectionParams,
    this.forceEnableTextSemantics = false,
    this.matchTextColor,
    this.activeMatchTextColor,
    this.pageDropShadow = const BoxShadow(color: Colors.black54, blurRadius: 4, spreadRadius: 2, offset: Offset(2, 2)),
    this.panEnabled = true,
    this.scaleEnabled = true,
    this.onInteractionEnd,
    this.onInteractionStart,
    this.onInteractionUpdate,
    this.interactionEndFrictionCoefficient = _kDrag,
    this.onSecondaryTapUp,
    this.onLongPressStart,
    this.onDocumentChanged,
    this.onDocumentLoadFinished,
    this.calculateInitialPageNumber,
    @Deprecated('Use sizeDelegateProvider: PdfViewerSizeDelegateProviderLegacy(calculateInitialZoom: ...) instead')
    this.calculateInitialZoom,
    this.calculateCurrentPageNumber,
    this.onViewerReady,
    this.onViewSizeChanged,
    this.onPageChanged,
    this.getPageRenderingScale,
    this.scrollByMouseWheel = 0.2,
    this.scaleByPointerScale = 1.0,
    this.scrollHorizontallyByMouseWheel = false,
    this.enableKeyboardNavigation = true,
    this.scrollByArrowKey = 25.0,
    this.maxImageBytesCachedOnMemory = 100 * 1024 * 1024,
    this.horizontalCacheExtent = 1.0,
    this.verticalCacheExtent = 1.0,
    this.linkHandlerParams,
    this.viewerOverlayBuilder,
    this.pageOverlaysBuilder,
    this.loadingBannerBuilder,
    this.errorBannerBuilder,
    this.linkWidgetBuilder,
    this.pagePaintCallbacks,
    this.pageBackgroundPaintCallbacks,
    this.onGeneralTap,
    this.buildContextMenu,
    this.customizeContextMenuItems,
    this.onKey,
    this.keyHandlerParams = const PdfViewerKeyHandlerParams(),
    this.behaviorControlParams = const PdfViewerBehaviorControlParams(),
    this.forceReload = false,
    this.scrollPhysics,
    this.scrollPhysicsScale,
    this.interactionDelegateProvider = const PdfViewerScrollInteractionDelegateProviderInstant(),
    this.sizeDelegateProvider,
    this.zoomStepsDelegateProvider = const PdfViewerZoomStepsDelegateProviderDefault(),
  }) : assert(
         sizeDelegateProvider == null ||
             (maxScale == null &&
                 minScale == null &&
                 useAlternativeFitScaleAsMinScale == null &&
                 onePassRenderingScaleThreshold == null &&
                 calculateInitialZoom == null),
         'sizeDelegateProvider cannot be used together with the deprecated parameters: '
         'maxScale, minScale, useAlternativeFitScaleAsMinScale, onePassRenderingScaleThreshold, or calculateInitialZoom. '
         'Please configure these values in the sizeDelegateProvider instead.',
       );

  final double margin;

  final Color backgroundColor;

  final PdfPageLayoutFunction? layoutPages;

  final PdfMatrixNormalizeFunction? normalizeMatrix;

  @Deprecated('Use sizeDelegateProvider: PdfViewerSizeDelegateProviderLegacy(maxScale: ...) instead')
  final double? maxScale;

  @Deprecated('Use sizeDelegateProvider: PdfViewerSizeDelegateProviderLegacy(minScale: ...) instead')
  final double? minScale;

  @Deprecated(
    'Use sizeDelegateProvider: PdfViewerSizeDelegateProviderLegacy(useAlternativeFitScaleAsMinScale: ...) instead',
  )
  final bool? useAlternativeFitScaleAsMinScale;

  final PanAxis panAxis;

  final EdgeInsets? boundaryMargin;

  final PdfAnnotationRenderingMode annotationRenderingMode;

  final bool limitRenderingCache;

  final PdfPageAnchor pageAnchor;

  final PdfPageAnchor? underflowAnchor;

  final PdfPageAnchor pageAnchorEnd;

  @Deprecated(
    'Use sizeDelegateProvider: PdfViewerSizeDelegateProviderLegacy(onePassRenderingScaleThreshold: ...) instead',
  )
  final double? onePassRenderingScaleThreshold;

  final double onePassRenderingSizeThreshold;

  final PdfTextSelectionParams? textSelectionParams;

  final bool forceEnableTextSemantics;

  final Color? matchTextColor;

  final Color? activeMatchTextColor;

  final BoxShadow? pageDropShadow;

  final bool panEnabled;

  final bool scaleEnabled;

  final GestureScaleEndCallback? onInteractionEnd;

  final GestureScaleStartCallback? onInteractionStart;

  final GestureScaleUpdateCallback? onInteractionUpdate;

  final double interactionEndFrictionCoefficient;

  final void Function(TapUpDetails details)? onSecondaryTapUp;

  final void Function(LongPressStartDetails details)? onLongPressStart;

  static const double _kDrag = 0.0000135;

  final PdfViewerDocumentChangedCallback? onDocumentChanged;

  final PdfDocumentLoadFinished? onDocumentLoadFinished;

  final PdfViewerReadyCallback? onViewerReady;

  final PdfViewerViewSizeChanged? onViewSizeChanged;

  final PdfViewerCalculateInitialPageNumberFunction? calculateInitialPageNumber;

  @Deprecated('Use sizeDelegateProvider: PdfViewerSizeDelegateProviderLegacy(calculateInitialZoom: ...) instead')
  final PdfViewerCalculateZoomFunction? calculateInitialZoom;

  final PdfViewerCalculateCurrentPageNumberFunction? calculateCurrentPageNumber;

  final PdfPageChangedCallback? onPageChanged;

  // ignore: deprecated_member_use_from_same_package
  final PdfViewerGetPageRenderingScale? getPageRenderingScale;

  final double? scrollByMouseWheel;

  final double scaleByPointerScale;

  final bool scrollHorizontallyByMouseWheel;

  final bool enableKeyboardNavigation;

  final double scrollByArrowKey;

  final int maxImageBytesCachedOnMemory;

  final double horizontalCacheExtent;

  final double verticalCacheExtent;

  final PdfLinkHandlerParams? linkHandlerParams;

  final PdfViewerOverlaysBuilder? viewerOverlayBuilder;

  final PdfPageOverlaysBuilder? pageOverlaysBuilder;

  final PdfViewerLoadingBannerBuilder? loadingBannerBuilder;

  final PdfViewerErrorBannerBuilder? errorBannerBuilder;

  final PdfLinkWidgetBuilder? linkWidgetBuilder;

  final List<PdfViewerPagePaintCallback>? pagePaintCallbacks;

  final List<PdfViewerPagePaintCallback>? pageBackgroundPaintCallbacks;

  final PdfViewerGeneralTapHandler? onGeneralTap;

  final PdfViewerContextMenuBuilder? buildContextMenu;

  final PdfViewerContextMenuUpdateMenuItemsFunction? customizeContextMenuItems;

  final PdfViewerOnKeyCallback? onKey;

  final PdfViewerKeyHandlerParams keyHandlerParams;

  final PdfViewerBehaviorControlParams behaviorControlParams;

  final bool forceReload;

  final ScrollPhysics? scrollPhysics;

  final ScrollPhysics? scrollPhysicsScale;

  final PdfViewerScrollInteractionDelegateProvider interactionDelegateProvider;

  final PdfViewerSizeDelegateProvider? sizeDelegateProvider;

  final PdfViewerZoomStepsDelegateProvider zoomStepsDelegateProvider;

  static ScrollPhysics getScrollPhysics(BuildContext context) {
    if (isAndroid) {
      return FixedOverscrollPhysics();
    } else {
      return ScrollConfiguration.of(context).getScrollPhysics(context);
    }
  }

  PdfViewerSizeDelegateProvider getSizeDelegateProvider() {
    final sizeDelegateProvider = this.sizeDelegateProvider;
    if (sizeDelegateProvider != null) {
      return sizeDelegateProvider;
    }
    return PdfViewerSizeDelegateProviderLegacy(
      // ignore: deprecated_member_use_from_same_package
      maxScale: maxScale,
      // ignore: deprecated_member_use_from_same_package
      minScale: minScale,
      // ignore: deprecated_member_use_from_same_package
      onePassRenderingScaleThreshold: onePassRenderingScaleThreshold,
      // ignore: deprecated_member_use_from_same_package
      useAlternativeFitScaleAsMinScale: useAlternativeFitScaleAsMinScale,
      // ignore: deprecated_member_use_from_same_package
      calculateInitialZoom: calculateInitialZoom,
    );
  }

  bool doChangesRequireReload(PdfViewerParams? other) {
    return other == null ||
        forceReload ||
        other.margin != margin ||
        other.backgroundColor != backgroundColor ||
        // ignore: deprecated_member_use_from_same_package
        other.maxScale != maxScale ||
        // ignore: deprecated_member_use_from_same_package
        other.minScale != minScale ||
        // ignore: deprecated_member_use_from_same_package
        other.useAlternativeFitScaleAsMinScale != useAlternativeFitScaleAsMinScale ||
        other.panAxis != panAxis ||
        other.boundaryMargin != boundaryMargin ||
        other.annotationRenderingMode != annotationRenderingMode ||
        other.limitRenderingCache != limitRenderingCache ||
        other.pageAnchor != pageAnchor ||
        other.underflowAnchor != underflowAnchor ||
        other.pageAnchorEnd != pageAnchorEnd ||
        // ignore: deprecated_member_use_from_same_package
        other.onePassRenderingScaleThreshold != onePassRenderingScaleThreshold ||
        other.onePassRenderingSizeThreshold != onePassRenderingSizeThreshold ||
        other.textSelectionParams != textSelectionParams ||
        other.forceEnableTextSemantics != forceEnableTextSemantics ||
        other.matchTextColor != matchTextColor ||
        other.activeMatchTextColor != activeMatchTextColor ||
        other.pageDropShadow != pageDropShadow ||
        other.panEnabled != panEnabled ||
        other.scaleEnabled != scaleEnabled ||
        other.interactionEndFrictionCoefficient != interactionEndFrictionCoefficient ||
        other.scrollByMouseWheel != scrollByMouseWheel ||
        other.scaleByPointerScale != scaleByPointerScale ||
        other.scrollHorizontallyByMouseWheel != scrollHorizontallyByMouseWheel ||
        other.enableKeyboardNavigation != enableKeyboardNavigation ||
        other.scrollByArrowKey != scrollByArrowKey ||
        other.horizontalCacheExtent != horizontalCacheExtent ||
        other.verticalCacheExtent != verticalCacheExtent ||
        other.linkHandlerParams != linkHandlerParams ||
        other.scrollPhysics != scrollPhysics ||
        other.interactionDelegateProvider != interactionDelegateProvider ||
        other.sizeDelegateProvider != sizeDelegateProvider ||
        other.zoomStepsDelegateProvider != zoomStepsDelegateProvider;
  }

  @override
  bool operator ==(covariant PdfViewerParams other) {
    if (identical(this, other)) return true;

    return other.margin == margin &&
        other.backgroundColor == backgroundColor &&
        // ignore: deprecated_member_use_from_same_package
        other.maxScale == maxScale &&
        // ignore: deprecated_member_use_from_same_package
        other.minScale == minScale &&
        // ignore: deprecated_member_use_from_same_package
        other.useAlternativeFitScaleAsMinScale == useAlternativeFitScaleAsMinScale &&
        other.panAxis == panAxis &&
        other.boundaryMargin == boundaryMargin &&
        other.annotationRenderingMode == annotationRenderingMode &&
        other.limitRenderingCache == limitRenderingCache &&
        other.pageAnchor == pageAnchor &&
        other.underflowAnchor == underflowAnchor &&
        other.pageAnchorEnd == pageAnchorEnd &&
        // ignore: deprecated_member_use_from_same_package
        other.onePassRenderingScaleThreshold == onePassRenderingScaleThreshold &&
        other.onePassRenderingSizeThreshold == onePassRenderingSizeThreshold &&
        other.textSelectionParams == textSelectionParams &&
        other.forceEnableTextSemantics == forceEnableTextSemantics &&
        other.matchTextColor == matchTextColor &&
        other.activeMatchTextColor == activeMatchTextColor &&
        other.pageDropShadow == pageDropShadow &&
        other.panEnabled == panEnabled &&
        other.scaleEnabled == scaleEnabled &&
        other.onInteractionEnd == onInteractionEnd &&
        other.onInteractionStart == onInteractionStart &&
        other.onInteractionUpdate == onInteractionUpdate &&
        other.interactionEndFrictionCoefficient == interactionEndFrictionCoefficient &&
        other.onSecondaryTapUp == onSecondaryTapUp &&
        other.onLongPressStart == onLongPressStart &&
        other.onDocumentChanged == onDocumentChanged &&
        other.onDocumentLoadFinished == onDocumentLoadFinished &&
        other.calculateInitialPageNumber == calculateInitialPageNumber &&
        // ignore: deprecated_member_use_from_same_package
        other.calculateInitialZoom == calculateInitialZoom &&
        other.calculateCurrentPageNumber == calculateCurrentPageNumber &&
        other.onViewerReady == onViewerReady &&
        other.onViewSizeChanged == onViewSizeChanged &&
        other.onPageChanged == onPageChanged &&
        other.getPageRenderingScale == getPageRenderingScale &&
        other.scrollByMouseWheel == scrollByMouseWheel &&
        other.scaleByPointerScale == scaleByPointerScale &&
        other.scrollHorizontallyByMouseWheel == scrollHorizontallyByMouseWheel &&
        other.enableKeyboardNavigation == enableKeyboardNavigation &&
        other.scrollByArrowKey == scrollByArrowKey &&
        other.horizontalCacheExtent == horizontalCacheExtent &&
        other.verticalCacheExtent == verticalCacheExtent &&
        other.linkHandlerParams == linkHandlerParams &&
        other.viewerOverlayBuilder == viewerOverlayBuilder &&
        other.pageOverlaysBuilder == pageOverlaysBuilder &&
        other.loadingBannerBuilder == loadingBannerBuilder &&
        other.errorBannerBuilder == errorBannerBuilder &&
        other.linkWidgetBuilder == linkWidgetBuilder &&
        other.pagePaintCallbacks == pagePaintCallbacks &&
        other.pageBackgroundPaintCallbacks == pageBackgroundPaintCallbacks &&
        other.onGeneralTap == onGeneralTap &&
        other.buildContextMenu == buildContextMenu &&
        other.customizeContextMenuItems == customizeContextMenuItems &&
        other.onKey == onKey &&
        other.keyHandlerParams == keyHandlerParams &&
        other.behaviorControlParams == behaviorControlParams &&
        other.forceReload == forceReload &&
        other.scrollPhysics == scrollPhysics &&
        other.interactionDelegateProvider == interactionDelegateProvider &&
        other.sizeDelegateProvider == sizeDelegateProvider &&
        other.zoomStepsDelegateProvider == zoomStepsDelegateProvider;
  }

  @override
  int get hashCode {
    return margin.hashCode ^
        backgroundColor.hashCode ^
        // ignore: deprecated_member_use_from_same_package
        maxScale.hashCode ^
        // ignore: deprecated_member_use_from_same_package
        minScale.hashCode ^
        // ignore: deprecated_member_use_from_same_package
        useAlternativeFitScaleAsMinScale.hashCode ^
        panAxis.hashCode ^
        boundaryMargin.hashCode ^
        annotationRenderingMode.hashCode ^
        limitRenderingCache.hashCode ^
        pageAnchor.hashCode ^
        underflowAnchor.hashCode ^
        pageAnchorEnd.hashCode ^
        // ignore: deprecated_member_use_from_same_package
        onePassRenderingScaleThreshold.hashCode ^
        onePassRenderingSizeThreshold.hashCode ^
        textSelectionParams.hashCode ^
        forceEnableTextSemantics.hashCode ^
        matchTextColor.hashCode ^
        activeMatchTextColor.hashCode ^
        pageDropShadow.hashCode ^
        panEnabled.hashCode ^
        scaleEnabled.hashCode ^
        onInteractionEnd.hashCode ^
        onInteractionStart.hashCode ^
        onInteractionUpdate.hashCode ^
        interactionEndFrictionCoefficient.hashCode ^
        onSecondaryTapUp.hashCode ^
        onLongPressStart.hashCode ^
        onDocumentChanged.hashCode ^
        onDocumentLoadFinished.hashCode ^
        calculateInitialPageNumber.hashCode ^
        // ignore: deprecated_member_use_from_same_package
        calculateInitialZoom.hashCode ^
        calculateCurrentPageNumber.hashCode ^
        onViewerReady.hashCode ^
        onViewSizeChanged.hashCode ^
        onPageChanged.hashCode ^
        getPageRenderingScale.hashCode ^
        scrollByMouseWheel.hashCode ^
        scaleByPointerScale.hashCode ^
        scrollHorizontallyByMouseWheel.hashCode ^
        enableKeyboardNavigation.hashCode ^
        scrollByArrowKey.hashCode ^
        horizontalCacheExtent.hashCode ^
        verticalCacheExtent.hashCode ^
        linkHandlerParams.hashCode ^
        viewerOverlayBuilder.hashCode ^
        pageOverlaysBuilder.hashCode ^
        loadingBannerBuilder.hashCode ^
        errorBannerBuilder.hashCode ^
        linkWidgetBuilder.hashCode ^
        pagePaintCallbacks.hashCode ^
        pageBackgroundPaintCallbacks.hashCode ^
        onGeneralTap.hashCode ^
        buildContextMenu.hashCode ^
        customizeContextMenuItems.hashCode ^
        onKey.hashCode ^
        keyHandlerParams.hashCode ^
        behaviorControlParams.hashCode ^
        forceReload.hashCode ^
        scrollPhysics.hashCode ^
        interactionDelegateProvider.hashCode ^
        sizeDelegateProvider.hashCode ^
        zoomStepsDelegateProvider.hashCode;
  }
}

@immutable
class PdfTextSelectionParams {
  const PdfTextSelectionParams({
    this.enabled = true,
    this.enableSelectionHandles,
    this.showContextMenuAutomatically,
    this.buildSelectionHandle,
    this.calcSelectionHandleOffset,
    this.onTextSelectionChange,
    this.onSelectionHandlePanStart,
    this.onSelectionHandlePanUpdate,
    this.onSelectionHandlePanEnd,
    this.magnifier,
  });

  final bool enabled;

  final bool? enableSelectionHandles;

  final bool? showContextMenuAutomatically;

  final PdfViewerTextSelectionAnchorHandleBuilder? buildSelectionHandle;

  final PdfViewerCalcSelectionAnchorHandleOffsetFunction? calcSelectionHandleOffset;

  final PdfViewerTextSelectionChangeCallback? onTextSelectionChange;

  final PdfViewerSelectionHandlePanStartCallback? onSelectionHandlePanStart;

  final PdfViewerSelectionHandlePanUpdateCallback? onSelectionHandlePanUpdate;

  final PdfViewerSelectionHandlePanEndCallback? onSelectionHandlePanEnd;

  final PdfViewerSelectionMagnifierParams? magnifier;

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is PdfTextSelectionParams &&
        other.buildSelectionHandle == buildSelectionHandle &&
        other.calcSelectionHandleOffset == calcSelectionHandleOffset &&
        other.onTextSelectionChange == onTextSelectionChange &&
        other.onSelectionHandlePanStart == onSelectionHandlePanStart &&
        other.onSelectionHandlePanUpdate == onSelectionHandlePanUpdate &&
        other.onSelectionHandlePanEnd == onSelectionHandlePanEnd &&
        other.enableSelectionHandles == enableSelectionHandles &&
        other.showContextMenuAutomatically == showContextMenuAutomatically &&
        other.magnifier == magnifier;
  }

  @override
  int get hashCode =>
      buildSelectionHandle.hashCode ^
      calcSelectionHandleOffset.hashCode ^
      onTextSelectionChange.hashCode ^
      onSelectionHandlePanStart.hashCode ^
      onSelectionHandlePanUpdate.hashCode ^
      onSelectionHandlePanEnd.hashCode ^
      enableSelectionHandles.hashCode ^
      showContextMenuAutomatically.hashCode ^
      magnifier.hashCode;
}

typedef PdfViewerContextMenuBuilder = Widget? Function(BuildContext context, PdfViewerContextMenuBuilderParams params);

typedef PdfViewerContextMenuUpdateMenuItemsFunction =
    void Function(PdfViewerContextMenuBuilderParams params, List<ContextMenuButtonItem> items);

class PdfViewerContextMenuBuilderParams {
  const PdfViewerContextMenuBuilderParams({
    required this.isTextSelectionEnabled,
    required this.anchorA,
    required this.textSelectionDelegate,
    required this.dismissContextMenu,
    required this.contextMenuFor,
    this.anchorB,
    this.a,
    this.b,
  });

  final bool isTextSelectionEnabled;

  final Offset anchorA;

  final Offset? anchorB;

  final PdfTextSelectionAnchor? a;

  final PdfTextSelectionAnchor? b;

  final PdfTextSelectionDelegate textSelectionDelegate;

  final PdfViewerPart contextMenuFor;

  final void Function() dismissContextMenu;
}

enum PdfViewerPart {
  selectedText,

  nonSelectedText,

  background,
}

enum PdfViewerTextSelectionAnchorHandleState { normal, hover, dragging }

typedef PdfViewerTextSelectionAnchorHandleBuilder =
    Widget? Function(
      BuildContext context,
      PdfTextSelectionAnchor anchor,
      PdfViewerTextSelectionAnchorHandleState state,
    );

typedef PdfViewerCalcSelectionAnchorHandleOffsetFunction =
    Offset Function(BuildContext context, PdfTextSelectionAnchor anchor, PdfViewerTextSelectionAnchorHandleState state);

typedef PdfViewerTextSelectionChangeCallback = void Function(PdfTextSelection textSelection);

typedef PdfViewerSelectionHandlePanStartCallback = void Function(PdfTextSelectionAnchor anchor);

typedef PdfViewerSelectionHandlePanUpdateCallback = void Function(PdfTextSelectionAnchor anchor, Offset delta);

typedef PdfViewerSelectionHandlePanEndCallback = void Function(PdfTextSelectionAnchor anchor);

abstract class PdfTextSelection {
  bool get isTextSelectionEnabled;

  bool get isCopyAllowed;

  bool get hasSelectedText;

  bool get isSelectingAllText;

  PdfTextSelectionRange? get textSelectionPointRange;

  Future<String> getSelectedText();

  Future<List<PdfPageTextRange>> getSelectedTextRanges();
}

abstract class PdfTextSelectionDelegate implements PdfTextSelection {
  Future<bool> copyTextSelection();

  Future<void> clearTextSelection();

  Future<void> selectAllText();

  Future<void> selectWord(Offset position);

  Future<void> setTextSelectionPointRange(PdfTextSelectionRange range);

  PdfViewerCoordinateConverter get doc2local;
}

abstract class PdfViewerCoordinateConverter {
  Offset? offsetToLocal(BuildContext context, Offset? position);

  Rect? rectToLocal(BuildContext context, Rect? rect);

  Offset? offsetToDocument(BuildContext context, Offset? position);

  Rect? rectToDocument(BuildContext context, Rect? rect);
}

@immutable
class PdfViewerSelectionMagnifierParams {
  const PdfViewerSelectionMagnifierParams({
    this.enabled,
    this.magnifierSizeThreshold = 72,
    this.getMagnifierRectForAnchor,
    this.builder,
    this.shouldShowMagnifier,
    this.calcPosition,
    this.animationDuration = const Duration(milliseconds: 100),
    this.shouldShowMagnifierForAnchor,
    this.maxImageBytesCachedOnMemory = defaultMaxImageBytesCachedOnMemory,
  });

  static const defaultMaxImageBytesCachedOnMemory = 256 * 1024;

  final bool? enabled;

  final double magnifierSizeThreshold;

  final PdfViewerGetMagnifierRectForAnchor? getMagnifierRectForAnchor;

  final PdfViewerMagnifierBuilder? builder;

  final bool Function()? shouldShowMagnifier;

  final PdfViewerCalcMagnifierPositionFunction? calcPosition;

  final Duration animationDuration;

  final PdfViewerMagnifierShouldBeShownFunction? shouldShowMagnifierForAnchor;

  final int maxImageBytesCachedOnMemory;

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;

    return other is PdfViewerSelectionMagnifierParams &&
        other.enabled == enabled &&
        other.magnifierSizeThreshold == magnifierSizeThreshold &&
        other.getMagnifierRectForAnchor == getMagnifierRectForAnchor &&
        other.builder == builder &&
        other.shouldShowMagnifierForAnchor == shouldShowMagnifierForAnchor &&
        other.maxImageBytesCachedOnMemory == maxImageBytesCachedOnMemory &&
        other.calcPosition == calcPosition &&
        other.shouldShowMagnifier == shouldShowMagnifier &&
        other.animationDuration == animationDuration;
  }

  @override
  int get hashCode =>
      enabled.hashCode ^
      magnifierSizeThreshold.hashCode ^
      getMagnifierRectForAnchor.hashCode ^
      builder.hashCode ^
      shouldShowMagnifierForAnchor.hashCode ^
      maxImageBytesCachedOnMemory.hashCode ^
      calcPosition.hashCode ^
      shouldShowMagnifier.hashCode ^
      animationDuration.hashCode;
}

typedef PdfViewerGetMagnifierRectForAnchor =
    Rect Function(
      PdfTextSelectionAnchor anchor,
      PdfViewerSelectionMagnifierParams params,
      Offset clampedPointerPosition,
    );

typedef PdfViewerMagnifierBuilder =
    Widget? Function(
      BuildContext context,
      PdfTextSelectionAnchor textAnchor,
      PdfViewerSelectionMagnifierParams params,
      Widget magnifierContent,
      Size magnifierContentSize,
      Offset pointerPosition,
      Offset magnifierPosition,
    );

typedef PdfViewerMagnifierShouldBeShownFunction =
    bool Function(
      PdfTextSelectionAnchor textAnchor,
      PdfViewerController controller,
      PdfViewerSelectionMagnifierParams params,
    );

typedef PdfViewerCalcMagnifierPositionFunction =
    Offset? Function(
      Size? widgetSize,
      Rect anchorLocalRect,
      Rect? handleLocalRect,
      PdfTextSelectionAnchor textAnchor,
      Offset pointerPosition, {
      double margin,
      double? marginOnTop,
      double? marginOnBottom,
    });

typedef PdfViewerDocumentChangedCallback = void Function(PdfDocument? document);

typedef PdfViewerCalculateInitialPageNumberFunction =
    int? Function(PdfDocument document, PdfViewerController controller);

typedef PdfViewerCalculateZoomFunction =
    double? Function(PdfDocument document, PdfViewerController controller, double fitZoom, double coverZoom);

typedef PdfViewerCalculateCurrentPageNumberFunction =
    int? Function(Rect visibleRect, List<Rect> pageRects, PdfViewerController controller);

typedef PdfViewerReadyCallback = void Function(PdfDocument document, PdfViewerController controller);

typedef PdfDocumentLoadFinished = void Function(PdfDocumentRef documentRef, bool loadSucceeded);

typedef PdfViewerViewSizeChanged = void Function(Size viewSize, Size? oldViewSize, PdfViewerController controller);

typedef PdfPageChangedCallback = void Function(int? pageNumber);

typedef PdfViewerGetPageRenderingScale =
    double Function(BuildContext context, PdfPage page, PdfViewerController controller, double estimatedScale);

typedef PdfPageLayoutFunction = PdfPageLayout Function(List<PdfPage> pages, PdfViewerParams params);

typedef PdfMatrixNormalizeFunction =
    Matrix4 Function(Matrix4 matrix, Size viewSize, PdfPageLayout layout, PdfViewerController? controller);

typedef PdfViewerOverlaysBuilder =
    List<Widget> Function(BuildContext context, Size size, PdfViewerHandleLinkTap handleLinkTap);

typedef PdfViewerHandleLinkTap = bool Function(Offset position);

typedef PdfViewerGeneralTapHandler =
    bool Function(BuildContext context, PdfViewerController controller, PdfViewerGeneralTapHandlerDetails details);

class PdfViewerGeneralTapHandlerDetails {
  const PdfViewerGeneralTapHandlerDetails({
    required this.localPosition,
    required this.documentPosition,
    required this.type,
    required this.tapOn,
  });

  final Offset localPosition;

  final Offset documentPosition;

  final PdfViewerGeneralTapType type;

  final PdfViewerPart tapOn;
}

typedef PdfPageOverlaysBuilder = List<Widget> Function(BuildContext context, Rect pageRectInViewer, PdfPage page);

typedef PdfViewerLoadingBannerBuilder = Widget Function(BuildContext context, int bytesDownloaded, int? totalBytes);

typedef PdfViewerErrorBannerBuilder =
    Widget Function(BuildContext context, Object error, StackTrace? stackTrace, PdfDocumentRef documentRef);

typedef PdfLinkWidgetBuilder = Widget? Function(BuildContext context, PdfLink link, Size size);

typedef PdfViewerPagePaintCallback = void Function(ui.Canvas canvas, Rect pageRect, PdfPage page);

enum PdfPageAnchor {
  top,
  left,
  right,
  bottom,
  topLeft,
  topCenter,
  topRight,
  centerLeft,
  center,
  centerRight,
  bottomLeft,
  bottomCenter,
  bottomRight,
  all,
}

class PdfLinkHandlerParams {
  const PdfLinkHandlerParams({
    required this.onLinkTap,
    this.linkColor,
    this.customPainter,
    this.enableAutoLinkDetection = true,
    this.laidOverPageOverlays = true,
  });

  final void Function(PdfLink link) onLinkTap;

  final Color? linkColor;

  final PdfLinkCustomPagePainter? customPainter;

  final bool enableAutoLinkDetection;

  final bool laidOverPageOverlays;

  @override
  bool operator ==(covariant PdfLinkHandlerParams other) {
    if (identical(this, other)) return true;

    return other.onLinkTap == onLinkTap &&
        other.linkColor == linkColor &&
        other.customPainter == customPainter &&
        other.enableAutoLinkDetection == enableAutoLinkDetection &&
        other.laidOverPageOverlays == laidOverPageOverlays;
  }

  @override
  int get hashCode {
    return onLinkTap.hashCode ^
        linkColor.hashCode ^
        customPainter.hashCode ^
        enableAutoLinkDetection.hashCode ^
        laidOverPageOverlays.hashCode;
  }
}

typedef PdfLinkCustomPagePainter = void Function(ui.Canvas canvas, Rect pageRect, PdfPage page, List<PdfLink> links);

typedef PdfViewerOnKeyCallback =
    bool? Function(PdfViewerKeyHandlerParams params, LogicalKeyboardKey key, bool isRealKeyPress);

class PdfViewerKeyHandlerParams {
  const PdfViewerKeyHandlerParams({
    this.enabled = true,
    this.autofocus = false,
    this.canRequestFocus = true,
    this.focusNode,
    this.parentNode,
  });

  final bool enabled;
  final bool autofocus;
  final bool canRequestFocus;
  final FocusNode? focusNode;
  final FocusNode? parentNode;

  @override
  bool operator ==(covariant PdfViewerKeyHandlerParams other) {
    if (identical(this, other)) return true;

    return other.enabled == enabled &&
        other.autofocus == autofocus &&
        other.canRequestFocus == canRequestFocus &&
        other.focusNode == focusNode &&
        other.parentNode == parentNode;
  }

  @override
  int get hashCode =>
      enabled.hashCode ^ autofocus.hashCode ^ canRequestFocus.hashCode ^ focusNode.hashCode ^ parentNode.hashCode;
}

enum PdfViewerGeneralTapType {
  tap,

  doubleTap,

  longPress,

  secondaryTap,
}

class PdfViewerBehaviorControlParams {
  const PdfViewerBehaviorControlParams({
    this.trailingPageLoadingDelay = const Duration(milliseconds: kIsWeb ? 200 : 100),
    this.enableLowResolutionPagePreview = true,
    this.pageImageCachingDelay = const Duration(milliseconds: kIsWeb ? 20 : 20),
    this.partialImageLoadingDelay = const Duration(milliseconds: kIsWeb ? 100 : 0),
  });

  final Duration trailingPageLoadingDelay;

  final bool enableLowResolutionPagePreview;

  final Duration pageImageCachingDelay;

  final Duration partialImageLoadingDelay;

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;

    return other is PdfViewerBehaviorControlParams &&
        other.trailingPageLoadingDelay == trailingPageLoadingDelay &&
        other.enableLowResolutionPagePreview == enableLowResolutionPagePreview &&
        other.pageImageCachingDelay == pageImageCachingDelay &&
        other.partialImageLoadingDelay == partialImageLoadingDelay;
  }

  @override
  int get hashCode =>
      trailingPageLoadingDelay.hashCode ^
      enableLowResolutionPagePreview.hashCode ^
      pageImageCachingDelay.hashCode ^
      partialImageLoadingDelay.hashCode;
}
