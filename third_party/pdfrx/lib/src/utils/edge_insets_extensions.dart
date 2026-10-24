import 'package:flutter/material.dart';

extension EdgeInsetsExtensions on EdgeInsets {
  bool get containsInfinite => left.isInfinite || right.isInfinite || top.isInfinite || bottom.isInfinite;

  Rect inflateRectIfFinite(Rect rect) {
    if (containsInfinite) return rect;
    return inflateRect(rect);
  }
}
