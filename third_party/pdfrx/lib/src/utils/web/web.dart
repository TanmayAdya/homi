import 'dart:js_interop';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pdfrx_engine/pdfrx_engine.dart';
import 'package:web/web.dart' as web;

import '../../wasm/pdfrx_wasm.dart';

final isApple = false;
final isAndroid = false;
final isWindows = false;

final isMobile = false;

bool get isCommandKeyPressed => HardwareKeyboard.instance.isMetaPressed || HardwareKeyboard.instance.isControlPressed;

void setClipboardData(String text) {
  web.window.navigator.clipboard.writeText(text);
}

Future<String> getCacheDirectory() async => throw UnimplementedError('No temporary directory available for web.');

PdfrxEntryFunctions? get pdfrxEntryFunctionsOverride => _factoryWasm;

final _factoryWasm = PdfrxEntryFunctionsWasmImpl();

final _focusObject = <Object>{};

Future<void> platformInitialize() async {
  web.document.addEventListener(
    'contextmenu',
    ((web.Event event) {
      if (_focusObject.isNotEmpty) {
        debugPrint('pdfrx: Context menu event prevented because PdfViewer has focus.');
        event.preventDefault();
      } else {
        debugPrint('pdfrx: Context menu event allowed.');
      }
    }).toJS,
  );
  await PdfrxEntryFunctions.instance.init();
}

void focusReportForPreventingContextMenuWeb(Object viewer, bool hasFocus) {
  if (hasFocus) {
    _focusObject.add(viewer);
  } else {
    _focusObject.remove(viewer);
  }
}
