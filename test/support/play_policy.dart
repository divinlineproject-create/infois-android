import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Kata yang tidak boleh tampil di aplikasi Play Store: harga, nama/ajakan
/// paket, langganan, upgrade, isi ulang koin (kebijakan Pembayaran Google
/// Play). "Rp" + angka di layar kasir/laporan wajar, jadi cek harga hanya
/// dipakai di layar yang memang tidak berisi transaksi.
final RegExp forbiddenPurchaseText = RegExp(
  r'paket|langganan|upgrade|top.?up|isi ulang koin|dompet koin|beli koin|starter|growth|firma akuntan',
  caseSensitive: false,
);

final RegExp rupiahAmount = RegExp(r'Rp\s?\d');

/// Semua teks yang tampil di layar (Text, RichText, EditableText); tab lain
/// yang tersembunyi (IndexedStack / Offstage) tidak ikut.
List<String> visibleTexts(WidgetTester tester) => [
      for (final element in find.byType(RichText).evaluate()) (element.widget as RichText).text.toPlainText(),
      for (final element in find.byType(EditableText).evaluate()) (element.widget as EditableText).controller.text,
    ];

/// Teks di layar yang menyebut paket/pembelian (dan harga bila [prices]).
List<String> purchaseTextOnScreen(WidgetTester tester, {bool prices = true}) => [
      for (final text in visibleTexts(tester))
        if (forbiddenPurchaseText.hasMatch(text) || (prices && rupiahAmount.hasMatch(text))) text,
    ];
