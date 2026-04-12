import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../constants.dart';

class PlantieDeviceState {
  const PlantieDeviceState({
    required this.id,
    this.name,
    this.alias,
    this.device,
    this.isNearby = false,
    this.isConnecting = false,
    this.isConnected = false,
    this.lastReading,
    this.moistureValue,
    this.lastUpdated,
    this.error,
    this.rssi,
    this.wetThreshold = 50,
    this.dryThreshold = 30,
    this.thirstAlertActive = false,
    this.thirstDismissed = false,
    this.hasCrossedWetReset = false,
    this.hasCrossedDryReset = true,
    this.hasTriggeredDryAlert = false,
    this.snoozedUntil,
    this.customThirstMessages = const <String>[],
    this.reminderDurationMinutes = 30,
  });

  factory PlantieDeviceState.fromStorage(String id, Map<String, dynamic> map) {
    return PlantieDeviceState(
      id: id,
      alias: map['alias'] as String?,
      name: map['name'] as String?,
      wetThreshold: (map['wetThreshold'] as num?)?.toInt() ?? 50,
      dryThreshold: (map['dryThreshold'] as num?)?.toInt() ?? 30,
      thirstAlertActive: map['thirstAlertActive'] as bool? ?? false,
      thirstDismissed: map['thirstDismissed'] as bool? ?? false,
      hasCrossedWetReset: map['hasCrossedWetReset'] as bool? ?? false,
      hasCrossedDryReset: map['hasCrossedDryReset'] as bool? ?? true,
      hasTriggeredDryAlert: map['hasTriggeredDryAlert'] as bool? ?? false,
      snoozedUntil: map['snoozedUntilMs'] == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(
              (map['snoozedUntilMs'] as num).toInt(),
            ),
      customThirstMessages: (map['customThirstMessages'] as List?)?.cast<String>() ?? const <String>[],
      reminderDurationMinutes: (map['reminderDurationMinutes'] as num?)?.toInt() ?? 30,
    );
  }

  final String id;
  final String? name;
  final String? alias;
  final BluetoothDevice? device;
  final bool isNearby;
  final bool isConnecting;
  final bool isConnected;
  final int? lastReading;
  final int? moistureValue;
  final DateTime? lastUpdated;
  final String? error;
  final int? rssi;
  final int wetThreshold;
  final int dryThreshold;
  final bool thirstAlertActive;
  final bool thirstDismissed;
  final bool hasCrossedWetReset;
  final bool hasCrossedDryReset;
  final bool hasTriggeredDryAlert;
  final DateTime? snoozedUntil;
  final List<String> customThirstMessages;
  final int reminderDurationMinutes;

  String get displayName {
    final trimmedAlias = alias?.trim();
    if (trimmedAlias != null && trimmedAlias.isNotEmpty) {
      return trimmedAlias;
    }

    return name ?? 'Plantie $id';
  }

  String get alertLabel {
    if (thirstAlertActive) {
      return 'Thirsty';
    }
    if (snoozedUntil != null) {
      return 'Reminder snoozed';
    }
    if (thirstDismissed) {
      return 'Reminder dismissed';
    }
    return 'Monitoring';
  }

  bool get showAlertActions => thirstAlertActive;

  bool get seemsConnected {
    if (isConnected) {
      return true;
    }

    final updated = lastUpdated;
    if (updated == null) {
      return false;
    }

    return DateTime.now().difference(updated) <= connectedGracePeriod;
  }

  Map<String, dynamic> toStorage() {
    return <String, dynamic>{
      'alias': alias,
      'name': name,
      'wetThreshold': wetThreshold,
      'dryThreshold': dryThreshold,
      'thirstAlertActive': thirstAlertActive,
      'thirstDismissed': thirstDismissed,
      'hasCrossedWetReset': hasCrossedWetReset,
      'hasCrossedDryReset': hasCrossedDryReset,
      'hasTriggeredDryAlert': hasTriggeredDryAlert,
      'snoozedUntilMs': snoozedUntil?.millisecondsSinceEpoch,
      'customThirstMessages': customThirstMessages,
      'reminderDurationMinutes': reminderDurationMinutes,
    };
  }

  Map<String, dynamic> toServiceState() {
    return <String, dynamic>{
      'id': id,
      'name': name,
      'alias': alias,
      'isNearby': isNearby,
      'isConnecting': isConnecting,
      'isConnected': isConnected,
      'lastReading': lastReading,
      'moistureValue': moistureValue,
      'lastUpdatedMs': lastUpdated?.millisecondsSinceEpoch,
      'error': error,
      'rssi': rssi,
      'wetThreshold': wetThreshold,
      'dryThreshold': dryThreshold,
      'thirstAlertActive': thirstAlertActive,
      'thirstDismissed': thirstDismissed,
      'hasCrossedWetReset': hasCrossedWetReset,
      'hasCrossedDryReset': hasCrossedDryReset,
      'hasTriggeredDryAlert': hasTriggeredDryAlert,
      'snoozedUntilMs': snoozedUntil?.millisecondsSinceEpoch,
      'customThirstMessages': customThirstMessages,
      'reminderDurationMinutes': reminderDurationMinutes,
    };
  }

  PlantieDeviceState mergeServiceState(Map<dynamic, dynamic> map) {
    return copyWith(
      name: map['name'] as String?,
      alias: map['alias'] as String?,
      isNearby: map['isNearby'] as bool? ?? isNearby,
      isConnecting: map['isConnecting'] as bool? ?? isConnecting,
      isConnected: map['isConnected'] as bool? ?? isConnected,
      lastReading: (map['lastReading'] as num?)?.toInt() ?? lastReading,
      moistureValue: (map['moistureValue'] as num?)?.toInt() ?? moistureValue,
      lastUpdated: map['lastUpdatedMs'] == null
          ? lastUpdated
          : DateTime.fromMillisecondsSinceEpoch(
              (map['lastUpdatedMs'] as num).toInt(),
            ),
      error: map.containsKey('error') ? map['error'] as String? : error,
      rssi: (map['rssi'] as num?)?.toInt() ?? rssi,
      wetThreshold: (map['wetThreshold'] as num?)?.toInt() ?? wetThreshold,
      dryThreshold: (map['dryThreshold'] as num?)?.toInt() ?? dryThreshold,
      thirstAlertActive: map['thirstAlertActive'] as bool? ?? thirstAlertActive,
      thirstDismissed: map['thirstDismissed'] as bool? ?? thirstDismissed,
      hasCrossedWetReset:
          map['hasCrossedWetReset'] as bool? ?? hasCrossedWetReset,
      hasCrossedDryReset:
          map['hasCrossedDryReset'] as bool? ?? hasCrossedDryReset,
      hasTriggeredDryAlert:
          map['hasTriggeredDryAlert'] as bool? ?? hasTriggeredDryAlert,
      snoozedUntil: map['snoozedUntilMs'] == null
          ? snoozedUntil
          : DateTime.fromMillisecondsSinceEpoch(
              (map['snoozedUntilMs'] as num).toInt(),
            ),
      customThirstMessages: (map['customThirstMessages'] as List?)?.cast<String>() ?? customThirstMessages,
      reminderDurationMinutes: (map['reminderDurationMinutes'] as num?)?.toInt() ?? reminderDurationMinutes,
    );
  }

  PlantieDeviceState copyWith({
    Object? name = unset,
    Object? alias = unset,
    BluetoothDevice? device,
    bool? isNearby,
    bool? isConnecting,
    bool? isConnected,
    int? lastReading,
    int? moistureValue,
    DateTime? lastUpdated,
    Object? error = unset,
    Object? rssi = unset,
    int? wetThreshold,
    int? dryThreshold,
    bool? thirstAlertActive,
    bool? thirstDismissed,
    bool? hasCrossedWetReset,
    bool? hasCrossedDryReset,
    bool? hasTriggeredDryAlert,
    Object? snoozedUntil = unset,
    List<String>? customThirstMessages,
    int? reminderDurationMinutes,
  }) {
    return PlantieDeviceState(
      id: id,
      name: identical(name, unset) ? this.name : name as String?,
      alias: identical(alias, unset) ? this.alias : alias as String?,
      device: device ?? this.device,
      isNearby: isNearby ?? this.isNearby,
      isConnecting: isConnecting ?? this.isConnecting,
      isConnected: isConnected ?? this.isConnected,
      lastReading: lastReading ?? this.lastReading,
      moistureValue: moistureValue ?? this.moistureValue,
      lastUpdated: lastUpdated ?? this.lastUpdated,
      error: identical(error, unset) ? this.error : error as String?,
      rssi: identical(rssi, unset) ? this.rssi : rssi as int?,
      wetThreshold: wetThreshold ?? this.wetThreshold,
      dryThreshold: dryThreshold ?? this.dryThreshold,
      thirstAlertActive: thirstAlertActive ?? this.thirstAlertActive,
      thirstDismissed: thirstDismissed ?? this.thirstDismissed,
      hasCrossedWetReset: hasCrossedWetReset ?? this.hasCrossedWetReset,
      hasCrossedDryReset: hasCrossedDryReset ?? this.hasCrossedDryReset,
      hasTriggeredDryAlert: hasTriggeredDryAlert ?? this.hasTriggeredDryAlert,
      snoozedUntil: identical(snoozedUntil, unset)
          ? this.snoozedUntil
          : snoozedUntil as DateTime?,
      customThirstMessages: customThirstMessages ?? this.customThirstMessages,
      reminderDurationMinutes: reminderDurationMinutes ?? this.reminderDurationMinutes,
    );
  }
}
