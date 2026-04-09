import 'package:flutter/widgets.dart';

import 'app.dart';
import 'src/services/background_monitoring.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeBackgroundMonitoring();
  runApp(const PlantieApp());
}
