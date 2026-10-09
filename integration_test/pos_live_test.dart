// Uji ujung-ke-ujung di HP sungguhan terhadap server Infois yang hidup.
// Jalankan: flutter test integration_test/pos_live_test.dart -d <device> \
//   --dart-define=INFOIS_LIVE=http://127.0.0.1:8099 \
//   --dart-define=INFOIS_LIVE_EMAIL=... --dart-define=INFOIS_LIVE_PASSWORD=...
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:infois/main.dart' as app;
import 'package:integration_test/integration_test.dart';

const server = String.fromEnvironment('INFOIS_LIVE');
const email = String.fromEnvironment('INFOIS_LIVE_EMAIL');
const password = String.fromEnvironment('INFOIS_LIVE_PASSWORD');
const company = String.fromEnvironment('INFOIS_LIVE_COMPANY', defaultValue: 'Kopi Senja');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  Future<void> settle(WidgetTester tester, [int ms = 800]) async {
    await tester.pump(Duration(milliseconds: ms));
    await tester.pumpAndSettle(const Duration(milliseconds: 200), EnginePhase.sendSemanticsUpdate, const Duration(seconds: 20));
  }

  Future<bool> waitFor(WidgetTester tester, Finder finder, {int seconds = 30}) async {
    for (var i = 0; i < seconds * 2; i++) {
      await tester.pump(const Duration(milliseconds: 500));
      if (finder.evaluate().isNotEmpty) {
        return true;
      }
    }
    return false;
  }

  // Layar direkam dari luar (adb screencap); takeScreenshot butuh convertFlutterSurfaceToImage di Android.
  Future<void> shot(String name) async {}

  testWidgets('kasir: login → perusahaan → sinkron → jual tunai → riwayat → tutup kasir', (tester) async {
    app.main();
    await settle(tester, 2500);

    // --- Mulai dari keadaan belum login: keluar bila sesi lama masih ada ---
    await shot('00-start');
    if (find.byKey(const Key('login-email')).evaluate().isEmpty) {
      final gotLogin = await waitFor(tester, find.byKey(const Key('login-email')), seconds: 15);
      if (!gotLogin) {
        if (find.text('Keluar').evaluate().isNotEmpty) {
          await tester.tap(find.text('Keluar').first);
          await settle(tester);
          if (find.text('Keluar').evaluate().length > 1) {
            await tester.tap(find.text('Keluar').last);
            await settle(tester, 1500);
          }
        } else if (find.text('Akun').evaluate().isNotEmpty) {
          await tester.tap(find.text('Akun'));
          await settle(tester);
          await tester.tap(find.text('Keluar').last);
          await settle(tester);
          if (find.text('Keluar').evaluate().isNotEmpty) {
            await tester.tap(find.text('Keluar').last);
            await settle(tester, 1500);
          }
        }
        await shot('00b-after-logout');
        expect(await waitFor(tester, find.byKey(const Key('login-email')), seconds: 20), isTrue, reason: 'layar masuk tidak muncul');
      }
    }
    // Alamat server
    await tester.tap(find.textContaining('Server:'));
    await settle(tester);
    await tester.enterText(find.byType(TextField).last, server);
    await tester.tap(find.text('Simpan'));
    await settle(tester);
    expect(find.textContaining(server), findsOneWidget, reason: 'alamat server tidak tersimpan');

    await tester.enterText(find.byKey(const Key('login-email')), email);
    await tester.enterText(find.byKey(const Key('login-password')), password);
    await tester.tap(find.byKey(const Key('login-submit')));
    await shot('01-login');
    final loggedIn = await waitFor(tester, find.text('Pilih perusahaan').evaluate().isEmpty ? find.byType(NavigationBar) : find.text('Pilih perusahaan'), seconds: 40);
    await shot('02-after-login');
    expect(loggedIn, isTrue, reason: 'login tidak membawa ke pilih perusahaan / beranda');

    // --- Pilih perusahaan (bila lebih dari satu) ---
    if (find.text('Pilih perusahaan').evaluate().isNotEmpty) {
      final tile = find.textContaining(company);
      expect(tile, findsWidgets, reason: 'perusahaan "$company" tidak ada di daftar');
      await tester.tap(tile.first);
      await settle(tester, 1500);
    }
    expect(await waitFor(tester, find.byType(NavigationBar), seconds: 40), isTrue, reason: 'beranda tidak muncul setelah pilih perusahaan');
    await shot('03-home');

    // --- Tunggu sinkron awal: barang muncul di kasir ---
    final products = find.byWidgetPredicate((w) => w.key is ValueKey<String> && (w.key as ValueKey<String>).value.startsWith('product-'));
    expect(await waitFor(tester, products, seconds: 60), isTrue, reason: 'barang tidak muncul setelah sinkron');
    await shot('04-kasir');

    // --- Buka kasir (shift) bila diminta ---
    if (find.byKey(const Key('open-shift')).evaluate().isNotEmpty) {
      await tester.tap(find.byKey(const Key('open-shift')));
      await settle(tester);
      await tester.enterText(find.byKey(const Key('opening-cash')), '100000');
      await tester.tap(find.byKey(const Key('opening-save')));
      await settle(tester, 1500);
      await shot('05-shift-open');
      expect(find.textContaining('Kasir dibuka'), findsOneWidget, reason: 'shift tidak terbuka');
    }

    // --- Tambah 2 barang ke keranjang ---
    await tester.tap(products.first);
    await settle(tester);
    await tester.tap(products.first);
    await settle(tester);
    await tester.tap(find.byKey(const Key('open-cart')));
    await settle(tester);
    await shot('06-cart');
    expect(find.byKey(const Key('go-pay')), findsOneWidget);
    await tester.tap(find.byKey(const Key('go-pay')));
    await settle(tester);

    // --- Bayar tunai dengan nominal cepat ---
    expect(find.byKey(const Key('pay-total')), findsOneWidget, reason: 'layar bayar tidak terbuka');
    await tester.tap(find.byKey(const Key('quick-0')));
    await settle(tester);
    await shot('07-pay');
    await tester.tap(find.byKey(const Key('pay-submit')));
    await settle(tester, 2000);
    await shot('08-done');
    expect(find.byKey(const Key('pay-error')), findsNothing, reason: 'pembayaran menampilkan galat');
    expect(find.byKey(const Key('done-number')), findsOneWidget, reason: 'layar "Penjualan tersimpan" tidak muncul');
    final number = (tester.widget(find.byKey(const Key('done-number'))) as Text).data ?? '';
    expect(number, isNot(contains('menyusul')), reason: 'nomor nota tidak dari jatah perangkat: $number');
    await tester.tap(find.byKey(const Key('new-sale')));
    await settle(tester);

    // --- Riwayat nota ---
    await tester.tap(find.text('Akun'));
    await settle(tester);
    await tester.tap(find.text('Riwayat nota'));
    await settle(tester, 1500);
    await shot('09-history');
    expect(find.textContaining(number), findsWidgets, reason: 'nota $number tidak ada di riwayat');
    await tester.pageBack();
    await settle(tester);

    // --- Status sinkron: outbox terkirim ---
    await tester.tap(find.text('Status sinkron'));
    await settle(tester, 4000);
    await shot('10-sync');
    await tester.pageBack();
    await settle(tester);

    // --- Tutup kasir ---
    await tester.tap(find.text('Kasir'));
    await settle(tester);
    if (find.text('Tutup kasir').evaluate().isNotEmpty) {
      await tester.tap(find.text('Tutup kasir'));
      await settle(tester, 1500);
      await shot('11-close-shift');
    }
  });
}
