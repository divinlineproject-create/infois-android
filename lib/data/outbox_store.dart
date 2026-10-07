import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import 'local_db.dart';

/// Status item outbox di HP.
class OutboxStatus {
  static const pending = 'pending';
  static const done = 'done';
  static const review = 'review';
  static const rejected = 'rejected';
}

class OutboxItem {
  const OutboxItem({
    required this.seq,
    required this.clientUuid,
    required this.type,
    required this.data,
    required this.status,
    this.attempts = 0,
    this.lastError,
    this.result,
    required this.createdAt,
  });

  factory OutboxItem.fromRow(Map<String, Object?> row) => OutboxItem(
        seq: row['seq'] as int,
        clientUuid: row['client_uuid'] as String,
        type: row['type'] as String,
        data: Map<String, dynamic>.from(jsonDecode(row['data'] as String) as Map),
        status: row['status'] as String,
        attempts: row['attempts'] as int? ?? 0,
        lastError: row['last_error'] as String?,
        result: row['result'] == null ? null : Map<String, dynamic>.from(jsonDecode(row['result'] as String) as Map),
        createdAt: DateTime.parse(row['created_at'] as String),
      );

  final int seq;
  final String clientUuid;
  final String type;
  final Map<String, dynamic> data;
  final String status;
  final int attempts;
  final String? lastError;
  final Map<String, dynamic>? result;
  final DateTime createdAt;

  /// Bentuk item untuk `POST /sync/push`.
  Map<String, dynamic> toPush() => {'type': type, 'client_uuid': clientUuid, 'data': data};
}

/// Antrean transaksi yang belum terkirim. Setiap item punya `client_uuid`
/// unik; memasukkan uuid yang sama dua kali diabaikan, dan server juga
/// menolak dobel, sehingga kirim ulang selalu aman.
class OutboxStore {
  OutboxStore(this.local);

  final LocalDb local;

  Database get _db => local.db;

  static const int batchSize = 50;

  /// Tambah ke antrean. Kembalikan false bila uuid sudah ada (mis. tombol bayar ditekan dua kali).
  Future<bool> enqueue(String type, String clientUuid, Map<String, dynamic> data, {DateTime? createdAt}) async {
    return _db.transaction((txn) async {
      final existing = await txn.query('outbox', columns: ['seq'], where: 'client_uuid = ?', whereArgs: [clientUuid], limit: 1);
      if (existing.isNotEmpty) {
        return false;
      }
      await txn.insert('outbox', {
        'client_uuid': clientUuid,
        'type': type,
        'data': jsonEncode(data),
        'status': OutboxStatus.pending,
        'created_at': (createdAt ?? DateTime.now()).toIso8601String(),
      });
      return true;
    });
  }

  /// Item berikutnya untuk dikirim, berurutan sesuai waktu dibuat.
  Future<List<OutboxItem>> pending({int limit = batchSize}) async {
    final rows = await _db.query('outbox', where: 'status = ?', whereArgs: [OutboxStatus.pending], orderBy: 'seq ASC', limit: limit);
    return [for (final row in rows) OutboxItem.fromRow(row)];
  }

  Future<int> pendingCount() async =>
      Sqflite.firstIntValue(await _db.rawQuery('SELECT COUNT(*) FROM outbox WHERE status = ?', [OutboxStatus.pending])) ?? 0;

  Future<List<OutboxItem>> problems({int limit = 100}) async {
    final rows = await _db.query('outbox', where: 'status IN (?, ?)', whereArgs: [OutboxStatus.review, OutboxStatus.rejected], orderBy: 'seq DESC', limit: limit);
    return [for (final row in rows) OutboxItem.fromRow(row)];
  }

  Future<OutboxItem?> find(String clientUuid) async {
    final rows = await _db.query('outbox', where: 'client_uuid = ?', whereArgs: [clientUuid], limit: 1);
    return rows.isEmpty ? null : OutboxItem.fromRow(rows.first);
  }

  /// Status lokal dari jawaban server per item.
  static String statusFor(Map<String, dynamic> result) {
    switch (result['status']) {
      case 'ok':
      case 'duplikat':
        return OutboxStatus.done;
      case 'perlu_ditinjau':
        return OutboxStatus.review;
      case 'ditolak':
        return result['retry'] == true ? OutboxStatus.pending : OutboxStatus.rejected;
      default:
        return OutboxStatus.pending;
    }
  }

  /// Simpan jawaban server. Item tanpa jawaban tetap menunggu.
  Future<void> applyResults(List<Map<String, dynamic>> results) async {
    final batch = _db.batch();
    final now = DateTime.now().toIso8601String();
    for (final result in results) {
      final uuid = result['client_uuid']?.toString();
      if (uuid == null || uuid.isEmpty) {
        continue;
      }
      final status = statusFor(result);
      if (status == OutboxStatus.pending) {
        batch.rawUpdate(
          'UPDATE outbox SET attempts = attempts + 1, last_error = ?, result = ? WHERE client_uuid = ?',
          [result['message']?.toString(), jsonEncode(result), uuid],
        );
        continue;
      }
      batch.update(
        'outbox',
        {'status': status, 'result': jsonEncode(result), 'last_error': status == OutboxStatus.done ? null : result['message']?.toString(), 'sent_at': now},
        where: 'client_uuid = ?',
        whereArgs: [uuid],
      );
    }
    await batch.commit(noResult: true);
  }

  /// Gagal kirim karena jaringan/server: item tetap menunggu, percobaan dicatat.
  Future<void> markAttemptFailed(List<OutboxItem> items, String error) async {
    final batch = _db.batch();
    for (final item in items) {
      batch.rawUpdate('UPDATE outbox SET attempts = attempts + 1, last_error = ? WHERE client_uuid = ?', [error, item.clientUuid]);
    }
    await batch.commit(noResult: true);
  }

  /// Kirim ulang item yang ditolak (mis. setelah hak akses diperbaiki).
  Future<void> retry(String clientUuid) async {
    await _db.update('outbox', {'status': OutboxStatus.pending, 'last_error': null}, where: 'client_uuid = ? AND status = ?', whereArgs: [clientUuid, OutboxStatus.rejected]);
  }

  /// Jeda sebelum mencoba lagi: 5 dtk, 10, 20, ... maksimal 5 menit.
  static Duration backoff(int attempts) {
    final seconds = 5 * (1 << (attempts.clamp(0, 6)));
    return Duration(seconds: seconds > 300 ? 300 : seconds);
  }
}
