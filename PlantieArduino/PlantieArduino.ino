#include <BLE2902.h>
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <esp_system.h>

namespace {
constexpr uint8_t kAnalogPin = 0;
constexpr unsigned long kNotifyIntervalMs = 5 * 1000;
const char* kServiceUuid = "12345678-1234-5678-1234-56789abc0000";
const char* kReadingCharacteristicUuid = "12345678-1234-5678-1234-56789abc0001";

BLECharacteristic* readingCharacteristic = nullptr;
bool deviceConnected = false;
unsigned long lastNotifyAt = 0;
}

class PlantieServerCallbacks : public BLEServerCallbacks {
  void onConnect(BLEServer* server) override {
    deviceConnected = true;
  }

  void onDisconnect(BLEServer* server) override {
    deviceConnected = false;
    server->startAdvertising();
  }
};

String buildDeviceName() {
  uint64_t efuseMac = ESP.getEfuseMac();
  uint16_t suffix = static_cast<uint16_t>(efuseMac & 0xFFFF);

  char name[20];
  snprintf(name, sizeof(name), "Plantie-%04X", suffix);
  return String(name);
}

void setup() {
  Serial.begin(115200);
  analogReadResolution(12);
  pinMode(kAnalogPin, INPUT);

  String deviceName = buildDeviceName();
  BLEDevice::init(deviceName.c_str());

  BLEServer* server = BLEDevice::createServer();
  server->setCallbacks(new PlantieServerCallbacks());

  BLEService* service = server->createService(kServiceUuid);
  readingCharacteristic = service->createCharacteristic(
      kReadingCharacteristicUuid,
      BLECharacteristic::PROPERTY_READ | BLECharacteristic::PROPERTY_NOTIFY);
  readingCharacteristic->addDescriptor(new BLE2902());

  uint16_t initialValue = analogRead(kAnalogPin);
  readingCharacteristic->setValue(reinterpret_cast<uint8_t*>(&initialValue), sizeof(initialValue));

  service->start();
  BLEAdvertising* advertising = BLEDevice::getAdvertising();
  advertising->addServiceUUID(kServiceUuid);
  advertising->setScanResponse(true);
  BLEDevice::startAdvertising();

  Serial.printf("Advertising as %s\n", deviceName.c_str());
}

void loop() {
  unsigned long now = millis();
  if (!deviceConnected || now - lastNotifyAt < kNotifyIntervalMs) {
    delay(20);
    return;
  }

  lastNotifyAt = now;
  uint16_t reading = analogRead(kAnalogPin);
  readingCharacteristic->setValue(reinterpret_cast<uint8_t*>(&reading), sizeof(reading));
  readingCharacteristic->notify();

  Serial.printf("GPIO0 reading: %u\n", reading);
}
