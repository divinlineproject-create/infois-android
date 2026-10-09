import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/api_client.dart';
import '../data/records_api.dart';
import '../domain/models.dart';
import '../domain/record_models.dart';
import 'session.dart';
import 'workspace.dart';

/// Klien Catatan untuk perusahaan aktif (null bila belum ada perusahaan).
final recordsApiProvider = Provider<RecordsApi?>((ref) {
  final workspace = ref.watch(workspaceProvider).valueOrNull;
  return workspace == null ? null : RecordsApi(workspace.api);
});

/// Bagian di tab Catatan. Tampil hanya bila hak aksesnya ada (sama dengan
/// policy web; server tetap mengecek ulang).
enum RecordSection {
  sales('Penjualan', Icons.receipt_long_outlined),
  payments('Pembayaran', Icons.payments_outlined),
  purchases('Pembelian', Icons.shopping_bag_outlined),
  cash('Kas & Bank', Icons.account_balance_wallet_outlined),
  stock('Stok', Icons.inventory_2_outlined),
  customers('Pelanggan', Icons.people_outline),
  suppliers('Pemasok', Icons.local_shipping_outlined);

  const RecordSection(this.label, this.icon);

  final String label;
  final IconData icon;
}

/// Hak akses Catatan dari daftar permission `GET /me`; bila sesi lama belum
/// menyimpan daftar itu, pakai menu yang sudah dipetakan server.
class RecordAccess {
  const RecordAccess({
    this.sales = false,
    this.paymentsIn = false,
    this.paymentsOut = false,
    this.purchases = false,
    this.cash = false,
    this.cashAccounts = false,
    this.stock = false,
    this.customers = false,
    this.suppliers = false,
    this.voidSale = false,
  });

  factory RecordAccess.of(TenantSummary? tenant, Menus menus) {
    if (tenant == null) {
      return const RecordAccess();
    }
    bool can(String permission, {bool fallback = false}) => tenant.can(permission, fallback: fallback);
    final sales = can('ViewAny:Invoice', fallback: menus.records);
    final purchases = can('ViewAny:Bill');
    // Saldo kas/bank seperti di web: butuh lihat laporan atau catat kas
    // (menu `cash_journal`), tidak cukup hak lihat jurnal/akun saja.
    final cashBalances = menus.cashJournal || menus.reports;
    return RecordAccess(
      sales: sales,
      paymentsIn: sales,
      paymentsOut: purchases,
      purchases: purchases,
      cash: cashBalances && can('ViewAny:JournalEntry', fallback: menus.cashJournal),
      cashAccounts: cashBalances && can('ViewAny:Account', fallback: menus.cashJournal),
      stock: can('ViewAny:ProductService', fallback: menus.stock),
      customers: can('ViewAny:Customer', fallback: menus.records),
      suppliers: can('ViewAny:Supplier'),
      voidSale: menus.voidSale,
    );
  }

  final bool sales;
  final bool paymentsIn;
  final bool paymentsOut;
  final bool purchases;
  final bool cash;
  final bool cashAccounts;
  final bool stock;
  final bool customers;
  final bool suppliers;
  final bool voidSale;

  bool get payments => paymentsIn || paymentsOut;

  List<RecordSection> get sections => [
        if (sales) RecordSection.sales,
        if (payments) RecordSection.payments,
        if (purchases) RecordSection.purchases,
        if (cash) RecordSection.cash,
        if (stock) RecordSection.stock,
        if (customers) RecordSection.customers,
        if (suppliers) RecordSection.suppliers,
      ];
}

final recordAccessProvider = Provider<RecordAccess>((ref) {
  final session = ref.watch(sessionProvider).valueOrNull;
  final master = ref.watch(masterDataProvider).valueOrNull;
  final tenant = session?.tenant;
  return RecordAccess.of(tenant, master?.menus ?? tenant?.menus ?? const Menus());
});

/// Token HP sudah tidak berlaku (401): keluar seperti yang dilakukan sinkron.
void _expireIfUnauthenticated(Ref ref, ApiException error) {
  if (error.unauthenticated) {
    unawaited(ref.read(sessionProvider.notifier).expire());
  }
}

/// Kunci daftar: bagian + parameter filter (nilai kosong diabaikan).
class RecordQuery {
  RecordQuery(this.section, [Map<String, String?> params = const {}])
      : params = Map.unmodifiable({
          for (final entry in params.entries)
            if (entry.value != null && entry.value!.isNotEmpty) entry.key: entry.value!,
        });

  final RecordSection section;
  final Map<String, String> params;

  String get _key {
    final keys = params.keys.toList()..sort();
    return '${section.name}?${[for (final key in keys) '$key=${params[key]}'].join('&')}';
  }

  RecordQuery with_(Map<String, String?> changes) => RecordQuery(section, {...params, ...changes});

  @override
  bool operator ==(Object other) => other is RecordQuery && other._key == _key;

  @override
  int get hashCode => _key.hashCode;
}

class RecordListState<T> {
  const RecordListState({this.items = const [], this.nextCursor, this.loadingMore = false, this.extra = const {}, this.loadMoreError});

  final List<T> items;
  final String? nextCursor;
  final bool loadingMore;

  /// Pesan bila halaman berikutnya gagal dimuat (tombol Coba lagi di kaki daftar).
  final String? loadMoreError;

  /// Kunci tambahan dari halaman pertama (akun & total buku kas, `low_count`).
  final Map<String, dynamic> extra;

  bool get hasMore => nextCursor != null;

  RecordListState<T> copyWith({List<T>? items, String? nextCursor, bool clearCursor = false, bool? loadingMore, Map<String, dynamic>? extra, String? loadMoreError, bool clearError = false}) => RecordListState(
        items: items ?? this.items,
        nextCursor: clearCursor ? null : (nextCursor ?? this.nextCursor),
        loadingMore: loadingMore ?? this.loadingMore,
        extra: extra ?? this.extra,
        loadMoreError: clearError ? null : (loadMoreError ?? this.loadMoreError),
      );
}

typedef RecordFetch<T> = Future<RecordPage<T>> Function(RecordsApi api, RecordQuery query, String? cursor);

/// Daftar berkursor satu bagian Catatan untuk satu filter: halaman pertama
/// saat dibuka, [loadMore] saat digulir, [refresh] saat ditarik ke bawah.
class RecordListController<T> extends AutoDisposeFamilyAsyncNotifier<RecordListState<T>, RecordQuery> {
  RecordListController(this._fetch);

  final RecordFetch<T> _fetch;

  /// Naik setiap kali daftar dimuat ulang (buka/tarik ulang); halaman
  /// lanjutan dari muatan lama dibuang supaya tidak menimpa daftar baru.
  int _generation = 0;

  @override
  Future<RecordListState<T>> build(RecordQuery arg) async {
    _generation++;
    final api = ref.watch(recordsApiProvider);
    if (api == null) {
      return RecordListState<T>();
    }
    try {
      final page = await _fetch(api, arg, null);
      return RecordListState(items: page.items, nextCursor: page.nextCursor, extra: page.extra);
    } on ApiException catch (error) {
      _expireIfUnauthenticated(ref, error);
      rethrow;
    }
  }

  Future<void> refresh() async {
    final api = ref.read(recordsApiProvider);
    if (api == null) {
      return;
    }
    final generation = ++_generation;
    try {
      final page = await _fetch(api, arg, null);
      if (generation == _generation) {
        state = AsyncData(RecordListState(items: page.items, nextCursor: page.nextCursor, extra: page.extra));
      }
    } on ApiException catch (error, stack) {
      _expireIfUnauthenticated(ref, error);
      if (generation != _generation) {
        return;
      }
      if (state.valueOrNull == null || state.valueOrNull!.items.isEmpty) {
        state = AsyncError(error, stack);
      } else {
        rethrow;
      }
    }
  }

  /// Halaman berikutnya. Setelah gagal, hanya dicoba lagi lewat tombol
  /// ([retry]) supaya gulir tidak mengulang permintaan terus-menerus.
  Future<void> loadMore({bool retry = false}) async {
    final api = ref.read(recordsApiProvider);
    final current = state.valueOrNull;
    if (api == null || current == null || !current.hasMore || current.loadingMore || state.isLoading || (current.loadMoreError != null && !retry)) {
      return;
    }
    final generation = _generation;
    state = AsyncData(current.copyWith(loadingMore: true, clearError: true));
    try {
      final page = await _fetch(api, arg, current.nextCursor);
      if (generation == _generation) {
        state = AsyncData(current.copyWith(items: [...current.items, ...page.items], nextCursor: page.nextCursor, clearCursor: page.nextCursor == null, loadingMore: false, clearError: true));
      }
    } catch (error) {
      if (error is ApiException) {
        _expireIfUnauthenticated(ref, error);
      }
      if (generation == _generation) {
        state = AsyncData(current.copyWith(loadingMore: false, loadMoreError: error is ApiException ? error.message : 'Data dari server belum bisa dibaca.'));
      }
    }
  }

  /// Ganti satu item yang sudah dimuat (mis. setelah penjualan dibatalkan).
  void replaceWhere(bool Function(T item) test, T replacement) {
    final current = state.valueOrNull;
    if (current != null) {
      state = AsyncData(current.copyWith(items: [for (final item in current.items) test(item) ? replacement : item]));
    }
  }
}

AutoDisposeAsyncNotifierProviderFamily<RecordListController<T>, RecordListState<T>, RecordQuery> _list<T>(RecordFetch<T> fetch) =>
    AsyncNotifierProvider.autoDispose.family<RecordListController<T>, RecordListState<T>, RecordQuery>(() => RecordListController<T>(fetch));

final salesListProvider = _list<SaleRecord>((api, query, cursor) => api.sales(params: query.params, cursor: cursor));
final paymentsListProvider = _list<PaymentRecord>((api, query, cursor) => api.payments(params: query.params, cursor: cursor));
final purchasesListProvider = _list<PurchaseRecord>((api, query, cursor) => api.purchases(params: query.params, cursor: cursor));
final cashListProvider = _list<CashEntry>((api, query, cursor) => api.cash(params: query.params, cursor: cursor));
final stockListProvider = _list<StockLevel>((api, query, cursor) => api.stock(params: query.params, cursor: cursor));
final stockMovementsProvider = _list<StockMovement>((api, query, cursor) => api.stockMovements(params: query.params, cursor: cursor));
final customersListProvider = _list<CustomerRecord>((api, query, cursor) => api.customers(params: query.params, cursor: cursor));
final suppliersListProvider = _list<SupplierRecord>((api, query, cursor) => api.suppliers(params: query.params, cursor: cursor));

Future<T?> _guard<T>(Ref ref, RecordsApi? api, Future<T> Function(RecordsApi api) request) async {
  if (api == null) {
    return null;
  }
  try {
    return await request(api);
  } on ApiException catch (error) {
    _expireIfUnauthenticated(ref, error);
    rethrow;
  }
}

final saleDetailProvider = FutureProvider.autoDispose.family<SaleDetail?, int>((ref, id) => _guard(ref, ref.watch(recordsApiProvider), (api) => api.sale(id)));

/// Kunci `"in:12"` / `"out:7"`.
final paymentDetailProvider = FutureProvider.autoDispose.family<PaymentRecord?, String>((ref, key) {
  final parts = key.split(':');
  return _guard(ref, ref.watch(recordsApiProvider), (api) => api.payment(parts.first, int.parse(parts.last)));
});

final purchaseDetailProvider = FutureProvider.autoDispose.family<PurchaseDetail?, int>((ref, id) => _guard(ref, ref.watch(recordsApiProvider), (api) => api.purchase(id)));

final customerDetailProvider = FutureProvider.autoDispose.family<CustomerRecord?, int>((ref, id) => _guard(ref, ref.watch(recordsApiProvider), (api) => api.customer(id)));

final supplierDetailProvider = FutureProvider.autoDispose.family<SupplierRecord?, int>((ref, id) => _guard(ref, ref.watch(recordsApiProvider), (api) => api.supplier(id)));

/// Isi lampiran dokumen (foto/PDF) dengan token; dilepas saat tidak ditampilkan.
final recordAttachmentBytesProvider = FutureProvider.autoDispose.family<Uint8List, String>((ref, url) async {
  final api = ref.watch(recordsApiProvider);
  if (api == null) {
    throw const ApiException('Belum ada perusahaan aktif.');
  }
  final raw = await api.attachmentBytes(url);
  return raw is Uint8List ? raw : Uint8List.fromList(raw);
});

/// Aksi Catatan yang mengubah data atau mengambil berkas.
class RecordActions {
  const RecordActions(this.ref);

  final Ref ref;

  RecordsApi? get _api => ref.read(recordsApiProvider);

  Future<Map<String, dynamic>> receipt(int saleId) async {
    final api = _api;
    if (api == null) {
      throw const ApiException('Belum ada perusahaan aktif.');
    }
    return api.receipt(saleId);
  }

  Future<List<int>> salePdf(int saleId) async {
    final api = _api;
    if (api == null) {
      throw const ApiException('Belum ada perusahaan aktif.');
    }
    return api.salePdf(saleId);
  }

  /// Batalkan penjualan; daftar & rincian yang sedang tampil ikut diperbarui.
  Future<String> voidSale(int saleId, String reason) async {
    final api = _api;
    if (api == null) {
      throw const ApiException('Belum ada perusahaan aktif.');
    }
    try {
      final result = await api.voidSale(saleId, reason);
      ref.invalidate(saleDetailProvider(saleId));
      ref.invalidate(salesListProvider);
      return result.message;
    } on ApiException catch (error) {
      _expireIfUnauthenticated(ref, error);
      rethrow;
    }
  }
}

final recordActionsProvider = Provider<RecordActions>((ref) => RecordActions(ref));
