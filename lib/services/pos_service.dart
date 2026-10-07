import 'dart:convert';

import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../core/format.dart';
import '../core/money.dart';
import '../data/local_db.dart';
import '../data/outbox_store.dart';
import '../domain/cart.dart';
import '../domain/master_data.dart';
import '../domain/models.dart';
import '../domain/numbering.dart';
import 'sync_engine.dart';

enum PayMode { cash, transfer, bon, mixed }

/// Pilihan bayar dari layar Bayar.
class PaymentInput {
  const PaymentInput({required this.mode, this.cashReceived, this.transferAccountId, this.transferAccountName});

  final PayMode mode;

  /// Uang tunai yang diterima (tunai: ≥ total; campuran: bagian tunai).
  final String? cashReceived;
  final int? transferAccountId;
  final String? transferAccountName;
}

class CheckoutException implements Exception {
  const CheckoutException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Simpan penjualan kasir ke HP (riwayat + outbox) dengan nomor nota offline.
/// Tidak butuh internet; sinkron & cetak dijalankan setelahnya.
class PosService {
  PosService({required this.local, required this.user, required this.master});

  final LocalDb local;
  final SessionUser user;
  final MasterData master;

  static const _uuid = Uuid();

  static String newUuid() => _uuid.v4();

  /// Susun pembayaran dari pilihan kasir. Kembalikan (pembayaran, kembalian).
  (List<Map<String, dynamic>>, String) buildPayments(String total, PaymentInput input) {
    final cashAccount = master.defaultCashId;
    switch (input.mode) {
      case PayMode.cash:
        final received = Money.normalize(input.cashReceived ?? total);
        if (Money.compare(received, total) < 0) {
          throw const CheckoutException('Uang yang diterima kurang dari total.');
        }
        if (cashAccount == null) {
          throw const CheckoutException('Akun kas belum tersedia. Sinkronkan data dulu.');
        }
        return (
          [
            {'client_uuid': newUuid(), 'method': 'cash', 'amount': Money.normalize(total), 'account_id': cashAccount, 'tendered': received},
          ],
          Money.sub(received, total),
        );
      case PayMode.transfer:
        if (input.transferAccountId == null) {
          throw const CheckoutException('Pilih rekening tujuan transfer.');
        }
        return (
          [
            {'client_uuid': newUuid(), 'method': 'transfer', 'amount': Money.normalize(total), 'account_id': input.transferAccountId, 'account_name': input.transferAccountName},
          ],
          '0.00',
        );
      case PayMode.bon:
        return (const [], '0.00');
      case PayMode.mixed:
        final cash = Money.normalize(input.cashReceived ?? '0');
        if (!Money.isPositive(cash) || Money.compare(cash, total) >= 0) {
          throw const CheckoutException('Isi bagian tunai lebih kecil dari total; sisanya transfer.');
        }
        if (input.transferAccountId == null) {
          throw const CheckoutException('Pilih rekening tujuan transfer.');
        }
        if (cashAccount == null) {
          throw const CheckoutException('Akun kas belum tersedia. Sinkronkan data dulu.');
        }
        return (
          [
            {'client_uuid': newUuid(), 'method': 'cash', 'amount': cash, 'account_id': cashAccount, 'tendered': cash},
            {'client_uuid': newUuid(), 'method': 'transfer', 'amount': Money.sub(total, cash), 'account_id': input.transferAccountId, 'account_name': input.transferAccountName},
          ],
          '0.00',
        );
    }
  }

  /// Simpan penjualan. [clientUuid] dibuat sekali saat layar Bayar dibuka,
  /// sehingga tombol Bayar yang ditekan dua kali tidak membuat nota dobel.
  Future<Map<String, dynamic>> checkout({required String clientUuid, required Cart cart, required PaymentInput payment, String? shiftClientUuid, DateTime? now}) async {
    if (cart.isEmpty) {
      throw const CheckoutException('Keranjang masih kosong.');
    }
    final inclusive = master.tenant.pricesIncludeTax;
    final totals = cart.totals(pricesIncludeTax: inclusive);
    if (!Money.isPositive(totals.total)) {
      throw const CheckoutException('Total belanja harus lebih dari nol.');
    }
    final (payments, change) = buildPayments(totals.total, payment);
    final paid = Money.add([for (final item in payments) item['amount']]);
    final customer = cart.customer;
    if (Money.compare(paid, totals.total) < 0 && (customer == null || customer.isWalkIn)) {
      throw const CheckoutException('Pilih pelanggan untuk penjualan bon (bayar nanti).');
    }

    final createdAt = now ?? DateTime.now();
    final items = [
      for (final line in cart.lines)
        () {
          final amounts = cart.amountsFor(line, pricesIncludeTax: inclusive);
          return {
            'product_id': line.product?.id,
            'description': line.description,
            'quantity': amounts.quantity,
            'unit': line.unit,
            'unit_price': amounts.unitPrice,
            'discount_percent': amounts.discountPercent,
            'tax_rate': amounts.taxRate,
            'gross_amount': amounts.grossAmount,
            'discount_amount': amounts.discountAmount,
            'line_total': amounts.lineTotal,
          };
        }(),
    ];

    final receipt = master.receipt;
    final sale = <String, dynamic>{
      'client_uuid': clientUuid,
      'number': null,
      'number_seq': null,
      'date': isoDate(createdAt),
      'created_at': createdAt.toUtc().toIso8601String(),
      'shift_client_uuid': shiftClientUuid,
      'customer_id': customer?.isWalkIn == true ? null : customer?.id,
      'customer_client_uuid': customer?.id == null ? customer?.clientUuid : null,
      'customer_name': customer?.name ?? 'Pelanggan Umum',
      'notes': cart.note,
      'items': items,
      'payments': payments,
      'subtotal': totals.subtotal,
      'discount_total': totals.discountTotal,
      'tax_total': totals.taxTotal,
      'total': totals.total,
      'paid': paid,
      'change': change,
      'cashier': user.name,
      'tax_name': master.tenant.salesTaxName,
      'prices_include_tax': inclusive,
      'verification_url': receipt.showQr && receipt.verifyBaseUrl != null ? '${receipt.verifyBaseUrl}/$clientUuid' : null,
    };

    return local.db.transaction((txn) async {
      final existing = await txn.query('sales', where: 'client_uuid = ?', whereArgs: [clientUuid], limit: 1);
      if (existing.isNotEmpty) {
        return Map<String, dynamic>.from(jsonDecode(existing.first['data'] as String) as Map);
      }

      final blocks = await _numberBlocks(txn);
      final lastUsed = int.tryParse(await _meta(txn, MetaKeys.lastNumberSeq) ?? '') ?? 0;
      final number = NumberAllocator.next(blocks, lastUsed, createdAt);
      if (number != null) {
        sale['number'] = number.number;
        sale['number_seq'] = number.sequence;
        await txn.insert('meta', {'key': MetaKeys.lastNumberSeq, 'value': number.sequence.toString()}, conflictAlgorithm: ConflictAlgorithm.replace);
      }

      await txn.insert('sales', {
        'client_uuid': clientUuid,
        'number': sale['number'],
        'created_at': createdAt.toIso8601String(),
        'total': totals.total,
        'sync_status': 'menunggu',
        'data': jsonEncode(sale),
      });
      await txn.insert('outbox', {
        'client_uuid': clientUuid,
        'type': 'sale',
        'data': jsonEncode(pushData(sale)),
        'status': OutboxStatus.pending,
        'created_at': createdAt.toIso8601String(),
      });
      return sale;
    });
  }

  /// Bagian penjualan yang dikirim ke server (API.md › item "sale").
  static Map<String, dynamic> pushData(Map<String, dynamic> sale) => {
        'client_uuid': sale['client_uuid'],
        'number': sale['number'],
        'number_seq': sale['number_seq'],
        'date': sale['date'],
        'created_at': sale['created_at'],
        'shift_client_uuid': sale['shift_client_uuid'],
        'customer_id': sale['customer_id'],
        'customer_client_uuid': sale['customer_client_uuid'],
        'notes': sale['notes'],
        'total': sale['total'],
        'items': [
          for (final item in sale['items'] as List)
            {
              'product_id': item['product_id'],
              'description': item['description'],
              'quantity': item['quantity'],
              'unit': item['unit'],
              'unit_price': item['unit_price'],
              'discount_percent': item['discount_percent'],
              'tax_rate': item['tax_rate'],
            },
        ],
        'payments': [
          for (final payment in sale['payments'] as List)
            {
              'client_uuid': payment['client_uuid'],
              'method': payment['method'],
              'amount': payment['amount'],
              'account_id': payment['account_id'],
              if (payment['tendered'] != null) 'tendered': payment['tendered'],
            },
        ],
      };

  Future<List<NumberBlock>> _numberBlocks(Transaction txn) async {
    final raw = await _meta(txn, MetaKeys.numberBlocks);
    return raw == null ? const [] : [for (final block in jsonDecode(raw) as List) NumberBlock.fromJson(Map<String, dynamic>.from(block as Map))];
  }

  Future<String?> _meta(Transaction txn, String key) async {
    final rows = await txn.query('meta', where: 'key = ?', whereArgs: [key], limit: 1);
    return rows.isEmpty ? null : rows.first['value'] as String?;
  }

  // ------------------------------------------------------------- pelanggan

  /// Pelanggan baru (bisa offline); dikirim lewat outbox sebelum penjualannya.
  Future<Customer> addCustomer({required String name, String? phone, String? address}) async {
    final clientUuid = newUuid();
    final customer = Customer(clientUuid: clientUuid, name: name.trim(), phone: phone?.trim(), address: address?.trim(), pending: true);
    await local.upsertCustomers([customer]);
    await OutboxStore(local).enqueue('customer', clientUuid, {
      'client_uuid': clientUuid,
      'name': customer.name,
      if ((customer.phone ?? '').isNotEmpty) 'phone': customer.phone,
      if ((customer.address ?? '').isNotEmpty) 'address': customer.address,
    });
    return customer;
  }

  // ------------------------------------------------------------------ shift

  Future<Map<String, dynamic>> openShift(String openingCash, {DateTime? now}) async {
    final clientUuid = newUuid();
    final openedAt = (now ?? DateTime.now()).toUtc().toIso8601String();
    final shift = {
      'client_uuid': clientUuid,
      'opened_at': openedAt,
      'closed_at': null,
      'opening_cash': Money.normalize(openingCash),
      'closing_cash': null,
      'cashier': user.name,
    };
    await local.saveShift(shift);
    await OutboxStore(local).enqueue('shift_open', clientUuid, {'client_uuid': clientUuid, 'opened_at': openedAt, 'opening_cash': shift['opening_cash']});
    return shift;
  }

  /// Ringkasan shift dari penjualan di HP ini.
  Future<Map<String, dynamic>> shiftSummary(Map<String, dynamic> shift) async {
    final sales = await local.recentSales(limit: 100000, shiftClientUuid: shift['client_uuid'] as String);
    var total = '0';
    var cash = '0';
    var transfer = '0';
    var paid = '0';
    for (final sale in sales) {
      total = Money.add([total, sale['total']]);
      for (final payment in (sale['payments'] as List? ?? const [])) {
        paid = Money.add([paid, payment['amount']]);
        if (payment['method'] == 'cash') {
          cash = Money.add([cash, payment['amount']]);
        } else {
          transfer = Money.add([transfer, payment['amount']]);
        }
      }
    }
    return {
      'sales_count': sales.length,
      'sales_total': Money.normalize(total),
      'cash_total': Money.normalize(cash),
      'transfer_total': Money.normalize(transfer),
      'unpaid_total': Money.sub(total, paid),
      'opening_cash': Money.normalize(shift['opening_cash']),
      'expected_cash': Money.add([shift['opening_cash'], cash]),
    };
  }

  /// Tutup shift dengan uang fisik yang dihitung. Kembalikan laporan untuk dicetak.
  Future<Map<String, dynamic>> closeShift(Map<String, dynamic> shift, String closingCash, {DateTime? now}) async {
    final summary = await shiftSummary(shift);
    final closedAt = (now ?? DateTime.now()).toUtc().toIso8601String();
    final counted = Money.normalize(closingCash);
    final closed = {
      ...shift,
      'closed_at': closedAt,
      'closing_cash': counted,
      'summary': summary,
    };
    await local.saveShift(closed);
    final closeUuid = newUuid();
    await OutboxStore(local).enqueue('shift_close', closeUuid, {
      'shift_client_uuid': shift['client_uuid'],
      'closed_at': closedAt,
      'closing_cash': counted,
    });
    return {
      ...summary,
      'cashier': shift['cashier'] ?? user.name,
      'opened_at': shift['opened_at'],
      'closed_at': closedAt,
      'closing_cash': counted,
      'difference': Money.sub(counted, summary['expected_cash']),
    };
  }
}
