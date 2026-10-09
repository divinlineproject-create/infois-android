import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:infois/domain/ai_models.dart';
import 'package:infois/domain/models.dart';
import 'package:infois/ui/screens/ai_proposal_edit_sheet.dart';
import 'package:intl/date_symbol_data_local.dart';

void main() {
  setUpAll(() => initializeDateFormatting('id_ID'));

  final proposal = AiProposal.fromJson({
    'id': 3,
    'type': 'sale',
    'title': 'Penjualan ke Pak Budi · Rp 30.000',
    'status': 'pending',
    'status_label': 'Menunggu persetujuan',
    'editable': true,
    'editable_fields': ['contact', 'date', 'items', 'paid', 'payment_method', 'cash_account_id'],
    'payload': {
      'customer_name': 'Pak Budi',
      'date': '2026-10-09',
      'paid': false,
      'items': [
        {'product_id': 1, 'description': 'Kopi susu', 'quantity': '2.000000', 'unit': 'gelas', 'unit_price': '15000.00', 'discount_percent': '0.00', 'tax_rate': '0.00'},
      ],
    },
    'preview': {'contact': 'Pak Budi'},
  });

  testWidgets('lembar ubah menolak kontak kosong, jumlah 0, harga minus, dan akun kas kosong saat dibayar', (tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    Map<String, dynamic>? result;
    var closed = false;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              result = await showProposalEditSheet(context, proposal, accounts: const [CashAccount(id: 11, code: '1-1100', name: 'Kas', kind: 'cash')]);
              closed = true;
            },
            child: const Text('buka'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('buka'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('edit-contact')), '');
    await tester.enterText(find.byKey(const Key('edit-qty-0')), '0');
    await tester.enterText(find.byKey(const Key('edit-price-0')), '-5');
    await tester.tap(find.text('Sudah dibayar'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('edit-save')));
    await tester.tap(find.byKey(const Key('edit-save')));
    await tester.pumpAndSettle();

    expect(closed, isFalse, reason: 'Isian salah tidak dikirim ke server.');
    expect(find.text('Isi nama'), findsOneWidget);
    expect(find.text('Harus lebih dari nol'), findsOneWidget);
    expect(find.text('Tidak boleh minus'), findsOneWidget);
    expect(find.text('Pilih akun kas/bank'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('edit-contact')), 'Pak Budi');
    await tester.enterText(find.byKey(const Key('edit-qty-0')), '3');
    await tester.enterText(find.byKey(const Key('edit-price-0')), '15000');
    await tester.ensureVisible(find.byKey(const Key('edit-account')));
    await tester.tap(find.byKey(const Key('edit-account')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Kas').last);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('edit-save')));
    await tester.tap(find.byKey(const Key('edit-save')));
    await tester.pumpAndSettle();

    expect(closed, isTrue);
    expect(result, isNotNull);
    expect(result!.containsKey('contact'), isFalse, reason: 'Kontak yang tidak berubah tidak dikirim.');
    expect(result!['paid'], '1');
    expect(result!['cash_account_id'], 11);
    expect((result!['items'] as List).single['quantity'], '3.000000');
    expect((result!['items'] as List).single['unit_price'], '15000.00');
  });
}
