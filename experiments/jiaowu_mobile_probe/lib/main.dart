import 'package:flutter/material.dart';

import 'src/jiaowu_gateway.dart';
import 'src/mobile_probe_screen.dart';
import 'src/probe_controller.dart';

void main() {
  final controller = ProbeController(JiaowuClientGateway());
  runApp(MobileProbeApp(controller: controller));
}

final class MobileProbeApp extends StatelessWidget {
  const MobileProbeApp({required this.controller, super.key});

  final ProbeController controller;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '教务移动探针',
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF147C72),
          brightness: Brightness.light,
        ),
        scaffoldBackgroundColor: const Color(0xFFFFFAF4),
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF55C7B9),
          brightness: Brightness.dark,
        ),
      ),
      themeMode: ThemeMode.system,
      home: MobileProbeScreen(controller: controller),
    );
  }
}
