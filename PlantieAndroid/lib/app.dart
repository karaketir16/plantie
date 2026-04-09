import 'package:flutter/material.dart';

import 'src/pages/device_dashboard_page.dart';

class PlantieApp extends StatelessWidget {
  const PlantieApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Plantie Android',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF1C7C54),
          surface: const Color(0xFFF3F7F1),
        ),
        scaffoldBackgroundColor: const Color(0xFFF3F7F1),
      ),
      home: const DeviceDashboardPage(),
    );
  }
}
