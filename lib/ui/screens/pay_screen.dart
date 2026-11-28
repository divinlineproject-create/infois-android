import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart' show DateFormat;

import '../../core/format.dart';
import '../../core/money.dart';
import '../../data/api_client.dart';
import '../../data/qris_api.dart';
import '../../domain/models.dart';
import '../../domain/qris.dart';
import '../../services/pos_service.dart';
import '../../services/printing/receipt_builder.dart';
import '../../state/pos_state.dart';
import '../../state/printer_controller.dart';
import '../../state/workspace.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/pos_keypad.dart';
import 'customer_picker.dart';
import 'shift_screens.dart';

/// QRIS butuh internet (dibuat & dicek di server).
const qrisOfflineMessage = 'QRIS butuh internet. Sambungkan internet lalu coba lagi.';

/// Jeda menanyakan status QR ke server.
const qrisPollEvery = Duration(seconds: 3);

/// Nominal cepat untuk tunai: uang pas, pembulatan ke atas, 20rb/50rb/100rb.
List<String> quickCashAmounts(String total) {
  final whole = BigInt.parse(Money.normalize(total).split('.').first);
  final hasCents = !Money.normalize(total).endsWith('.00');
  final base = hasCents ? whole + BigInt.one : whole;
  BigInt ceilTo(int step) {
    final s = BigInt.from(step);
    return ((base + s - BigInt.one) ~/ s) * s;
  }

  final values = <BigInt>{
    base,
    ceilTo(1000),
    ceilTo(5000),
    ceilTo(10000),
    ceilTo(50000),
    ceilTo(100000),
    for (final note in [20000, 50000, 100000]) BigInt.from(note),
  }.where((value) => value >= base).toList()
    ..sort();
  return [for (final value in values.take(6)) Money.normalize(value.toString())];
}

/// Layar Bayar: tunai (keypad, nominal cepat, kembalian), transfer
/// (rekening tujuan), bon, campuran.
class PayScreen extends ConsumerStatefulWidget {
  const PayScreen({super.key});

  @override
  ConsumerState<PayScreen> createState() => _PayScreenState();
}

class _PayScreenState extends ConsumerState<PayScreen> {
  /// Dibuat sekali per layar: bayar ditekan dua kali tetap satu nota.
  /// Diganti hanya bila penjualan QRIS ditolak lalu kasir memilih cara lain.
  String _clientUuid = PosService.newUuid();

  /// Nominal tunai dari keypad (digit saja). Kosong = uang pas (mode tunai).
  String _cash = '';
  PayMode _mode = PayMode.cash;
  CashAccount? _account;
  bool _busy = false;
  String? _error;

  // ------------------------------------------------------------- QRIS
  QrisPayment? _qris;
  QrisApi? _qrisApi;
  bool _qrisBusy = false;
  String? _qrisError;
  Timer? _qrisTimer;
  bool _qrisChecking = false;

  /// Penjualan QRIS sudah disimpan (lalu ditolak server): cara bayar lain
  /// memakai nota baru.
  bool _qrisAttempted = false;

  @override
  void dispose() {
    // Keluar dari layar Bayar: QR yang belum dibayar dibatalkan.
    _cancelQris();
    super.dispose();
  }

  String _total() => ref.read(cartProvider).totals(pricesIncludeTax: ref.read(masterDataProvider).valueOrNull?.tenant.pricesIncludeTax ?? false).total;

  void _setMode(PayMode mode) {
    final lockedQris = ref.read(masterDataProvider).valueOrNull?.tenant.locked('pos_qris');
    if (mode == PayMode.qris && lockedQris != null && !(ref.read(masterDataProvider).valueOrNull?.tenant.qrisEnabled ?? false)) {
      showLockedFeature(context, lockedQris);
      return;
    }
    if (_mode == PayMode.qris && mode != PayMode.qris) {
      _cancelQris();
    }
    if (_qrisAttempted && mode != PayMode.qris) {
      _clientUuid = PosService.newUuid();
      _qrisAttempted = false;
    }
    setState(() {
      _mode = mode;
      _cash = '';
      _error = null;
    });
    // QRIS: QR langsung dibuat & tampil, statusnya ditanyakan sampai dibayar.
    if (mode == PayMode.qris) {
      _startQris();
    }
  }

  Future<void> _startQris() async {
    final current = _qris;
    if (_qrisBusy || (current != null && (current.isPending || current.isPaid))) {
      return;
    }
    final api = ref.read(qrisApiProvider);
    final total = _total();
    setState(() {
      _qrisBusy = true;
      _qrisError = null;
      _qris = null;
    });
    try {
      if (api == null) {
        throw const ApiException(qrisOfflineMessage, offline: true);
      }
      final qris = await api.create(total);
      _qrisApi = api;
      if (!mounted || _mode != PayMode.qris) {
        // Kasir sudah pindah cara bayar / keluar saat QR dibuat.
        unawaited(api.cancel(qris.id).then((_) {}, onError: (Object _) {}));
        return;
      }
      setState(() => _qris = qris);
      _qrisTimer?.cancel();
      _qrisTimer = Timer.periodic(qrisPollEvery, (_) => _checkQris());
    } on ApiException catch (error) {
      if (mounted) {
        setState(() => _qrisError = error.offline ? qrisOfflineMessage : error.message);
      }
    } catch (_) {
      if (mounted) {
        setState(() => _qrisError = 'QR belum bisa dibuat. Coba lagi.');
      }
    } finally {
      if (mounted) {
        setState(() => _qrisBusy = false);
      }
    }
  }

  Future<void> _checkQris() async {
    final qris = _qris;
    final api = _qrisApi;
    if (!mounted || qris == null || !qris.isPending || _mode != PayMode.qris || api == null) {
      _qrisTimer?.cancel();
      return;
    }
    if (_qrisChecking) {
      return;
    }
    _qrisChecking = true;
    try {
      final next = await api.status(qris.id);
      if (!mounted || _qris?.id != next.id) {
        return;
      }
      final merged = _qris!.merge(next);
      setState(() => _qris = merged);
      if (!merged.isPending) {
        _qrisTimer?.cancel();
      }
      if (merged.isPaid) {
        showMessage(context, 'Pembayaran QRIS diterima.');
        await _pay(_total());
      }
    } on ApiException {
      // Jaringan sesaat: dicoba lagi pada putaran berikutnya.
    } finally {
      _qrisChecking = false;
    }
  }

  /// Hentikan pengecekan; QR yang belum dibayar dibatalkan (tanpa menunggu).
  /// QR yang sudah dibayar tetap disimpan.
  void _cancelQris() {
    _qrisTimer?.cancel();
    _qrisTimer = null;
    final qris = _qris;
    final api = _qrisApi;
    if (qris != null && qris.isPending && api != null) {
      unawaited(api.cancel(qris.id).then((_) {}, onError: (Object _) {}));
    }
    if (qris == null || !qris.isPaid) {
      _qris = null;
    }
    _qrisError = null;
  }

  Future<void> _printQris() async {
    final qris = _qris;
    if (qris == null) {
      return;
    }
    final result = await ref.read(posActionsProvider).printQrisBill(qris);
    if (mounted) {
      showMessage(context, draftPrintMessage(result, 'Tagihan QRIS'), error: result != PrintResult.printed);
    }
  }

  Widget _qrisPanel(BuildContext context, {required bool printOnBill}) {
    final qris = _qris;
    if (_qrisBusy) {
      return const Padding(
        key: Key('qris-creating'),
        padding: EdgeInsets.symmetric(vertical: Space.l),
        child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5)),
          SizedBox(width: Space.m),
          Text('Membuat QR…'),
        ]),
      );
    }
    if (qris == null) {
      if (_qrisError == null) {
        return const SizedBox.shrink();
      }
      return Column(children: [
        Text(_qrisError!, key: const Key('qris-error'), textAlign: TextAlign.center, style: TextStyle(color: dangerText(context), fontWeight: FontWeight.w500)),
        const SizedBox(height: Space.s),
        OutlinedButton(key: const Key('qris-retry'), onPressed: _startQris, child: const Text('Coba lagi')),
      ]);
    }
    final image = qris.isPending ? qris.imageBytes : null;
    final expires = qris.expiresAt == null ? null : DateFormat('HH:mm').format(qris.expiresAt!.toLocal());
    final status = qris.isPending
        ? 'Scan dengan aplikasi bank / e-wallet${expires == null ? '' : ' · berlaku sampai $expires'}'
        : (qris.isPaid ? 'Pembayaran diterima${qris.issuer == null ? '' : ' · ${qris.issuer}'}' : (qris.statusLabel ?? 'QR tidak berlaku lagi'));
    return Container(
      key: const Key('qris-panel'),
      padding: const EdgeInsets.all(Space.l),
      decoration: BoxDecoration(border: Border.all(color: Theme.of(context).colorScheme.outlineVariant), borderRadius: BorderRadius.circular(Radii.l)),
      child: Column(children: [
        if (image != null) ...[
          Container(
            color: Colors.white,
            padding: const EdgeInsets.all(Space.s),
            child: Image.memory(image, key: const Key('qris-image'), width: 240, height: 240, filterQuality: FilterQuality.none, gaplessPlayback: true),
          ),
          const SizedBox(height: Space.m),
        ],
        Text(rupiah(qris.amount), key: const Key('qris-amount'), style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w700)),
        const SizedBox(height: Space.xs),
        Text(
          status,
          key: const Key('qris-status'),
          textAlign: TextAlign.center,
          style: TextStyle(color: qris.isPaid ? Brand.green : (qris.isOver ? warningText(context) : mutedText(context)), fontWeight: qris.isPending ? FontWeight.w400 : FontWeight.w600),
        ),
        if (qris.isPending) ...[
          const SizedBox(height: Space.m),
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
            const SizedBox(width: Space.s),
            Text('Menunggu pembayaran…', style: TextStyle(fontSize: 13, color: mutedText(context))),
          ]),
        ],
        const SizedBox(height: Space.m),
        Wrap(alignment: WrapAlignment.center, spacing: Space.s, runSpacing: Space.s, children: [
          if (qris.isPending && printOnBill)
            OutlinedButton.icon(key: const Key('qris-print'), onPressed: _printQris, icon: const Icon(Icons.print_outlined), label: const Text('Cetak QR')),
          if (qris.isOver)
            OutlinedButton(
              key: const Key('qris-new'),
              onPressed: () {
                setState(() => _qris = null);
                _startQris();
              },
              child: const Text('Buat QR baru'),
            ),
          if (qris.isPending) TextButton(key: const Key('qris-cancel'), onPressed: () => _setMode(PayMode.cash), child: const Text('Batalkan QR')),
        ]),
      ]),
    );
  }

  Future<void> _pay(String total) async {
    if (_busy) {
      return;
    }
    final shift = await ref.read(openShiftProvider.future);
    final master = await ref.read(masterDataProvider.future);
    if ((master?.menus.shift ?? false) && shift == null) {
      if (!mounted) {
        return;
      }
      final opened = await showOpenShiftDialog(context, ref);
      if (!opened) {
        return;
      }
    }
    final cash = _mode == PayMode.cash ? (_cash.isEmpty ? total : parseMoneyInput(_cash)) : parseMoneyInput(_cash);
    if ((_mode == PayMode.cash || _mode == PayMode.mixed) && cash == null) {
      setState(() => _error = 'Isi jumlah uang tunai.');
      return;
    }
    if (_mode == PayMode.qris && !(_qris?.isPaid ?? false)) {
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (_mode == PayMode.qris) {
        _qrisAttempted = true;
      }
      final outcome = await ref.read(posActionsProvider).checkout(
            clientUuid: _clientUuid,
            payment: PaymentInput(mode: _mode, cashReceived: cash, transferAccountId: _account?.id, transferAccountName: _account?.name, qrisPaymentId: _mode == PayMode.qris ? _qris?.id : null),
          );
      if (mounted) {
        context.pushReplacement('/selesai', extra: {'sale': outcome.sale, 'print': outcome.print?.name, 'kitchen': outcome.kitchen?.failedNames});
      }
    } on CheckoutException catch (error) {
      setState(() => _error = error.message);
    } catch (error) {
      setState(() => _error = plainError(error, fallback: 'Penjualan belum tersimpan. Coba bayar lagi.'));
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  void _key(String key) => setState(() {
        _cash = applyKeypad(_cash, key);
        _error = null;
      });

  @override
  Widget build(BuildContext context) {
    final cart = ref.watch(cartProvider);
    final master = ref.watch(masterDataProvider).valueOrNull;
    final inclusive = master?.tenant.pricesIncludeTax ?? false;
    final total = cart.totals(pricesIncludeTax: inclusive).total;
    final accounts = master?.transferAccounts ?? const <CashAccount>[];
    final cashAccounts = master?.cashAccounts ?? const <CashAccount>[];
    // Akun yang dipakai penjualan tunai (PosService: `default_cash_id`).
    final drawerAccount = cashAccounts.length > 1 ? master?.accounts.where((account) => account.id == master.defaultCashId).firstOrNull : null;
    _account ??= accounts.where((account) => account.id == master?.defaultTransferId).firstOrNull ?? accounts.firstOrNull;
    final cashValue = parseMoneyInput(_cash);
    final change = _mode == PayMode.cash && cashValue != null && Money.compare(cashValue, total) >= 0 ? Money.sub(cashValue, total) : null;
    final short = _mode == PayMode.cash && cashValue != null && Money.compare(cashValue, total) < 0 ? Money.sub(total, cashValue) : null;
    final transferPart = _mode == PayMode.mixed && cashValue != null ? Money.sub(total, cashValue) : null;
    final qrisEnabled = master?.tenant.qrisEnabled ?? false;
    final qrisWaiting = _mode == PayMode.qris && !(_qris?.isPaid ?? false);
    final orderInfo = (master?.tenant.posDining ?? true) ? [cart.orderType?.label, cart.orderLabel].whereType<String>().join(' · ') : '';
    final screen = MediaQuery.sizeOf(context);
    // Layar miring yang pendek (tablet kasir): total & tombol lebih rapat.
    final dense = screen.width > screen.height && screen.height < 640;

    final quickCash = <Widget>[
      if (_mode == PayMode.cash) ...[
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final (index, amount) in quickCashAmounts(total).indexed)
            ActionChip(
              key: Key('quick-$index'),
              label: Text(index == 0 && Money.compare(amount, total) == 0 ? 'Uang pas' : rupiah(amount)),
              onPressed: () => setState(() {
                _cash = Money.normalize(amount).split('.').first;
                _error = null;
              }),
            ),
        ]),
        const SizedBox(height: 12),
      ],
    ];
    final keypadSection = <Widget>[
      _CashDisplay(
        label: _mode == PayMode.mixed ? 'Bagian tunai' : 'Uang diterima',
        value: _cash.isEmpty ? null : rupiah(_cash),
        placeholder: _mode == PayMode.cash ? 'Uang pas ${rupiah(total)}' : 'Rp 0',
      ),
      const SizedBox(height: 8),
      if (change != null)
        Container(
          padding: const EdgeInsets.symmetric(horizontal: Space.l, vertical: Space.s),
          decoration: BoxDecoration(color: Theme.of(context).colorScheme.surfaceContainer, borderRadius: BorderRadius.circular(Radii.m)),
          child: Row(children: [
            Text('Kembalian', style: TextStyle(color: mutedText(context), fontWeight: FontWeight.w500)),
            const SizedBox(width: 12),
            Expanded(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerRight,
                child: Text(rupiah(change), key: const Key('pay-change'), style: TextStyle(fontSize: 26, fontWeight: FontWeight.w700, color: Theme.of(context).colorScheme.primary)),
              ),
            ),
          ]),
        ),
      if (short != null) Text('Kurang ${rupiah(short)}', key: const Key('pay-short'), style: TextStyle(color: dangerText(context), fontWeight: FontWeight.w600)),
      if (transferPart != null && Money.isPositive(transferPart)) Text('Sisanya transfer: ${rupiah(transferPart)}'),
      const SizedBox(height: 12),
      PosKeypad(onKey: _key, keyHeight: dense ? 48 : 56),
    ];

    final header = <Widget>[
      Container(
        padding: EdgeInsets.symmetric(horizontal: Space.xl, vertical: dense ? Space.m : Space.l + 4),
        decoration: BoxDecoration(color: Theme.of(context).colorScheme.primaryContainer, borderRadius: BorderRadius.circular(Radii.l)),
        child: DefaultTextStyle.merge(
          style: TextStyle(color: Theme.of(context).colorScheme.onPrimaryContainer),
          child: Column(children: [
            const Text('Total belanja', style: TextStyle(fontWeight: FontWeight.w500)),
            const SizedBox(height: Space.xs),
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(rupiah(total), key: const Key('pay-total'), style: TextStyle(fontSize: 34, fontWeight: FontWeight.w700, color: Theme.of(context).colorScheme.onPrimaryContainer)),
            ),
            Text('${cart.itemCount} barang · ${cart.customer?.nameWithLevel ?? 'Pelanggan umum'}', textAlign: TextAlign.center),
            if (orderInfo.isNotEmpty) Text(orderInfo, key: const Key('pay-order-info'), textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.w600)),
          ]),
        ),
      ),
      SizedBox(height: dense ? 12 : 16),
      SegmentedButton<PayMode>(
        // HP sempit: tanpa ikon dan label tidak dipenggal ("Tun/ai").
        segments: [
          for (final (mode, label, icon) in [
            (PayMode.cash, 'Tunai', Icons.payments_outlined),
            (PayMode.transfer, 'Transfer', Icons.account_balance_outlined),
            (PayMode.bon, 'Bon', Icons.schedule_outlined),
            (PayMode.mixed, 'Campur', Icons.call_split),
            // QRIS dinamis bila dinyalakan perusahaan (online saja). Tetap tampil
            // bila sedang dipilih walau dimatikan lewat sinkron di tengah jalan.
            if (qrisEnabled || _mode == PayMode.qris) (PayMode.qris, 'QRIS', Icons.qr_code),
            // QRIS dikunci paket: tetap tampil bergembok, diketuk menjelaskan paketnya.
            if (!qrisEnabled && _mode != PayMode.qris && master?.tenant.locked('pos_qris') != null) (PayMode.qris, 'QRIS', Icons.lock_outline),
          ])
            ButtonSegment(
              value: mode,
              label: FittedBox(fit: BoxFit.scaleDown, child: Text(label, maxLines: 1, softWrap: false)),
              icon: MediaQuery.sizeOf(context).width < 480 ? null : Icon(icon),
            ),
        ],
        selected: {_mode},
        showSelectedIcon: false,
        onSelectionChanged: (value) => _setMode(value.first),
      ),
      // Lebih dari satu akun kas: jelaskan ke mana uang tunai dicatat (akun laci
      // kasir dari Pengaturan Kasir web = `accounts.default_cash_id`).
      if (drawerAccount != null && (_mode == PayMode.cash || _mode == PayMode.mixed)) ...[
        const SizedBox(height: 6),
        Text('Uang tunai masuk ke: ${drawerAccount.name}', key: const Key('pay-cash-account'), textAlign: TextAlign.center, style: TextStyle(fontSize: 12.5, color: mutedText(context))),
      ],
      const SizedBox(height: 20),
    ];
    final details = <Widget>[
      if (_mode == PayMode.qris) ...[
        _qrisPanel(context, printOnBill: master?.tenant.qrisPrintOnBill ?? false),
        const SizedBox(height: 8),
      ],
      if (_mode == PayMode.transfer || _mode == PayMode.mixed) ...[
        DropdownButtonFormField<int>(
          value: _account?.id,
          decoration: const InputDecoration(labelText: 'Rekening tujuan transfer'),
          items: [for (final account in accounts) DropdownMenuItem(value: account.id, child: Text(account.name))],
          onChanged: (id) => setState(() => _account = accounts.firstWhere((account) => account.id == id)),
        ),
        const SizedBox(height: 16),
      ],
      if (_mode == PayMode.bon) ...[
        const Text('Bon dicatat sebagai piutang pelanggan.'),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: () async {
            final customer = await pickCustomer(context, ref);
            if (customer != null) {
              ref.read(cartProvider.notifier).setCustomer(customer.isWalkIn ? null : customer);
            }
          },
          icon: const Icon(Icons.person_outline),
          label: Text(cart.customer == null ? 'Pilih pelanggan' : 'Pelanggan: ${cart.customer!.nameWithLevel}'),
        ),
      ],
      if (_error != null) ...[const SizedBox(height: 16), Text(_error!, key: const Key('pay-error'), style: TextStyle(color: dangerText(context), fontWeight: FontWeight.w500))],
      const SizedBox(height: 16),
      Consumer(builder: (context, ref, _) {
        final printer = ref.watch(printerProvider);
        return Text(
          printer.printer == null ? 'Belum ada printer.' : 'Struk ke ${printer.printer!.name}.',
          style: TextStyle(fontSize: 13, color: mutedText(context)),
        );
      }),
    ];
    final usesKeypad = _mode == PayMode.cash || _mode == PayMode.mixed;

    return Scaffold(
      appBar: AppBar(title: const Text('Bayar')),
      body: LayoutBuilder(builder: (context, constraints) {
        // Tablet / layar miring: rincian kiri, keypad kanan (tanpa gulir panjang).
        if (usesKeypad && (constraints.maxWidth >= 720 || (constraints.maxWidth >= 600 && constraints.maxWidth > constraints.maxHeight))) {
          // Pilihan uang cepat di kiri supaya keypad kanan muat tanpa digulir.
          return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(child: ListView(padding: const EdgeInsets.all(16), children: [...header, ...quickCash, ...details])),
            SizedBox(width: 380, child: ListView(padding: const EdgeInsets.all(16), children: keypadSection)),
          ]);
        }
        return ListView(padding: const EdgeInsets.all(16), children: [
          ...header,
          if (usesKeypad) ...[...quickCash, ...keypadSection],
          ...details,
        ]);
      }),
      bottomNavigationBar: DecoratedBox(
        decoration: BoxDecoration(color: Theme.of(context).colorScheme.surface, border: Border(top: BorderSide(color: Theme.of(context).colorScheme.outlineVariant))),
        child: SafeArea(
          child: Padding(
            padding: EdgeInsets.fromLTRB(Space.l, dense ? Space.s : Space.m, Space.l, dense ? Space.s : Space.m),
            child: FilledButton(
              key: const Key('pay-submit'),
              onPressed: _busy || cart.isEmpty || qrisWaiting
                  ? null
                  : () {
                      HapticFeedback.mediumImpact();
                      _pay(total);
                    },
              style: FilledButton.styleFrom(minimumSize: Size.fromHeight(dense ? 48 : 56), textStyle: const TextStyle(fontFamily: 'Poppins', fontSize: 17, fontWeight: FontWeight.w700)),
              child: _busy
                  ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white))
                  : Text(switch (_mode) {
                      PayMode.bon => 'Simpan bon',
                      PayMode.qris => qrisWaiting ? 'Menunggu pembayaran QRIS…' : 'Simpan penjualan',
                      _ => _mode == PayMode.cash && change != null && Money.isPositive(change) ? 'Bayar · kembali ${rupiah(change)}' : 'Bayar',
                    }),
            ),
          ),
        ),
      ),
    );
  }
}

/// Tampilan nominal tunai dari keypad.
class _CashDisplay extends StatelessWidget {
  const _CashDisplay({required this.label, required this.value, required this.placeholder});

  final String label;
  final String? value;
  final String placeholder;

  @override
  Widget build(BuildContext context) => Container(
        key: const Key('pay-cash'),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: Theme.of(context).inputDecorationTheme.fillColor,
          border: Border.all(color: Theme.of(context).colorScheme.primary, width: 1.5),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: TextStyle(fontSize: 12.5, color: mutedText(context))),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              value ?? placeholder,
              key: const Key('pay-cash-value'),
              style: TextStyle(fontSize: 26, fontWeight: FontWeight.w700, color: value == null ? mutedText(context) : null),
            ),
          ),
        ]),
      );
}

/// Pesan hasil cetak untuk ditampilkan.
String printMessage(String? result) => switch (result) {
      'printed' => 'Struk tercetak.',
      'noPrinter' => 'Belum ada printer. Atur di Akun › Pengaturan kasir.',
      'failed' => 'Struk belum tercetak. Periksa printer lalu tekan Cetak ulang.',
      _ => '',
    };

/// Pesan hasil cetak tagihan / list pesanan ([what] = "Tagihan", "List pesanan").
String draftPrintMessage(PrintResult result, String what) => switch (result) {
      PrintResult.printed => '$what tercetak.',
      PrintResult.noPrinter => printMessage('noPrinter'),
      _ => '$what belum tercetak. Periksa printer lalu coba lagi.',
    };

/// Pesan hasil "Cetak list": printer yang belum mencetak disebut namanya.
String productionMessage(ProductionResult result) {
  if (result.noPrinter) {
    return printMessage('noPrinter');
  }
  final parts = [
    if (result.failed.isNotEmpty) 'Belum tercetak: ${result.failedNames}' else if (result.printed.isNotEmpty) 'List tercetak',
    if (result.unrouted.isNotEmpty) 'Tanpa printer: ${result.unrouted.join(', ')}',
  ];
  return parts.isEmpty ? 'Tidak ada barang untuk dicetak' : parts.join(' · ');
}

/// Tampilkan hasil "Cetak list"; printer yang gagal bisa diulang.
void showProductionResult(BuildContext context, WidgetRef ref, ProductionResult result) {
  final messenger = ScaffoldMessenger.of(context);
  showMessage(
    context,
    productionMessage(result),
    error: !result.ok || result.unrouted.isNotEmpty,
    actionLabel: 'Ulangi',
    onAction: result.failed.isEmpty
        ? null
        : () async {
            final again = await ref.read(printerProvider.notifier).retryProduction();
            messenger.hideCurrentSnackBar();
            if (context.mounted) {
              showProductionResult(context, ref, again);
            }
          },
  );
}

/// Penjualan selesai: nomor nota, kembalian, cetak struk / list pesanan,
/// kirim struk lewat WhatsApp, transaksi baru.
class SaleDoneScreen extends ConsumerWidget {
  const SaleDoneScreen({super.key, required this.sale, this.printResult, this.kitchenResult});

  final Map<String, dynamic> sale;
  final String? printResult;

  /// Printer produksi yang belum mencetak list otomatis (null / kosong = beres).
  final String? kitchenResult;

  Future<void> _sendWhatsApp(BuildContext context, WidgetRef ref) async {
    var phone = sale['customer_phone']?.toString();
    if (phone == null || phone.isEmpty) {
      final controller = TextEditingController();
      final entered = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Kirim struk WhatsApp'),
          content: TextField(
            key: const Key('wa-phone'),
            controller: controller,
            autofocus: true,
            keyboardType: TextInputType.phone,
            decoration: const InputDecoration(labelText: 'No. WhatsApp pembeli', hintText: '0812…', helperText: 'Kosongkan untuk memilih kontak di WhatsApp'),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Batal')),
            FilledButton(key: const Key('wa-send'), onPressed: () => Navigator.pop(context, controller.text), child: const Text('Kirim')),
          ],
        ),
      );
      if (entered == null) {
        return;
      }
      phone = entered;
    }
    final actions = ref.read(posActionsProvider);
    final ok = await actions.sendWhatsApp(sale, phone: phone);
    if (!ok) {
      // Tanpa WhatsApp / browser: struk disalin supaya tetap bisa dikirim.
      await Clipboard.setData(ClipboardData(text: await actions.receiptText(sale)));
      if (context.mounted) {
        showMessage(context, 'WhatsApp belum bisa dibuka. Struk disalin: buka WhatsApp, pilih pembeli, lalu tempel.', error: true);
      }
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final change = sale['change']?.toString() ?? '0';
    final unpaid = Money.sub(sale['total'], sale['paid']);
    final order = ReceiptBuilder.orderHeadline(sale);
    return Scaffold(
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) => SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: constraints.maxHeight - 48),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 520),
                  child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                    const Icon(Icons.check_circle, size: 88, color: Brand.green),
                    const SizedBox(height: 12),
                    Text('Penjualan tersimpan', style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700)),
                    const SizedBox(height: 4),
                    Text(sale['number']?.toString() ?? 'Nomor nota menyusul saat sinkron', key: const Key('done-number')),
                    if (order != null) Text(order, style: const TextStyle(fontWeight: FontWeight.w600)),
                    const SizedBox(height: 24),
                    AmountRow('Total', rupiah(sale['total']), bold: true),
                    if (Money.isPositive(change)) AmountRow('Kembalian', rupiah(change), bold: true, large: true),
                    if (Money.isPositive(unpaid)) AmountRow('Belum dibayar (bon)', rupiah(unpaid), bold: true, color: warningText(context)),
                    const SizedBox(height: 16),
                    if (printResult != null && printResult != 'printed') Text(printMessage(printResult), textAlign: TextAlign.center, style: TextStyle(color: warningText(context))),
                    if ((kitchenResult ?? '').isNotEmpty)
                      Text('Belum tercetak: $kitchenResult', key: const Key('done-kitchen-failed'), textAlign: TextAlign.center, style: TextStyle(color: warningText(context), fontWeight: FontWeight.w600)),
                    const SizedBox(height: 24),
                    Row(children: [
                      Expanded(
                        child: _DoneAction(
                          key: const Key('print-receipt'),
                          icon: Icons.print_outlined,
                          label: printResult == 'printed' ? 'Cetak ulang' : 'Cetak struk',
                          onTap: () async {
                            final result = await ref.read(printerProvider.notifier).printSale(sale, reprint: printResult == 'printed');
                            if (context.mounted) {
                              showMessage(context, printMessage(result.name), error: result != PrintResult.printed);
                            }
                          },
                        ),
                      ),
                      const SizedBox(width: 8),
                      // List pesanan (dapur/bar, atau menyiapkan barang di toko eceran): selalu ada.
                      Expanded(
                        child: _DoneAction(
                          key: const Key('print-kitchen'),
                          icon: Icons.list_alt_outlined,
                          label: 'Cetak list',
                          onTap: () async {
                            final printer = ref.read(printerProvider.notifier);
                            // Yang gagal saja dicetak ulang; selain itu list baru ke semua printer.
                            final result = ref.read(printerProvider).productionFailed.isNotEmpty ? await printer.retryProduction() : await ref.read(posActionsProvider).printOrderList(sale);
                            if (context.mounted) {
                              showProductionResult(context, ref, result);
                            }
                          },
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _DoneAction(key: const Key('send-wa'), icon: Icons.chat_outlined, label: 'Kirim struk WA', onTap: () => _sendWhatsApp(context, ref)),
                      ),
                    ]),
                    const SizedBox(height: 12),
                    FilledButton(
                      key: const Key('new-sale'),
                      onPressed: () => context.pop(),
                      style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(56)),
                      child: const Text('Transaksi baru'),
                    ),
                  ]),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DoneAction extends StatelessWidget {
  const _DoneAction({super.key, required this.icon, required this.label, required this.onTap});

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => OutlinedButton(
        onPressed: onTap,
        style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 4), minimumSize: const Size(0, 76)),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon),
          const SizedBox(height: 4),
          Text(label, textAlign: TextAlign.center, maxLines: 2, style: const TextStyle(fontSize: 12.5)),
        ]),
      );
}
