import 'package:flutter/widgets.dart';
import 'support/local_acceptance_harness.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final harness = AcceptanceHarness(LocalFixtureConfig.fromEnvironment());
  runApp(AcceptanceHost(harness: harness, showFixtureBanner: true));
}
