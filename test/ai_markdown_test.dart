import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:infois/ui/theme.dart';
import 'package:infois/ui/widgets/ai_markdown.dart';

/// Markdown ringan jawaban Tim AI (tanpa paket tambahan).
void main() {
  const answer = '''
## Ringkasan hari ini
Penjualan **Rp 1.250.000** dari _12 transaksi_, naik `8%`.

- Kopi susu paling laku
- Roti bakar **habis** sore
  dan perlu dipesan lagi

1. Cek stok gula
2. Bayar tagihan listrik

| Barang | Terjual | Total |
|---|---:|---:|
| Kopi susu | 40 | Rp 600.000 |
| Roti bakar | 25 | Rp 375.000 |

> Catatan: harga belum termasuk pajak.

[Buka laporan](https://dashboard.infois.ai/app/reports)
''';

  test('parse: judul, paragraf, daftar butir & nomor, tabel, kutipan, tautan', () {
    final blocks = parseMarkdown(answer);
    expect(blocks.whereType<MdHeading>().single.text, 'Ringkasan hari ini');
    final lists = blocks.whereType<MdList>().toList();
    expect(lists, hasLength(2));
    expect(lists.first.items.map((item) => item.marker), ['•', '•']);
    expect(lists.first.items.last.text, 'Roti bakar **habis** sore\ndan perlu dipesan lagi', reason: 'Baris menjorok ikut butir sebelumnya.');
    expect(lists.last.items.map((item) => item.marker), ['1.', '2.']);
    final table = blocks.whereType<MdTable>().single;
    expect(table.header, ['Barang', 'Terjual', 'Total']);
    expect(table.rows, hasLength(2));
    expect(table.alignRight, [false, true, true]);
    expect(blocks.whereType<MdQuote>().single.text, 'Catatan: harga belum termasuk pajak.');
    expect(parseMarkdown('---').single, isA<MdRule>());
    expect(parseMarkdown('```\nkode\n```').single, isA<MdCode>());
    expect(parseMarkdown('*miring* saja').single, isA<MdParagraph>(), reason: 'Bintang miring bukan butir daftar.');
  });

  test('teks polos untuk Salin: tanda Markdown dibuang', () {
    expect(markdownToPlainText('Saya siapkan **2 kopi susu** ke `Pak Budi`.'), 'Saya siapkan 2 kopi susu ke Pak Budi.');
    expect(markdownToPlainText('# Judul\n- satu\n- **dua**'), 'Judul\n\n• satu\n• dua');
    expect(markdownToPlainText('Lihat [laporan](https://infois.ai/r)'), 'Lihat laporan (https://infois.ai/r)');
  });

  Future<List<String>> pump(WidgetTester tester, String text, {Brightness brightness = Brightness.light, double width = 360}) async {
    final links = <String>[];
    tester.view.physicalSize = Size(width, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(child: MaterialApp(theme: buildTheme(brightness), home: Scaffold(body: SingleChildScrollView(padding: const EdgeInsets.all(16), child: AiMarkdown(text, onTapLink: links.add))))),
    );
    return links;
  }

  bool hasSpan(WidgetTester tester, String text, bool Function(TextStyle style) test) {
    for (final rich in tester.widgetList<RichText>(find.byType(RichText))) {
      var found = false;
      rich.text.visitChildren((span) {
        if (span is TextSpan && span.text == text && span.style != null && test(span.style!)) {
          found = true;
          return false;
        }
        return true;
      });
      if (found) {
        return true;
      }
    }
    return false;
  }

  testWidgets('render: tebal, miring, daftar, tabel yang bisa digeser, dan tautan', (tester) async {
    final links = await pump(tester, answer);

    expect(find.text('Ringkasan hari ini'), findsOneWidget);
    expect(hasSpan(tester, 'Rp 1.250.000', (style) => style.fontWeight == FontWeight.w700), isTrue, reason: '**tebal**');
    expect(hasSpan(tester, '12 transaksi', (style) => style.fontStyle == FontStyle.italic), isTrue, reason: '_miring_');
    expect(hasSpan(tester, '8%', (style) => style.fontFamily == 'monospace'), isTrue, reason: '`kode`');
    expect(find.text('•'), findsNWidgets(2));
    expect(find.text('1.'), findsOneWidget);
    expect(find.text('2.'), findsOneWidget);

    final table = find.byKey(const Key('md-table'));
    expect(table, findsOneWidget);
    expect(tester.widget<SingleChildScrollView>(table).scrollDirection, Axis.horizontal, reason: 'Tabel lebar digeser ke samping, tidak terpotong.');
    expect(find.descendant(of: table, matching: find.text('Rp 600.000')), findsOneWidget);
    expect(find.descendant(of: table, matching: find.text('Barang')), findsOneWidget);

    await tester.ensureVisible(find.text('Buka laporan'));
    await tester.tap(find.text('Buka laporan'));
    expect(links, ['https://dashboard.infois.ai/app/reports']);
  });

  testWidgets('tabel lebar & mode gelap di layar 320dp tidak meluap', (tester) async {
    const wide = '| A | B | C | D | E |\n|---|---|---|---|---|\n| isi panjang sekali untuk kolom pertama | 2 | 3 | 4 | Rp 1.000.000 |';
    await pump(tester, '$wide\n\nAlamat https://infois.ai.', brightness: Brightness.dark, width: 320);
    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('md-table')), findsOneWidget);
    expect(hasSpan(tester, 'https://infois.ai', (style) => style.decoration == TextDecoration.underline), isTrue, reason: 'Alamat web polos juga bisa diketuk; titik akhir kalimat tidak ikut.');
  });

  test('tautan: hanya http/https; situs di luar Infois atau teks yang menyamar dikonfirmasi dulu', () {
    expect(aiLinkAction('https://dashboard.infois.ai/app/reports', label: 'Buka laporan'), AiLinkAction.open);
    expect(aiLinkAction('https://wa.me/6281234', label: 'Chat WhatsApp'), AiLinkAction.open);
    expect(aiLinkAction('https://infois.ai', label: 'infois.ai'), AiLinkAction.open);
    expect(aiLinkAction('https://evil.example/login', label: 'dashboard.infois.ai'), AiLinkAction.confirm, reason: 'Teks menyebut alamat lain dari tujuan aslinya.');
    expect(aiLinkAction('https://dashboard.infois.ai/x', label: 'https://bank.example'), AiLinkAction.confirm);
    expect(aiLinkAction('https://toko.example/promo', label: 'promo'), AiLinkAction.confirm);
    for (final url in ['tel:0812', 'mailto:a@b.id', 'javascript:alert(1)', 'intent://x#Intent;end', 'file:///sdcard/a.db', 'https://']) {
      expect(aiLinkAction(url, label: 'x'), AiLinkAction.block, reason: url);
    }
  });

  testWidgets('tautan ke situs lain: dialog menampilkan alamat aslinya sebelum dibuka', (tester) async {
    tester.view.physicalSize = const Size(360, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(child: MaterialApp(theme: buildTheme(Brightness.light), home: const Scaffold(body: AiMarkdown('[dashboard.infois.ai](https://evil.example/login)')))),
    );
    await tester.tap(find.text('dashboard.infois.ai', findRichText: true));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('link-confirm')), findsOneWidget);
    expect(find.text('evil.example'), findsOneWidget, reason: 'Alamat tujuan sebenarnya ditampilkan.');
    await tester.tap(find.text('Batal'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('link-confirm')), findsNothing);
  });

  testWidgets('tabel sangat besar diringkas; baris sangat panjang tampil polos tanpa macet', (tester) async {
    final big = StringBuffer('| ${[for (var c = 0; c < 20; c++) 'K$c'].join(' | ')} |\n|${List.filled(20, '---').join('|')}|\n');
    for (var r = 0; r < 300; r++) {
      big.writeln('| ${[for (var c = 0; c < 20; c++) 'r$r c$c'].join(' | ')} |');
    }
    final watch = Stopwatch()..start();
    await pump(tester, big.toString());
    expect(tester.takeException(), isNull);
    expect(find.textContaining('240 baris lagi'), findsOneWidget);
    expect(find.textContaining('8 kolom lagi'), findsOneWidget);
    expect(find.text('K12'), findsNothing);
    expect(markdownToPlainText(big.toString()), contains('r299 c19'), reason: 'Salin tetap menyalin seluruh tabel.');

    final long = List.filled(4000, 'a *b _c ').join();
    await pump(tester, long);
    expect(tester.takeException(), isNull);
    expect(markdownToPlainText(long).length, greaterThan(mdInlineLimit));
    expect(watch.elapsed, lessThan(const Duration(seconds: 20)));
  });
}
