import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdfrx_engine/pdfrx_engine.dart';

final isApple = Platform.isMacOS || Platform.isIOS;
final isAndroid = Platform.isAndroid;
final isWindows = Platform.isWindows;

final isMobile = Platform.isAndroid || Platform.isIOS || Platform.isFuchsia;

bool get isCommandKeyPressed =>
    isApple ? HardwareKeyboard.instance.isMetaPressed : HardwareKeyboard.instance.isControlPressed;

void setClipboardData(String text) {
  Clipboard.setData(ClipboardData(text: text));
}

Future<String> getCacheDirectory() async => (await getTemporaryDirectory()).path;

PdfrxEntryFunctions? get pdfrxEntryFunctionsOverride => null;

Future<void> platformInitialize() async {
  await PdfrxEntryFunctions.instance.init();
}

void focusReportForPreventingContextMenuWeb(Object viewer, bool hasFocus) {}
