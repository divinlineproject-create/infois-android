import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../core/config.dart';
import '../domain/models.dart';

/// Printer struk yang disimpan sebagai default.
class SavedPrinter {
  const SavedPrinter({required this.mac, required this.name, required this.width});

  final String mac;
  final String name;

  /// Lebar kertas 58 atau 80 mm.
  final int width;
}

/// Penyimpanan kecil di HP: token (aman, Keystore), ID HP, alamat server,
/// sesi terakhir (untuk dipakai saat offline), perusahaan aktif, printer.
class AppStorage {
  AppStorage(this.prefs, this.secure);

  final SharedPreferences prefs;
  final FlutterSecureStorage secure;

  static Future<AppStorage> load() async => AppStorage(
        await SharedPreferences.getInstance(),
        const FlutterSecureStorage(aOptions: AndroidOptions(encryptedSharedPreferences: true)),
      );

  static const _token = 'auth_token';
  static const _deviceUid = 'device_uid';
  static const _server = 'server_url';
  static const _session = 'session';
  static const _tenant = 'tenant_id';
  static const _printerMac = 'printer_mac';
  static const _printerName = 'printer_name';
  static const _printerWidth = 'printer_width';
  static const _autoPrint = 'auto_print';

  String get serverUrl => prefs.getString(_server) ?? AppConfig.defaultServerUrl;

  Future<void> setServerUrl(String url) => prefs.setString(_server, url.trim());

  Future<String?> token() => secure.read(key: _token);

  Future<void> setToken(String? token) => token == null ? secure.delete(key: _token) : secure.write(key: _token, value: token);

  /// ID unik pemasangan aplikasi ini; token server terikat ke ID ini.
  Future<String> deviceUid() async {
    final existing = await secure.read(key: _deviceUid) ?? prefs.getString(_deviceUid);
    if (existing != null && existing.isNotEmpty) {
      return existing;
    }
    final created = const Uuid().v4();
    await secure.write(key: _deviceUid, value: created);
    await prefs.setString(_deviceUid, created);
    return created;
  }

  /// User + daftar perusahaan dari login/`/me` terakhir.
  ({SessionUser user, List<TenantSummary> tenants})? session() {
    final raw = prefs.getString(_session);
    if (raw == null) {
      return null;
    }
    final json = Map<String, dynamic>.from(jsonDecode(raw) as Map);
    return (
      user: SessionUser.fromJson(Map<String, dynamic>.from(json['user'] as Map)),
      tenants: [for (final tenant in json['tenants'] as List) TenantSummary.fromJson(Map<String, dynamic>.from(tenant as Map))],
    );
  }

  Future<void> setSession(SessionUser? user, List<TenantSummary> tenants) => user == null
      ? prefs.remove(_session)
      : prefs.setString(_session, jsonEncode({'user': user.toJson(), 'tenants': [for (final tenant in tenants) tenant.toJson()]}));

  int? get tenantId => prefs.getInt(_tenant);

  Future<void> setTenantId(int? id) => id == null ? prefs.remove(_tenant) : prefs.setInt(_tenant, id);

  SavedPrinter? get printer {
    final mac = prefs.getString(_printerMac);
    if (mac == null || mac.isEmpty) {
      return null;
    }
    return SavedPrinter(mac: mac, name: prefs.getString(_printerName) ?? mac, width: prefs.getInt(_printerWidth) ?? 58);
  }

  Future<void> setPrinter(SavedPrinter? printer) async {
    if (printer == null) {
      await prefs.remove(_printerMac);
      await prefs.remove(_printerName);
      return;
    }
    await prefs.setString(_printerMac, printer.mac);
    await prefs.setString(_printerName, printer.name);
    await prefs.setInt(_printerWidth, printer.width);
  }

  int? get printerWidth => prefs.getInt(_printerWidth);

  Future<void> setPrinterWidth(int width) => prefs.setInt(_printerWidth, width);

  bool get autoPrint => prefs.getBool(_autoPrint) ?? true;

  Future<void> setAutoPrint(bool value) => prefs.setBool(_autoPrint, value);

  Future<void> clearSession() async {
    await setToken(null);
    await prefs.remove(_session);
    await prefs.remove(_tenant);
  }
}
