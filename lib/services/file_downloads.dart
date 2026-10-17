import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/store_policy.dart';
import '../data/api_client.dart';
import '../state/workspace.dart';

/// Jenis file dari nama (untuk membuka / membagikan dengan aplikasi yang pas).
String mimeTypeForName(String name) => switch (p.extension(name).toLowerCase()) {
      '.pdf' => 'application/pdf',
      '.xlsx' => 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
      '.xls' => 'application/vnd.ms-excel',
      '.csv' => 'text/csv',
      '.txt' => 'text/plain',
      '.jpg' || '.jpeg' => 'image/jpeg',
      '.png' => 'image/png',
      '.webp' => 'image/webp',
      '.m4a' => 'audio/mp4',
      '.aac' => 'audio/aac',
      '.mp3' => 'audio/mpeg',
      '.ogg' => 'audio/ogg',
      '.wav' => 'audio/wav',
      '.webm' => 'audio/webm',
      '.docx' => 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
      _ => 'application/octet-stream',
    };

/// Nama file yang aman untuk folder Download (huruf besar/kecil dan spasi
/// dipertahankan, tanda yang dilarang sistem berkas dibuang).
String cleanFileName(String name, {String fallback = 'berkas'}) {
  final cleaned = name.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]+'), '-').replaceAll(RegExp(r'\s+'), ' ').trim().replaceAll(RegExp(r'^[.\-]+'), '');
  return cleaned.isEmpty ? fallback : cleaned;
}

/// Tautan WhatsApp `wa.me` dengan pesan siap kirim. Nomor Indonesia
/// `0812…` / `+62 812…` diubah ke `62812…`; tanpa nomor, WhatsApp meminta
/// pengguna memilih kontak.
Uri whatsappUri(String text, {String? phone}) {
  var digits = (phone ?? '').replaceAll(RegExp(r'\D'), '');
  if (digits.startsWith('0')) {
    digits = '62${digits.substring(1)}';
  } else if (digits.startsWith('8') && digits.length >= 9) {
    digits = '62$digits';
  }
  return Uri.https('wa.me', digits.length >= 8 ? '/$digits' : '/', {'text': text});
}

/// File yang sudah disimpan di HP.
class SavedFile {
  const SavedFile({required this.path, required this.name, required this.mime, this.downloadsName});

  /// Salinan di folder aplikasi: dibuka / dibagikan dari sini.
  final String path;
  final String name;
  final String mime;

  /// Nama file di folder Download HP (bisa berbeda bila nama sudah dipakai,
  /// mis. "nota (1).pdf"); null bila tidak berhasil masuk ke Download.
  final String? downloadsName;

  bool get inDownloads => downloadsName != null;
}

/// Kemampuan HP yang dipakai unduhan & tautan (diganti di tes).
abstract class FilePlatform {
  /// Folder aplikasi untuk salinan yang dibuka / dibagikan.
  Future<Directory> workDirectory();

  /// Salin [file] ke folder Download HP; kembalikan nama akhirnya, atau null
  /// bila tidak bisa (izin ditolak / bukan Android).
  Future<String?> copyToDownloads(File file, String name, String mime);

  /// Buka file dengan aplikasi lain (PDF viewer, Excel, Galeri). False bila
  /// tidak ada aplikasi yang bisa membukanya.
  Future<bool> openFile(String path, String mime);

  Future<bool> shareFile(String path, String mime, {String? text});

  Future<bool> shareText(String text);

  /// Buka tautan di browser / aplikasi lain (WhatsApp).
  Future<bool> openUrl(Uri uri);
}

/// Implementasi di HP: MediaStore (Android 10+, tanpa izin) atau folder
/// Download publik (Android 9 ke bawah, izin penyimpanan), open_filex,
/// share_plus, url_launcher.
class DeviceFilePlatform implements FilePlatform {
  const DeviceFilePlatform();

  static const _channel = MethodChannel('id.infois/downloads');

  @override
  Future<Directory> workDirectory() async {
    final directory = Directory(p.join((await getTemporaryDirectory()).path, 'unduhan'));
    await directory.create(recursive: true);
    return directory;
  }

  @override
  Future<String?> copyToDownloads(File file, String name, String mime) async {
    if (!Platform.isAndroid) {
      return null;
    }
    Future<String?> save() => _channel.invokeMethod<String>('saveToDownloads', {'path': file.path, 'name': name, 'mime': mime});
    try {
      return await save();
    } on PlatformException catch (error) {
      if (error.code != 'permission') {
        return null;
      }
      // Android 9 ke bawah: folder Download publik butuh izin penyimpanan.
      final status = await Permission.storage.request();
      if (!status.isGranted) {
        return null;
      }
      try {
        return await save();
      } on PlatformException {
        return null;
      }
    } on MissingPluginException {
      return null;
    }
  }

  @override
  Future<bool> openFile(String path, String mime) async {
    try {
      final result = await OpenFilex.open(path, type: mime);
      return result.type == ResultType.done;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> shareFile(String path, String mime, {String? text}) async {
    try {
      await Share.shareXFiles([XFile(path, mimeType: mime, name: p.basename(path))], text: text);
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> shareText(String text) async {
    try {
      await Share.share(text);
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> openUrl(Uri uri) async {
    try {
      return await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      return false;
    }
  }
}

final filePlatformProvider = Provider<FilePlatform>((ref) => const DeviceFilePlatform());

final fileDownloadsProvider = Provider<FileDownloads>((ref) => FileDownloads(ref.watch(filePlatformProvider)));

/// Simpan file unduhan (dengan token) ke HP: salinan di folder aplikasi untuk
/// dibuka / dibagikan, dan salinan di folder Download supaya mudah dicari.
class FileDownloads {
  FileDownloads(this.platform);

  final FilePlatform platform;

  /// Unduh [apiPath] (relatif ke `/api/v1/`, token + X-Tenant ikut) lalu
  /// simpan sebagai [name]. [onProgress] 0..1, atau null bila ukuran belum diketahui.
  Future<SavedFile> download(ApiClient api, String apiPath, String name, {void Function(double? progress)? onProgress}) async {
    final bytes = await api.bytes(apiPath, onProgress: onProgress == null ? null : (received, total) => onProgress(total > 0 ? received / total : null));
    return save(name, bytes);
  }

  Future<SavedFile> save(String name, List<int> bytes) async {
    final fileName = cleanFileName(name);
    final mime = mimeTypeForName(fileName);
    final directory = await platform.workDirectory();
    final file = File(p.join(directory.path, fileName));
    await file.writeAsBytes(bytes, flush: true);
    String? downloadsName;
    try {
      downloadsName = await platform.copyToDownloads(file, fileName, mime);
    } catch (_) {
      downloadsName = null;
    }
    return SavedFile(path: file.path, name: fileName, mime: mime, downloadsName: downloadsName);
  }

  Future<bool> open(SavedFile file) => platform.openFile(file.path, file.mime);

  Future<bool> share(SavedFile file) => platform.shareFile(file.path, file.mime);
}

Future<ApiClient?> _activeApi(WidgetRef ref) async {
  try {
    final workspace = await ref.read(workspaceProvider.future);
    return workspace == null || workspace.disposed ? null : workspace.api;
  } catch (_) {
    return null;
  }
}

/// Unduh file (PDF nota, lampiran, file dari Tim AI) dengan progres, lalu
/// tampilkan "Tersimpan di Download" dengan tombol Buka dan Bagikan.
Future<SavedFile?> downloadAndOffer(BuildContext context, WidgetRef ref, {required String apiPath, required String fileName}) async {
  final messenger = ScaffoldMessenger.of(context);
  final colors = Theme.of(context).colorScheme;
  final downloads = ref.read(fileDownloadsProvider);
  final api = await _activeApi(ref);
  if (api == null) {
    messenger.showSnackBar(const SnackBar(content: Text('Belum ada perusahaan aktif.')));
    return null;
  }
  final progress = ValueNotifier<double?>(null);
  messenger.hideCurrentSnackBar();
  messenger.showSnackBar(SnackBar(
    key: const Key('download-progress'),
    duration: const Duration(minutes: 5),
    content: ValueListenableBuilder<double?>(
      valueListenable: progress,
      builder: (context, value, _) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(value == null ? 'Mengunduh $fileName…' : 'Mengunduh $fileName… ${(value * 100).round()}%', maxLines: 1, overflow: TextOverflow.ellipsis),
        const SizedBox(height: 8),
        LinearProgressIndicator(value: value, minHeight: 4, semanticsLabel: 'Progres unduhan'),
      ]),
    ),
  ));
  try {
    final saved = await downloads.download(api, apiPath, fileName, onProgress: (value) => progress.value = value);
    messenger.hideCurrentSnackBar();
    showSavedFile(messenger, downloads, saved, actionColor: colors.inversePrimary);
    return saved;
  } on ApiException catch (error) {
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(SnackBar(content: Text(error.message)));
  } catch (_) {
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(const SnackBar(content: Text('File belum bisa disimpan di HP. Coba lagi.')));
  } finally {
    progress.dispose();
  }
  return null;
}

/// Pemberitahuan file tersimpan + tombol Buka / Bagikan.
void showSavedFile(ScaffoldMessengerState messenger, FileDownloads downloads, SavedFile saved, {Color? actionColor}) {
  Future<void> open() async {
    if (!await downloads.open(saved)) {
      messenger.showSnackBar(const SnackBar(content: Text('Tidak ada aplikasi di HP yang bisa membuka file ini. Coba Bagikan.')));
    }
  }

  Future<void> share() async {
    messenger.hideCurrentSnackBar();
    if (!await downloads.share(saved)) {
      messenger.showSnackBar(const SnackBar(content: Text('File belum bisa dibagikan dari HP ini.')));
    }
  }

  final style = TextButton.styleFrom(foregroundColor: actionColor, visualDensity: VisualDensity.compact, padding: const EdgeInsets.symmetric(horizontal: 10));
  messenger.showSnackBar(SnackBar(
    key: const Key('download-saved'),
    duration: const Duration(seconds: 8),
    content: Row(children: [
      Expanded(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(saved.inDownloads ? 'Tersimpan di Download' : 'Tersimpan di HP', style: const TextStyle(fontWeight: FontWeight.w600)),
          Text(saved.downloadsName ?? saved.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12)),
        ]),
      ),
      TextButton(key: const Key('download-open'), style: style, onPressed: open, child: const Text('Buka')),
      TextButton(key: const Key('download-share'), style: style, onPressed: share, child: const Text('Bagikan')),
    ]),
  ));
}

/// Buka tautan di browser (mis. Infois di web). Bila tidak ada browser,
/// tautannya disalin supaya tetap bisa dibuka manual.
Future<bool> openExternalLink(BuildContext context, WidgetRef ref, String url) async {
  final messenger = ScaffoldMessenger.of(context);
  // Kebijakan Google Play: halaman pembelian paket/koin tidak dibuka (dan
  // tautannya tidak disalin) dari aplikasi.
  if (isPurchaseUrl(url)) {
    messenger.showSnackBar(const SnackBar(content: Text('Halaman ini tidak tersedia di aplikasi. Hubungi pemilik usaha atau admin Infois Anda.')));
    return false;
  }
  // Panel dashboard (menu sampingnya memuat Langganan & Dompet Koin).
  if (isWebPanelUrl(url)) {
    messenger.showSnackBar(const SnackBar(content: Text(blockedLinkMessage)));
    return false;
  }
  final uri = Uri.tryParse(url);
  if (uri != null && await ref.read(filePlatformProvider).openUrl(uri)) {
    return true;
  }
  await Clipboard.setData(ClipboardData(text: url));
  messenger.showSnackBar(SnackBar(content: Text('Browser tidak bisa dibuka. Tautan disalin: $url')));
  return false;
}

/// Kirim pesan lewat WhatsApp (wa.me). Bila WhatsApp / browser tidak ada,
/// pesannya disalin dengan petunjuk [copiedMessage].
Future<bool> sendWhatsApp(BuildContext context, WidgetRef ref, String text, {String? phone, String copiedMessage = 'Pesan disalin. Buka WhatsApp, pilih kontak, lalu tempel.'}) async {
  final messenger = ScaffoldMessenger.of(context);
  if (await ref.read(filePlatformProvider).openUrl(whatsappUri(text, phone: phone))) {
    return true;
  }
  await Clipboard.setData(ClipboardData(text: text));
  messenger.showSnackBar(SnackBar(content: Text(copiedMessage)));
  return false;
}

/// Bagikan teks (ringkasan laporan) lewat menu Bagikan HP; bila tidak bisa,
/// teksnya disalin.
Future<bool> shareTextOrCopy(BuildContext context, WidgetRef ref, String text, {String copiedMessage = 'Teks disalin. Tempel di WhatsApp atau catatan Anda.'}) async {
  final messenger = ScaffoldMessenger.of(context);
  if (await ref.read(filePlatformProvider).shareText(text)) {
    return true;
  }
  await Clipboard.setData(ClipboardData(text: text));
  messenger.showSnackBar(SnackBar(content: Text(copiedMessage)));
  return false;
}
