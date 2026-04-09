import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../models/plantie_device_state.dart';

class HeaderCard extends StatelessWidget {
  const HeaderCard({
    super.key,
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

class SavedDeviceCard extends StatelessWidget {
  const SavedDeviceCard({
    super.key,
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
                    device.seemsConnected
                        ? 'Connected'
                        : device.isNearby
                        ? 'Nearby'
                        : 'Saved',
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
                OutlinedButton(
                  onPressed: onEditSettings,
                  child: const Text('Alias & Thresholds'),
                ),
                OutlinedButton(
                  onPressed: onRemove,
                  child: const Text('Remove Device'),
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

class DiscoveryCard extends StatelessWidget {
  const DiscoveryCard({
    super.key,
    required this.result,
    required this.isSaved,
    required this.onTap,
  });

  final ScanResult result;
  final bool isSaved;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final name = result.device.platformName.trim().isNotEmpty
        ? result.device.platformName
        : result.advertisementData.advName;

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: ListTile(
        onTap: isSaved ? null : onTap,
        contentPadding: const EdgeInsets.all(16),
        title: Text(name.isEmpty ? result.device.remoteId.str : name),
        subtitle: Text(
          '${result.device.remoteId.str}\nRSSI ${result.rssi}\n'
          '${isSaved ? 'Already saved' : 'Tap to add this sensor'}',
        ),
        isThreeLine: true,
        trailing: Icon(
          isSaved ? Icons.check_circle : Icons.add_circle_outline,
          color: isSaved
              ? Theme.of(context).colorScheme.primary
              : Theme.of(context).colorScheme.secondary,
        ),
      ),
    );
  }
}

class RawDiscoveryCard extends StatelessWidget {
  const RawDiscoveryCard({
    super.key,
    required this.result,
    required this.matchesPlantie,
  });

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

class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(padding: const EdgeInsets.all(16), child: Text(message)),
    );
  }
}

class DeviceSettingsResult {
  const DeviceSettingsResult({
    required this.alias,
    required this.wetThreshold,
    required this.dryThreshold,
  });

  final String alias;
  final int wetThreshold;
  final int dryThreshold;
}

class DeviceSettingsDialog extends StatefulWidget {
  const DeviceSettingsDialog({super.key, required this.device});

  final PlantieDeviceState device;

  @override
  State<DeviceSettingsDialog> createState() => _DeviceSettingsDialogState();
}

class _DeviceSettingsDialogState extends State<DeviceSettingsDialog> {
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
              DeviceSettingsResult(
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
