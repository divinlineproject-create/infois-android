import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:infois/data/api_client.dart';
import 'package:infois/domain/report_models.dart';
import 'package:infois/state/sync_controller.dart';
import 'package:infois/ui/theme.dart';
import 'package:infois/ui/widgets/report_widgets.dart';

/// Potongan kecil Laporan/Catatan: angka singkat, batas rentang, label
/// grafik, ringkasan untuk pembaca layar, dan pesan galat tanpa istilah teknis.
void main() {
  test('compactRupiah memilih satuan setelah pembulatan', () {
    expect(compactRupiah('999.00'), '999');
    expect(compactRupiah('999.60'), '1 rb');
    expect(compactRupiah('850000'), '850 rb');
    expect(compactRupiah('999950'), '1 jt', reason: 'bukan "1000 rb"');
    expect(compactRupiah('20300000'), '20,3 jt');
    expect(compactRupiah('999999999'), '1 M', reason: 'bukan "1000 jt"');
    expect(compactRupiah('1200000000'), '1,2 M');
    expect(compactRupiah('-999950'), '-1 jt');
  });

  test('rentang tanggal dihitung termasuk kedua ujung, seperti server', () {
    expect(inclusiveDays(DateTime(2026, 10, 10), DateTime(2026, 10, 10)), 1);
    expect(inclusiveDays(DateTime(2025, 10, 10), DateTime(2026, 10, 10)), 366, reason: 'diterima server');
    expect(inclusiveDays(DateTime(2025, 10, 9), DateTime(2026, 10, 10)), 367, reason: 'ditolak server (422)');
    expect(inclusiveDays(DateTime(2025, 10, 9), DateTime(2026, 10, 10)) > maxRangeDays, isTrue);
  });

  test('ringkasan grafik untuk pembaca layar menyebut puncak dan total', () {
    expect(chartSummary('Omzet per hari', ['1/10', '2/10', '3/10'], [1000000, 9900000, 0]), 'Omzet per hari. Tertinggi 2/10 9,9 jt. Total 10,9 jt.');
    expect(chartSummary('Omzet per jam', ['00:00'], [0]), 'Omzet per jam. Belum ada penjualan.');
  });

  test('galat tak terduga tidak menampilkan teks teknis', () {
    final typeError = (() {
      try {
        // ignore: unnecessary_cast
        ({} as Object) as List;
      } catch (error) {
        return error;
      }
      return null;
    })()!;
    expect(friendlyError(typeError), 'Data dari server belum bisa dibaca. Coba lagi atau perbarui aplikasi.');
    expect(friendlyError(ApiException('Anda tidak punya akses laporan.', code: 'tidak_berhak', status: 403)), 'Anda tidak punya akses laporan.');
  });

  test('bentuk JSON yang tidak terduga dibaca sebagai daftar kosong', () {
    final overview = ReportOverview.fromJson({'sparkline': <String, dynamic>{}, 'today': 'x'});
    expect(overview.sparkline, isEmpty);
  });

  testWidgets('ReportProblem: galat lain tampil sebagai kalimat biasa', (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [connectivityStreamProvider.overrideWithValue(const Stream.empty())],
      child: MaterialApp(home: Scaffold(body: ReportProblem(error: StateError("type '_Map<String, dynamic>' is not a subtype of type 'List<dynamic>?'"), onRetry: () {}))),
    ));
    await tester.pump();
    expect(find.textContaining('_Map'), findsNothing);
    expect(find.textContaining('subtype'), findsNothing);
    expect(find.text('Data dari server belum bisa dibaca. Coba lagi atau perbarui aplikasi.'), findsOneWidget);
  });

  testWidgets('grafik batang: label sumbu-x pertama, tengah, terakhir tersebar di lebar grafik', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 328,
            child: BarSeriesChart(labels: [for (var i = 1; i <= 14; i++) '$i/10'], values: [for (var i = 1; i <= 14; i++) i * 1000000.0], semanticLabel: 'Omzet 14 hari'),
          ),
        ),
      ),
    ));
    final box = tester.renderObject<RenderCustomPaint>(find.descendant(of: find.byType(BarSeriesChart), matching: find.byType(CustomPaint)).first);
    final canvas = TestRecordingCanvas();
    box.paint(TestRecordingPaintingContext(canvas), Offset.zero);
    final offsets = [
      for (final call in canvas.invocations)
        if (call.invocation.memberName == #drawParagraph) call.invocation.positionalArguments[1] as Offset,
    ];
    expect(offsets, hasLength(4), reason: 'nilai maksimum + 3 label sumbu-x');
    // Posisi paragraf (kotak selebar 60 px, teks di tengahnya). Dulu ketiganya
    // menumpuk di kiri (sekitar -18, 20, 15).
    final labels = offsets.skip(1).map((offset) => offset.dx).toList();
    expect(labels[0], lessThan(30));
    expect(labels[1], inInclusiveRange(100, 200), reason: 'label tengah di tengah grafik');
    expect(labels[2], greaterThan(230), reason: 'label terakhir di kanan grafik');
    expect(labels[2], lessThanOrEqualTo(328));

    final semantics = tester.getSemantics(find.byType(BarSeriesChart));
    expect(semantics.label, contains('Tertinggi 14/10 14 jt'));
    expect(semantics.label, contains('Total 105 jt'));
  });

  testWidgets('warna "masuk" tetap kontras di mode gelap', (tester) async {
    late Color light;
    late Color dark;
    await tester.pumpWidget(Theme(data: buildTheme(Brightness.light), child: Builder(builder: (context) {
      light = successText(context);
      return const SizedBox();
    })));
    await tester.pumpWidget(Theme(data: buildTheme(Brightness.dark), child: Builder(builder: (context) {
      dark = successText(context);
      return const SizedBox();
    })));
    expect(light, Brand.green);
    expect(dark, isNot(Brand.green));
    expect(dark.computeLuminance(), greaterThan(Brand.green.computeLuminance()));
  });
}
