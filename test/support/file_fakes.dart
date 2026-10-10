import 'dart:io';

import 'package:infois/services/file_downloads.dart';

/// Kemampuan HP palsu untuk unduhan, tautan, dan bagikan: mencatat semua
/// panggilan; folder kerja di direktori sementara.
class FakeFilePlatform implements FilePlatform {
  FakeFilePlatform({this.downloadsResult = 'auto', this.urlResult = true, this.openResult = true});

  /// Nama akhir di folder Download (`auto` = nama yang diminta; null = gagal).
  final String? downloadsResult;
  final bool urlResult;
  final bool openResult;

  final List<Uri> urls = [];
  final List<(String path, String mime)> opened = [];
  final List<(String path, String mime)> sharedFiles = [];
  final List<String> sharedTexts = [];
  final List<(String path, String name, String mime)> downloads = [];
  Directory? _directory;

  @override
  Future<Directory> workDirectory() async => _directory ??= await Directory.systemTemp.createTemp('infois_unduhan');

  @override
  Future<String?> copyToDownloads(File file, String name, String mime) async {
    downloads.add((file.path, name, mime));
    return downloadsResult == 'auto' ? name : downloadsResult;
  }

  @override
  Future<bool> openFile(String path, String mime) async {
    opened.add((path, mime));
    return openResult;
  }

  @override
  Future<bool> openUrl(Uri uri) async {
    urls.add(uri);
    return urlResult;
  }

  @override
  Future<bool> shareFile(String path, String mime, {String? text}) async {
    sharedFiles.add((path, mime));
    return true;
  }

  @override
  Future<bool> shareText(String text) async {
    sharedTexts.add(text);
    return true;
  }
}
