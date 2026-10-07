import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../domain/models.dart';

/// Database lokal per user + perusahaan (data perusahaan terpisah). Menyimpan
/// salinan data master, outbox transaksi, riwayat nota, dan pengaturan sinkron.
class LocalDb {
  LocalDb(this.db);

  final Database db;

  static const int version = 1;

  static String fileName(int userId, int tenantId) => 'infois_u${userId}_t$tenantId.db';

  static Future<LocalDb> open(String path, {DatabaseFactory? factory}) async {
    final options = OpenDatabaseOptions(version: version, onCreate: (db, _) => _create(db));
    return LocalDb(await (factory ?? databaseFactory).openDatabase(path, options: options));
  }

  static Future<void> _create(Database db) async {
    final batch = db.batch();
    batch.execute('CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT)');
    batch.execute('CREATE TABLE products (id INTEGER PRIMARY KEY, name TEXT NOT NULL, sku TEXT, search TEXT NOT NULL, is_active INTEGER NOT NULL, data TEXT NOT NULL)');
    batch.execute('CREATE INDEX products_search ON products (search)');
    batch.execute('CREATE TABLE customers (key TEXT PRIMARY KEY, id INTEGER, client_uuid TEXT, name TEXT NOT NULL, search TEXT NOT NULL, data TEXT NOT NULL)');
    batch.execute(
      'CREATE TABLE outbox (seq INTEGER PRIMARY KEY AUTOINCREMENT, client_uuid TEXT NOT NULL UNIQUE, type TEXT NOT NULL, data TEXT NOT NULL, '
      "status TEXT NOT NULL DEFAULT 'pending', attempts INTEGER NOT NULL DEFAULT 0, last_error TEXT, result TEXT, created_at TEXT NOT NULL, sent_at TEXT)",
    );
    batch.execute(
      'CREATE TABLE sales (client_uuid TEXT PRIMARY KEY, number TEXT, created_at TEXT NOT NULL, total TEXT NOT NULL, '
      "sync_status TEXT NOT NULL DEFAULT 'menunggu', message TEXT, data TEXT NOT NULL)",
    );
    batch.execute('CREATE INDEX sales_created ON sales (created_at)');
    batch.execute(
      'CREATE TABLE shifts (client_uuid TEXT PRIMARY KEY, opened_at TEXT NOT NULL, closed_at TEXT, opening_cash TEXT NOT NULL, '
      'closing_cash TEXT, data TEXT NOT NULL)',
    );
    await batch.commit(noResult: true);
  }

  Future<void> close() => db.close();

  // ---------------------------------------------------------------- meta

  Future<String?> getMeta(String key) async {
    final rows = await db.query('meta', where: 'key = ?', whereArgs: [key], limit: 1);
    return rows.isEmpty ? null : rows.first['value'] as String?;
  }

  Future<void> setMeta(String key, String? value) async {
    if (value == null) {
      await db.delete('meta', where: 'key = ?', whereArgs: [key]);
      return;
    }
    await db.insert('meta', {'key': key, 'value': value}, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<Map<String, dynamic>?> getJson(String key) async {
    final value = await getMeta(key);
    return value == null ? null : Map<String, dynamic>.from(jsonDecode(value) as Map);
  }

  Future<void> setJson(String key, Object? value) => setMeta(key, value == null ? null : jsonEncode(value));

  // ------------------------------------------------------------ products

  Future<void> upsertProducts(List<Product> products) async {
    final batch = db.batch();
    for (final product in products) {
      batch.insert(
        'products',
        {
          'id': product.id,
          'name': product.name,
          'sku': product.sku,
          'search': '${product.name} ${product.sku ?? ''}'.toLowerCase(),
          'is_active': product.isActive ? 1 : 0,
          'data': jsonEncode(product.toJson()),
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    await batch.commit(noResult: true);
  }

  /// Hapus barang yang tidak ada lagi di server.
  Future<void> keepProducts(List<int> ids) async {
    final existing = (await db.query('products', columns: ['id'])).map((row) => row['id'] as int).toSet();
    final remove = existing.difference(ids.toSet());
    if (remove.isEmpty) {
      return;
    }
    final batch = db.batch();
    for (final id in remove) {
      batch.delete('products', where: 'id = ?', whereArgs: [id]);
    }
    await batch.commit(noResult: true);
  }

  Future<List<Product>> products({String query = '', bool activeOnly = true, int limit = 500}) async {
    final where = <String>[];
    final args = <Object>[];
    if (activeOnly) {
      where.add('is_active = 1');
    }
    for (final word in query.toLowerCase().split(RegExp(r'\s+')).where((word) => word.isNotEmpty)) {
      where.add('search LIKE ?');
      args.add('%$word%');
    }
    final rows = await db.query('products', where: where.isEmpty ? null : where.join(' AND '), whereArgs: args, orderBy: 'name COLLATE NOCASE', limit: limit);
    return [for (final row in rows) Product.fromJson(Map<String, dynamic>.from(jsonDecode(row['data'] as String) as Map))];
  }

  Future<Product?> productBySku(String sku) async {
    final rows = await db.query('products', where: 'LOWER(sku) = ?', whereArgs: [sku.toLowerCase()], limit: 1);
    return rows.isEmpty ? null : Product.fromJson(Map<String, dynamic>.from(jsonDecode(rows.first['data'] as String) as Map));
  }

  Future<int> productCount() async => Sqflite.firstIntValue(await db.rawQuery('SELECT COUNT(*) FROM products')) ?? 0;

  // ----------------------------------------------------------- customers

  Future<void> upsertCustomers(List<Customer> customers) async {
    final batch = db.batch();
    for (final customer in customers) {
      if (customer.id != null && customer.clientUuid != null) {
        // Pelanggan yang dibuat di HP sudah punya id server: hapus versi sementara.
        batch.delete('customers', where: 'key = ?', whereArgs: ['uuid:${customer.clientUuid}']);
      }
      batch.insert(
        'customers',
        {
          'key': customer.key,
          'id': customer.id,
          'client_uuid': customer.clientUuid,
          'name': customer.name,
          'search': '${customer.name} ${customer.phone ?? ''}'.toLowerCase(),
          'data': jsonEncode(customer.toJson()),
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    await batch.commit(noResult: true);
  }

  /// Hapus pelanggan server yang sudah dihapus (pelanggan baru dari HP tetap).
  Future<void> keepCustomers(List<int> ids) async {
    final keep = ids.toSet();
    final rows = await db.query('customers', columns: ['key', 'id'], where: 'id IS NOT NULL');
    final batch = db.batch();
    for (final row in rows) {
      if (!keep.contains(row['id'] as int)) {
        batch.delete('customers', where: 'key = ?', whereArgs: [row['key']]);
      }
    }
    await batch.commit(noResult: true);
  }

  Future<List<Customer>> customers({String query = '', int limit = 100}) async {
    final where = <String>[];
    final args = <Object>[];
    for (final word in query.toLowerCase().split(RegExp(r'\s+')).where((word) => word.isNotEmpty)) {
      where.add('search LIKE ?');
      args.add('%$word%');
    }
    final rows = await db.query('customers', where: where.isEmpty ? null : where.join(' AND '), whereArgs: args, orderBy: 'name COLLATE NOCASE', limit: limit);
    return [for (final row in rows) Customer.fromJson(Map<String, dynamic>.from(jsonDecode(row['data'] as String) as Map))];
  }

  // ---------------------------------------------------------------- sales

  Future<void> saveSale(String clientUuid, {required String? number, required DateTime createdAt, required String total, required Map<String, dynamic> data}) async {
    await db.insert(
      'sales',
      {'client_uuid': clientUuid, 'number': number, 'created_at': createdAt.toIso8601String(), 'total': total, 'sync_status': 'menunggu', 'data': jsonEncode(data)},
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  Future<void> updateSaleSync(String clientUuid, {required String status, String? number, String? message, Map<String, dynamic>? patch}) async {
    final rows = await db.query('sales', where: 'client_uuid = ?', whereArgs: [clientUuid], limit: 1);
    if (rows.isEmpty) {
      return;
    }
    final data = Map<String, dynamic>.from(jsonDecode(rows.first['data'] as String) as Map)..addAll(patch ?? const {});
    if (number != null) {
      data['number'] = number;
    }
    await db.update(
      'sales',
      {'sync_status': status, 'message': message, if (number != null) 'number': number, 'data': jsonEncode(data)},
      where: 'client_uuid = ?',
      whereArgs: [clientUuid],
    );
  }

  Future<List<Map<String, dynamic>>> recentSales({int limit = 100, String? shiftClientUuid}) async {
    final rows = await db.query('sales', orderBy: 'created_at DESC', limit: limit);
    final sales = [
      for (final row in rows)
        {
          ...Map<String, dynamic>.from(jsonDecode(row['data'] as String) as Map),
          'sync_status': row['sync_status'],
          'sync_message': row['message'],
        },
    ];
    return shiftClientUuid == null ? sales : sales.where((sale) => sale['shift_client_uuid'] == shiftClientUuid).toList();
  }

  // --------------------------------------------------------------- shifts

  Future<void> saveShift(Map<String, dynamic> shift) async {
    await db.insert(
      'shifts',
      {
        'client_uuid': shift['client_uuid'],
        'opened_at': shift['opened_at'],
        'closed_at': shift['closed_at'],
        'opening_cash': shift['opening_cash'],
        'closing_cash': shift['closing_cash'],
        'data': jsonEncode(shift),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<Map<String, dynamic>?> openShift() async {
    final rows = await db.query('shifts', where: 'closed_at IS NULL', orderBy: 'opened_at DESC', limit: 1);
    return rows.isEmpty ? null : Map<String, dynamic>.from(jsonDecode(rows.first['data'] as String) as Map);
  }
}
