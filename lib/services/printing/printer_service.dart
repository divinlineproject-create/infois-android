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
    // Hanya printer yang sudah dipasangkan (tanpa memindai): lokasi tidak
    // perlu. BLUETOOTH_SCAN tetap diminta (Android 12+) karena plugin
    // memanggil cancelDiscovery() sebelum menyambung. Android 11 ke bawah:
    // keduanya dianggap diizinkan oleh permission_handler.
    final statuses = await [Permission.bluetoothConnect, Permission.bluetoothScan].request();
    final connect = statuses[Permission.bluetoothConnect];
    // Android 11 ke bawah tidak punya izin BLUETOOTH_CONNECT (dianggap diizinkan).
    return connect == null || connect.isGranted || connect.isLimited || await PrintBluetoothThermal.isPermissionBluetoothGranted;
  }

  @override
  Future<bool> bluetoothOn() => PrintBluetoothThermal.bluetoothEnabled;

  @override
  Future<List<PrinterDevice>> pairedDevices() async => [for (final device in await PrintBluetoothThermal.pairedBluetooths) PrinterDevice(name: device.name, mac: device.macAdress)];

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

/// Printer jaringan (Wi-Fi / LAN): perintah ESC/POS mentah lewat TCP
/// (umumnya port 9100). Diganti di tes.
abstract class NetworkPrinterTransport {
  Future<bool> send(String host, int port, List<int> bytes);

  /// Alamat IP printer di jaringan yang sama dengan HP (port [port] terbuka).
  Future<List<String>> discover({int port = 9100});
}

class SocketPrinterTransport implements NetworkPrinterTransport {
  const SocketPrinterTransport({this.connectTimeout = const Duration(seconds: 4), this.probeTimeout = const Duration(milliseconds: 700)});

  final Duration connectTimeout;
  final Duration probeTimeout;

  @override
  Future<bool> send(String host, int port, List<int> bytes) async {
    Socket? socket;
    try {
      socket = await Socket.connect(host, port, timeout: connectTimeout);
      socket.add(bytes);
      await socket.flush().timeout(const Duration(seconds: 10));
      // Sebagian printer tidak menutup sambungannya: cukup tunggu sebentar.
      await socket.close().timeout(const Duration(seconds: 2), onTimeout: () => socket);
      return true;
    } on Object {
      return false;
    } finally {
      socket?.destroy();
    }
  }

  @override
  Future<List<String>> discover({int port = 9100}) async {
    final own = <String>{};
    final prefixes = <String>{};
    for (final interface in await NetworkInterface.list(type: InternetAddressType.IPv4)) {
      for (final address in interface.addresses) {
        final parts = address.address.split('.');
        if (parts.length == 4 && isPrivateIPv4(address.address)) {
          own.add(address.address);
          prefixes.add(parts.take(3).join('.'));
        }
      }
    }
    final candidates = [
      for (final prefix in prefixes)
        for (var host = 1; host < 255; host++)
          if (!own.contains('$prefix.$host')) '$prefix.$host',
    ];
    final found = <String>[];
    // Dicoba bertahap (48 sekaligus) supaya jaringan & HP tidak terbebani.
    for (var start = 0; start < candidates.length; start += 48) {
      final batch = candidates.skip(start).take(48);
      final open = await Future.wait(
        batch.map((host) async {
          try {
            final socket = await Socket.connect(host, port, timeout: probeTimeout);
            socket.destroy();
            return host;
          } on Object {
            return null;
          }
        }),
      );
      found.addAll(open.whereType<String>());
    }
    return found;
  }

  static bool isPrivateIPv4(String address) {
    final parts = [for (final part in address.split('.')) int.tryParse(part) ?? -1];
    if (parts.length != 4) {
      return false;
    }
    return parts[0] == 10 || (parts[0] == 172 && parts[1] >= 16 && parts[1] <= 31) || (parts[0] == 192 && parts[1] == 168);
  }
}
