import 'dart:async';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:permission_handler/permission_handler.dart';

import '../constants.dart';
import '../models/plantie_device_state.dart';
import '../services/plantie_notifications.dart';
import '../services/plantie_storage.dart';
import '../services/background_monitoring.dart';
import '../widgets/device_widgets.dart';

class DeviceDashboardPage extends StatefulWidget {
  const DeviceDashboardPage({super.key});

  @override
  State<DeviceDashboardPage> createState() => _DeviceDashboardPageState();
}

class _DeviceDashboardPageState extends State<DeviceDashboardPage> {
  final Map<String, PlantieDeviceState> _savedDevices = {};
  final Map<String, ScanResult> _scanResults = {};
  final FlutterLocalNotificationsPlugin _notifications =
      FlutterLocalNotificationsPlugin();

  StreamSubscription<List<ScanResult>>? _scanSubscription;
  StreamSubscription<bool>? _isScanningSubscription;
  StreamSubscription<Map<String, dynamic>?>? _serviceStateSubscription;
  Timer? _storageRefreshTimer;

  bool _isScanning = false;
  bool _permissionsGranted = false;
  String? _statusMessage;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    await _loadSavedDevices();
    await _initializeNotifications();
    await _ensurePermissions();
    _listenToScanState();
    _listenToServiceState();
    _startStorageRefresh();
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
      onDidReceiveBackgroundNotificationResponse: notificationTapBackground,
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
    // Ensure devices are loaded (handles cold start from notification tap).
    if (_savedDevices.isEmpty) {
      await _loadSavedDevices();
    }

    final deviceId = resolveNotificationDeviceId(
      _savedDevices,
      payload: response.payload,
      notificationId: response.id,
    );
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

  Future<void> _refreshSavedDevicesFromStorage() async {
    final storedDevices = await loadStoredDevices();
    if (!mounted) {
      return;
    }

    setState(() {
      for (final entry in storedDevices.entries) {
        final existing = _savedDevices[entry.key];
        _savedDevices[entry.key] =
            existing?.copyWith(
              name: entry.value.name,
              alias: entry.value.alias,
              lastReading: entry.value.lastReading,
              moistureValue: entry.value.moistureValue,
              lastUpdated: entry.value.lastUpdated,
              error: entry.value.error,
              wetThreshold: entry.value.wetThreshold,
              dryThreshold: entry.value.dryThreshold,
              thirstAlertActive: entry.value.thirstAlertActive,
              thirstDismissed: entry.value.thirstDismissed,
              hasCrossedWetReset: entry.value.hasCrossedWetReset,
              hasCrossedDryReset: entry.value.hasCrossedDryReset,
              hasTriggeredDryAlert: entry.value.hasTriggeredDryAlert,
              snoozedUntil: entry.value.snoozedUntil,
            ) ??
            entry.value;
      }
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

  void _startStorageRefresh() {
    _storageRefreshTimer?.cancel();
    _storageRefreshTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      _refreshSavedDevicesFromStorage();
    });
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
    await _notifications.cancel(thirstNotificationIdFor(id));
    await _notifications.cancel(thanksNotificationIdFor(id));
  }

  Future<void> _snoozeAlert(String id) async {
    final current = _savedDevices[id];
    if (current == null) {
      return;
    }

    final updated = current.copyWith(
      thirstAlertActive: false,
      thirstDismissed: false,
      snoozedUntil: DateTime.now().add(reminderDuration),
    );

    if (mounted) {
      setState(() {
        _savedDevices[id] = updated;
      });
    } else {
      _savedDevices[id] = updated;
    }

    await _notifications.cancel(thirstNotificationIdFor(id));
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

    await _notifications.cancel(thirstNotificationIdFor(id));
    await _persistSavedDevices();
  }

  Future<void> _editDeviceSettings(String id) async {
    final current = _savedDevices[id];
    if (current == null || !mounted) {
      return;
    }

    final result = await showDialog<DeviceSettingsResult>(
      context: context,
      builder: (context) => DeviceSettingsDialog(device: current),
    );

    if (result == null) {
      return;
    }

    final updated = current.copyWith(
      alias: result.alias.trim().isEmpty ? null : result.alias.trim(),
      wetThreshold: result.wetThreshold,
      dryThreshold: result.dryThreshold,
      thirstAlertActive: false,
      thirstDismissed: false,
      hasCrossedWetReset: false,
      hasCrossedDryReset: true,
      hasTriggeredDryAlert: false,
      snoozedUntil: null,
    );

    setState(() {
      _savedDevices[id] = updated;
    });
    await _cancelDeviceNotification(id);
    await _persistSavedDevices();
  }

  String _displayName(BluetoothDevice device) {
    final platformName = device.platformName.trim();
    if (platformName.isNotEmpty) {
      return platformName;
    }
    return 'Plantie ${device.remoteId.str.substring(0, 4)}';
  }



  @override
  void dispose() {
    _scanSubscription?.cancel();
    _isScanningSubscription?.cancel();
    _serviceStateSubscription?.cancel();
    _storageRefreshTimer?.cancel();
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

    return Scaffold(
      appBar: AppBar(
        title: const Text('Plantie Monitor'),
        backgroundColor: Theme.of(context).colorScheme.surface,
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          HeaderCard(
            isScanning: _isScanning,
            permissionsGranted: _permissionsGranted,
            statusMessage: _statusMessage,
            onScanPressed: _startScan,
          ),
          const SizedBox(height: 16),
          Text('Saved Devices', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          if (savedDevices.isEmpty)
            const EmptyState(
              message:
                  'No saved Plantie sensors yet. Scan first, then tap a nearby Plantie to add it.',
            ),
          for (final device in savedDevices)
            SavedDeviceCard(
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
            const EmptyState(
              message: 'Run a scan to find nearby ESP32-C3 Plantie devices.',
            ),
          for (final result in discoveredDevices)
            DiscoveryCard(
              result: result,
              isSaved: _savedDevices.containsKey(result.device.remoteId.str),
              onTap: () => _toggleSaved(result.device),
            ),
        ],
      ),
    );
  }
}
