import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

final Guid plantieServiceUuid = Guid('12345678-1234-5678-1234-56789abc0000');
final Guid plantieReadingCharacteristicUuid = Guid(
  '12345678-1234-5678-1234-56789abc0001',
);

const String pairedDevicesKey = 'paired_device_ids';
const String deviceConfigsKey = 'device_configs';
const String alertChannelId = 'plantie_alerts';
const String alertChannelName = 'Plantie Alerts';
const String alertSnoozeActionId = 'snooze_1h';
const String alertDismissActionId = 'dismiss_alert';
const String monitorChannelId = 'plantie_monitor';
const String monitorChannelName = 'Plantie Monitor';
const Object _unset = Object();
const int reminderDurationMinutes = 1;
const int foregroundServiceNotificationId = 7001;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeBackgroundMonitoring();
  runApp(const PlantieApp());
}

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
      onBackground: _unsupportedIosBackground,
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
Future<bool> _unsupportedIosBackground(ServiceInstance service) async => true;

@pragma('vm:entry-point')
Future<void> notificationTapBackground(NotificationResponse response) async {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();
  final payload = response.payload;
  if (payload == null) {
    return;
  }

  final devices = await loadStoredDevices();
  final current = devices[payload];
  if (current == null) {
    return;
  }

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
  await saveStoredDevices(devices);
}

@pragma('vm:entry-point')
Future<void> backgroundMonitoringStart(ServiceInstance service) async {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();

  final monitor = PlantieBackgroundMonitor(service);
  await monitor.start();
}

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

int mapRawReadingToMoisture(int rawReading) =>
    ((rawReading / 4095) * 100).round().clamp(0, 100);

class PlantieBackgroundMonitor {
  PlantieBackgroundMonitor(this.service);

  final ServiceInstance service;
  final FlutterLocalNotificationsPlugin _notifications =
      FlutterLocalNotificationsPlugin();
  final Map<String, PlantieDeviceState> _devices = {};
  final Map<String, BluetoothDevice> _btDevices = {};
  final Map<String, StreamSubscription<BluetoothConnectionState>>
  _connectionSubscriptions = {};
  final Map<String, StreamSubscription<List<int>>> _valueSubscriptions = {};
  final Set<String> _settingUpIds = <String>{};
  Timer? _refreshTimer;

  Future<void> start() async {
    const androidSettings = AndroidInitializationSettings(
      '@mipmap/ic_launcher',
    );
    const settings = InitializationSettings(android: androidSettings);
    await _notifications.initialize(
      settings,
      onDidReceiveBackgroundNotificationResponse: notificationTapBackground,
    );

    if (service is AndroidServiceInstance) {
      await (service as AndroidServiceInstance).setAsForegroundService();
    }

    await _reloadConfigs();
    await _refreshForegroundNotification();

    service.on('refresh-config').listen((_) async {
      await _reloadConfigs();
      await _refreshForegroundNotification();
    });

    service.on('stopService').listen((_) async {
      await stop();
    });

    _refreshTimer?.cancel();
    _refreshTimer = Timer.periodic(const Duration(seconds: 20), (_) async {
      await _reloadConfigs();
      await _refreshForegroundNotification();
    });
  }

  Future<void> stop() async {
    _refreshTimer?.cancel();
    for (final sub in _connectionSubscriptions.values) {
      await sub.cancel();
    }
    for (final sub in _valueSubscriptions.values) {
      await sub.cancel();
    }
    await service.stopSelf();
  }

  Future<void> _reloadConfigs() async {
    final latest = await loadStoredDevices();

    final removedIds = _devices.keys.toSet().difference(latest.keys.toSet());
    for (final id in removedIds) {
      await _connectionSubscriptions.remove(id)?.cancel();
      await _valueSubscriptions.remove(id)?.cancel();
      _btDevices.remove(id);
      await _notifications.cancel(_thirstNotificationIdFor(id));
      await _notifications.cancel(_thanksNotificationIdFor(id));
    }

    _devices
      ..clear()
      ..addAll(latest);

    if (_devices.isEmpty) {
      await stop();
      return;
    }

    for (final id in _devices.keys) {
      await _ensureConnected(id);
    }
    _broadcastSnapshot();
  }

  Future<void> _ensureConnected(String id) async {
    final device = _btDevices.putIfAbsent(id, () => BluetoothDevice.fromId(id));
    final current = _devices[id];
    if (current != null) {
      _devices[id] = current.copyWith(isConnecting: true, error: null);
    }
    _broadcastSnapshot();

    _connectionSubscriptions[id] ??= device.connectionState.listen((
      state,
    ) async {
      final current = _devices[id];
      if (current != null) {
        _devices[id] = current.copyWith(
          isConnected: state == BluetoothConnectionState.connected,
          isConnecting: false,
          error: state == BluetoothConnectionState.disconnected
              ? null
              : current.error,
        );
        _broadcastSnapshot();
      }

      if (state == BluetoothConnectionState.connected) {
        await _setupConnectedDevice(id, device);
      }
    });

    if (device.isConnected || _settingUpIds.contains(id)) {
      return;
    }

    try {
      await device.connect(autoConnect: true, mtu: null);
    } catch (_) {
      // Ignore auto-connect races; plugin retries when the peripheral is seen.
      final current = _devices[id];
      if (current != null) {
        _devices[id] = current.copyWith(isConnecting: false);
        _broadcastSnapshot();
      }
    }
  }

  Future<void> _setupConnectedDevice(String id, BluetoothDevice device) async {
    if (_settingUpIds.contains(id)) {
      return;
    }
    _settingUpIds.add(id);

    try {
      final services = await device.discoverServices();
      final characteristic = _findReadingCharacteristic(services);
      if (characteristic == null) {
        final current = _devices[id];
        if (current != null) {
          _devices[id] = current.copyWith(
            error: 'Plantie reading characteristic not found.',
            isConnecting: false,
          );
          _broadcastSnapshot();
        }
        return;
      }

      await characteristic.setNotifyValue(true);
      await _valueSubscriptions.remove(id)?.cancel();
      _valueSubscriptions[id] = characteristic.onValueReceived.listen((value) {
        if (value.length < 2) {
          return;
        }
        final reading = value[0] | (value[1] << 8);
        _handleReading(id, reading);
      });

      final latestValue = await characteristic.read();
      if (latestValue.length >= 2) {
        final reading = latestValue[0] | (latestValue[1] << 8);
        await _handleReading(id, reading);
      }
    } finally {
      _settingUpIds.remove(id);
    }
  }

  BluetoothCharacteristic? _findReadingCharacteristic(
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

  Future<void> _handleReading(String id, int rawReading) async {
    final current = _devices[id];
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

    next = await _evaluateAlerts(next);
    _devices[id] = next;
    await saveStoredDevices(_devices);
    await _refreshForegroundNotification();
    _broadcastSnapshot();
  }

  Future<PlantieDeviceState> _evaluateAlerts(PlantieDeviceState device) async {
    if (device.moistureValue == null) {
      return device;
    }

    var next = device;
    final moisture = device.moistureValue!;
    final now = DateTime.now();
    final snoozeExpired =
        next.snoozedUntil != null && !next.snoozedUntil!.isAfter(now);

    if (snoozeExpired) {
      next = next.copyWith(snoozedUntil: null);
    }

    if (moisture > next.wetThreshold + 5) {
      next = next.copyWith(hasCrossedWetReset: true);
    }

    if (moisture > next.dryThreshold) {
      if (!next.thirstDismissed &&
          next.snoozedUntil == null &&
          !next.thirstAlertActive) {
        next = next.copyWith(
          thirstAlertActive: true,
          hasTriggeredDryAlert: true,
        );
        await _showThirstyNotification(next);
      }
    } else if (moisture <= next.wetThreshold && next.hasCrossedWetReset) {
      if (next.hasTriggeredDryAlert || next.moistureValue != null) {
        await _showThanksNotification(next);
      }
      await _notifications.cancel(_thirstNotificationIdFor(next.id));
      next = next.copyWith(
        thirstAlertActive: false,
        thirstDismissed: false,
        snoozedUntil: null,
        hasCrossedWetReset: false,
        hasTriggeredDryAlert: false,
      );
    }

    return next;
  }

  void _broadcastSnapshot() {
    service.invoke('device-sync', <String, dynamic>{
      'devices': _devices.values
          .map((device) => device.toServiceState())
          .toList(),
    });
  }

  Future<void> _showThirstyNotification(PlantieDeviceState device) async {
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

    await _notifications.show(
      _thirstNotificationIdFor(device.id),
      device.displayName,
      'I am thirsty',
      NotificationDetails(android: androidDetails),
      payload: device.id,
    );
  }

  Future<void> _showThanksNotification(PlantieDeviceState device) async {
    const androidDetails = AndroidNotificationDetails(
      alertChannelId,
      alertChannelName,
      channelDescription:
          'Watering reminders and recovery messages for Plantie sensors',
      importance: Importance.high,
      priority: Priority.high,
    );

    await _notifications.show(
      _thanksNotificationIdFor(device.id),
      device.displayName,
      'Thanks',
      const NotificationDetails(android: androidDetails),
      payload: device.id,
    );
  }

  Future<void> _refreshForegroundNotification() async {
    if (service is! AndroidServiceInstance) {
      return;
    }
    final active = _devices.length;
    final connected = _btDevices.values
        .where((device) => device.isConnected)
        .length;
    await (service as AndroidServiceInstance).setForegroundNotificationInfo(
      title: 'Plantie monitoring',
      content: '$connected connected, $active saved device(s)',
    );
  }
}

int _thirstNotificationIdFor(String id) => id.hashCode & 0x7fffffff;
int _thanksNotificationIdFor(String id) =>
    (id.hashCode & 0x7fffffff) ^ 0x2fffffff;

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

class DeviceDashboardPage extends StatefulWidget {
  const DeviceDashboardPage({super.key});

  @override
  State<DeviceDashboardPage> createState() => _DeviceDashboardPageState();
}

class _DeviceDashboardPageState extends State<DeviceDashboardPage> {
  final Map<String, PlantieDeviceState> _savedDevices = {};
  final Map<String, ScanResult> _scanResults = {};
  final Map<String, ScanResult> _rawScanResults = {};
  final FlutterLocalNotificationsPlugin _notifications =
      FlutterLocalNotificationsPlugin();

  StreamSubscription<List<ScanResult>>? _scanSubscription;
  StreamSubscription<bool>? _isScanningSubscription;
  StreamSubscription<Map<String, dynamic>?>? _serviceStateSubscription;

  bool _isScanning = false;
  bool _permissionsGranted = false;
  String? _statusMessage;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    await _initializeNotifications();
    await _loadSavedDevices();
    await _ensurePermissions();
    _listenToScanState();
    _listenToServiceState();
    await _startBackgroundServiceIfNeeded();
  }

  Future<void> _initializeNotifications() async {
    const androidSettings = AndroidInitializationSettings(
      '@mipmap/ic_launcher',
    );
    const settings = InitializationSettings(android: androidSettings);

    await _notifications.initialize(
      settings,
      onDidReceiveNotificationResponse: _handleNotificationResponse,
    );

    const channel = AndroidNotificationChannel(
      alertChannelId,
      alertChannelName,
      description:
          'Watering reminders and recovery messages for Plantie sensors',
      importance: Importance.high,
    );

    final androidPlugin = _notifications
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    await androidPlugin?.createNotificationChannel(channel);
  }

  Future<void> _handleNotificationResponse(
    NotificationResponse response,
  ) async {
    final deviceId = response.payload;
    if (deviceId == null || !_savedDevices.containsKey(deviceId)) {
      return;
    }

    if (response.actionId == alertSnoozeActionId) {
      await _snoozeAlert(deviceId);
      return;
    }

    if (response.actionId == alertDismissActionId) {
      await _dismissAlert(deviceId);
    }
  }

  Future<void> _loadSavedDevices() async {
    final storedDevices = await loadStoredDevices();

    if (!mounted) {
      return;
    }

    setState(() {
      _savedDevices
        ..clear()
        ..addAll(storedDevices);
    });
  }

  Future<void> _persistSavedDevices() async {
    await saveStoredDevices(_savedDevices);
    await _startBackgroundServiceIfNeeded();
  }

  Future<void> _ensurePermissions() async {
    if (!Platform.isAndroid) {
      if (!mounted) {
        return;
      }

      setState(() {
        _permissionsGranted = true;
        _statusMessage = null;
      });
      return;
    }

    final androidInfo = await DeviceInfoPlugin().androidInfo;
    final sdkInt = androidInfo.version.sdkInt;

    final requests = <Permission>[
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
    ];
    if (sdkInt <= 30) {
      requests.add(Permission.locationWhenInUse);
    }
    if (sdkInt >= 33) {
      requests.add(Permission.notification);
    }

    final statuses = await requests.request();
    final granted = statuses.values.every((status) => status.isGranted);

    if (!mounted) {
      return;
    }

    setState(() {
      _permissionsGranted = granted;
      _statusMessage = granted
          ? null
          : 'Bluetooth and notification permissions are required.';
    });
  }

  void _listenToScanState() {
    _scanSubscription ??= FlutterBluePlus.scanResults.listen((results) {
      if (!mounted) {
        return;
      }

      setState(() {
        for (final result in results) {
          _rawScanResults[result.device.remoteId.str] = result;

          if (!_isPlantieResult(result)) {
            continue;
          }

          final id = result.device.remoteId.str;
          _scanResults[id] = result;
          final existing = _savedDevices[id];
          if (existing != null) {
            _savedDevices[id] = existing.copyWith(
              device: result.device,
              name: _displayName(result.device),
              rssi: result.rssi,
              isNearby: true,
            );
          }
        }
      });
    });

    _isScanningSubscription ??= FlutterBluePlus.isScanning.listen((value) {
      if (!mounted) {
        return;
      }

      setState(() {
        _isScanning = value;
        if (!value) {
          _statusMessage = _scanResults.isEmpty
              ? 'Scan complete. No Plantie devices found.'
              : 'Scan complete. Found ${_scanResults.length} Plantie device(s).';
        }
      });
    });
  }

  void _listenToServiceState() {
    if (!Platform.isAndroid) {
      return;
    }

    try {
      _serviceStateSubscription ??= FlutterBackgroundService()
          .on('device-sync')
          .listen((event) {
            if (!mounted || event == null) {
              return;
            }

            final rawDevices = event['devices'];
            if (rawDevices is! List) {
              return;
            }

            setState(() {
              for (final item in rawDevices) {
                if (item is! Map) {
                  continue;
                }

                final id = item['id'] as String?;
                if (id == null || !_savedDevices.containsKey(id)) {
                  continue;
                }

                final current = _savedDevices[id]!;
                _savedDevices[id] = current.mergeServiceState(item);
              }
            });
          });
    } catch (_) {
      // Ignore plugin absence in tests or unsupported environments.
    }
  }

  Future<void> _startScan() async {
    if (!_permissionsGranted) {
      await _ensurePermissions();
      if (!_permissionsGranted) {
        return;
      }
    }

    final adapterState = await FlutterBluePlus.adapterState.first;
    if (adapterState != BluetoothAdapterState.on) {
      if (!mounted) {
        return;
      }

      setState(() {
        _statusMessage = 'Turn Bluetooth on before scanning.';
      });
      return;
    }

    setState(() {
      _statusMessage = 'Scanning for Plantie sensors...';
      _scanResults.clear();
      _rawScanResults.clear();
      for (final device in _savedDevices.values) {
        _savedDevices[device.id] = device.copyWith(isNearby: false, rssi: null);
      }
    });

    await FlutterBluePlus.startScan(timeout: const Duration(seconds: 8));
  }

  Future<void> _startBackgroundServiceIfNeeded() async {
    if (!Platform.isAndroid) {
      return;
    }

    try {
      final service = FlutterBackgroundService();
      if (_savedDevices.isEmpty) {
        service.invoke('stopService');
        return;
      }

      final isRunning = await service.isRunning();
      if (!isRunning) {
        await service.startService();
      }
      service.invoke('refresh-config');
    } catch (_) {
      // Ignore plugin absence in tests or unsupported environments.
    }
  }

  bool _isPlantieResult(ScanResult result) {
    final platformName = result.device.platformName.trim().toLowerCase();
    final advertisedName = result.advertisementData.advName
        .trim()
        .toLowerCase();
    final serviceUuids = result.advertisementData.serviceUuids
        .map((uuid) => uuid.toString().toLowerCase())
        .toList();
    final plantieServiceUuidString = plantieServiceUuid
        .toString()
        .toLowerCase();

    return platformName.contains('plantie') ||
        advertisedName.contains('plantie') ||
        serviceUuids.contains(plantieServiceUuidString);
  }

  Future<void> _toggleSaved(BluetoothDevice device) async {
    final id = device.remoteId.str;
    final existing = _savedDevices[id];

    if (existing == null) {
      _savedDevices[id] = PlantieDeviceState(
        id: id,
        name: _displayName(device),
        alias: _displayName(device),
        device: device,
        isNearby: true,
      );
    } else {
      await _removeSaved(id);
      return;
    }

    await _persistSavedDevices();
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _removeSaved(String id) async {
    await _cancelDeviceNotification(id);
    _savedDevices.remove(id);
    await _persistSavedDevices();
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _cancelDeviceNotification(String id) async {
    await _cancelThirstNotification(id);
    await _cancelThanksNotification(id);
  }

  Future<void> _cancelThirstNotification(String id) async {
    await _notifications.cancel(_thirstNotificationIdFor(id));
  }

  Future<void> _cancelThanksNotification(String id) async {
    await _notifications.cancel(_thanksNotificationIdFor(id));
  }

  int _thirstNotificationIdFor(String id) => id.hashCode & 0x7fffffff;
  int _thanksNotificationIdFor(String id) =>
      (id.hashCode & 0x7fffffff) ^ 0x2fffffff;

  Future<void> _snoozeAlert(String id) async {
    final current = _savedDevices[id];
    if (current == null) {
      return;
    }

    final updated = current.copyWith(
      thirstAlertActive: false,
      thirstDismissed: false,
      snoozedUntil: DateTime.now().add(
        const Duration(minutes: reminderDurationMinutes),
      ),
    );

    if (mounted) {
      setState(() {
        _savedDevices[id] = updated;
      });
    } else {
      _savedDevices[id] = updated;
    }

    await _cancelThirstNotification(id);
    await _persistSavedDevices();
  }

  Future<void> _dismissAlert(String id) async {
    final current = _savedDevices[id];
    if (current == null) {
      return;
    }

    final updated = current.copyWith(
      thirstAlertActive: false,
      thirstDismissed: true,
      snoozedUntil: null,
    );

    if (mounted) {
      setState(() {
        _savedDevices[id] = updated;
      });
    } else {
      _savedDevices[id] = updated;
    }

    await _cancelThirstNotification(id);
    await _persistSavedDevices();
  }

  Future<void> _editDeviceSettings(String id) async {
    final current = _savedDevices[id];
    if (current == null || !mounted) {
      return;
    }

    final result = await showDialog<_DeviceSettingsResult>(
      context: context,
      builder: (context) => _DeviceSettingsDialog(device: current),
    );

    if (result == null) {
      return;
    }

    final updated = current.copyWith(
      alias: result.alias.trim().isEmpty ? null : result.alias.trim(),
      wetThreshold: result.wetThreshold,
      dryThreshold: result.dryThreshold,
    );

    setState(() {
      _savedDevices[id] = updated;
    });
    await _persistSavedDevices();
  }

  String _displayName(BluetoothDevice device) {
    final platformName = device.platformName.trim();
    if (platformName.isNotEmpty) {
      return platformName;
    }
    return 'Plantie ${device.remoteId.str.substring(0, 4)}';
  }

  String _rawDisplayName(ScanResult result) {
    final platformName = result.device.platformName.trim();
    if (platformName.isNotEmpty) {
      return platformName;
    }

    final advName = result.advertisementData.advName.trim();
    if (advName.isNotEmpty) {
      return advName;
    }

    return result.device.remoteId.str;
  }

  @override
  void dispose() {
    _scanSubscription?.cancel();
    _isScanningSubscription?.cancel();
    _serviceStateSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final savedDevices = _savedDevices.values.toList()
      ..sort((a, b) => a.displayName.compareTo(b.displayName));
    final discoveredDevices = _scanResults.values.toList()
      ..sort(
        (a, b) => _displayName(a.device).compareTo(_displayName(b.device)),
      );
    final rawDevices = _rawScanResults.values.toList()
      ..sort((a, b) => _rawDisplayName(a).compareTo(_rawDisplayName(b)));

    return Scaffold(
      appBar: AppBar(
        title: const Text('Plantie Monitor'),
        backgroundColor: Theme.of(context).colorScheme.surface,
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _HeaderCard(
            isScanning: _isScanning,
            permissionsGranted: _permissionsGranted,
            statusMessage: _statusMessage,
            onScanPressed: _startScan,
          ),
          const SizedBox(height: 16),
          Text('Saved Pairings', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          if (savedDevices.isEmpty)
            const _EmptyState(
              message:
                  'No saved Plantie sensors yet. Scan first, then tap Save on a device.',
            ),
          for (final device in savedDevices)
            _SavedDeviceCard(
              device: device,
              onRemove: () => _removeSaved(device.id),
              onEditSettings: () => _editDeviceSettings(device.id),
              onSnooze: () => _snoozeAlert(device.id),
              onDismissAlert: () => _dismissAlert(device.id),
            ),
          const SizedBox(height: 24),
          Text(
            'Discovered Nearby Devices',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 8),
          if (discoveredDevices.isEmpty)
            const _EmptyState(
              message: 'Run a scan to find nearby ESP32-C3 Plantie devices.',
            ),
          for (final result in discoveredDevices)
            _DiscoveryCard(
              result: result,
              isSaved: _savedDevices.containsKey(result.device.remoteId.str),
              onToggleSaved: () => _toggleSaved(result.device),
              onConnect: () => _toggleSaved(result.device),
            ),
          const SizedBox(height: 24),
          Text(
            'Raw BLE Results',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 8),
          if (rawDevices.isEmpty)
            const _EmptyState(
              message: 'No BLE advertisements captured in the last scan.',
            ),
          for (final result in rawDevices.take(15))
            _RawDiscoveryCard(
              result: result,
              matchesPlantie: _isPlantieResult(result),
            ),
        ],
      ),
    );
  }
}

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
    this.dryThreshold = 70,
    this.thirstAlertActive = false,
    this.thirstDismissed = false,
    this.hasCrossedWetReset = false,
    this.hasTriggeredDryAlert = false,
    this.snoozedUntil,
  });

  factory PlantieDeviceState.fromStorage(String id, Map<String, dynamic> map) {
    return PlantieDeviceState(
      id: id,
      alias: map['alias'] as String?,
      name: map['name'] as String?,
      wetThreshold: (map['wetThreshold'] as num?)?.toInt() ?? 50,
      dryThreshold: (map['dryThreshold'] as num?)?.toInt() ?? 70,
      thirstAlertActive: map['thirstAlertActive'] as bool? ?? false,
      thirstDismissed: map['thirstDismissed'] as bool? ?? false,
      hasCrossedWetReset: map['hasCrossedWetReset'] as bool? ?? false,
      hasTriggeredDryAlert: map['hasTriggeredDryAlert'] as bool? ?? false,
      snoozedUntil: map['snoozedUntilMs'] == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(
              (map['snoozedUntilMs'] as num).toInt(),
            ),
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
  final bool hasTriggeredDryAlert;
  final DateTime? snoozedUntil;

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

  Map<String, dynamic> toStorage() {
    return <String, dynamic>{
      'alias': alias,
      'name': name,
      'wetThreshold': wetThreshold,
      'dryThreshold': dryThreshold,
      'thirstAlertActive': thirstAlertActive,
      'thirstDismissed': thirstDismissed,
      'hasCrossedWetReset': hasCrossedWetReset,
      'hasTriggeredDryAlert': hasTriggeredDryAlert,
      'snoozedUntilMs': snoozedUntil?.millisecondsSinceEpoch,
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
      'hasTriggeredDryAlert': hasTriggeredDryAlert,
      'snoozedUntilMs': snoozedUntil?.millisecondsSinceEpoch,
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
      hasTriggeredDryAlert:
          map['hasTriggeredDryAlert'] as bool? ?? hasTriggeredDryAlert,
      snoozedUntil: map['snoozedUntilMs'] == null
          ? snoozedUntil
          : DateTime.fromMillisecondsSinceEpoch(
              (map['snoozedUntilMs'] as num).toInt(),
            ),
    );
  }

  PlantieDeviceState copyWith({
    Object? name = _unset,
    Object? alias = _unset,
    BluetoothDevice? device,
    bool? isNearby,
    bool? isConnecting,
    bool? isConnected,
    int? lastReading,
    int? moistureValue,
    DateTime? lastUpdated,
    Object? error = _unset,
    int? rssi,
    int? wetThreshold,
    int? dryThreshold,
    bool? thirstAlertActive,
    bool? thirstDismissed,
    bool? hasCrossedWetReset,
    bool? hasTriggeredDryAlert,
    Object? snoozedUntil = _unset,
  }) {
    return PlantieDeviceState(
      id: id,
      name: identical(name, _unset) ? this.name : name as String?,
      alias: identical(alias, _unset) ? this.alias : alias as String?,
      device: device ?? this.device,
      isNearby: isNearby ?? this.isNearby,
      isConnecting: isConnecting ?? this.isConnecting,
      isConnected: isConnected ?? this.isConnected,
      lastReading: lastReading ?? this.lastReading,
      moistureValue: moistureValue ?? this.moistureValue,
      lastUpdated: lastUpdated ?? this.lastUpdated,
      error: identical(error, _unset) ? this.error : error as String?,
      rssi: rssi ?? this.rssi,
      wetThreshold: wetThreshold ?? this.wetThreshold,
      dryThreshold: dryThreshold ?? this.dryThreshold,
      thirstAlertActive: thirstAlertActive ?? this.thirstAlertActive,
      thirstDismissed: thirstDismissed ?? this.thirstDismissed,
      hasCrossedWetReset: hasCrossedWetReset ?? this.hasCrossedWetReset,
      hasTriggeredDryAlert: hasTriggeredDryAlert ?? this.hasTriggeredDryAlert,
      snoozedUntil: identical(snoozedUntil, _unset)
          ? this.snoozedUntil
          : snoozedUntil as DateTime?,
    );
  }
}

class _HeaderCard extends StatelessWidget {
  const _HeaderCard({
    required this.isScanning,
    required this.permissionsGranted,
    required this.statusMessage,
    required this.onScanPressed,
  });

  final bool isScanning;
  final bool permissionsGranted;
  final String? statusMessage;
  final Future<void> Function() onScanPressed;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Multi-device BLE dashboard',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              permissionsGranted
                  ? 'The app can scan, save, connect, rename devices, and alert when they get dry.'
                  : 'Grant Bluetooth and notification permissions to continue.',
            ),
            if (statusMessage != null) ...[
              const SizedBox(height: 8),
              Text(statusMessage!),
            ],
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: isScanning ? null : onScanPressed,
              icon: Icon(isScanning ? Icons.radar : Icons.search),
              label: Text(isScanning ? 'Scanning...' : 'Scan for Devices'),
            ),
          ],
        ),
      ),
    );
  }
}

class _SavedDeviceCard extends StatelessWidget {
  const _SavedDeviceCard({
    required this.device,
    required this.onRemove,
    required this.onEditSettings,
    required this.onSnooze,
    required this.onDismissAlert,
  });

  final PlantieDeviceState device;
  final VoidCallback onRemove;
  final VoidCallback onEditSettings;
  final VoidCallback onSnooze;
  final VoidCallback onDismissAlert;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    device.displayName,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                IconButton(
                  onPressed: onEditSettings,
                  icon: const Icon(Icons.edit_outlined),
                  tooltip: 'Edit alias and thresholds',
                ),
              ],
            ),
            Text(device.id),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                Chip(
                  label: Text(
                    device.isConnected
                        ? 'Connected'
                        : device.isNearby
                        ? 'Nearby'
                        : 'Not in range',
                  ),
                ),
                if (device.rssi != null)
                  Chip(label: Text('RSSI ${device.rssi}')),
                if (device.moistureValue != null)
                  Chip(label: Text('Dryness ${device.moistureValue}/100')),
                Chip(
                  label: Text(
                    'Wet ${device.wetThreshold}  Dry ${device.dryThreshold}',
                  ),
                ),
                Chip(label: Text(device.alertLabel)),
              ],
            ),
            if (device.lastUpdated != null) ...[
              const SizedBox(height: 8),
              Text('Last update: ${device.lastUpdated}'),
            ],
            if (device.snoozedUntil != null) ...[
              const SizedBox(height: 8),
              Text('Reminder muted until ${device.snoozedUntil}'),
            ],
            if (device.error != null) ...[
              const SizedBox(height: 8),
              Text(
                device.error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.tonal(
                  onPressed: null,
                  child: Text(
                    device.isConnecting
                        ? 'Connecting automatically...'
                        : device.isConnected
                        ? 'Connected automatically'
                        : 'Waiting to reconnect',
                  ),
                ),
                OutlinedButton(
                  onPressed: onEditSettings,
                  child: const Text('Alias & Thresholds'),
                ),
                OutlinedButton(
                  onPressed: device.device == null ? null : onRemove,
                  child: const Text('Remove Pairing'),
                ),
              ],
            ),
            if (device.showAlertActions) ...[
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton.tonal(
                    onPressed: onSnooze,
                    child: const Text('Remind in 1 minute'),
                  ),
                  FilledButton.tonal(
                    onPressed: onDismissAlert,
                    child: const Text('Dismiss alert'),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _DiscoveryCard extends StatelessWidget {
  const _DiscoveryCard({
    required this.result,
    required this.isSaved,
    required this.onToggleSaved,
    required this.onConnect,
  });

  final ScanResult result;
  final bool isSaved;
  final VoidCallback onToggleSaved;
  final VoidCallback onConnect;

  @override
  Widget build(BuildContext context) {
    final name = result.device.platformName.trim().isNotEmpty
        ? result.device.platformName
        : result.advertisementData.advName;

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: ListTile(
        contentPadding: const EdgeInsets.all(16),
        title: Text(name.isEmpty ? result.device.remoteId.str : name),
        subtitle: Text('${result.device.remoteId.str}\nRSSI ${result.rssi}'),
        isThreeLine: true,
        trailing: Wrap(
          spacing: 8,
          children: [
            OutlinedButton(
              onPressed: onToggleSaved,
              child: Text(isSaved ? 'Saved' : 'Save'),
            ),
            FilledButton(onPressed: onConnect, child: const Text('Pair')),
          ],
        ),
      ),
    );
  }
}

class _RawDiscoveryCard extends StatelessWidget {
  const _RawDiscoveryCard({required this.result, required this.matchesPlantie});

  final ScanResult result;
  final bool matchesPlantie;

  @override
  Widget build(BuildContext context) {
    final platformName = result.device.platformName.trim();
    final advName = result.advertisementData.advName.trim();
    final title = platformName.isNotEmpty
        ? platformName
        : advName.isNotEmpty
        ? advName
        : result.device.remoteId.str;

    final services = result.advertisementData.serviceUuids
        .map((uuid) => uuid.toString())
        .join(', ');

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(result.device.remoteId.str),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                Chip(label: Text('RSSI ${result.rssi}')),
                Chip(
                  label: Text(matchesPlantie ? 'Matches Plantie' : 'Other BLE'),
                ),
              ],
            ),
            if (advName.isNotEmpty && advName != title) ...[
              const SizedBox(height: 8),
              Text('Adv name: $advName'),
            ],
            if (services.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text('Services: $services'),
            ],
          ],
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(padding: const EdgeInsets.all(16), child: Text(message)),
    );
  }
}

class _DeviceSettingsResult {
  const _DeviceSettingsResult({
    required this.alias,
    required this.wetThreshold,
    required this.dryThreshold,
  });

  final String alias;
  final int wetThreshold;
  final int dryThreshold;
}

class _DeviceSettingsDialog extends StatefulWidget {
  const _DeviceSettingsDialog({required this.device});

  final PlantieDeviceState device;

  @override
  State<_DeviceSettingsDialog> createState() => _DeviceSettingsDialogState();
}

class _DeviceSettingsDialogState extends State<_DeviceSettingsDialog> {
  late final TextEditingController _aliasController;
  late RangeValues _thresholds;

  @override
  void initState() {
    super.initState();
    _aliasController = TextEditingController(text: widget.device.alias ?? '');
    _thresholds = RangeValues(
      widget.device.wetThreshold.toDouble(),
      widget.device.dryThreshold.toDouble(),
    );
  }

  @override
  void dispose() {
    _aliasController.dispose();
    super.dispose();
  }

  void _updateThresholds(RangeValues next) {
    var wet = next.start.round();
    var dry = next.end.round();

    if (dry - wet < 10) {
      final movedWet = wet != _thresholds.start.round();
      if (movedWet) {
        wet = dry - 10;
      } else {
        dry = wet + 10;
      }
    }

    wet = wet.clamp(0, 90);
    dry = dry.clamp(wet + 10, 100);

    setState(() {
      _thresholds = RangeValues(wet.toDouble(), dry.toDouble());
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Device settings'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _aliasController,
              decoration: const InputDecoration(
                labelText: 'Alias',
                hintText: 'Kitchen basil',
              ),
            ),
            const SizedBox(height: 24),
            Text(
              'Wet ${_thresholds.start.round()}    Dry ${_thresholds.end.round()}',
            ),
            const SizedBox(height: 8),
            RangeSlider(
              min: 0,
              max: 100,
              divisions: 100,
              labels: RangeLabels(
                'Wet ${_thresholds.start.round()}',
                'Dry ${_thresholds.end.round()}',
              ),
              values: _thresholds,
              onChanged: _updateThresholds,
            ),
            const Text(
              'Left handle is wet, right handle is dry. The gap stays at least 10 points.',
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            Navigator.of(context).pop(
              _DeviceSettingsResult(
                alias: _aliasController.text,
                wetThreshold: _thresholds.start.round(),
                dryThreshold: _thresholds.end.round(),
              ),
            );
          },
          child: const Text('Save'),
        ),
      ],
    );
  }
}
