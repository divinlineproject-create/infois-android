import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:infois/domain/models.dart';
import 'package:infois/ui/widgets/common.dart';

/// Fitur kasir yang dikunci paket langganan (`tenant.locked_features` dari
/// sync/pull): tetap tampil bergembok; diketuk menjelaskan paketnya.
void main() {
  test('pengaturan usaha membaca fitur terkunci; server lama tanpa kunci = tidak ada yang terkunci', () {
    final tenant = TenantSettings.fromJson({
      'id': 1,
      'name': 'Warung',
      'pos_dining': false,
      'locked_features': {
        'pos_dining': {'label': 'Fitur rumah makan', 'message': 'Fitur rumah makan tidak tersedia pada paket ini. Tersedia di paket Pro.'},
        'pos_qris': {'label': 'QRIS di kasir', 'message': 'QRIS di kasir tidak tersedia pada paket ini.'},
      },
    });
    expect(tenant.locked('pos_dining')?.label, 'Fitur rumah makan');
    expect(tenant.locked('pos_ai_input'), isNull);
    expect(TenantSettings.fromJson(tenant.toJson()).locked('pos_qris')?.message, 'QRIS di kasir tidak tersedia pada paket ini.');
    expect(TenantSettings.fromJson({'id': 1, 'name': 'Warung', 'locked_features': []}).lockedFeatures, isEmpty, reason: 'PHP mengirim [] bila kosong.');
    expect(TenantSettings.fromJson({'id': 1, 'name': 'Warung'}).lockedFeatures, isEmpty);
  });

  testWidgets('fitur terkunci diketuk: "Fitur tidak tersedia pada paket ini" + paket yang membukanya', (tester) async {
    const feature = LockedFeature(label: 'Input AI di kasir', message: 'Input AI di kasir tidak tersedia pada paket ini. Tersedia di paket Pro.');
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: Builder(builder: (context) => TextButton(onPressed: () => showLockedFeature(context, feature), child: const Text('buka')))),
    ));
    await tester.tap(find.text('buka'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('locked-feature-dialog')), findsOneWidget);
    expect(find.text('Input AI di kasir'), findsOneWidget);
    expect(find.textContaining('Fitur tidak tersedia pada paket ini.'), findsOneWidget);
    expect(find.textContaining('Tersedia di paket Pro.'), findsOneWidget);
    expect(find.byIcon(Icons.lock_outline), findsOneWidget);
  });
}
