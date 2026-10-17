import 'dart:convert';

import '../core/config.dart';
import '../data/api_client.dart';
import '../data/local_db.dart';
import '../data/outbox_store.dart';
import '../domain/models.dart';
import '../domain/numbering.dart';

/// Kunci data di tabel meta.
class MetaKeys {
  static const cursor = 'sync_cursor';
  static const lastFullPull = 'last_full_pull';
  static const lastSyncAt = 'last_sync_at';
  static const tenant = 'tenant_settings';
  static const receipt = 'receipt_config';
  static const device = 'device';
  static const menus = 'menus';
  static const accounts = 'accounts';
  static const warehouses = 'warehouses';
  static const numberBlocks = 'number_blocks';
  static const lastNumberSeq = 'last_number_seq';
  static const logoVersion = 'logo_version';
  static const logoBytes = 'logo_bytes';
  static const user = 'user';
}

class PushSummary {
  const PushSummary({this.sent = 0, this.review = 0, this.rejected = 0, this.failed = false, this.error});

  final int sent;
  final int review;
  final int rejected;
  final bool failed;
  final String? error;
}

class PingResult {
  const PingResult({required this.ok, this.minAppVersion, this.serverTime});

  final bool ok;
  final String? minAppVersion;
  final DateTime? serverTime;

  bool get mustUpdate => minAppVersion != null && compareVersions(AppConfig.version, minAppVersion!) < 0;
}

/// Mesin sinkron tanpa UI (dipakai aplikasi dan tugas latar): cek internet,
/// kirim outbox berurutan (maks. 50 per kiriman), tarik data master, dan
/// minta jatah nomor nota offline bila hampir habis.
class SyncEngine {
  SyncEngine({required this.api, required this.local, required this.outbox});

  final ApiClient api;
  final LocalDb local;
  final OutboxStore outbox;

  /// Tarikan penuh minimal sekali sehari supaya perubahan kecil (mis. harga
  /// grosir yang dihapus) pasti ikut.
  static const Duration fullPullEvery = Duration(hours: 24);

  /// Satu kiriman berisi sampai 50 penjualan; tiap penjualan dibukukan
  /// (stok, HPP, jurnal) sehingga server bisa butuh > 1 detik per nota.
  static const Duration pushTimeout = Duration(minutes: 3);

  Future<PingResult> ping() async {
    try {
      final data = await api.get('ping', timeout: AppConfig.pingTimeout);
      return PingResult(ok: data['ok'] == true, minAppVersion: data['min_app_version']?.toString(), serverTime: DateTime.tryParse(data['server_time']?.toString() ?? ''));
    } on ApiException {
      return const PingResult(ok: false);
    }
  }

  /// Kirim semua item outbox. Gagal jaringan menghentikan kiriman (dicoba lagi nanti).
  Future<PushSummary> pushAll() async {
    var sent = 0;
    var review = 0;
    var rejected = 0;
    final seen = <String>{};

    while (true) {
      final items = (await outbox.pending()).where((item) => !seen.contains(item.clientUuid)).toList();
      if (items.isEmpty) {
        break;
      }
      seen.addAll(items.map((item) => item.clientUuid));

      final List<Map<String, dynamic>> results;
      try {
        final response = await api.post('sync/push', data: {'items': [for (final item in items) item.toPush()]}, timeout: pushTimeout);
        results = [for (final result in (response['results'] as List? ?? const [])) Map<String, dynamic>.from(result as Map)];
      } on ApiException catch (error) {
        if (error.companyClosed || error.notMember) {
          // Bukan galat per transaksi: perusahaan ditutup / user dikeluarkan.
          // Pemanggil yang memutuskan (pesan + hapus data), tanpa coba ulang.
          rethrow;
        }
        await outbox.markAttemptFailed(items, error.message);
        return PushSummary(sent: sent, review: review, rejected: rejected, failed: true, error: error.message);
      }

      await outbox.applyResults(results);
      for (final result in results) {
        await _applyLocally(result);
        switch (OutboxStore.statusFor(result)) {
          case OutboxStatus.done:
            sent++;
          case OutboxStatus.review:
            review++;
          case OutboxStatus.rejected:
            rejected++;
        }
      }
    }

    return PushSummary(sent: sent, review: review, rejected: rejected);
  }

  /// Perbarui catatan lokal (riwayat nota, pelanggan, shift) dari jawaban server.
  Future<void> _applyLocally(Map<String, dynamic> result) async {
    final uuid = result['client_uuid']?.toString() ?? '';
    final status = result['status']?.toString();
    switch (result['type']) {
      case 'sale':
        final localStatus = switch (status) {
          'ok' || 'duplikat' => result['needs_review'] == true ? 'perlu_ditinjau' : 'terkirim',
          'perlu_ditinjau' => 'perlu_ditinjau',
          'ditolak' => result['retry'] == true ? 'menunggu' : 'ditolak',
          _ => 'menunggu',
        };
        await local.updateSaleSync(
          uuid,
          status: localStatus,
          number: result['number']?.toString(),
          message: result['message']?.toString() ?? ((result['warnings'] as List?)?.isNotEmpty == true ? (result['warnings'] as List).join(' ') : null),
          patch: {
            if (result['verification_url'] != null) 'verification_url': result['verification_url'],
            if (result['invoice_status'] != null) 'invoice_status': result['invoice_status'],
          },
        );
      case 'customer':
        final id = result['customer_id'];
        if (id is int) {
          final rows = await local.db.query('customers', where: 'client_uuid = ?', whereArgs: [uuid], limit: 1);
          if (rows.isNotEmpty) {
            final customer = Customer.fromJson(Map<String, dynamic>.from(jsonDecode(rows.first['data'] as String) as Map));
            await local.upsertCustomers([
              Customer(id: id, clientUuid: uuid, name: customer.name, phone: customer.phone, email: customer.email, address: customer.address),
            ]);
          }
        }
      case 'shift_open':
      case 'shift_close':
        final shift = result['shift'];
        if (shift is Map) {
          final rows = await local.db.query('shifts', where: 'client_uuid = ?', whereArgs: [shift['client_uuid']], limit: 1);
          if (rows.isNotEmpty) {
            final data = Map<String, dynamic>.from(jsonDecode(rows.first['data'] as String) as Map)
              ..['server_id'] = shift['id']
              ..['server'] = Map<String, dynamic>.from(shift);
            await local.saveShift(data);
          }
        }
    }
  }

  /// Tarik data master sejak cursor terakhir (atau penuh).
  Future<void> pull({bool forceFull = false}) async {
    final lastFull = DateTime.tryParse(await local.getMeta(MetaKeys.lastFullPull) ?? '');
    final cursor = await local.getMeta(MetaKeys.cursor);
    final full = forceFull || cursor == null || lastFull == null || DateTime.now().difference(lastFull) > fullPullEvery;
    final data = await api.get('sync/pull', query: full ? null : {'since': cursor});

    final products = Map<String, dynamic>.from(data['products'] as Map);
    await local.upsertProducts([for (final item in products['items'] as List) Product.fromJson(Map<String, dynamic>.from(item as Map))]);
    await local.keepProducts([for (final id in products['ids'] as List) id as int]);

    final customers = Map<String, dynamic>.from(data['customers'] as Map);
    await local.upsertCustomers([for (final item in customers['items'] as List) Customer.fromJson(Map<String, dynamic>.from(item as Map))]);
    await local.keepCustomers([for (final id in customers['ids'] as List) id as int]);

    await local.setJson(MetaKeys.tenant, data['tenant']);
    await local.setJson(MetaKeys.device, data['device']);
    await local.setJson(MetaKeys.menus, data['menus']);
    await local.setJson(MetaKeys.accounts, data['accounts']);
    await local.setJson(MetaKeys.warehouses, data['warehouses']);
    await local.setJson(MetaKeys.user, data['user']);
    await local.setMeta(MetaKeys.numberBlocks, jsonEncode(data['number_blocks'] ?? const []));
    await _seedLastNumber(data['number_blocks']);

    final receipt = Map<String, dynamic>.from(data['receipt'] as Map);
    await local.setJson(MetaKeys.receipt, receipt);
    await _refreshLogo(ReceiptConfig.fromJson(receipt));

    final openShift = data['open_shift'];
    if (openShift is Map && await local.openShift() == null) {
      await local.saveShift({
        'client_uuid': openShift['client_uuid'],
        'opened_at': openShift['opened_at'],
        'closed_at': null,
        'opening_cash': openShift['opening_cash'],
        'closing_cash': null,
        'server_id': openShift['id'],
      });
    }

    await local.setMeta(MetaKeys.cursor, data['cursor']?.toString());
    if (full) {
      await local.setMeta(MetaKeys.lastFullPull, DateTime.now().toIso8601String());
    }
    await local.setMeta(MetaKeys.lastSyncAt, DateTime.now().toIso8601String());
  }

  /// Nomor terakhir yang sudah dipakai menurut server (`last_used` tiap jatah).
  /// Setelah aplikasi dipasang ulang / keluar-masuk, penghitung di HP mulai
  /// dari nol padahal nomor 1..N sudah terpakai: tanpa ini struk dicetak
  /// dengan nomor lama lalu diganti server saat sinkron.
  Future<void> _seedLastNumber(Object? rawBlocks) async {
    if (rawBlocks is! List) {
      return;
    }
    var serverLast = 0;
    for (final block in rawBlocks) {
      if (block is Map) {
        final used = NumberBlock.fromJson(Map<String, dynamic>.from(block)).lastUsed ?? 0;
        serverLast = used > serverLast ? used : serverLast;
      }
    }
    final localLast = int.tryParse(await local.getMeta(MetaKeys.lastNumberSeq) ?? '') ?? 0;
    if (serverLast > localLast) {
      await local.setMeta(MetaKeys.lastNumberSeq, serverLast.toString());
    }
  }

  Future<void> _refreshLogo(ReceiptConfig receipt) async {
    if (receipt.logoUrl == null) {
      await local.setMeta(MetaKeys.logoBytes, null);
      await local.setMeta(MetaKeys.logoVersion, null);
      return;
    }
    if (await local.getMeta(MetaKeys.logoVersion) == receipt.logoVersion) {
      return;
    }
    try {
      final bytes = await api.bytes(receipt.logoUrl!);
      await local.setMeta(MetaKeys.logoBytes, base64Encode(bytes));
      await local.setMeta(MetaKeys.logoVersion, receipt.logoVersion);
    } on ApiException {
      // Logo opsional; dicoba lagi pada sinkron berikutnya.
    }
  }

  Future<List<NumberBlock>> numberBlocks() async {
    final raw = await local.getMeta(MetaKeys.numberBlocks);
    if (raw == null) {
      return const [];
    }
    return [for (final block in jsonDecode(raw) as List) NumberBlock.fromJson(Map<String, dynamic>.from(block as Map))];
  }

  /// Minta jatah nomor baru bila sisa nomor offline menipis.
  Future<void> ensureNumberBlock() async {
    final menus = await local.getJson(MetaKeys.menus);
    if (menus != null && menus['pos'] != true) {
      return;
    }
    final blocks = await numberBlocks();
    final lastUsed = int.tryParse(await local.getMeta(MetaKeys.lastNumberSeq) ?? '') ?? 0;
    if (NumberAllocator.remaining(blocks, lastUsed) >= AppConfig.numberBlockLowWatermark) {
      return;
    }
    final response = await api.post('pos/number-blocks');
    final block = NumberBlock.fromJson(Map<String, dynamic>.from(response['block'] as Map));
    final merged = [...blocks.where((existing) => existing.id != block.id), block];
    await local.setMeta(MetaKeys.numberBlocks, jsonEncode([for (final item in merged) item.toJson()]));
  }

  /// Satu siklus sinkron lengkap. [afterPush] dipanggil setelah outbox
  /// terkirim, sebelum tarik data: kesempatan memperbarui jumlah tertunda
  /// yang dikirim di header X-Outbox-Count request berikutnya.
  Future<PushSummary> run({bool forceFull = false, Future<void> Function()? afterPush}) async {
    final summary = await pushAll();
    if (afterPush != null) {
      await afterPush();
    }
    if (summary.failed) {
      return summary;
    }
    await pull(forceFull: forceFull);
    try {
      await ensureNumberBlock();
    } on ApiException {
      // Tidak berhak / gagal: nomor diberikan server saat sinkron.
    }
    return summary;
  }
}
