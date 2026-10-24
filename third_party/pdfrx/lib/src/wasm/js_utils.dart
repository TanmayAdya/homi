import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:web/web.dart' as web;

bool _determineWhetherSharedArrayBufferSupportedOrNot() {
  try {
    return web.window.hasProperty('SharedArrayBuffer'.toJS).toDart;
  } catch (e) {
    return false;
  }
}

final bool isSharedArrayBufferSupported = _determineWhetherSharedArrayBufferSupportedOrNot();
