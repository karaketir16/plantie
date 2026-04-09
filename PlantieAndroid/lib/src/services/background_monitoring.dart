import 'dart:async';
import 'dart:ui';

import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter/widgets.dart';

import '../constants.dart';
import '../models/plantie_device_state.dart';
import 'plantie_notifications.dart';
import 'plantie_storage.dart';

Future<void> initializeBackgroundMonitoring() async {
  final notifications = FlutterLocalNotificationsPlugin();

  const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
  const settings = InitializationSettings(android: androidSettings);

  await notifications.initialize(
    settings,
    onDidReceiveBackgroundNotificationResponse: notificationTapBackground,
  );

  final androidPlugin = notifications
      .resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin
      >();

  await androidPlugin?.createNotificationChannel(
    const AndroidNotificationChannel(
      alertChannelId,
      alertChannelName,
      description:
          'Watering reminders and recovery messages for Plantie sensors',
      importance: Importance.high,
    ),
  );

  await androidPlugin?.createNotificationChannel(
    const AndroidNotificationChannel(
      monitorChannelId,
      monitorChannelName,
      description: 'Foreground service for background plant monitoring',
      importance: Importance.low,
    ),
  );

  final service = FlutterBackgroundService();
  await service.configure(
    iosConfiguration: IosConfiguration(
      autoStart: false,
      onForeground: backgroundMonitoringStart,
      onBackground: unsupportedIosBackground,
    ),
    androidConfiguration: AndroidConfiguration(
      onStart: backgroundMonitoringStart,
      autoStart: false,
      autoStartOnBoot: true,
      isForegroundMode: true,
      notificationChannelId: monitorChannelId,
      initialNotificationTitle: 'Plantie monitoring',
      initialNotificationContent: 'Preparing plant monitors',
      foregroundServiceNotificationId: foregroundServiceNotificationId,
      foregroundServiceTypes: const [AndroidForegroundType.connectedDevice],
    ),
  );
}

@pragma('vm:entry-point')
Future<bool> unsupportedIosBackground(ServiceInstance service) async => true;

@pragma('vm:entry-point')
Future<void> notificationTapBackground(NotificationResponse response) async {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();
  final devices = await loadStoredDevices();
  final payload = resolveNotificationDeviceId(
    devices,
    payload: response.payload,
    notificationId: response.id,
  );
  if (payload == null) {
    return;
  }

  final current = devices[payload];
  if (current == null) {
    return;
  }

  final notifications = FlutterLocalNotificationsPlugin();
  const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
  const settings = InitializationSettings(android: androidSettings);
  await notifications.initialize(settings);

  PlantieDeviceState updated = current;
  if (response.actionId == alertSnoozeActionId) {
    updated = current.copyWith(
      thirstAlertActive: false,
      thirstDismissed: false,
      snoozedUntil: DateTime.now().add(
        const Duration(minutes: reminderDurationMinutes),
      ),
    );
  } else if (response.actionId == alertDismissActionId) {
    updated = current.copyWith(
      thirstAlertActive: false,
      thirstDismissed: true,
      snoozedUntil: null,
    );
  } else {
    return;
  }

  devices[payload] = updated;
  await notifications.cancel(response.id ?? thirstNotificationIdFor(payload));
  await saveStoredDevices(devices);
}

@pragma('vm:entry-point')
Future<void> backgroundMonitoringStart(ServiceInstance service) async {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();

  final monitor = PlantieBackgroundMonitor(service);
  await monitor.start();
}

class PlantieBackgroundMonitor {
  PlantieBackgroundMonitor(this.service);

  final ServiceInstance service;
  final FlutterLocalNotificationsPlugin notifications =
      FlutterLocalNotificationsPlugin();
  final Map<String, PlantieDeviceState> devices = {};
  final Map<String, BluetoothDevice> btDevices = {};
  final Map<String, StreamSubscription<BluetoothConnectionState>>
  connectionSubscriptions = {};
  final Map<String, StreamSubscription<List<int>>> valueSubscriptions = {};
  final Set<String> settingUpIds = <String>{};
  Timer? refreshTimer;

  Future<void> start() async {
    const androidSettings = AndroidInitializationSettings(
      '@mipmap/ic_launcher',
    );
    const settings = InitializationSettings(android: androidSettings);
    await notifications.initialize(
      settings,
      onDidReceiveBackgroundNotificationResponse: notificationTapBackground,
    );

    if (service is AndroidServiceInstance) {
      await (service as AndroidServiceInstance).setAsForegroundService();
    }

    await reloadConfigs();
    await refreshForegroundNotification();

    service.on('refresh-config').listen((_) async {
      await reloadConfigs();
      await reconcileNotifications();
      await refreshForegroundNotification();
    });

    service.on('stopService').listen((_) async {
      await stop();
    });

    refreshTimer?.cancel();
    refreshTimer = Timer.periodic(backgroundRefreshInterval, (_) async {
      await reloadConfigs();
      await reconcileNotifications();
      await refreshForegroundNotification();
    });
  }

  Future<void> stop() async {
    refreshTimer?.cancel();
    for (final sub in connectionSubscriptions.values) {
      await sub.cancel();
    }
    for (final sub in valueSubscriptions.values) {
      await sub.cancel();
    }
    await service.stopSelf();
  }

  Future<void> reloadConfigs() async {
    final latest = await loadStoredDevices();

    final removedIds = devices.keys.toSet().difference(latest.keys.toSet());
    for (final id in removedIds) {
      await connectionSubscriptions.remove(id)?.cancel();
      await valueSubscriptions.remove(id)?.cancel();
      btDevices.remove(id);
      await notifications.cancel(thirstNotificationIdFor(id));
      await notifications.cancel(thanksNotificationIdFor(id));
    }

    devices
      ..clear()
      ..addAll(latest);

    if (devices.isEmpty) {
      await stop();
      return;
    }

    for (final id in devices.keys) {
      await ensureConnected(id);
    }
    await reconcileNotifications();
    broadcastSnapshot();
  }

  Future<void> ensureConnected(String id) async {
    final device = btDevices.putIfAbsent(id, () => BluetoothDevice.fromId(id));
    final current = devices[id];
    if (current != null) {
      devices[id] = current.copyWith(isConnecting: true, error: null);
    }
    broadcastSnapshot();

    connectionSubscriptions[id] ??= device.connectionState.listen((
      state,
    ) async {
      final current = devices[id];
      if (current != null) {
        devices[id] = current.copyWith(
          isConnected: state == BluetoothConnectionState.connected,
          isConnecting: false,
          error: state == BluetoothConnectionState.disconnected
              ? null
              : current.error,
        );
        broadcastSnapshot();
      }

      if (state == BluetoothConnectionState.connected) {
        await setupConnectedDevice(id, device);
      }
    });

    if (device.isConnected || settingUpIds.contains(id)) {
      return;
    }

    try {
      await device.connect(autoConnect: true, mtu: null);
    } catch (_) {
      final current = devices[id];
      if (current != null) {
        devices[id] = current.copyWith(isConnecting: false);
        broadcastSnapshot();
      }
    }
  }

  Future<void> setupConnectedDevice(String id, BluetoothDevice device) async {
    if (settingUpIds.contains(id)) {
      return;
    }
    settingUpIds.add(id);

    try {
      final services = await device.discoverServices();
      final characteristic = findReadingCharacteristic(services);
      if (characteristic == null) {
        final current = devices[id];
        if (current != null) {
          devices[id] = current.copyWith(
            error: 'Plantie reading characteristic not found.',
            isConnecting: false,
          );
          broadcastSnapshot();
        }
        return;
      }

      await characteristic.setNotifyValue(true);
      await valueSubscriptions.remove(id)?.cancel();
      valueSubscriptions[id] = characteristic.onValueReceived.listen((value) {
        if (value.length < 2) {
          return;
        }
        final reading = value[0] | (value[1] << 8);
        handleReading(id, reading);
      });

      final latestValue = await characteristic.read();
      if (latestValue.length >= 2) {
        final reading = latestValue[0] | (latestValue[1] << 8);
        await handleReading(id, reading);
      }
    } finally {
      settingUpIds.remove(id);
    }
  }

  BluetoothCharacteristic? findReadingCharacteristic(
    List<BluetoothService> services,
  ) {
    for (final service in services) {
      if (service.uuid != plantieServiceUuid) {
        continue;
      }
      for (final characteristic in service.characteristics) {
        if (characteristic.uuid == plantieReadingCharacteristicUuid) {
          return characteristic;
        }
      }
    }
    return null;
  }

  Future<void> handleReading(String id, int rawReading) async {
    final current = devices[id];
    if (current == null) {
      return;
    }

    var next = current.copyWith(
      lastReading: rawReading,
      moistureValue: mapRawReadingToMoisture(rawReading),
      lastUpdated: DateTime.now(),
      isConnected: true,
      isConnecting: false,
      error: null,
    );

    next = await evaluateAlerts(next);
    devices[id] = await _mergeRuntimeDeviceState(next);
    await _persistDevicesPreservingConfig();
    await refreshForegroundNotification();
    broadcastSnapshot();
  }

  Future<PlantieDeviceState> _mergeRuntimeDeviceState(
    PlantieDeviceState runtime,
  ) async {
    final latestStored = await loadStoredDevices();
    final persisted = latestStored[runtime.id];
    if (persisted == null) {
      return runtime;
    }

    return persisted.copyWith(
      name: runtime.name ?? persisted.name,
      device: runtime.device,
      isNearby: runtime.isNearby,
      isConnecting: runtime.isConnecting,
      isConnected: runtime.isConnected,
      lastReading: runtime.lastReading,
      moistureValue: runtime.moistureValue,
      lastUpdated: runtime.lastUpdated,
      error: runtime.error,
      rssi: runtime.rssi,
      thirstAlertActive: runtime.thirstAlertActive,
      thirstDismissed: runtime.thirstDismissed,
      hasCrossedWetReset: runtime.hasCrossedWetReset,
      hasCrossedDryReset: runtime.hasCrossedDryReset,
      hasTriggeredDryAlert: runtime.hasTriggeredDryAlert,
      snoozedUntil: runtime.snoozedUntil,
    );
  }

  Future<void> _persistDevicesPreservingConfig() async {
    final latestStored = await loadStoredDevices();
    final merged = <String, PlantieDeviceState>{...latestStored};

    for (final entry in devices.entries) {
      final persisted = latestStored[entry.key];
      merged[entry.key] = persisted == null
          ? entry.value
          : persisted.copyWith(
              name: entry.value.name ?? persisted.name,
              device: entry.value.device,
              isNearby: entry.value.isNearby,
              isConnecting: entry.value.isConnecting,
              isConnected: entry.value.isConnected,
              lastReading: entry.value.lastReading,
              moistureValue: entry.value.moistureValue,
              lastUpdated: entry.value.lastUpdated,
              error: entry.value.error,
              rssi: entry.value.rssi,
              thirstAlertActive: entry.value.thirstAlertActive,
              thirstDismissed: entry.value.thirstDismissed,
              hasCrossedWetReset: entry.value.hasCrossedWetReset,
              hasCrossedDryReset: entry.value.hasCrossedDryReset,
              hasTriggeredDryAlert: entry.value.hasTriggeredDryAlert,
              snoozedUntil: entry.value.snoozedUntil,
            );
    }

    devices
      ..clear()
      ..addAll(merged);
    await saveStoredDevices(merged);
  }

  Future<PlantieDeviceState> evaluateAlerts(PlantieDeviceState device) async {
    if (device.moistureValue == null) {
      return device;
    }

    var next = device;
    final moisture = device.moistureValue!;
    final now = DateTime.now();
    final snoozeExpired =
        next.snoozedUntil != null && !next.snoozedUntil!.isAfter(now);

    if (snoozeExpired) {
      next = next.copyWith(
        snoozedUntil: null,
        thirstDismissed: false,
        hasCrossedDryReset: true,
      );
    }

    if (moisture > next.wetThreshold + 5) {
      next = next.copyWith(hasCrossedWetReset: true);
    }

    if (moisture <= next.dryThreshold - 5) {
      if (next.thirstAlertActive ||
          next.thirstDismissed ||
          next.snoozedUntil != null) {
        await notifications.cancel(thirstNotificationIdFor(next.id));
      }
      next = next.copyWith(
        thirstAlertActive: false,
        thirstDismissed: false,
        snoozedUntil: null,
        hasCrossedDryReset: true,
      );
    }

    if (moisture > next.dryThreshold) {
      if (!next.thirstDismissed &&
          next.snoozedUntil == null &&
          !next.thirstAlertActive &&
          next.hasCrossedDryReset) {
        next = next.copyWith(
          thirstAlertActive: true,
          hasCrossedDryReset: false,
          hasTriggeredDryAlert: true,
        );
        await showThirstyNotification(next);
      }
    } else if (moisture <= next.wetThreshold && next.hasCrossedWetReset) {
      if (next.hasTriggeredDryAlert || next.moistureValue != null) {
        await showThanksNotification(next);
      }
      await notifications.cancel(thirstNotificationIdFor(next.id));
      next = next.copyWith(
        thirstAlertActive: false,
        thirstDismissed: false,
        snoozedUntil: null,
        hasCrossedWetReset: false,
        hasCrossedDryReset: true,
        hasTriggeredDryAlert: false,
      );
    }

    return next;
  }

  Future<void> reconcileNotifications() async {
    for (final device in devices.values) {
      if (!device.thirstAlertActive) {
        await notifications.cancel(thirstNotificationIdFor(device.id));
      }
    }
  }

  void broadcastSnapshot() {
    service.invoke('device-sync', <String, dynamic>{
      'devices': devices.values
          .map((device) => device.toServiceState())
          .toList(),
    });
  }

  Future<void> showThirstyNotification(PlantieDeviceState device) async {
    final androidDetails = AndroidNotificationDetails(
      alertChannelId,
      alertChannelName,
      channelDescription:
          'Watering reminders and recovery messages for Plantie sensors',
      importance: Importance.high,
      priority: Priority.high,
      actions: const <AndroidNotificationAction>[
        AndroidNotificationAction(
          alertSnoozeActionId,
          'Remind in 1 minute',
          cancelNotification: true,
        ),
        AndroidNotificationAction(
          alertDismissActionId,
          'Dismiss',
          cancelNotification: true,
        ),
      ],
    );

    await notifications.show(
      thirstNotificationIdFor(device.id),
      device.displayName,
      'I am thirsty',
      NotificationDetails(android: androidDetails),
      payload: device.id,
    );
  }

  Future<void> showThanksNotification(PlantieDeviceState device) async {
    const androidDetails = AndroidNotificationDetails(
      alertChannelId,
      alertChannelName,
      channelDescription:
          'Watering reminders and recovery messages for Plantie sensors',
      importance: Importance.high,
      priority: Priority.high,
    );

    await notifications.show(
      thanksNotificationIdFor(device.id),
      device.displayName,
      'Thanks',
      const NotificationDetails(android: androidDetails),
      payload: device.id,
    );
  }

  Future<void> refreshForegroundNotification() async {
    if (service is! AndroidServiceInstance) {
      return;
    }
    final active = devices.length;
    final connected = btDevices.values
        .where((device) => device.isConnected)
        .length;
    await (service as AndroidServiceInstance).setForegroundNotificationInfo(
      title: 'Plantie monitoring',
      content: '$connected connected, $active saved device(s)',
    );
  }
}
