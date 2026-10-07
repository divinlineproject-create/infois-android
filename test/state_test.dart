import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:infois/data/app_storage.dart';
import 'package:infois/data/local_db.dart';
import 'package:infois/domain/models.dart';
import 'package:infois/state/session.dart';
import 'package:infois/state/workspace.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('menu baru dari sinkron tidak membuka ulang database; ganti perusahaan membuka database lain', () async {
    SharedPreferences.setMockInitialValues({
      'session': jsonEncode({
        'user': {'id': 1, 'name': 'Sari', 'email': 'sari@tes.id'},
        'tenants': [
          const TenantSummary(id: 1, name: 'Warung A', menus: Menus(pos: true)).toJson(),
          const TenantSummary(id: 2, name: 'Warung B', menus: Menus(pos: true)).toJson(),
        ],
      }),
      'tenant_id': 1,
    });
    FlutterSecureStorage.setMockInitialValues({'auth_token': 'token-tes'});
    final storage = await AppStorage.load();
    final opened = <String>[];
    final container = ProviderContainer(overrides: [
      storageProvider.overrideWithValue(storage),
      localDbOpenerProvider.overrideWithValue((name) async {
        opened.add(name);
        return memoryDb();
      }),
      apiFactoryProvider.overrideWithValue((_, __, ___, ____) => fakeApi(offlineServer())),
    ]);
    addTearDown(container.dispose);
    final keepAlive = container.listen(workspaceProvider, (_, __) {});
    addTearDown(keepAlive.close);

    await container.read(sessionProvider.future);
    final first = await container.read(workspaceProvider.future);
    expect(first!.tenant.name, 'Warung A');

    await container.read(sessionProvider.notifier).updateMenus(1, const Menus(pos: true, reports: true));
    expect(await container.read(workspaceProvider.future), same(first));
    expect(container.read(sessionProvider).value!.tenant!.menus.reports, isTrue);

    await container.read(sessionProvider.notifier).selectTenant(2);
    final second = await container.read(workspaceProvider.future);
    expect(second!.tenant.name, 'Warung B');
    expect(opened, [LocalDb.fileName(1, 1), LocalDb.fileName(1, 2)]);
  });
}
