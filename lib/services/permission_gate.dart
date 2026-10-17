import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Izin Android yang dijelaskan dulu sebelum jendela izin sistem muncul.
enum AppPermission {
  /// Voice note Tim AI (RECORD_AUDIO).
  microphone,

  /// Printer struk Bluetooth yang sudah dipasangkan (Android 12+:
  /// BLUETOOTH_CONNECT/SCAN "Perangkat sekitar"; tanpa izin lokasi).
  bluetoothPrinter,
}

/// Apakah penjelasan izin [AppPermission] perlu ditampilkan (izin belum
/// diberikan dan belum pernah dijelaskan di HP ini).
abstract class PermissionGate {
  Future<bool> needsRationale(AppPermission permission);

  /// Penjelasan sudah ditampilkan dan pengguna memilih Lanjutkan.
  Future<void> markExplained(AppPermission permission);
}

/// Cek status izin di HP. Selain Android, atau bila plugin tidak tersedia
/// (tes), dianggap tidak perlu penjelasan. Penjelasan cukup sekali per izin
/// (diingat di SharedPreferences).
class DevicePermissionGate implements PermissionGate {
  const DevicePermissionGate();

  static String _key(AppPermission permission) => 'permission_explained_${permission.name}';

  @override
  Future<void> markExplained(AppPermission permission) async {
    try {
      await (await SharedPreferences.getInstance()).setBool(_key(permission), true);
    } catch (_) {
      // Gagal menyimpan: penjelasan muncul lagi lain kali, tidak masalah.
    }
  }

  @override
  Future<bool> needsRationale(AppPermission permission) async {
    if (!Platform.isAndroid) {
      return false;
    }
    try {
      if ((await SharedPreferences.getInstance()).getBool(_key(permission)) ?? false) {
        return false;
      }
      final permissions = switch (permission) {
        AppPermission.microphone => [Permission.microphone],
        AppPermission.bluetoothPrinter => [Permission.bluetoothConnect, Permission.bluetoothScan],
      };
      for (final item in permissions) {
        final status = await item.status;
        // permanentlyDenied: jendela sistem tidak muncul lagi; pesan galat
        // yang ada sudah mengarahkan ke pengaturan HP.
        if (status.isDenied) {
          return true;
        }
      }
      return false;
    } catch (_) {
      return false;
    }
  }
}

final permissionGateProvider = Provider<PermissionGate>((ref) => const DevicePermissionGate());

/// Judul & isi penjelasan izin (bahasa sehari-hari).
(String, String) permissionRationale(AppPermission permission) => switch (permission) {
      AppPermission.microphone => (
          'Izinkan mikrofon',
          'Infois memakai mikrofon hanya saat Anda menekan tombol voice note di Tim AI. Rekaman dikirim ke server Infois dan penyedia AI kami untuk diubah menjadi teks lalu diproses Tim AI. Infois tidak merekam di luar itu.',
        ),
      AppPermission.bluetoothPrinter => (
          'Izinkan Bluetooth',
          'Infois memakai izin Perangkat sekitar (Bluetooth) hanya untuk menampilkan printer struk yang sudah dipasangkan di HP ini dan menyambung ke printer itu. Infois tidak memindai perangkat lain dan tidak meminta lokasi Anda.',
        ),
    };

/// Tampilkan penjelasan sebelum meminta izin. Hasil `false` = pengguna
/// memilih Nanti (jangan minta izin sekarang). Bila izin sudah diberikan,
/// langsung `true` tanpa dialog.
Future<bool> explainPermission(BuildContext context, WidgetRef ref, AppPermission permission) async {
  final gate = ref.read(permissionGateProvider);
  if (!await gate.needsRationale(permission)) {
    return true;
  }
  if (!context.mounted) {
    return false;
  }
  final (title, body) = permissionRationale(permission);
  final ok = await showDialog<bool>(
    context: context,
    builder: (dialog) => AlertDialog(
      key: Key('permission-rationale-${permission.name}'),
      title: Text(title),
      content: Text(body),
      actions: [
        TextButton(onPressed: () => Navigator.pop(dialog, false), child: const Text('Nanti')),
        FilledButton(key: const Key('permission-rationale-continue'), onPressed: () => Navigator.pop(dialog, true), child: const Text('Lanjutkan')),
      ],
    ),
  );
  if (ok == true) {
    await gate.markExplained(permission);
  }
  return ok == true;
}
