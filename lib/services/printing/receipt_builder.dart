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

  static const Map<String, String> methodLabels = {'cash': 'Tunai', 'transfer': 'Transfer'};

  Generator _generator(int width) => Generator(width == 80 ? PaperSize.mm80 : PaperSize.mm58, profile);

  /// Hanya karakter yang aman untuk code page printer termal.
  static String clean(String? text) => (text ?? '')
      .replaceAll('×', 'x')
      .replaceAll(RegExp('[‘’]'), "'")
      .replaceAll(RegExp('[“”]'), '"')
      .replaceAll(RegExp('[–—]'), '-')
      .replaceAll('·', '-')
      .replaceAll(RegExp(r'[^\x0A\x20-\x7E]'), '');

  PosStyles _base(ReceiptConfig config) => PosStyles(fontType: config.fontSize == 'small' ? PosFontType.fontB : PosFontType.fontA);

  /// Struk satu penjualan (data penjualan lokal, lihat PosService).
  List<int> sale(Map<String, dynamic> sale, ReceiptConfig config, {int? width, List<int>? logo, bool reprint = false}) {
    final paper = width ?? config.width;
    final generator = _generator(paper);
    final base = _base(config);
    final bytes = <int>[...generator.reset()];

    bytes.addAll(_header(generator, config, base, logo, paper));
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
    info('No', sale['number']?.toString() ?? 'Menunggu nomor');
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
    bytes.addAll(generator.hr());

    for (final raw in (sale['items'] as List? ?? const [])) {
      final item = Map<String, dynamic>.from(raw as Map);
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

    amount('Subtotal', sale['subtotal']);
    if (Money.isPositive(sale['discount_total'])) {
      amount('Diskon', sale['discount_total'], prefix: '-');
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
    final status = Money.isPositive(balance) ? 'BELUM LUNAS' : 'LUNAS';
    bytes.addAll(generator.text(' $status ', styles: base.copyWith(align: PosAlign.center, bold: true, reverse: true)));
    if (reprint) {
      bytes.addAll(generator.text('-- CETAK ULANG --', styles: base.copyWith(align: PosAlign.center)));
    }
    bytes.addAll(generator.hr());
    bytes.addAll(_footer(generator, config, base, sale['verification_url']?.toString()));
    bytes.addAll(generator.cut());
    return bytes;
  }

  /// Baris jenis pesanan + meja/antrian: "BAWA PULANG - Meja 5". Null bila kosong.
  static String? orderHeadline(Map<String, dynamic> sale) {
    final parts = [OrderType.fromCode(sale['order_type'])?.ticketLabel, cleanNote(sale['order_label']?.toString(), 40)].whereType<String>().toList();
    return parts.isEmpty ? null : parts.join(' - ');
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

  /// Tiket pesanan dapur/bar: tanpa harga, qty & nama besar, catatan barang
  /// dan catatan pesanan, jenis pesanan + meja/antrian.
  List<int> kitchenTicket(Map<String, dynamic> sale, ReceiptConfig config, {int? width}) {
    final paper = width ?? config.width;
    final generator = _generator(paper);
    final base = _base(config);
    final bytes = <int>[...generator.reset()];
    bytes.addAll(generator.text('PESANAN DAPUR', styles: base.copyWith(align: PosAlign.center, bold: true, height: PosTextSize.size2, width: PosTextSize.size2)));
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

    info('No', sale['number']?.toString() ?? 'Menunggu nomor');
    info('Waktu', receiptDateTime(createdAt));
    info('Kasir', sale['cashier']?.toString());
    final customer = sale['customer_name']?.toString();
    if (customer != null && customer != 'Pelanggan Umum') {
      info('Pelanggan', customer);
    }
    bytes.addAll(generator.hr());
    for (final raw in (sale['items'] as List? ?? const [])) {
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
    final verify = sale['verification_url']?.toString();
    if (verify != null && verify.isNotEmpty) {
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
    bytes.addAll(generator.text('LAPORAN TUTUP KASIR', styles: base.copyWith(align: PosAlign.center, bold: true)));
    bytes.addAll(generator.hr());

    void line(String label, String value, {bool bold = false}) => bytes.addAll(generator.row([
          PosColumn(text: clean(label), width: 6, styles: base.copyWith(bold: bold)),
          PosColumn(text: clean(value), width: 6, styles: base.copyWith(align: PosAlign.right, bold: bold)),
        ]));

    line('Kasir', report['cashier']?.toString() ?? '-');
    line('Buka', report['opened_at'] == null ? '-' : receiptDateTime(DateTime.parse(report['opened_at'].toString()).toLocal()));
    line('Tutup', report['closed_at'] == null ? '-' : receiptDateTime(DateTime.parse(report['closed_at'].toString()).toLocal()));
    bytes.addAll(generator.hr());
    line('Jumlah nota', '${report['sales_count'] ?? 0}');
    line('Total penjualan', rupiah(report['sales_total']));
    line('Tunai', rupiah(report['cash_total']));
    line('Transfer', rupiah(report['transfer_total']));
    line('Bon (belum dibayar)', rupiah(report['unpaid_total']));
    bytes.addAll(generator.hr());
    line('Uang awal', rupiah(report['opening_cash']));
    line('Seharusnya di laci', rupiah(report['expected_cash']), bold: true);
    line('Uang dihitung', rupiah(report['closing_cash']), bold: true);
    line('Selisih', rupiah(report['difference']), bold: true);
    bytes.addAll(generator.hr());
    bytes.addAll(generator.text('Dicetak ${receiptDateTime(DateTime.now())}', styles: base.copyWith(align: PosAlign.center)));
    bytes.addAll(generator.cut());
    return bytes;
  }

  /// Halaman tes printer.
  List<int> testPage(ReceiptConfig config, {required int width, List<int>? logo}) {
    final generator = _generator(width);
    final base = _base(config);
    final bytes = <int>[...generator.reset()];
    bytes.addAll(_header(generator, config, base, logo, width));
    bytes.addAll(generator.hr());
    bytes.addAll(generator.text('Tes cetak berhasil', styles: base.copyWith(align: PosAlign.center, bold: true)));
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
    if (config.showQr && verificationUrl != null && verificationUrl.isNotEmpty) {
      bytes.addAll(generator.qrcode(verificationUrl, size: QRSize.size5));
      bytes.addAll(generator.text('Pindai untuk cek keaslian nota', styles: base.copyWith(align: PosAlign.center, fontType: PosFontType.fontB)));
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
