import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:infois/ui/widgets/user_avatar.dart';

/// Foto profil (foto akun Google) di Akun & layar PIN; tanpa foto / gagal
/// dimuat = inisial nama.
void main() {
  Future<void> pump(WidgetTester tester, Widget avatar) => tester.pumpWidget(MaterialApp(home: Scaffold(body: Center(child: avatar))));

  testWidgets('dengan foto: gambar foto dimuat dari alamatnya, inisial selama memuat / bila gagal', (tester) async {
    await pump(tester, const UserAvatar(name: 'Sri Wahyuni', url: 'https://lh3.googleusercontent.com/a/ABC=s96-c'));
    final image = tester.widget<Image>(find.byKey(const Key('user-avatar-photo')));
    expect((image.image as NetworkImage).url, 'https://lh3.googleusercontent.com/a/ABC=s96-c');
    expect(find.text('SW'), findsOneWidget, reason: 'Belum termuat: inisial.');
  });

  testWidgets('tanpa foto: inisial', (tester) async {
    await pump(tester, const UserAvatar(name: 'Sari'));
    expect(find.byKey(const Key('user-avatar-photo')), findsNothing);
    expect(find.text('S'), findsOneWidget);
    expect(UserAvatar.initialsOf('  Budi   Santoso Putra '), 'BP');
    expect(UserAvatar.initialsOf(''), '?');
    expect(UserAvatar.isPhotoUrl('/avatars/5'), isFalse, reason: 'Alamat web (butuh sesi browser) tidak dipakai.');
  });
}
