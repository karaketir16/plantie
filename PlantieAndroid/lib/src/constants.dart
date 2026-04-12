import 'package:flutter_blue_plus/flutter_blue_plus.dart';

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
const Object unset = Object();
const Duration reminderDuration = Duration(seconds: 30);
const int foregroundServiceNotificationId = 7001;
const Duration connectedGracePeriod = Duration(seconds: 15);
