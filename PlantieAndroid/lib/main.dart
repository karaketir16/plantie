import 'dart:async';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

final Guid plantieServiceUuid = Guid('12345678-1234-5678-1234-56789abc0000');
final Guid plantieReadingCharacteristicUuid = Guid(
  '12345678-1234-5678-1234-56789abc0001',
);
const String pairedDevicesKey = 'paired_device_ids';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const PlantieApp());
}

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
  final Map<String, StreamSubscription<List<int>>> _valueSubscriptions = {};
  final Map<String, StreamSubscription<BluetoothConnectionState>>
  _connectionSubscriptions = {};

  StreamSubscription<List<ScanResult>>? _scanSubscription;
  StreamSubscription<bool>? _isScanningSubscription;

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
    await _ensurePermissions();
    _listenToScanState();
  }

  Future<void> _loadSavedDevices() async {
    final prefs = await SharedPreferences.getInstance();
    final savedIds = prefs.getStringList(pairedDevicesKey) ?? <String>[];

    setState(() {
      for (final id in savedIds) {
        _savedDevices[id] = PlantieDeviceState(id: id);
      }
    });
  }

  Future<void> _persistSavedDevices() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      pairedDevicesKey,
      _savedDevices.keys.toList()..sort(),
    );
  }

  Future<void> _ensurePermissions() async {
    if (!Platform.isAndroid) {
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

    final statuses = await requests.request();
    final granted = statuses.values.every((status) => status.isGranted);

    setState(() {
      _permissionsGranted = granted;
      _statusMessage = granted
          ? null
          : 'Bluetooth permissions are required for scanning and connecting.';
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

  Future<void> _startScan() async {
    if (!_permissionsGranted) {
      await _ensurePermissions();
      if (!_permissionsGranted) {
        return;
      }
    }

    final adapterState = await FlutterBluePlus.adapterState.first;
    if (adapterState != BluetoothAdapterState.on) {
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
    await _disconnect(id);
    _savedDevices.remove(id);
    await _persistSavedDevices();
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _connect(String id) async {
    final saved = _savedDevices[id];
    final device = saved?.device ?? _scanResults[id]?.device;
    if (device == null) {
      setState(() {
        _statusMessage = 'Device $id is not currently discoverable.';
      });
      return;
    }

    setState(() {
      _savedDevices[id] = (saved ?? PlantieDeviceState(id: id)).copyWith(
        device: device,
        name: _displayName(device),
        isConnecting: true,
        error: null,
      );
    });

    try {
      await device.connect(timeout: const Duration(seconds: 10));
    } catch (error) {
      final message = error.toString().toLowerCase();
      if (!(message.contains('already') && message.contains('connected'))) {
        _setDeviceError(id, error.toString());
        return;
      }
    }

    _connectionSubscriptions[id]?.cancel();
    _connectionSubscriptions[id] = device.connectionState.listen((state) {
      if (!mounted) {
        return;
      }

      setState(() {
        final current = _savedDevices[id];
        if (current == null) {
          return;
        }

        _savedDevices[id] = current.copyWith(
          isConnected: state == BluetoothConnectionState.connected,
          isConnecting: false,
          device: device,
          name: _displayName(device),
          error: state == BluetoothConnectionState.disconnected
              ? null
              : current.error,
        );
      });
    });

    try {
      final services = await device.discoverServices();
      final characteristic = _findReadingCharacteristic(services);
      if (characteristic == null) {
        _setDeviceError(id, 'Plantie reading characteristic not found.');
        return;
      }

      await characteristic.setNotifyValue(true);
      _valueSubscriptions[id]?.cancel();
      _valueSubscriptions[id] = characteristic.onValueReceived.listen((value) {
        if (!mounted || value.length < 2) {
          return;
        }

        final reading = value[0] | (value[1] << 8);
        setState(() {
          final current = _savedDevices[id];
          if (current == null) {
            return;
          }

          _savedDevices[id] = current.copyWith(
            lastReading: reading,
            lastUpdated: DateTime.now(),
            isConnected: true,
            isConnecting: false,
            error: null,
          );
        });
      });

      final latestValue = await characteristic.read();
      if (latestValue.length >= 2 && mounted) {
        final reading = latestValue[0] | (latestValue[1] << 8);
        setState(() {
          final current = _savedDevices[id];
          if (current == null) {
            return;
          }
          _savedDevices[id] = current.copyWith(
            lastReading: reading,
            lastUpdated: DateTime.now(),
            isConnected: true,
            isConnecting: false,
            error: null,
          );
        });
      }
    } catch (error) {
      _setDeviceError(id, error.toString());
    }
  }

  Future<void> _disconnect(String id) async {
    await _valueSubscriptions.remove(id)?.cancel();
    await _connectionSubscriptions.remove(id)?.cancel();

    final device = _savedDevices[id]?.device;
    if (device != null) {
      try {
        await device.disconnect();
      } catch (_) {
        // Ignore disconnect races when the peripheral has already gone away.
      }
    }

    if (!mounted) {
      return;
    }

    setState(() {
      final current = _savedDevices[id];
      if (current == null) {
        return;
      }

      _savedDevices[id] = current.copyWith(
        isConnected: false,
        isConnecting: false,
      );
    });
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

  void _setDeviceError(String id, String message) {
    if (!mounted) {
      return;
    }

    setState(() {
      final current = _savedDevices[id];
      if (current == null) {
        return;
      }

      _savedDevices[id] = current.copyWith(
        isConnecting: false,
        isConnected: false,
        error: message,
      );
    });
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
    for (final subscription in _valueSubscriptions.values) {
      subscription.cancel();
    }
    for (final subscription in _connectionSubscriptions.values) {
      subscription.cancel();
    }
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
      ..sort((a, b) {
        final aName = _rawDisplayName(a);
        final bName = _rawDisplayName(b);
        return aName.compareTo(bName);
      });

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
              onConnect: () => _connect(device.id),
              onDisconnect: () => _disconnect(device.id),
              onRemove: () => _removeSaved(device.id),
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
              onConnect: () async {
                if (!_savedDevices.containsKey(result.device.remoteId.str)) {
                  await _toggleSaved(result.device);
                }
                await _connect(result.device.remoteId.str);
              },
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
}

class PlantieDeviceState {
  const PlantieDeviceState({
    required this.id,
    this.name,
    this.device,
    this.isNearby = false,
    this.isConnecting = false,
    this.isConnected = false,
    this.lastReading,
    this.lastUpdated,
    this.error,
    this.rssi,
  });

  final String id;
  final String? name;
  final BluetoothDevice? device;
  final bool isNearby;
  final bool isConnecting;
  final bool isConnected;
  final int? lastReading;
  final DateTime? lastUpdated;
  final String? error;
  final int? rssi;

  String get displayName => name ?? 'Plantie $id';

  PlantieDeviceState copyWith({
    String? name,
    BluetoothDevice? device,
    bool? isNearby,
    bool? isConnecting,
    bool? isConnected,
    int? lastReading,
    DateTime? lastUpdated,
    String? error,
    int? rssi,
  }) {
    return PlantieDeviceState(
      id: id,
      name: name ?? this.name,
      device: device ?? this.device,
      isNearby: isNearby ?? this.isNearby,
      isConnecting: isConnecting ?? this.isConnecting,
      isConnected: isConnected ?? this.isConnected,
      lastReading: lastReading ?? this.lastReading,
      lastUpdated: lastUpdated ?? this.lastUpdated,
      error: error,
      rssi: rssi ?? this.rssi,
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
                  ? 'The app can scan, save, and connect to multiple Plantie ESP32-C3 sensors.'
                  : 'Grant Bluetooth permissions to scan and connect.',
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
    required this.onConnect,
    required this.onDisconnect,
    required this.onRemove,
  });

  final PlantieDeviceState device;
  final VoidCallback onConnect;
  final VoidCallback onDisconnect;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              device.displayName,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
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
                if (device.lastReading != null)
                  Chip(label: Text('ADC ${device.lastReading} / 4095')),
              ],
            ),
            if (device.lastUpdated != null) ...[
              const SizedBox(height: 8),
              Text('Last update: ${device.lastUpdated}'),
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
                FilledButton(
                  onPressed: device.device == null || device.isConnecting
                      ? null
                      : device.isConnected
                      ? onDisconnect
                      : onConnect,
                  child: Text(
                    device.isConnecting
                        ? 'Connecting...'
                        : device.isConnected
                        ? 'Disconnect'
                        : 'Connect',
                  ),
                ),
                OutlinedButton(
                  onPressed: device.device == null ? null : onRemove,
                  child: const Text('Remove Pairing'),
                ),
              ],
            ),
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
            FilledButton(onPressed: onConnect, child: const Text('Connect')),
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
