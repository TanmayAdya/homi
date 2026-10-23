import 'dart:convert';

import 'package:flutter/services.dart';

import '../models/contracts.dart';

abstract interface class DemoScenarioService {
  Future<List<DemoScenario>> loadScenarios();
}

class AssetDemoScenarioService implements DemoScenarioService {
  AssetDemoScenarioService({AssetBundle? bundle})
    : _bundle = bundle ?? rootBundle;

  static const assetPath = 'contracts/v1/fixtures/scenarios.json';
  final AssetBundle _bundle;

  @override
  Future<List<DemoScenario>> loadScenarios() async {
    final json = await _bundle.loadString(assetPath);
    return parseDemoScenarios(jsonDecode(json));
  }
}
