import 'package:flutter/material.dart';
import 'app/live_app.dart';
import 'app/safe_at_home_app.dart';
import 'app/theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  const live = bool.fromEnvironment('SAH_LIVE_BACKEND');
  runApp(live ? const LiveAppBootstrap() : const _DemoEntry());
}

class _DemoEntry extends StatelessWidget {
  const _DemoEntry();
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Safe at Home',
    theme: SafeAtHomeTheme.light(),
    debugShowCheckedModeBanner: false,
    home: Scaffold(
      appBar: AppBar(title: const Text('Safe at Home')),
      body: SafeArea(
        child: Builder(
          builder: (context) => ListView(
            padding: const EdgeInsets.all(24),
            children: [
              const Text(
                'Fictional demonstration',
                style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 16),
              const Text(
                'Live account access is not enabled in this build. The examples below use bundled fictional information and do not send data to a server.',
              ),
              const SizedBox(height: 24),
              FilledButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const SafeAtHomeApp(),
                  ),
                ),
                child: const Text('Open fictional examples'),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
