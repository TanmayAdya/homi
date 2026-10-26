import 'dart:async';

import 'package:flutter/foundation.dart';

import 'bathroom_scan_adapter.dart';

class BathroomScanAvailability extends ChangeNotifier {
  BathroomScanAvailability({required this.adapter, required this.isCurrent});

  final BathroomScanAdapter adapter;
  final bool Function() isCurrent;
  BathroomScanCapabilities? capabilities;
  bool checking = false, failed = false;
  bool _disposed = false;
  int _generation = 0;
  Timer? _timeout;

  bool get prefersScan => capabilities?.canRequestCapture == true;

  void refresh() {
    if (_disposed || !isCurrent() || checking) return;
    final generation = ++_generation;
    checking = true;
    failed = false;
    notifyListeners();
    void finish(BathroomScanCapabilities? result) {
      if (_disposed || generation != _generation) return;
      _timeout?.cancel();
      _generation++;
      checking = false;
      if (!isCurrent()) return;
      capabilities = result;
      failed = result == null;
      notifyListeners();
    }

    _timeout = Timer(const Duration(seconds: 5), () => finish(null));
    Future<BathroomScanCapabilities>.sync(
      adapter.capabilities,
    ).then(finish, onError: (Object _, StackTrace _) => finish(null));
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    _timeout?.cancel();
    super.dispose();
  }
}
