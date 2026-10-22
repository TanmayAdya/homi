import 'package:flutter/material.dart';

import '../features/programs/demo_programs_screen.dart';
import '../shared/services/demo_scenario_service.dart';
import '../shared/services/packet_preparation_service.dart';

class SafeAtHomeApp extends StatelessWidget {
  const SafeAtHomeApp({super.key, this.scenarioService, this.packetService});

  final DemoScenarioService? scenarioService;
  final PacketPreparationService? packetService;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Safe at Home',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF176456)),
        scaffoldBackgroundColor: const Color(0xFFF7F9F7),
        useMaterial3: true,
      ),
      home: DemoProgramsScreen(
        service: scenarioService ?? AssetDemoScenarioService(),
        packetService: packetService ?? AssetDemoPacketService(),
      ),
    );
  }
}
