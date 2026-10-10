import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart' show getDatabasesPath;
import 'package:uuid/uuid.dart';

import '../core/config.dart';
import '../domain/models.dart';

/// Data lokal milik server lama belum berhasil dipindah ke karantina, jadi
/// database lokal belum boleh dibuka (lihat [AppStorage.ensureServerMigrated]).
class ServerMigrationPending implements Exception {
  const ServerMigrationPending();

  String get message => 'Data lama di HP ini belum selesai dipindahkan. Tutup aplikasi lalu buka lagi.';

  @override
  String toString() => message;
}

/// Printer struk yang disimpan sebagai default.
class SavedPrinter {
  const SavedPrinter({required this.mac, required this.name, required this.width});

  final String mac;
  final String name;

  /// Lebar kertas 58 atau 80 mm.
  final int width;
}

/// Penyimpanan kecil di HP: token (aman, Keystore), ID HP, sesi terakhir
/// (untuk dipakai saat offline), perusahaan aktif, printer.
///
/// Alamat server TIDAK disimpan di sini: tetap sejak build
/// ([AppConfig.serverUrl]). Yang disimpan hanya penanda server pemilik
/// login & data lokal di HP ([dataServerKey]) untuk perpindahan server.
class AppStorage {
  AppStorage(this.prefs, this.secure);

  final SharedPreferences prefs;
  final FlutterSecureStorage secure;

  /// Muat penyimpanan lalu jalankan [migrateServer] (dipanggil juga oleh
  /// sinkron latar, jadi data server lama tidak pernah ikut terkirim).
  static Future<AppStorage> load({String builtInServer = AppConfig.serverUrl}) async {
    final storage = AppStorage(
      await SharedPreferences.getInstance(),
      const FlutterSecureStorage(aOptions: AndroidOptions(encryptedSharedPreferences: true)),
    );
    await storage.migrateServer(builtInServer: builtInServer);
    return storage;
  }

  static const _token = 'auth_token';
  static const _deviceUid = 'device_uid';

  /// Versi lama: alamat server yang diketik di layar Masuk › Server.
  @visibleForTesting
  static const legacyServerKey = 'server_url';

  /// Server pemilik login + database lokal di HP ini.
  @visibleForTesting
  static const dataServerKey = 'data_server';
  /// Server lama yang login-nya sudah dilepas (perpindahan belum tuntas).
  static const _droppedLogin = 'data_server_login_dropped';
  static const _session = 'session';
  static const _tenant = 'tenant_id';
  static const _printerMac = 'printer_mac';
  static const _printerName = 'printer_name';
  static const _printerWidth = 'printer_width';
  static const _autoPrint = 'auto_print';
  static const _themeMode = 'theme_mode';
  static const _foregroundAt = 'foreground_at';

  /// Server aplikasi (tetap sejak build, lihat [AppConfig.serverUrl]).
  String get serverUrl => AppConfig.serverUrl;

  /// Pindahkan file database lokal server lama ke tempat karantina (diganti
  /// di tes). Default: [quarantineLocalDataIn] di folder database sqflite.
  @visibleForTesting
  static Future<List<String>> Function(String oldServer) quarantineLocalData = _quarantineInDatabasesPath;

  static Future<List<String>> _quarantineInDatabasesPath(String oldServer) async => quarantineLocalDataIn(Directory(await getDatabasesPath()), oldServer);

  /// Server bawaan yang dipakai [migrateServer] terakhir (tes bisa memakai
  /// server lain lewat parameter `builtInServer`).
  String _builtInServer = AppConfig.serverUrl;

  /// Login/data di HP masih milik server lain dan file database-nya belum
  /// berhasil dipindah ke karantina. Selama ini benar, database lokal tidak
  /// boleh dibuka atau disinkron (lihat [ensureServerMigrated]).
  bool get serverMigrationPending {
    final legacy = prefs.getString(legacyServerKey)?.trim();
    final marker = prefs.getString(dataServerKey)?.trim();
    final previous = (legacy != null && legacy.isNotEmpty) ? legacy : marker;
    return previous != null && previous.isNotEmpty && !sameServer(previous, _builtInServer);
  }

  /// Sesuaikan HP dengan server bawaan build ini.
  ///
  /// - Alamat server ketikan versi lama ([legacyServerKey]) diabaikan lalu
  ///   dihapus.
  /// - Bila login/data di HP milik server lain (ketikan lama, atau penanda
  ///   [dataServerKey] dari build lain): login dihapus (tokennya milik
  ///   server lain) dan file database lokal dipindah utuh ke karantina,
  ///   tidak dibuka dan tidak pernah disinkron ke server ini. Nomor
  ///   user/perusahaan di server lain bisa sama dengan di server ini, jadi
  ///   file itu tidak boleh terbuka lagi atas nama login baru.
  /// - Belum ada penanda sama sekali (pemasangan versi lama tanpa ketikan
  ///   server): dianggap milik server bawaan, cukup diberi penanda.
  ///
  /// Penanda baru hanya ditulis setelah SEMUA file database lama keluar dari
  /// folder database. Bila pemindahan gagal (atau sedang dikerjakan proses
  /// lain, mis. sinkron latar), penanda lama dibiarkan: perpindahan diulang
  /// saat aplikasi dibuka lagi dan [serverMigrationPending] tetap benar.
  ///
  /// Mengembalikan alamat server lama yang dilepas, atau null.
  Future<String?> migrateServer({String builtInServer = AppConfig.serverUrl}) async {
    _builtInServer = builtInServer;
    // Baca ulang dari disk: aplikasi dan sinkron latar punya salinan sendiri.
    await prefs.reload();
    final legacy = prefs.getString(legacyServerKey)?.trim();
    final marker = prefs.getString(dataServerKey)?.trim();
    final previous = (legacy != null && legacy.isNotEmpty) ? legacy : marker;
    String? dropped;
    if (previous != null && previous.isNotEmpty && !sameServer(previous, builtInServer)) {
      dropped = previous;
      // Login server lama dilepas sekali saja: bila pemindahan file perlu
      // diulang, login baru (ke server ini) tidak ikut terhapus.
      if (prefs.getString(_droppedLogin) != previous) {
        await clearSession();
        await prefs.setString(_droppedLogin, previous);
      }
      try {
        final moved = await quarantineLocalData(previous);
        debugPrint('Infois: data lokal server lama $previous dikarantina (tidak disinkron ke $builtInServer): ${moved.isEmpty ? 'tidak ada file' : moved.join(', ')}');
      } catch (error) {
        // Penanda lama tetap: diulang saat dibuka lagi, database tidak dibuka.
        debugPrint('Infois: gagal mengarantina data lokal server lama $previous (diulang nanti): $error');
        return dropped;
      }
    }
    // Penanda ditulis terakhir: bila terputus/gagal di tengah, diulang saat dibuka lagi.
    if (prefs.containsKey(legacyServerKey)) {
      await prefs.remove(legacyServerKey);
    }
    if (marker != builtInServer) {
      await prefs.setString(dataServerKey, builtInServer);
    }
    if (prefs.containsKey(_droppedLogin)) {
      await prefs.remove(_droppedLogin);
    }
    return dropped;
  }

  /// Dipanggil sebelum membuka database lokal: bila perpindahan server belum
  /// tuntas, coba sekali lagi; bila masih gagal, lempar [ServerMigrationPending]
  /// supaya database server lama tidak terbuka atas nama login baru.
  Future<void> ensureServerMigrated() async {
    if (!serverMigrationPending) {
      return;
    }
    await migrateServer(builtInServer: _builtInServer);
    if (serverMigrationPending) {
      throw const ServerMigrationPending();
    }
  }

  /// Dua alamat server sama (abaikan spasi, huruf besar, `/` di akhir).
  static bool sameServer(String a, String b) {
    String normalize(String url) => url.trim().toLowerCase().replaceAll(RegExp(r'/+$'), '');
    return normalize(a) == normalize(b);
  }

  /// Nama file kunci selama pemindahan (satu proses saja yang memindah).
  @visibleForTesting
  static const quarantineLockName = 'server_lama.lock';

  /// Kunci yang lebih tua dari ini dianggap sisa proses yang terhenti.
  static const _staleLock = Duration(minutes: 2);

  /// Pindahkan file database lokal (`infois_u*`, termasuk `-wal`/`-shm`/
  /// `-journal`) di [directory] ke `server_lama/<server>-<waktu>/` tanpa
  /// mengubah isinya. Aplikasi hanya membuka `infois_u*` langsung di
  /// [directory], jadi file karantina tidak dibuka, tidak dihitung, dan tidak
  /// disinkron. Mengembalikan nama file yang dipindah.
  ///
  /// Melempar [FileSystemException] bila masih ada `infois_u*` di [directory]
  /// sesudahnya, atau bila proses lain (aplikasi / sinkron latar) sedang
  /// memindah: pemanggil tidak boleh menganggap perpindahan selesai.
  static Future<List<String>> quarantineLocalDataIn(Directory directory, String oldServer) async {
    if (!directory.existsSync()) {
      return const [];
    }
    List<File> leftovers() => [
          for (final entity in directory.listSync())
            if (entity is File && p.basename(entity.path).startsWith('infois_u')) entity,
        ];
    if (leftovers().isEmpty) {
      return const [];
    }
    final lock = File(p.join(directory.path, quarantineLockName));
    try {
      await lock.create(exclusive: true);
    } on FileSystemException {
      if (lock.existsSync() && DateTime.now().difference(lock.statSync().modified) < _staleLock) {
        throw FileSystemException('Data server lama sedang dipindah oleh proses lain', lock.path);
      }
      // Kunci sisa proses yang terhenti: ambil alih.
      await lock.writeAsString('');
    }
    try {
      final files = leftovers();
      final label = oldServer.replaceAll(RegExp(r'^[a-zA-Z]+://'), '').replaceAll(RegExp(r'[^a-zA-Z0-9.-]+'), '_');
      final target = Directory(p.join(directory.path, 'server_lama', '$label-${DateTime.now().millisecondsSinceEpoch}'));
      await target.create(recursive: true);
      final moved = <String>[];
      for (final file in files) {
        final name = p.basename(file.path);
        try {
          await file.rename(p.join(target.path, name));
          moved.add(name);
        } catch (error) {
          debugPrint('Infois: gagal memindah $name: $error');
        }
      }
      final remaining = leftovers();
      if (remaining.isNotEmpty) {
        throw FileSystemException('Data server lama belum bisa dipindah: ${remaining.map((file) => p.basename(file.path)).join(', ')}', directory.path);
      }
      return moved;
    } finally {
      try {
        await lock.delete();
      } catch (_) {
        // Kunci yang tertinggal dianggap kedaluwarsa setelah [_staleLock].
      }
    }
  }

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

  /// Tampilan: `system` (ikuti HP), `light`, atau `dark`.
  String get themeMode => switch (prefs.getString(_themeMode)) {
        'light' => 'light',
        'dark' => 'dark',
        _ => 'system',
      };

  Future<void> setThemeMode(String mode) => prefs.setString(_themeMode, mode);

  /// Tanda aplikasi sedang dibuka di layar (diperbarui berkala selama
  /// tampil). Sinkron latar dilewati selama tanda ini masih baru supaya tidak
  /// berebut database dengan aplikasi.
  Future<void> markForeground(bool active) => active ? prefs.setInt(_foregroundAt, DateTime.now().millisecondsSinceEpoch) : prefs.remove(_foregroundAt);

  /// Aplikasi tampil di layar dalam [within] terakhir (dibaca ulang dari disk:
  /// dipanggil dari tugas latar yang punya salinan sendiri).
  Future<bool> foregroundActive({Duration within = const Duration(minutes: 20)}) async {
    await prefs.reload();
    final at = prefs.getInt(_foregroundAt);
    return at != null && DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(at)) < within;
  }

  /// Hapus login dari HP. Tiap langkah berdiri sendiri: penyimpanan aman yang
  /// rusak (Keystore) tidak boleh membuat tombol Keluar macet.
  Future<void> clearSession() async {
    try {
      await setToken(null);
    } catch (_) {
      // Token tetap tidak dipakai: sesi di bawah ini yang menentukan login.
    }
    await prefs.remove(_session);
    await prefs.remove(_tenant);
  }
}
