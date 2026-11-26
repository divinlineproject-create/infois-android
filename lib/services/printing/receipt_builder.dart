import 'dart:convert' show latin1;
import 'dart:typed_data';

import 'package:esc_pos_utils_plus/esc_pos_utils_plus.dart';
import 'package:image/image.dart' as img;

import '../../core/format.dart';
import '../../core/money.dart';
import '../../domain/cart.dart';
import '../../domain/models.dart';

/// Struk kasir ESC/POS yang dirender di HP (bisa dicetak saat offline):
/// logo hitam-putih, item, total, pembayaran, cap LUNAS, QR cek keaslian,
/// header/footer sesuai Dokumen & Nota › Nota Termal di web.
class ReceiptBuilder {
  ReceiptBuilder(this.profile);

  final CapabilityProfile profile;

  static Future<ReceiptBuilder> create() async => ReceiptBuilder(await CapabilityProfile.load());

  static const Map<String, String> methodLabels = {'cash': 'Tunai', 'transfer': 'Transfer', 'qris': 'QRIS'};

  Generator _generator(int width) => Generator(width == 80 ? PaperSize.mm80 : PaperSize.mm58, profile);

  /// Hanya karakter yang aman untuk code page printer termal.
  static String clean(String? text) => (text ?? '')
      .replaceAll('×', 'x')
      .replaceAll(RegExp('[‘’]'), "'")
      .replaceAll(RegExp('[“”]'), '"')
      .replaceAll(RegExp('[–—]'), '-')
      .replaceAll('·', '-')
      .replaceAll('→', '->')
      .replaceAll('›', '>')
      .replaceAll(RegExp(r'[^\x0A\x20-\x7E]'), '');

  PosStyles _base(ReceiptConfig config) => PosStyles(fontType: config.fontSize == 'small' ? PosFontType.fontB : PosFontType.fontA);

  /// Baris biaya tambahan (ongkos kirim, ...), bukan barang.
  static bool isCharge(Object? item) => item is Map && item['charge'] == true;

  /// Struk satu penjualan (data penjualan lokal, lihat PosService). Biaya
  /// tambahan tercetak sebagai baris biasa.
  List<int> sale(Map<String, dynamic> sale, ReceiptConfig config, {int? width, List<int>? logo, bool reprint = false}) =>
      _receipt(sale, config, width: width, logo: logo, reprint: reprint);

  /// Tagihan sebelum dibayar (data dari `PosService.draft`): tampilan struk
  /// berjudul TAGIHAN, "Bukan bukti pembayaran", biaya tambahan di bagian
  /// total, Sisa tagihan = total, cap BELUM DIBAYAR, tanpa pembayaran & QR.
  List<int> bill(Map<String, dynamic> draft, ReceiptConfig config, {int? width, List<int>? logo}) =>
      _receipt(draft, config, width: width, logo: logo, bill: true);

  List<int> _receipt(Map<String, dynamic> sale, ReceiptConfig config, {int? width, List<int>? logo, bool reprint = false, bool bill = false}) {
    final paper = width ?? config.width;
    final generator = _generator(paper);
    final base = _base(config);
    final bytes = <int>[...generator.reset()];

    bytes.addAll(_header(generator, config, base, logo, paper));
    if (bill) {
      bytes.addAll(generator.feed(1));
      bytes.addAll(generator.text('TAGIHAN', styles: base.copyWith(align: PosAlign.center, bold: true, height: PosTextSize.size2)));
      bytes.addAll(generator.text('Bukan bukti pembayaran', styles: base.copyWith(align: PosAlign.center)));
    }
    bytes.addAll(generator.hr());

    void info(String label, String? value) {
      if (value == null || value.isEmpty) {
        return;
      }
      bytes.addAll(generator.row([
        PosColumn(text: clean(label), width: 4, styles: base),
        PosColumn(text: clean(value), width: 8, styles: base.copyWith(align: PosAlign.right)),
      ]));
    }

    final createdAt = DateTime.tryParse(sale['created_at']?.toString() ?? '')?.toLocal() ?? DateTime.now();
    info('No', bill ? (sale['title']?.toString() ?? '-') : (sale['number']?.toString() ?? 'Menunggu nomor'));
    info('Tanggal', receiptDateTime(createdAt));
    if (config.showCashier) {
      info('Kasir', sale['cashier']?.toString());
    }
    final customer = sale['customer_name']?.toString();
    if (config.showCustomer && customer != null && customer != 'Pelanggan Umum') {
      info('Pelanggan', customer);
    }
    final order = orderHeadline(sale);
    if (order != null) {
      bytes.addAll(generator.text(clean(order), styles: base.copyWith(align: PosAlign.center, bold: true)));
    }
    final queue = queueNumberOf(sale);
    if (queue != null) {
      bytes.addAll(generator.text('Antrian $queue', styles: base.copyWith(align: PosAlign.center, bold: true)));
    }
    bytes.addAll(_deliveryAddress(generator, base, sale));
    bytes.addAll(generator.hr());

    final items = [for (final raw in (sale['items'] as List? ?? const [])) Map<String, dynamic>.from(raw as Map)];
    final charges = bill ? items.where(isCharge).toList() : const <Map<String, dynamic>>[];
    for (final item in items) {
      if (bill && isCharge(item)) {
        continue;
      }
      bytes.addAll(generator.text(clean(item['description']?.toString()), styles: base.copyWith(bold: true)));
      final discount = Money.normalize(item['discount_percent']);
      final detail = '${qty(item['quantity'])}${(item['unit'] ?? '').toString().isEmpty ? '' : ' ${item['unit']}'} x ${rupiah(item['unit_price'], symbol: false)}'
          '${Money.isPositive(discount) ? ' (-${percentLabel(discount)}%)' : ''}';
      bytes.addAll(generator.row([
        PosColumn(text: clean(detail), width: 8, styles: base),
        PosColumn(text: rupiah(item['line_total'], symbol: false), width: 4, styles: base.copyWith(align: PosAlign.right)),
      ]));
      final note = cleanNote(item['note']?.toString());
      if (note != null) {
        bytes.addAll(generator.text(clean('  * $note'), styles: base));
      }
    }
    bytes.addAll(_orderNote(generator, base, sale));
    bytes.addAll(generator.hr());

    void amount(String label, Object? value, {bool bold = false, String prefix = ''}) {
      bytes.addAll(generator.row([
        PosColumn(text: clean(label), width: 6, styles: base.copyWith(bold: bold)),
        PosColumn(text: '$prefix${rupiah(value)}', width: 6, styles: base.copyWith(align: PosAlign.right, bold: bold)),
      ]));
    }

    // Tagihan: subtotal barang saja, biaya tambahan sebaris masing-masing.
    amount('Subtotal', bill ? Money.sub(sale['subtotal'], Money.add([for (final charge in charges) charge['line_total']])) : sale['subtotal']);
    if (Money.isPositive(sale['discount_total'])) {
      amount('Diskon', sale['discount_total'], prefix: '-');
    }
    for (final charge in charges) {
      amount(charge['description']?.toString() ?? 'Biaya tambahan', charge['line_total']);
    }
    if (config.showTax && Money.isPositive(sale['tax_total'])) {
      amount('${sale['tax_name'] ?? 'PPN'}${sale['prices_include_tax'] == true ? ' (termasuk)' : ''}', sale['tax_total']);
    }
    bytes.addAll(generator.row([
      PosColumn(text: 'TOTAL', width: 5, styles: base.copyWith(bold: true, height: PosTextSize.size2)),
      PosColumn(text: rupiah(sale['total']), width: 7, styles: base.copyWith(bold: true, height: PosTextSize.size2, align: PosAlign.right)),
    ]));

    final payments = [for (final raw in (sale['payments'] as List? ?? const [])) Map<String, dynamic>.from(raw as Map)];
    if (config.showPayment) {
      for (final payment in payments) {
        final method = methodLabels[payment['method']] ?? 'Bayar';
        final shown = payment['method'] == 'cash' && payment['tendered'] != null ? payment['tendered'] : payment['amount'];
        amount('Bayar - $method', shown);
      }
      if (Money.isPositive(sale['change'])) {
        amount('Kembali', sale['change']);
      }
    }
    final paid = Money.add([for (final payment in payments) payment['amount']]);
    final balance = Money.sub(sale['total'], paid);
    if (Money.isPositive(balance)) {
      amount('Sisa tagihan', balance, bold: true);
    }

    bytes.addAll(generator.feed(1));
    final status = bill ? 'BELUM DIBAYAR' : (Money.isPositive(balance) ? 'BELUM LUNAS' : 'LUNAS');
    // Tulisan tebal besar, tanpa blok hitam (cetak terbalik boros & sulit dibaca di kertas termal).
    bytes.addAll(generator.text(status, styles: base.copyWith(align: PosAlign.center, bold: true, height: PosTextSize.size2)));
    if (reprint) {
      bytes.addAll(generator.text('-- CETAK ULANG --', styles: base.copyWith(align: PosAlign.center)));
    }
    if (bill) {
      bytes.addAll(_qrisBlock(generator, base, sale['qris'], paper));
    }
    bytes.addAll(generator.hr());
    bytes.addAll(_footer(generator, config, base, sale['verification_url']?.toString()));
    bytes.addAll(generator.cut());
    return bytes;
  }

  /// Nomor antrian pesanan ("000012"), atau null.
  static String? queueNumberOf(Map<String, dynamic> sale) => cleanNote(sale['queue_number']?.toString(), 10);

  /// Baris jenis pesanan + meja/antrian: "BAWA PULANG - Meja 5". Null bila kosong.
  static String? orderHeadline(Map<String, dynamic> sale) {
    final parts = [OrderType.fromCode(sale['order_type'])?.ticketLabel, cleanNote(sale['order_label']?.toString(), 40)].whereType<String>().toList();
    return parts.isEmpty ? null : parts.join(' - ');
  }

  /// Tagihan dengan QR QRIS yang belum dibayar ("Cetak QR"): perintah QR
  /// ESC/POS dari isi QR (bukan gambar), nominal, dan petunjuk scan.
  List<int> _qrisBlock(Generator generator, PosStyles base, Object? qris, int paper) {
    if (qris is! Map) {
      return const [];
    }
    final content = qris['content']?.toString() ?? '';
    if (content.isEmpty) {
      return const [];
    }
    return [
      ...generator.hr(),
      ...generator.text('Bayar dengan QRIS', styles: base.copyWith(align: PosAlign.center, bold: true)),
      ...generator.setStyles(base.copyWith(align: PosAlign.center)),
      ...qrCommand(content, moduleSize: paper == 80 ? 7 : 5),
      ...generator.feed(1),
      if (qris['amount'] != null) ...generator.text(rupiah(qris['amount']), styles: base.copyWith(align: PosAlign.center, bold: true)),
      ...generator.text('Scan dengan aplikasi bank / e-wallet', styles: base.copyWith(align: PosAlign.center)),
    ];
  }

  /// Perintah QR ESC/POS (GS ( k, model 2, koreksi M) untuk [content].
  /// Panjang data ditulis dua byte (pL pH): isi QRIS bisa lebih dari 252
  /// karakter, batas `Generator.qrcode` yang hanya menulis satu byte.
  static List<int> qrCommand(String content, {int moduleSize = 5}) {
    const header = [0x1D, 0x28, 0x6B];
    final data = latin1.encode(clean(content));
    final length = data.length + 3;
    return [
      ...header, 0x04, 0x00, 0x31, 0x41, 0x32, 0x00, // model 2
      ...header, 0x03, 0x00, 0x31, 0x43, moduleSize.clamp(1, 16), // ukuran modul
      ...header, 0x03, 0x00, 0x31, 0x45, 0x31, // koreksi galat M
      ...header, length & 0xFF, length >> 8, 0x31, 0x50, 0x30, ...data, // simpan data
      ...header, 0x03, 0x00, 0x31, 0x51, 0x30, // cetak
    ];
  }

  /// Blok "Kirim ke:" + alamat pengiriman (struk, tagihan, list pesanan).
  List<int> _deliveryAddress(Generator generator, PosStyles base, Map<String, dynamic> sale) {
    final address = cleanNote(sale['delivery_address']?.toString(), 500);
    if (address == null) {
      return const [];
    }
    return [
      ...generator.text('Kirim ke:', styles: base.copyWith(bold: true)),
      for (final line in clean(address).split('\n'))
        if (line.trim().isNotEmpty) ...generator.text(line.trim(), styles: base),
    ];
  }

  List<int> _orderNote(Generator generator, PosStyles base, Map<String, dynamic> sale) {
    final note = cleanNote(sale['notes']?.toString(), 1000);
    if (note == null) {
      return const [];
    }
    return [
      ...generator.text('Catatan:', styles: base.copyWith(bold: true)),
      for (final line in clean(note).split('\n')) ...generator.text(line, styles: base),
    ];
  }

  /// List pesanan untuk dapur/bar atau menyiapkan barang di gudang: tanpa
  /// harga, qty & nama besar, catatan barang dan catatan pesanan, jenis
  /// pesanan + meja/antrian. Biaya tambahan tidak ikut. Penjualan yang sudah
  /// dibayar, atau keranjang sebelum dibayar (`PosService.draft`).
  /// [station] = nama printer produksi (mis. "Bar") sebagai judul.
  List<int> orderList(Map<String, dynamic> sale, ReceiptConfig config, {int? width, String? station}) {
    final paper = width ?? config.width;
    final generator = _generator(paper);
    final base = _base(config);
    final bytes = <int>[...generator.reset()];
    final title = cleanNote(station, 24)?.toUpperCase() ?? 'LIST PESANAN';
    bytes.addAll(generator.text(clean(title), styles: base.copyWith(align: PosAlign.center, bold: true, height: PosTextSize.size2, width: PosTextSize.size2)));
    final queue = queueNumberOf(sale);
    if (queue != null) {
      bytes.addAll(generator.text('ANTRIAN $queue', styles: base.copyWith(align: PosAlign.center, bold: true, height: PosTextSize.size2, width: PosTextSize.size2)));
    }
    final order = orderHeadline(sale);
    if (order != null) {
      bytes.addAll(generator.text(clean(order), styles: base.copyWith(align: PosAlign.center, bold: true, height: PosTextSize.size2)));
    }
    bytes.addAll(generator.hr());
    final createdAt = DateTime.tryParse(sale['created_at']?.toString() ?? '')?.toLocal() ?? DateTime.now();
    void info(String label, String? value) {
      if (value == null || value.isEmpty) {
        return;
      }
      bytes.addAll(generator.row([
        PosColumn(text: clean(label), width: 4, styles: base),
        PosColumn(text: clean(value), width: 8, styles: base.copyWith(align: PosAlign.right)),
      ]));
    }

    info('No', sale['draft'] == true ? (sale['title']?.toString() ?? 'Belum dibayar') : (sale['number']?.toString() ?? 'Menunggu nomor'));
    info('Waktu', receiptDateTime(createdAt));
    info('Kasir', sale['cashier']?.toString());
    final customer = sale['customer_name']?.toString();
    if (customer != null && customer != 'Pelanggan Umum') {
      info('Pelanggan', customer);
    }
    bytes.addAll(_deliveryAddress(generator, base, sale));
    bytes.addAll(generator.hr());
    for (final raw in (sale['items'] as List? ?? const [])) {
      if (isCharge(raw)) {
        continue;
      }
      final item = Map<String, dynamic>.from(raw as Map);
      final unit = (item['unit'] ?? '').toString();
      bytes.addAll(generator.text(
        clean('${qty(item['quantity'])}${unit.isEmpty ? '' : ' $unit'}  ${item['description'] ?? ''}'),
        styles: base.copyWith(bold: true, height: PosTextSize.size2),
      ));
      final note = cleanNote(item['note']?.toString());
      if (note != null) {
        bytes.addAll(generator.text(clean('   >> $note'), styles: base.copyWith(bold: true)));
      }
    }
    bytes.addAll(generator.hr());
    final orderNote = _orderNote(generator, base, sale);
    if (orderNote.isNotEmpty) {
      bytes.addAll(orderNote);
      bytes.addAll(generator.hr());
    }
    bytes.addAll(generator.text('Dicetak ${receiptDateTime(DateTime.now())}', styles: base.copyWith(align: PosAlign.center)));
    bytes.addAll(generator.cut());
    return bytes;
  }

  /// Struk sebagai teks biasa untuk dikirim lewat WhatsApp.
  static String plainText(Map<String, dynamic> sale, ReceiptConfig config) {
    final out = StringBuffer();
    if (config.companyName.isNotEmpty) {
      out.writeln('*${config.companyName}*');
    }
    if (config.showAddress && (config.address ?? '').isNotEmpty) {
      out.writeln(config.address);
    }
    out.writeln('No. nota: ${sale['number'] ?? 'menunggu nomor'}');
    final createdAt = DateTime.tryParse(sale['created_at']?.toString() ?? '')?.toLocal();
    if (createdAt != null) {
      out.writeln('Tanggal: ${receiptDateTime(createdAt)}');
    }
    final type = OrderType.fromCode(sale['order_type'])?.label;
    final label = cleanNote(sale['order_label']?.toString(), 40);
    if (type != null || label != null) {
      out.writeln([type, label].whereType<String>().join(' · '));
    }
    final queue = queueNumberOf(sale);
    if (queue != null) {
      out.writeln('Antrian $queue');
    }
    final address = cleanNote(sale['delivery_address']?.toString(), 500);
    if (address != null) {
      out.writeln('Kirim ke: $address');
    }
    out.writeln();
    for (final raw in (sale['items'] as List? ?? const [])) {
      final item = Map<String, dynamic>.from(raw as Map);
      final unit = (item['unit'] ?? '').toString();
      out.writeln('${item['description']}');
      final discount = Money.normalize(item['discount_percent']);
      out.writeln('  ${qty(item['quantity'])}${unit.isEmpty ? '' : ' $unit'} x ${rupiah(item['unit_price'])}'
          '${Money.isPositive(discount) ? ' (-${percentLabel(discount)}%)' : ''} = ${rupiah(item['line_total'])}');
      final note = cleanNote(item['note']?.toString());
      if (note != null) {
        out.writeln('  Catatan: $note');
      }
    }
    out.writeln();
    out.writeln('Subtotal: ${rupiah(sale['subtotal'])}');
    if (Money.isPositive(sale['discount_total'])) {
      out.writeln('Diskon: -${rupiah(sale['discount_total'])}');
    }
    if (Money.isPositive(sale['tax_total'])) {
      out.writeln('${sale['tax_name'] ?? 'PPN'}${sale['prices_include_tax'] == true ? ' (termasuk)' : ''}: ${rupiah(sale['tax_total'])}');
    }
    out.writeln('*Total: ${rupiah(sale['total'])}*');
    final payments = [for (final raw in (sale['payments'] as List? ?? const [])) Map<String, dynamic>.from(raw as Map)];
    for (final payment in payments) {
      final shown = payment['method'] == 'cash' && payment['tendered'] != null ? payment['tendered'] : payment['amount'];
      out.writeln('${methodLabels[payment['method']] ?? 'Bayar'}: ${rupiah(shown)}');
    }
    if (Money.isPositive(sale['change'])) {
      out.writeln('Kembali: ${rupiah(sale['change'])}');
    }
    final balance = Money.sub(sale['total'], Money.add([for (final payment in payments) payment['amount']]));
    out.writeln(Money.isPositive(balance) ? 'Sisa tagihan: ${rupiah(balance)}' : 'LUNAS');
    final note = cleanNote(sale['notes']?.toString(), 1000);
    if (note != null) {
      out.writeln();
      out.writeln('Catatan: $note');
    }
    final link = config.customQrLink;
    final verify = sale['verification_url']?.toString();
    if (link != null) {
      out.writeln();
      out.writeln([if (config.qrCaption != null) config.qrCaption, link].join(' '));
    } else if (verify != null && verify.isNotEmpty && config.qrMode != 'link') {
      out.writeln();
      out.writeln('Cek keaslian nota: $verify');
    }
    if (config.footerText.isNotEmpty) {
      out.writeln();
      out.writeln(config.footerText);
    }
    return out.toString().trimRight();
  }

  /// Laporan tutup shift (Z-report).
  List<int> shiftReport(Map<String, dynamic> report, ReceiptConfig config, {int? width}) {
    final paper = width ?? config.width;
    final generator = _generator(paper);
    final base = _base(config);
    final bytes = <int>[...generator.reset()];
    bytes.addAll(generator.text(clean(config.companyName), styles: base.copyWith(align: PosAlign.center, bold: true)));
    final closed = report['closed_at'] != null;
    bytes.addAll(generator.text(closed ? 'LAPORAN TUTUP KASIR' : 'REKAP KASIR', styles: base.copyWith(align: PosAlign.center, bold: true)));
    bytes.addAll(generator.hr());

    void line(String label, String value, {bool bold = false}) => bytes.addAll(generator.row([
          PosColumn(text: clean(label), width: 6, styles: base.copyWith(bold: bold)),
          PosColumn(text: clean(value), width: 6, styles: base.copyWith(align: PosAlign.right, bold: bold)),
        ]));

    line('Kasir', report['cashier']?.toString() ?? '-');
    line('Buka', report['opened_at'] == null ? '-' : receiptDateTime(DateTime.parse(report['opened_at'].toString()).toLocal()));
    line('Tutup', closed ? receiptDateTime(DateTime.parse(report['closed_at'].toString()).toLocal()) : 'Masih dibuka');
    bytes.addAll(generator.hr());
    line('Jumlah nota', '${report['sales_count'] ?? 0}');
    line('Total penjualan', rupiah(report['sales_total']));
    line('Tunai', rupiah(report['cash_total']));
    line('Transfer', rupiah(report['transfer_total']));
    if (Money.isPositive(report['qris_total'])) {
      line('QRIS', rupiah(report['qris_total']));
    }
    line('Bon (belum dibayar)', rupiah(report['unpaid_total']));
    bytes.addAll(generator.hr());
    line('Uang awal', rupiah(report['opening_cash']));
    line('Seharusnya di laci', rupiah(report['expected_cash']), bold: true);
    if (closed) {
      line('Uang dihitung', rupiah(report['closing_cash']), bold: true);
      line('Selisih', rupiah(report['difference']), bold: true);
    }
    // Pindah uang otomatis dari server (uang awal & setoran); server lama: tidak ada.
    final transfers = ShiftCashTransfers.fromJson(report['cash_transfers']);
    if (transfers != null && !transfers.isEmpty) {
      bytes.addAll(generator.hr());
      if (transfers.float != null) {
        line('Uang awal ke ${transfers.float!.to ?? 'laci'}', rupiah(transfers.float!.amount));
      }
      if (transfers.deposit != null) {
        line('Setoran ke ${transfers.deposit!.to ?? 'kas'}', rupiah(transfers.deposit!.amount));
      }
      if (transfers.note != null) {
        bytes.addAll(generator.text(clean(transfers.note), styles: base));
      }
    }
    final notes = cleanNote(report['notes']?.toString(), 500);
    if (notes != null) {
      bytes.addAll(generator.hr());
      bytes.addAll(generator.text('Catatan:', styles: base.copyWith(bold: true)));
      for (final note in clean(notes).split('\n')) {
        bytes.addAll(generator.text(note, styles: base));
      }
    }
    bytes.addAll(generator.hr());
    bytes.addAll(generator.text('Dicetak ${receiptDateTime(DateTime.now())}', styles: base.copyWith(align: PosAlign.center)));
    bytes.addAll(generator.cut());
    return bytes;
  }

  /// Halaman tes printer.
  List<int> testPage(ReceiptConfig config, {required int width, List<int>? logo, String? title}) {
    final generator = _generator(width);
    final base = _base(config);
    final bytes = <int>[...generator.reset()];
    bytes.addAll(_header(generator, config, base, logo, width));
    bytes.addAll(generator.hr());
    bytes.addAll(generator.text('Tes cetak berhasil', styles: base.copyWith(align: PosAlign.center, bold: true)));
    if (title != null) {
      bytes.addAll(generator.text(clean(title), styles: base.copyWith(align: PosAlign.center)));
    }
    bytes.addAll(generator.text('Kertas $width mm', styles: base.copyWith(align: PosAlign.center)));
    bytes.addAll(generator.row([
      PosColumn(text: 'Contoh barang', width: 8, styles: base),
      PosColumn(text: rupiah('15000', symbol: false), width: 4, styles: base.copyWith(align: PosAlign.right)),
    ]));
    bytes.addAll(generator.hr());
    bytes.addAll(generator.text(receiptDateTime(DateTime.now()), styles: base.copyWith(align: PosAlign.center)));
    bytes.addAll(generator.cut());
    return bytes;
  }

  List<int> _header(Generator generator, ReceiptConfig config, PosStyles base, List<int>? logo, int width) {
    final bytes = <int>[];
    if (config.showLogo && logo != null && logo.isNotEmpty) {
      final image = logoImage(logo, width);
      if (image != null) {
        bytes.addAll(generator.image(image));
      }
    }
    bytes.addAll(generator.text(clean(config.companyName), styles: base.copyWith(align: PosAlign.center, bold: true, height: PosTextSize.size2)));
    if (config.showAddress && (config.address ?? '').isNotEmpty) {
      for (final line in clean(config.address).split('\n')) {
        bytes.addAll(generator.text(line, styles: base.copyWith(align: PosAlign.center)));
      }
    }
    if (config.showPhone && (config.phone ?? '').isNotEmpty) {
      bytes.addAll(generator.text('Telp. ${clean(config.phone)}', styles: base.copyWith(align: PosAlign.center)));
    }
    if ((config.headerText ?? '').isNotEmpty) {
      for (final line in clean(config.headerText).split('\n')) {
        bytes.addAll(generator.text(line, styles: base.copyWith(align: PosAlign.center)));
      }
    }
    return bytes;
  }

  List<int> _footer(Generator generator, ReceiptConfig config, PosStyles base, String? verificationUrl) {
    final bytes = <int>[];
    for (final line in clean(config.footerText).split('\n')) {
      bytes.addAll(generator.text(line, styles: base.copyWith(align: PosAlign.center)));
    }
    // QR: tautan sendiri (mis. Google Maps, Instagram) atau cek keaslian nota.
    final link = config.customQrLink;
    final qr = link ?? (config.showQr && config.qrMode != 'link' ? verificationUrl : null);
    if (qr != null && qr.isNotEmpty) {
      bytes.addAll(qrCommand(qr));
      final caption = config.qrCaption ?? (link == null ? 'Pindai untuk cek keaslian nota' : null);
      if (caption != null) {
        for (final line in clean(caption).split('\n')) {
          bytes.addAll(generator.text(line, styles: base.copyWith(align: PosAlign.center, fontType: PosFontType.fontB)));
        }
      }
    }
    if ((config.website ?? '').isNotEmpty) {
      bytes.addAll(generator.text(clean(config.website), styles: base.copyWith(align: PosAlign.center)));
    }
    return bytes;
  }

  /// Logo menjadi gambar hitam-putih selebar ±60% kertas.
  static img.Image? logoImage(List<int> bytes, int paperWidth) {
    final decoded = img.decodeImage(Uint8List.fromList(bytes));
    if (decoded == null) {
      return null;
    }
    final maxWidth = ((paperWidth == 80 ? 576 : 384) * 0.6).round();
    var image = decoded.width > maxWidth ? img.copyResize(decoded, width: maxWidth) : decoded;
    if (image.hasAlpha) {
      final flattened = img.Image(width: image.width, height: image.height);
      img.fill(flattened, color: img.ColorRgb8(255, 255, 255));
      img.compositeImage(flattened, image);
      image = flattened;
    }
    return img.grayscale(image);
  }
}
