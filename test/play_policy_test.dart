import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:infois/core/store_policy.dart';
import 'package:infois/services/file_downloads.dart';
import 'package:infois/services/permission_gate.dart';
import 'package:infois/ui/theme.dart';
import 'package:infois/ui/widgets/ai_markdown.dart';

import 'support/file_fakes.dart';
import 'support/play_policy.dart';

/// Kebijakan Pembayaran Google Play: aplikasi tidak menjual / mengarahkan ke
/// pembelian paket & koin di web. Juga izin dijelaskan sebelum diminta.
void main() {
  group('pesan server', () {
    test('kode galat paket/langganan/koin diganti kalimat netral', () {
      const serverText = 'Aplikasi HP Infois hanya untuk perusahaan dengan paket berbayar yang aktif. Aplikasi HP tersedia mulai paket Starter. Kelola paket lewat website: dashboard.infois.ai › Langganan.';
      expect(storeSafeServerMessage('akses_hp_tidak_tersedia', serverText), mobileAccessMessage);
      expect(storeSafeServerMessage('langganan_tidak_aktif', 'Langganan berhenti. Kelola paket lewat website.'), companyInactiveMessage);
      expect(storeSafeServerMessage('kanal_tidak_termasuk_paket', 'Tersedia di paket Growth.'), aiChannelLockedMessage);
      expect(storeSafeServerMessage('koin_habis', 'Isi ulang koin di menu Dompet Koin.'), aiQuotaExhaustedMessage);
      for (final message in [mobileAccessMessage, companyInactiveMessage, aiChannelLockedMessage, aiQuotaExhaustedMessage, aiTeamLockedLabel, neutralAccountMessage, aiAccountTopicMessage]) {
        expect(forbiddenPurchaseText.hasMatch(message), isFalse, reason: message);
        expect(rupiahAmount.hasMatch(message), isFalse, reason: message);
      }
    });

    test('pesan lain: kalimat ajakan membeli dibuang, sisanya tetap', () {
      expect(storeSafeServerMessage('validasi', 'Nama barang wajib diisi.'), 'Nama barang wajib diisi.');
      expect(storeSafeServerMessage(null, 'Fitur ini belum aktif. Upgrade paket di menu Langganan.'), 'Fitur ini belum aktif.');
      expect(storeSafeServerMessage(null, 'Silakan upgrade sekarang.'), neutralAccountMessage);
    });

    test('teks usaha pengguna tidak ikut terbuang (biaya langganan internet, paket oli)', () {
      const text = 'Biaya langganan internet Rp 350.000 sudah dicatat.\nServis besar termasuk paket oli dan filter.\nPelanggan langganan bayar mingguan.';
      expect(scrubPurchaseSentences(text), text);
    });

    test('jawaban Tim AI: kalimat beli paket/isi ulang koin dibuang; seluruhnya tentang beli → pesan netral', () {
      expect(storeSafeAiText('Penjualan hari ini Rp 1.250.000. Tim Analis tersedia di paket Growth, buka lewat menu Langganan.'), 'Penjualan hari ini Rp 1.250.000.');
      expect(storeSafeAiText('Sisa koin 3.\n- Isi ulang koin di menu Dompet Koin.\n- Laporan siap.'), 'Sisa koin 3.\n- Laporan siap.');
      expect(storeSafeAiText('Silakan upgrade ke paket Growth.'), aiAccountTopicMessage);
    });

    test('jawaban Tim AI: variasi ajakan beli/tambah koin, kuota, berlangganan ikut dibuang', () {
      const probes = [
        'Koin Anda hampir habis, silakan beli tambahan koin di web.',
        'Anda bisa membeli koin tambahan lewat Infois versi web.',
        'Tambah jumlah koin supaya Tim AI bisa lanjut bekerja.',
        'Top up saldo koin dulu ya.',
        'Jatah Tim AI habis, isi saldo di web untuk melanjutkan.',
        'Silakan isi saldo agar koin Tim AI bertambah.',
        'Minta pemilik usaha menambah kuota Tim AI.',
        'Kuota AI bulan ini bisa ditambah dari web.',
        'Fitur ini aktif bila perusahaan Anda berlangganan.',
        'Silakan berlangganan untuk membuka Tim Analis.',
        'Dengan berlangganan paket tahunan Anda hemat.',
      ];
      for (final probe in probes) {
        expect(purchasePattern.hasMatch(probe), isTrue, reason: probe);
        expect(storeSafeAiText('Penjualan hari ini Rp 1.250.000. $probe'), 'Penjualan hari ini Rp 1.250.000.', reason: probe);
      }
    });

    test('teks usaha yang mirip tetap utuh (kuota internet, isi saldo e-wallet, pelanggan berlangganan)', () {
      const texts = [
        'Tambahan kuota internet kantor Rp 100.000 sudah dicatat.',
        'Penjualan isi saldo e-wallet pelanggan Rp 50.000 dicatat.',
        'Pelanggan berlangganan galon mingguan, tagihan dibuat tiap Senin.',
        'Sisa koin 3.',
        'Koleksi koin kuno terjual 2 keping.',
      ];
      for (final text in texts) {
        expect(scrubPurchaseSentences(text), text, reason: text);
      }
    });

    test('alamat halaman pembelian dikenali', () {
      expect(isPurchaseUrl('https://dashboard.infois.ai/app/kopi-senja/langganan'), isTrue);
      expect(isPurchaseUrl('https://dashboard.infois.ai/app/kopi-senja/dompet-koin'), isTrue);
      expect(isPurchaseUrl('https://dashboard.infois.ai/billing/finish'), isTrue);
      expect(isPurchaseUrl('https://app.midtrans.com/snap/v2/vtweb/abc'), isTrue);
      expect(isPurchaseUrl('https://infois.ai/'), isTrue, reason: 'Situs pemasaran memuat harga paket.');
      expect(isPurchaseUrl('https://infois.ai/kebijakan-privasi'), isFalse);
      expect(isPurchaseUrl(privacyPolicyUrl), isFalse);
      expect(isPurchaseUrl(termsUrl), isFalse);
      expect(isPurchaseUrl('https://dashboard.infois.ai$deleteAccountPath'), isFalse);
      expect(isPurchaseUrl('https://dashboard.infois.ai/app/kopi-senja/laporan/penjualan'), isFalse);
      expect(isPurchaseUrl('https://wa.me/6281234'), isFalse);
    });

    test('alasan perusahaan ditolak tanpa nama paket', () {
      for (final reason in ['trial', 'tanpa_paket', 'paket_tanpa_hp', 'langganan_tidak_aktif', null]) {
        expect(forbiddenPurchaseText.hasMatch(deniedReasonLabel(reason)), isFalse, reason: '$reason');
      }
    });
  });

  testWidgets('jawaban Tim AI: kalimat ajakan membeli tidak tampil; tautan Langganan tidak dibuka', (tester) async {
    final files = FakeFilePlatform();
    await tester.pumpWidget(ProviderScope(
      overrides: [filePlatformProvider.overrideWithValue(files)],
      child: MaterialApp(
        theme: buildTheme(Brightness.light),
        home: const Scaffold(body: AiMarkdown('Laba bulan ini **Rp 4.200.000**. Isi ulang koin di [Dompet Koin](https://dashboard.infois.ai/app/kopi-senja/dompet-koin).\n\nBuka [langganan](https://dashboard.infois.ai/app/kopi-senja/langganan)')),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.textContaining('Laba bulan ini', findRichText: true), findsOneWidget);
    expect(find.textContaining('Dompet Koin', findRichText: true), findsNothing);
    // Kalimat kedua lolos pola (tanpa "menu"), tetapi tautannya tetap diblokir.
    final link = find.textContaining('langganan', findRichText: true);
    if (link.evaluate().isNotEmpty) {
      await tester.tap(link);
      await tester.pumpAndSettle();
    }
    expect(files.urls, isEmpty);
  });

  testWidgets('openExternalLink menolak halaman pembelian (tidak dibuka, tidak disalin)', (tester) async {
    final files = FakeFilePlatform();
    late WidgetRef widgetRef;
    late BuildContext widgetContext;
    await tester.pumpWidget(ProviderScope(
      overrides: [filePlatformProvider.overrideWithValue(files)],
      child: MaterialApp(home: Scaffold(body: Consumer(builder: (context, ref, _) {
        widgetRef = ref;
        widgetContext = context;
        return const SizedBox();
      }))),
    ));
    expect(await openExternalLink(widgetContext, widgetRef, 'https://dashboard.infois.ai/app/kopi-senja/langganan'), isFalse);
    await tester.pump();
    expect(files.urls, isEmpty);
    expect(find.textContaining('tidak tersedia di aplikasi'), findsOneWidget);

    expect(await openExternalLink(widgetContext, widgetRef, 'https://dashboard.infois.ai$deleteAccountPath'), isTrue);
    expect(files.urls.single.path, '/app/hapus-akun');
  });

  group('penjelasan izin', () {
    Future<(WidgetRef, BuildContext)> pumpHost(WidgetTester tester, _FakeGate gate) async {
      late WidgetRef widgetRef;
      late BuildContext widgetContext;
      await tester.pumpWidget(ProviderScope(
        overrides: [permissionGateProvider.overrideWithValue(gate)],
        child: MaterialApp(home: Scaffold(body: Consumer(builder: (context, ref, _) {
          widgetRef = ref;
          widgetContext = context;
          return const SizedBox();
        }))),
      ));
      return (widgetRef, widgetContext);
    }

    testWidgets('izin belum diberikan: dialog penjelasan dulu; Lanjutkan → diminta & dicatat', (tester) async {
      final gate = _FakeGate(needs: true);
      final (ref, context) = await pumpHost(tester, gate);
      final result = explainPermission(context, ref, AppPermission.bluetoothPrinter);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('permission-rationale-bluetoothPrinter')), findsOneWidget);
      expect(find.textContaining('tidak meminta lokasi'), findsOneWidget);
      await tester.tap(find.byKey(const Key('permission-rationale-continue')));
      await tester.pumpAndSettle();
      expect(await result, isTrue);
      expect(gate.explained, [AppPermission.bluetoothPrinter]);
    });

    testWidgets('Nanti: izin tidak diminta', (tester) async {
      final gate = _FakeGate(needs: true);
      final (ref, context) = await pumpHost(tester, gate);
      final result = explainPermission(context, ref, AppPermission.microphone);
      await tester.pumpAndSettle();
      expect(find.textContaining('voice note'), findsOneWidget);
      // Sama dengan Kebijakan Privasi & Data safety: rekaman juga diproses penyedia AI.
      expect(find.textContaining('penyedia AI kami'), findsOneWidget);
      await tester.tap(find.text('Nanti'));
      await tester.pumpAndSettle();
      expect(await result, isFalse);
      expect(gate.explained, isEmpty);
    });

    testWidgets('izin sudah ada / sudah dijelaskan: tanpa dialog', (tester) async {
      final gate = _FakeGate(needs: false);
      final (ref, context) = await pumpHost(tester, gate);
      expect(await explainPermission(context, ref, AppPermission.microphone), isTrue);
      await tester.pump();
      expect(find.byType(AlertDialog), findsNothing);
    });
  });
}

class _FakeGate implements PermissionGate {
  _FakeGate({required this.needs});

  final bool needs;
  final List<AppPermission> explained = [];

  @override
  Future<bool> needsRationale(AppPermission permission) async => needs && !explained.contains(permission);

  @override
  Future<void> markExplained(AppPermission permission) async => explained.add(permission);
}
