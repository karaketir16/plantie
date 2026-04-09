import '../models/plantie_device_state.dart';

int thirstNotificationIdFor(String id) => id.hashCode & 0x7fffffff;

int thanksNotificationIdFor(String id) =>
    (id.hashCode & 0x7fffffff) ^ 0x2fffffff;

String? resolveNotificationDeviceId(
  Map<String, PlantieDeviceState> devices, {
  String? payload,
  int? notificationId,
}) {
  if (payload != null && devices.containsKey(payload)) {
    return payload;
  }
  if (notificationId == null) {
    return null;
  }

  for (final id in devices.keys) {
    if (thirstNotificationIdFor(id) == notificationId ||
        thanksNotificationIdFor(id) == notificationId) {
      return id;
    }
  }
  return null;
}

int mapRawReadingToMoisture(int rawReading) =>
    ((rawReading / 4095) * 100).round().clamp(0, 100);
