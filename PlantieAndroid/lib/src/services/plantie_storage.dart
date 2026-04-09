import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../constants.dart';
import '../models/plantie_device_state.dart';

Future<Map<String, PlantieDeviceState>> loadStoredDevices() async {
  final prefs = await SharedPreferences.getInstance();
  final savedIds = prefs.getStringList(pairedDevicesKey) ?? <String>[];
  final rawConfig = prefs.getString(deviceConfigsKey);
  final decodedConfig = rawConfig == null
      ? <String, dynamic>{}
      : jsonDecode(rawConfig) as Map<String, dynamic>;

  final devices = <String, PlantieDeviceState>{};
  for (final id in savedIds) {
    final config = decodedConfig[id];
    devices[id] = PlantieDeviceState.fromStorage(
      id,
      config is Map<String, dynamic> ? config : <String, dynamic>{},
    );
  }
  return devices;
}

Future<void> saveStoredDevices(Map<String, PlantieDeviceState> devices) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setStringList(pairedDevicesKey, devices.keys.toList()..sort());
  final configs = <String, Map<String, dynamic>>{};
  for (final entry in devices.entries) {
    configs[entry.key] = entry.value.toStorage();
  }
  await prefs.setString(deviceConfigsKey, jsonEncode(configs));
}
