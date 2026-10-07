import 'dart:io';

import 'package:permission_handler/permission_handler.dart';
import 'package:print_bluetooth_thermal/print_bluetooth_thermal.dart';

class PrinterDevice {
  const PrinterDevice({required this.name, required this.mac});

  final String name;
  final String mac;
}

/// Jalur ke printer (diganti di tes).
abstract class PrinterTransport {
  Future<bool> requestPermissions();
  Future<bool> bluetoothOn();
  Future<List<PrinterDevice>> pairedDevices();
  Future<bool> connect(String mac);
  Future<bool> isConnected();
  Future<bool> write(List<int> bytes);
  Future<void> disconnect();
}

/// Printer termal Bluetooth (Android: printer yang sudah dipasangkan di
/// pengaturan Bluetooth HP, SPP/Classic; iOS: BLE).
class BluetoothPrinterTransport implements PrinterTransport {
  @override
  Future<bool> requestPermissions() async {
    if (!Platform.isAndroid) {
      return true;
    }
    final statuses = await [Permission.bluetoothConnect, Permission.bluetoothScan, Permission.locationWhenInUse].request();
    final connect = statuses[Permission.bluetoothConnect];
    // Android 11 ke bawah tidak punya izin BLUETOOTH_CONNECT (dianggap diizinkan).
    return connect == null || connect.isGranted || connect.isLimited || await PrintBluetoothThermal.isPermissionBluetoothGranted;
  }

  @override
  Future<bool> bluetoothOn() => PrintBluetoothThermal.bluetoothEnabled;

  @override
  Future<List<PrinterDevice>> pairedDevices() async =>
      [for (final device in await PrintBluetoothThermal.pairedBluetooths) PrinterDevice(name: device.name, mac: device.macAdress)];

  @override
  Future<bool> connect(String mac) => PrintBluetoothThermal.connect(macPrinterAddress: mac);

  @override
  Future<bool> isConnected() => PrintBluetoothThermal.connectionStatus;

  @override
  Future<bool> write(List<int> bytes) => PrintBluetoothThermal.writeBytes(bytes);

  @override
  Future<void> disconnect() async {
    await PrintBluetoothThermal.disconnect;
  }
}
