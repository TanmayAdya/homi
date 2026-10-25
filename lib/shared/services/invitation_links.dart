import 'dart:async';
import 'package:flutter/foundation.dart';

final _invitationCode = RegExp(r'^[A-Za-z0-9_-]{43}$');

String? normalizeInvitationEmail(String value) {
  if (value.length > 254) return null;
  final email = value.trim().toLowerCase(), parts = email.split('@');
  if (parts.length != 2 ||
      parts[0].length > 64 ||
      !RegExp(r'^[a-z0-9._%+-]+$').hasMatch(parts[0]) ||
      parts[0].startsWith('.') ||
      parts[0].endsWith('.') ||
      parts[0].contains('..') ||
      !RegExp(r'^[a-z0-9-]+(?:\.[a-z0-9-]+)+$').hasMatch(parts[1]) ||
      parts[1]
          .split('.')
          .any((s) => s.length > 63 || s.startsWith('-') || s.endsWith('-'))) {
    return null;
  }
  return email;
}

String? readInvitationCode(String input, Uri apiOrigin) {
  final text = input.trim();
  if (_invitationCode.hasMatch(text)) return text;
  if (text.length > 2048) return null;
  final uri = Uri.tryParse(text);
  if (uri == null || uri.userInfo.isNotEmpty || uri.hasQuery || uri.hasPort) {
    return null;
  }
  final landing =
      uri.scheme == 'https' &&
      uri.origin == apiOrigin.origin &&
      uri.path == '/invite';
  final app =
      uri.scheme == 'safeathome' && uri.host == 'invite' && uri.path.isEmpty;
  if (!landing && !app) return null;
  final match = RegExp(r'^code=([A-Za-z0-9_-]{43})$').firstMatch(uri.fragment);
  return match != null && text.endsWith('#code=${match[1]}') ? match[1] : null;
}

Uri invitationLink(Uri apiOrigin, String code) {
  if (!_invitationCode.hasMatch(code)) throw const FormatException();
  return apiOrigin.replace(path: '/invite', fragment: 'code=$code');
}

class InvitationLinkInbox extends ValueNotifier<String?> {
  InvitationLinkInbox() : super(null);
  Timer? _expiry;
  bool _closed = false;
  void receive(Uri uri, Uri origin) {
    if (_closed) return;
    final code = readInvitationCode(uri.toString(), origin);
    if (code == null) return;
    _expiry?.cancel();
    value = code;
    _expiry = Timer(const Duration(minutes: 10), clear);
  }

  String? take() {
    final code = value;
    clear();
    return code;
  }

  void clear() {
    if (_closed) return;
    _expiry?.cancel();
    value = null;
  }

  @override
  void dispose() {
    clear();
    _closed = true;
    super.dispose();
  }
}
