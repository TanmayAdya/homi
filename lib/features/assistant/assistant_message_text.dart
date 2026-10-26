import 'package:flutter/material.dart';

TextSpan assistantMessageText(String text) {
  final normalized = text.replaceAllMapped(
    RegExp(r'^\s*[-*] (?=\S)', multiLine: true),
    (_) => '• ',
  );
  final spans = <InlineSpan>[];
  var end = 0;
  for (final match in RegExp(r'\*\*([^\n]+?)\*\*').allMatches(normalized)) {
    if (match.start > end) {
      spans.add(TextSpan(text: normalized.substring(end, match.start)));
    }
    spans.add(
      TextSpan(
        text: match.group(1),
        style: const TextStyle(fontWeight: FontWeight.w600),
      ),
    );
    end = match.end;
  }
  spans.add(TextSpan(text: normalized.substring(end)));
  return TextSpan(children: spans);
}
