import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../services/product_photos.dart';
import 'workspace.dart';

/// Folder induk foto barang di HP, atau null bila tidak tersedia (tes tanpa
/// plugin). Diganti di tes dengan folder sementara.
final photoRootProvider = Provider<Future<Directory?> Function()>((ref) {
  return () async {
    try {
      return await ProductPhotoStore.rootDirectory();
    } catch (_) {
      return null;
    }
  };
});

/// Cache foto barang perusahaan aktif (unduh lewat API dengan token +
/// X-Tenant), atau null: foto tidak dipakai, kartu barang memakai inisial.
final productPhotoStoreProvider = FutureProvider<ProductPhotoStore?>((ref) async {
  final workspace = await ref.watch(workspaceProvider.future);
  if (workspace == null) {
    return null;
  }
  final root = await ref.read(photoRootProvider)();
  if (root == null) {
    return null;
  }
  return ProductPhotoStore(
    directory: Directory(p.join(root.path, ProductPhotoStore.folderName(workspace.user.id, workspace.tenant.id))),
    download: (url) => workspace.api.bytes(url),
  );
});
