import 'dart:math' as math;

import 'package:flutter/material.dart';
import '../../app/theme.dart';
import 'package:safe_at_home/l10n/app_localizations.dart';

import 'profile_suggestions.dart';

class ProfileSuggestionField extends StatefulWidget {
  const ProfileSuggestionField({
    super.key,
    required this.field,
    required this.controller,
    required this.focusNode,
    required this.enabled,
    required this.onSelected,
    required this.child,
  });

  final String field;
  final TextEditingController controller;
  final FocusNode focusNode;
  final bool enabled;
  final ValueChanged<ProfileSuggestion> onSelected;
  final Widget child;

  @override
  State<ProfileSuggestionField> createState() => _ProfileSuggestionFieldState();
}

class _ProfileSuggestionFieldState extends State<ProfileSuggestionField> {
  final _groupFocus = FocusNode(canRequestFocus: false);
  final _overlay = OverlayPortalController();
  String? _dismissedQuery;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_refresh);
    _groupFocus.addListener(_refresh);
  }

  @override
  void didUpdateWidget(ProfileSuggestionField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_refresh);
      widget.controller.addListener(_refresh);
    }
    if (oldWidget.enabled != widget.enabled) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _refresh();
      });
    }
  }

  void _refresh() {
    if (!mounted) return;
    final query = widget.controller.text;
    if (query != _dismissedQuery) _dismissedQuery = null;
    final show =
        widget.enabled &&
        _groupFocus.hasFocus &&
        query.trim().isNotEmpty &&
        query != _dismissedQuery &&
        profileSuggestions(widget.field, query).isNotEmpty;
    if (show) {
      _overlay.show();
    } else {
      _overlay.hide();
    }
    setState(() {});
  }

  @override
  void dispose() {
    widget.controller.removeListener(_refresh);
    _groupFocus.removeListener(_refresh);
    _groupFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Focus(
    focusNode: _groupFocus,
    child: TextFieldTapRegion(
      child: OverlayPortal.overlayChildLayoutBuilder(
        controller: _overlay,
        overlayChildBuilder: _suggestions,
        child: widget.child,
      ),
    ),
  );

  Widget _suggestions(BuildContext context, OverlayChildLayoutInfo layout) {
    if (layout.childPaintTransform.determinant() == 0 || !widget.enabled) {
      return const SizedBox.shrink();
    }
    final suggestions = profileSuggestions(
      widget.field,
      widget.controller.text,
    );
    final field = MatrixUtils.transformRect(
      layout.childPaintTransform,
      Offset.zero & layout.childSize,
    );
    final input = widget.focusNode.context?.findRenderObject();
    final overlay = Overlay.of(this.context).context.findRenderObject();
    final inputRect =
        input is RenderBox && input.hasSize && overlay is RenderBox
        ? MatrixUtils.transformRect(
            input.getTransformTo(overlay),
            Offset.zero & input.size,
          ).inflate(16)
        : field;
    final media = MediaQuery.of(context);
    final view = View.of(context);
    final keyboardInset = math.max(
      media.viewInsets.bottom,
      view.viewInsets.bottom / view.devicePixelRatio,
    );
    final viewport = Scrollable.maybeOf(
      this.context,
    )?.context.findRenderObject();
    final viewportRect =
        viewport is RenderBox && viewport.hasSize && overlay is RenderBox
        ? MatrixUtils.transformRect(
            viewport.getTransformTo(overlay),
            Offset.zero & viewport.size,
          )
        : null;
    final top = math.max(
      media.padding.top + kToolbarHeight,
      viewportRect?.top ?? 0,
    );
    final bottom = math.min(
      layout.overlaySize.height - keyboardInset,
      viewportRect?.bottom ?? layout.overlaySize.height,
    );
    if (bottom <= top || inputRect.bottom <= top || inputRect.top >= bottom) {
      return const SizedBox.shrink();
    }
    final anchorTop = inputRect.top.clamp(top, bottom);
    final anchorBottom = inputRect.bottom.clamp(top, bottom);
    final above = math.max(0.0, anchorTop - top - 8);
    final below = math.max(0.0, bottom - anchorBottom - 8);
    final opensUp = above > below;
    final height = math.min(320.0, opensUp ? above : below);
    if (height < 48 || suggestions.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Transform.translate(
      offset: Offset(
        field.left,
        opensUp ? anchorTop - height - 8 : anchorBottom + 8,
      ),
      child: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: field.width,
          height: height,
          child: TextFieldTapRegion(
            child: Align(
              alignment: opensUp ? Alignment.bottomLeft : Alignment.topLeft,
              child: Material(
                key: ValueKey('profile-suggestions-${widget.field}'),
                color: theme.colorScheme.surfaceContainerLow,
                elevation: 6,
                borderRadius: BorderRadius.circular(SahRadius.medium),
                clipBehavior: Clip.antiAlias,
                child: ListView(
                  shrinkWrap: true,
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                      child: Text(
                        context.tr('Suggestions'),
                        style: theme.textTheme.labelLarge,
                      ),
                    ),
                    for (final suggestion in suggestions)
                      TextButton(
                        key: ValueKey(
                          'profile-suggestion-${widget.field}-${suggestion.value}',
                        ),
                        style: TextButton.styleFrom(
                          alignment: Alignment.centerLeft,
                          minimumSize: const Size(48, 56),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 12,
                          ),
                        ),
                        onPressed: !widget.enabled
                            ? null
                            : () {
                                _dismissedQuery = suggestion.value;
                                _overlay.hide();
                                widget.focusNode.requestFocus();
                                widget.onSelected(suggestion);
                              },
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              widget.field == 'county'
                                  ? context.tr(suggestion.label)
                                  : suggestion.label,
                            ),
                            if (suggestion.detail != null)
                              Text(
                                {
                                      'San Mateo County',
                                      'Santa Clara County',
                                      'California',
                                    }.contains(suggestion.detail)
                                    ? context.tr(suggestion.detail!)
                                    : suggestion.detail!,
                                style: theme.textTheme.bodySmall,
                              ),
                          ],
                        ),
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
}
