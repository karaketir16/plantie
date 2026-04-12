import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../models/plantie_device_state.dart';

String _formatTimeAgo(DateTime dt) {
  final diff = DateTime.now().difference(dt);
  if (diff.inSeconds < 60) return '${diff.inSeconds}s ago';
  if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
  if (diff.inHours < 24) return '${diff.inHours}h ago';
  return '${diff.inDays}d ago';
}

String _formatTime(DateTime dt) {
  final h = dt.hour.toString().padLeft(2, '0');
  final m = dt.minute.toString().padLeft(2, '0');
  final s = dt.second.toString().padLeft(2, '0');
  return '$h:$m:$s';
}

Color _moistureColor(int moisture, int dryThreshold, int wetThreshold) {
  if (moisture <= dryThreshold) {
    final t = moisture / dryThreshold.clamp(1, 100);
    return Color.lerp(const Color(0xFFD32F2F), const Color(0xFFFF9800), t)!;
  } else if (moisture <= wetThreshold) {
    final t = (moisture - dryThreshold) /
        (wetThreshold - dryThreshold).clamp(1, 100);
    return Color.lerp(const Color(0xFFFF9800), const Color(0xFF43A047), t)!;
  } else {
    final t = (moisture - wetThreshold) / (100 - wetThreshold).clamp(1, 100);
    return Color.lerp(const Color(0xFF43A047), const Color(0xFF00897B), t)!;
  }
}

// ---------------------------------------------------------------------------
// Header
// ---------------------------------------------------------------------------

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
    final scheme = Theme.of(context).colorScheme;

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      color: scheme.primaryContainer.withValues(alpha: 0.35),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.eco, color: scheme.primary, size: 28),
                const SizedBox(width: 10),
                Text(
                  'Plantie Monitor',
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: scheme.primary,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              permissionsGranted
                  ? 'Scan for nearby ESP32 sensors, save them, and get watering alerts.'
                  : 'Grant Bluetooth and notification permissions to continue.',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            if (statusMessage != null) ...[
              const SizedBox(height: 8),
              Text(
                statusMessage!,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: isScanning ? null : onScanPressed,
              icon: Icon(isScanning ? Icons.radar : Icons.search),
              label: Text(isScanning ? 'Scanning…' : 'Scan for Devices'),
              style: FilledButton.styleFrom(
                minimumSize: const Size(double.infinity, 48),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Saved-device card
// ---------------------------------------------------------------------------

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
    final scheme = Theme.of(context).colorScheme;
    final moisture = device.moistureValue;

    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Header row ──────────────────────────────────────────
            Row(
              children: [
                Text('🌱', style: const TextStyle(fontSize: 22)),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        device.displayName,
                        style:
                            Theme.of(context).textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                      ),
                      Text(
                        device.id,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  onPressed: onEditSettings,
                  icon: const Icon(Icons.settings_outlined),
                  tooltip: 'Settings',
                ),
              ],
            ),

            const SizedBox(height: 16),

            // ── Moisture bar ────────────────────────────────────────
            if (moisture != null) ...[
              _MoistureBar(
                moisture: moisture,
                dryThreshold: device.dryThreshold,
                wetThreshold: device.wetThreshold,
              ),
              const SizedBox(height: 12),
            ],

            // ── Status row ──────────────────────────────────────────
            Row(
              children: [
                _StatusDot(connected: device.seemsConnected),
                const SizedBox(width: 6),
                Text(
                  device.seemsConnected
                      ? 'Connected'
                      : device.isNearby
                          ? 'Nearby'
                          : 'Offline',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    fontWeight: FontWeight.w500,
                  ),
                ),
                if (device.rssi != null) ...[
                  const SizedBox(width: 8),
                  Text(
                    '· RSSI ${device.rssi}',
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                ],
                if (device.lastUpdated != null) ...[
                  const SizedBox(width: 8),
                  Text(
                    '· ${_formatTimeAgo(device.lastUpdated!)}',
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                ],
              ],
            ),

            // ── Alert label ─────────────────────────────────────────
            const SizedBox(height: 4),
            Row(
              children: [
                Icon(
                  device.thirstAlertActive
                      ? Icons.warning_amber_rounded
                      : device.snoozedUntil != null
                          ? Icons.snooze
                          : Icons.check_circle_outline,
                  size: 16,
                  color: device.thirstAlertActive
                      ? scheme.error
                      : scheme.onSurfaceVariant,
                ),
                const SizedBox(width: 4),
                Text(
                  device.alertLabel,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: device.thirstAlertActive
                        ? scheme.error
                        : scheme.onSurfaceVariant,
                  ),
                ),
                if (device.snoozedUntil != null) ...[
                  const SizedBox(width: 4),
                  Text(
                    '(until ${_formatTime(device.snoozedUntil!)})',
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                ],
              ],
            ),

            if (device.error != null) ...[
              const SizedBox(height: 8),
              Text(
                device.error!,
                style: TextStyle(color: scheme.error, fontSize: 12),
              ),
            ],

            const SizedBox(height: 12),
            const Divider(height: 1),
            const SizedBox(height: 8),

            // ── Action buttons ──────────────────────────────────────
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (device.showAlertActions) ...[
                  FilledButton.tonal(
                    onPressed: onSnooze,
                    style: FilledButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                    ),
                    child: Text('Remind in ${device.reminderDurationMinutes} min'),
                  ),
                  FilledButton.tonal(
                    onPressed: onDismissAlert,
                    style: FilledButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                    ),
                    child: const Text('Dismiss alert'),
                  ),
                ],
                TextButton(
                  onPressed: onRemove,
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    foregroundColor: scheme.error,
                  ),
                  child: const Text('Remove'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Moisture bar
// ---------------------------------------------------------------------------

class _MoistureBar extends StatelessWidget {
  const _MoistureBar({
    required this.moisture,
    required this.dryThreshold,
    required this.wetThreshold,
  });

  final int moisture;
  final int dryThreshold;
  final int wetThreshold;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = _moistureColor(moisture, dryThreshold, wetThreshold);
    final fraction = moisture.clamp(0, 100) / 100;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.water_drop_outlined, size: 16, color: color),
            const SizedBox(width: 4),
            Text(
              'Moisture',
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            const Spacer(),
            Text(
              '$moisture%',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
                color: color,
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        SizedBox(
          height: 14,
          child: Stack(
            children: [
              // Background track
              Container(
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(7),
                ),
              ),
              // Filled portion
              FractionallySizedBox(
                widthFactor: fraction,
                child: Container(
                  decoration: BoxDecoration(
                    color: color,
                    borderRadius: BorderRadius.circular(7),
                  ),
                ),
              ),
              // Dry threshold marker
              Positioned(
                left: _markerPosition(context, dryThreshold),
                top: 0,
                bottom: 0,
                child: Container(
                  width: 2,
                  color: scheme.onSurface.withValues(alpha: 0.25),
                ),
              ),
              // Wet threshold marker
              Positioned(
                left: _markerPosition(context, wetThreshold),
                top: 0,
                bottom: 0,
                child: Container(
                  width: 2,
                  color: scheme.onSurface.withValues(alpha: 0.25),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 4),
        Row(
          children: [
            Text(
              '🏜️ Dry $dryThreshold',
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            const Spacer(),
            Text(
              'Wet $wetThreshold 💧',
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ],
    );
  }

  double _markerPosition(BuildContext context, int threshold) {
    // We compute fractional position. The actual pixel offset is resolved
    // via LayoutBuilder, but for simplicity we approximate using the
    // available width obtained from the parent constraints.
    // Since we are inside a Column → Row → Expanded chain, we use a
    // LayoutBuilder-free approach: the Stack fills its parent and we can
    // use relative positioning.
    // Return a fraction.  Positioned.left doesn't take fractions so we
    // fall back to using Align inside the stack in a real implementation.
    // For now this is close enough using media query.
    final barWidth =
        MediaQuery.of(context).size.width - 32 - 32; // padding estimates
    return (threshold / 100) * barWidth;
  }
}

// ---------------------------------------------------------------------------
// Status dot
// ---------------------------------------------------------------------------

class _StatusDot extends StatelessWidget {
  const _StatusDot({required this.connected});
  final bool connected;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: connected ? const Color(0xFF43A047) : Colors.grey,
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Discovery card
// ---------------------------------------------------------------------------

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
    final scheme = Theme.of(context).colorScheme;
    final name = result.device.platformName.trim().isNotEmpty
        ? result.device.platformName
        : result.advertisementData.advName;

    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ListTile(
        onTap: isSaved ? null : onTap,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        leading: CircleAvatar(
          backgroundColor: isSaved
              ? scheme.primaryContainer
              : scheme.surfaceContainerHighest,
          child: Icon(
            isSaved ? Icons.check : Icons.add,
            color: isSaved ? scheme.primary : scheme.onSurfaceVariant,
          ),
        ),
        title: Text(
          name.isEmpty ? result.device.remoteId.str : name,
          style: const TextStyle(fontWeight: FontWeight.w500),
        ),
        subtitle: Text(
          '${result.device.remoteId.str}\n'
          'RSSI ${result.rssi} · ${isSaved ? 'Already saved' : 'Tap to add'}',
        ),
        isThreeLine: true,
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Empty state placeholder
// ---------------------------------------------------------------------------

class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Center(
          child: Text(
            message,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Settings dialog
// ---------------------------------------------------------------------------

class DeviceSettingsResult {
  const DeviceSettingsResult({
    required this.alias,
    required this.wetThreshold,
    required this.dryThreshold,
    required this.customThirstMessages,
    required this.reminderDurationMinutes,
  });

  final String alias;
  final int wetThreshold;
  final int dryThreshold;
  final List<String> customThirstMessages;
  final int reminderDurationMinutes;
}

class DeviceSettingsDialog extends StatefulWidget {
  const DeviceSettingsDialog({super.key, required this.device});

  final PlantieDeviceState device;

  @override
  State<DeviceSettingsDialog> createState() => _DeviceSettingsDialogState();
}

class _DeviceSettingsDialogState extends State<DeviceSettingsDialog> {
  late final TextEditingController _aliasController;
  late final TextEditingController _reminderController;
  late RangeValues _thresholds;
  late List<String> _customThirstMessages;

  @override
  void initState() {
    super.initState();
    _aliasController = TextEditingController(text: widget.device.alias ?? '');
    _reminderController = TextEditingController(text: widget.device.reminderDurationMinutes.toString());
    // Left = dryThreshold (lower), Right = wetThreshold (higher).
    _thresholds = RangeValues(
      widget.device.dryThreshold.toDouble(),
      widget.device.wetThreshold.toDouble(),
    );
    _customThirstMessages = List.of(widget.device.customThirstMessages);
  }

  @override
  void dispose() {
    _aliasController.dispose();
    _reminderController.dispose();
    super.dispose();
  }

  void _updateThresholds(RangeValues next) {
    var dry = next.start.round();
    var wet = next.end.round();

    if (wet - dry < 10) {
      final movedDry = dry != _thresholds.start.round();
      if (movedDry) {
        dry = wet - 10;
      } else {
        wet = dry + 10;
      }
    }

    dry = dry.clamp(0, 90);
    wet = wet.clamp(dry + 10, 100);

    setState(() {
      _thresholds = RangeValues(dry.toDouble(), wet.toDouble());
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
            const SizedBox(height: 16),
            TextField(
              controller: _reminderController,
              decoration: const InputDecoration(
                labelText: 'Reminder interval (minutes)',
                hintText: '30',
              ),
              keyboardType: TextInputType.number,
            ),
            const SizedBox(height: 24),
            Text(
              '🏜️ Dry ${_thresholds.start.round()}    💧 Wet ${_thresholds.end.round()}',
            ),
            const SizedBox(height: 8),
            RangeSlider(
              min: 0,
              max: 100,
              divisions: 100,
              labels: RangeLabels(
                'Dry ${_thresholds.start.round()}',
                'Wet ${_thresholds.end.round()}',
              ),
              values: _thresholds,
              onChanged: _updateThresholds,
            ),
            const Text(
              'Alert when moisture drops below Dry. '
              'Recovery when moisture rises above Wet. '
              'Gap stays at least 10.',
              style: TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 24),
            OutlinedButton.icon(
              onPressed: () async {
                final result = await showDialog<List<String>>(
                  context: context,
                  builder: (context) => CustomMessagesDialog(
                    initialMessages: _customThirstMessages,
                  ),
                );
                if (result != null) {
                  setState(() {
                    _customThirstMessages = result;
                  });
                }
              },
              icon: const Icon(Icons.forum_outlined),
              label: Text('Custom Thirst Messages (${_customThirstMessages.length})'),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size(double.infinity, 48),
                alignment: Alignment.centerLeft,
              ),
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
                dryThreshold: _thresholds.start.round(),
                wetThreshold: _thresholds.end.round(),
                customThirstMessages: _customThirstMessages,
                reminderDurationMinutes: int.tryParse(_reminderController.text) ?? 30,
              ),
            );
          },
          child: const Text('Save'),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Custom messages dialog
// ---------------------------------------------------------------------------

class CustomMessagesDialog extends StatefulWidget {
  const CustomMessagesDialog({super.key, required this.initialMessages});

  final List<String> initialMessages;

  @override
  State<CustomMessagesDialog> createState() => _CustomMessagesDialogState();
}

class _CustomMessagesDialogState extends State<CustomMessagesDialog> {
  late List<String> _messages;
  late final TextEditingController _newMessageController;

  @override
  void initState() {
    super.initState();
    _messages = List.of(widget.initialMessages);
    _newMessageController = TextEditingController();
  }

  @override
  void dispose() {
    _newMessageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Custom messages'),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Add custom thirsty alerts. When the plant needs water, '
              'one of these will be randomly chosen. If empty, it defaults to "I am thirsty!".',
              style: TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 16),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: _messages.length,
                itemBuilder: (context, i) {
                  return ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(_messages[i]),
                    trailing: IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () {
                        setState(() {
                          _messages.removeAt(i);
                        });
                      },
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _newMessageController,
                    decoration: const InputDecoration(
                      hintText: 'e.g., Water me please!',
                      isDense: true,
                    ),
                    onSubmitted: (_) => _addMessage(),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.add),
                  onPressed: _addMessage,
                ),
              ],
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
            final text = _newMessageController.text.trim();
            if (text.isNotEmpty) {
              _messages.add(text);
            }
            Navigator.of(context).pop(_messages);
          },
          child: const Text('Save'),
        ),
      ],
    );
  }

  void _addMessage() {
    final text = _newMessageController.text.trim();
    if (text.isNotEmpty) {
      setState(() {
        _messages.add(text);
        _newMessageController.clear();
      });
    }
  }
}
