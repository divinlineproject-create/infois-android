import '../domain/qris.dart';
import 'api_client.dart';

/// QRIS dinamis kasir (online saja, lihat API.md › `/pos/qris`).
class QrisApi {
  QrisApi(this.api);

  final ApiClient api;

  /// Buat QR untuk [amount] (total nota, tanpa sen).
  Future<QrisPayment> create(String amount) async => _parse(await api.post('pos/qris', data: {'amount': amount}));

  /// Status terbaru (server mengecek DOKU paling sering tiap 3 detik).
  Future<QrisPayment> status(int id) async => _parse(await api.get('pos/qris/$id'));

  /// Batalkan QR yang belum dibayar.
  Future<QrisPayment> cancel(int id) async => _parse(await api.delete('pos/qris/$id'));

  static QrisPayment _parse(Map<String, dynamic> data) {
    final qris = data['qris'];
    if (qris is! Map) {
      throw const ApiException('Jawaban server QRIS tidak terbaca. Coba lagi.');
    }
    return QrisPayment.fromJson(Map<String, dynamic>.from(qris));
  }
}
