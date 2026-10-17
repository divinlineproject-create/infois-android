import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../domain/models.dart';

/// Ukuran foto barang: kecil (thumbnail persegi untuk grid & daftar) atau
/// besar (lembar barang).
enum PhotoSize { thumb, full }

/// Cache foto barang di HP. Foto diunduh dengan token + X-Tenant (rute
/// `products/{id}/photo` butuh login), disimpan sebagai file per perusahaan
/// dengan nama `{id}_{versi}_{ukuran}`, sehingga foto yang sudah pernah
/// tampil tetap muncul saat offline dan foto yang diganti di web (versi
/// berubah) diunduh ulang. Versi lama barang yang sama dihapus.
class ProductPhotoStore {
  ProductPhotoStore({required this.directory, required this.download, this.retryAfter = const Duration(minutes: 5)});

  /// Folder foto perusahaan ini.
  final Directory directory;

  /// Unduh isi foto (URL absolut atau relatif ke `/api/v1/`).
  final Future<List<int>> Function(String url) download;

  /// Jeda sebelum mencoba lagi foto yang gagal diunduh (offline / 404).
  final Duration retryAfter;

  final Map<String, File> _resolved = {};
  final Map<String, Future<File?>> _inFlight = {};
  final Map<String, DateTime> _failedAt = {};

  static String _key(Product product, PhotoSize size) => '${product.id}_${_safe(product.photoVersion ?? 'v0')}_${size == PhotoSize.thumb ? 't' : 'f'}';

  static String _safe(String value) => value.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '');

  /// Folder foto untuk satu user + perusahaan.
  static String folderName(int userId, int tenantId) => 'u${userId}_t$tenantId';

  /// Alamat unduhan foto, selalu rute relatif ke server aplikasi (token
  /// tidak pernah terkirim ke host lain walau `photo_url` dari server
  /// memakai alamat berbeda). `v` = versi foto (pemecah cache).
  static String urlFor(Product product, PhotoSize size) {
    final query = [if (size == PhotoSize.thumb) 'size=thumb', if (product.photoVersion != null) 'v=${Uri.encodeQueryComponent(product.photoVersion!)}'];
    return 'products/${product.id}/photo${query.isEmpty ? '' : '?${query.join('&')}'}';
  }

  /// File yang sudah diketahui ada di sesi ini (tanpa I/O), untuk tampil
  /// langsung tanpa kedip saat grid digulir.
  File? peek(Product product, PhotoSize size) => product.hasPhoto ? _resolved[_key(product, size)] : null;

  /// File di HP (tanpa mengunduh), atau null.
  Future<File?> cached(Product product, PhotoSize size) async {
    if (!product.hasPhoto) {
      return null;
    }
    final key = _key(product, size);
    final known = _resolved[key];
    if (known != null) {
      return known;
    }
    final file = File(p.join(directory.path, key));
    if (await file.exists() && await file.length() > 0) {
      return _resolved[key] = file;
    }
    return null;
  }

  /// File foto: dari HP bila ada, kalau tidak diunduh lalu disimpan. Null
  /// bila barang tanpa foto, offline, atau baru saja gagal.
  Future<File?> load(Product product, PhotoSize size) async {
    if (!product.hasPhoto) {
      return null;
    }
    final existing = await cached(product, size);
    if (existing != null) {
      return existing;
    }
    final key = _key(product, size);
    final failed = _failedAt[key];
    if (failed != null && DateTime.now().difference(failed) < retryAfter) {
      return null;
    }
    return _inFlight[key] ??= _fetch(product, size, key).whenComplete(() {
      // Blok, bukan `=>`: remove() mengembalikan Future ini sendiri dan
      // whenComplete akan menunggunya (macet).
      _inFlight.remove(key);
    });
  }

  Future<File?> _fetch(Product product, PhotoSize size, String key) async {
    try {
      final bytes = await download(urlFor(product, size));
      if (bytes.isEmpty) {
        _failedAt[key] = DateTime.now();
        return null;
      }
      await directory.create(recursive: true);
      final file = File(p.join(directory.path, key));
      final temp = File('${file.path}.part');
      await temp.writeAsBytes(bytes, flush: true);
      await temp.rename(file.path);
      _failedAt.remove(key);
      _resolved[key] = file;
      await _removeOldVersions(product, size, keep: key);
      return file;
    } catch (_) {
      // Offline / foto dihapus / server lama: tampil inisial, dicoba lagi nanti.
      _failedAt[key] = DateTime.now();
      return null;
    }
  }

  Future<void> _removeOldVersions(Product product, PhotoSize size, {required String keep}) async {
    final suffix = size == PhotoSize.thumb ? '_t' : '_f';
    try {
      await for (final entry in directory.list()) {
        final name = p.basename(entry.path);
        if (entry is File && name != keep && name.startsWith('${product.id}_') && name.endsWith(suffix)) {
          _resolved.removeWhere((_, file) => file.path == entry.path);
          await entry.delete();
        }
      }
    } catch (_) {
      // Sisa file lama tidak mengganggu; dibersihkan lain kali.
    }
  }

  /// Unduh thumbnail barang yang belum ada di HP (setelah sinkron), sedikit
  /// demi sedikit supaya HP murah tidak tersendat. Berhenti di kegagalan
  /// jaringan pertama (offline).
  Future<int> prefetchThumbs(Iterable<Product> products, {int limit = 300}) async {
    var fetched = 0;
    for (final product in products.where((product) => product.hasPhoto).take(limit)) {
      if (await cached(product, PhotoSize.thumb) != null) {
        continue;
      }
      final file = await load(product, PhotoSize.thumb);
      if (file == null) {
        break;
      }
      fetched++;
    }
    return fetched;
  }

  /// Hapus foto barang yang tidak ada lagi di katalog HP.
  Future<void> keepOnly(Set<int> productIds) async {
    try {
      if (!await directory.exists()) {
        return;
      }
      await for (final entry in directory.list()) {
        final id = int.tryParse(p.basename(entry.path).split('_').first);
        if (entry is File && id != null && !productIds.contains(id)) {
          await entry.delete();
        }
      }
      _resolved.removeWhere((key, _) => !productIds.contains(int.tryParse(key.split('_').first)));
    } catch (_) {
      // Abaikan: dibersihkan lain kali.
    }
  }

  /// Folder induk semua foto barang di HP.
  static Future<Directory> rootDirectory() async => Directory(p.join((await getApplicationSupportDirectory()).path, 'product_photos'));

  /// Hapus foto satu perusahaan ([tenantId]) atau semua perusahaan milik
  /// [userId] (keluar). Tidak pernah melempar galat.
  static Future<void> deleteFor(int userId, {int? tenantId}) async {
    try {
      final root = await rootDirectory();
      if (!await root.exists()) {
        return;
      }
      await for (final entry in root.list()) {
        final name = p.basename(entry.path);
        final match = tenantId == null ? name.startsWith('u${userId}_t') : name == folderName(userId, tenantId);
        if (entry is Directory && match) {
          await entry.delete(recursive: true);
        }
      }
    } catch (_) {
      // Tanpa plugin (tes) / folder tidak terbaca: tidak ada yang dihapus.
    }
  }
}
