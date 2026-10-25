// Aturan Google Play (kebijakan Pembayaran): aplikasi yang dipasang dari
// Play Store tidak boleh menjual atau mengarahkan pengguna membeli barang
// digital (paket langganan, koin Tim AI) di luar penagihan Google Play.
// Paket & koin Infois dibeli di web, jadi aplikasi HP:
// - tidak menampilkan nama paket, harga, atau tombol/tautan ke halaman
//   pembelian (Langganan, Dompet Koin, upgrade);
// - mengganti pesan server yang menyebut paket/pembelian dengan kalimat
//   netral ("Hubungi pemilik usaha atau admin Infois Anda");
// - menolak membuka tautan ke halaman pembelian (mis. dari jawaban Tim AI)
//   dan ke panel dashboard yang memuat menu pembelian.

import 'config.dart';

/// Login / perusahaan ditolak aplikasi HP (trial, paket tanpa HP, dll.).
const String mobileAccessMessage = 'Aplikasi HP belum aktif untuk perusahaan ini. Hubungi pemilik usaha atau admin Infois Anda.';

/// Perusahaan sedang tidak aktif (langganan berhenti).
const String companyInactiveMessage = 'Akun perusahaan ini sedang tidak aktif. Hubungi pemilik usaha atau admin Infois Anda.';

/// Tim AI terkunci untuk aplikasi HP.
const String aiChannelLockedTitle = 'Tim AI belum aktif di aplikasi HP';
const String aiChannelLockedMessage = 'Tim AI belum aktif di aplikasi HP untuk perusahaan ini. Hubungi pemilik usaha atau admin Infois Anda.';

/// Jatah Tim AI bulan ini habis.
const String aiQuotaExhaustedMessage = 'Jatah Tim AI bulan ini sudah habis. Hubungi pemilik usaha atau admin Infois Anda.';

/// Koin perusahaan tidak cukup untuk Input AI di kasir.
const String posAiCoinsShortMessage = 'Koin perusahaan tidak cukup untuk Input AI. Hubungi pemilik usaha atau admin Infois Anda.';

/// Satu tim Tim AI yang terkunci.
const String aiTeamLockedLabel = 'Belum aktif untuk perusahaan ini';

/// Pesan server yang menyebut paket/pembelian tanpa padanan khusus.
const String neutralAccountMessage = 'Fitur ini belum aktif untuk perusahaan ini. Hubungi pemilik usaha atau admin Infois Anda.';

/// Kode galat server → pesan netral (pesan aslinya menyebut paket & menu
/// Langganan di web).
const Map<String, String> _codeMessages = {
  'akses_hp_tidak_tersedia': mobileAccessMessage,
  'langganan_tidak_aktif': companyInactiveMessage,
  'kanal_tidak_termasuk_paket': aiChannelLockedMessage,
  'koin_habis': aiQuotaExhaustedMessage,
};

/// Kalimat yang mengarah ke pembelian: menu Langganan / Dompet Koin, isi
/// ulang koin, upgrade, paket yang membuka fitur, harga paket. Sengaja
/// sempit: "biaya langganan internet" atau "paket oli" (barang/jasa usaha
/// pengguna) tidak boleh ikut terbuang.
final RegExp purchasePattern = RegExp(
  r'(menu|halaman|kelola|atur|paket( &| dan)?) langganan|langganan (infois|anda|perusahaan|berbayar)|langganannya|/langganan|'
  r'dompet[ -]koin|(isi|mengisi|beli|membeli|tambah|menambah)( ulang)? koin|top[ -]?up koin|upgrade|'
  r'(kelola|naikkan|tingkatkan|ganti|ubah)( ke)? paket|paket (berbayar|lebih tinggi|starter|growth|firma akuntan)|'
  r'(tersedia|mulai|dibuka)( di| dari| lewat| dengan)? paket|(belum )?termasuk paket (langganan|berbayar|trial|anda|perusahaan)|'
  r'belum termasuk paket|harga paket|midtrans|/billing|'
  // Beli/tambah/isi koin dengan kata sisipan: "beli tambahan koin",
  // "menambah jumlah koin", "top up saldo koin", "koin tambahan".
  r'\b(beli|membeli|pembelian|tambah|menambah|menambahkan|isi|mengisi|top[ -]?up)\s+(\S+\s+){0,2}koin\b|\bkoin tambahan|'
  // Isi saldo / tambah kuota-jatah, hanya bila menyangkut koin/Tim AI
  // ("isi saldo e-wallet pelanggan", "kuota internet" tetap aman).
  r'\b(koin|tim ai|jatah|kuota)\b[^.!?\n]*\bisi( ulang)? saldo|\bisi( ulang)? saldo\b[^.!?\n]*\b(koin|tim ai|jatah|kuota)\b|'
  r'\b(tambah|tambahan|menambah|naikkan|menaikkan)( \S+)? (kuota|jatah) (tim ai|ai|koin|pemakaian|bulanan|bulan ini)|'
  r'\b(kuota|jatah) (tim ai|ai|koin)\b[^.!?\n]*(tambah|beli|naik)|'
  // Ajakan berlangganan Infois ("pelanggan berlangganan galon" tetap aman).
  r'\b(silakan|untuk|dengan|perlu|harus|cara|mulai|ayo) berlangganan|\bberlangganan( \S+){0,3} (infois|paket|tim ai)|'
  r'\b(infois|paket|tim ai|fitur ini)\b[^.!?\n]*\bberlangganan',
  caseSensitive: false,
);

/// Pesan galat server yang aman ditampilkan di aplikasi Play Store.
String storeSafeServerMessage(String? code, String message) {
  final mapped = code == null ? null : _codeMessages[code];
  if (mapped != null) {
    return mapped;
  }
  if (!purchasePattern.hasMatch(message)) {
    return message;
  }
  final kept = scrubPurchaseSentences(message).trim();
  return kept.isEmpty ? neutralAccountMessage : kept;
}

/// Buang kalimat yang mengarah ke pembelian dari teks (pesan server,
/// jawaban Tim AI). Per baris; baris yang tinggal penanda daftar dibuang.
String scrubPurchaseSentences(String text) {
  if (!purchasePattern.hasMatch(text)) {
    return text;
  }
  final lines = <String>[];
  for (final line in text.split('\n')) {
    if (!purchasePattern.hasMatch(line)) {
      lines.add(line);
      continue;
    }
    final sentences = line.split(RegExp(r'(?<=[.!?])\s+'));
    final kept = sentences.where((sentence) => !purchasePattern.hasMatch(sentence)).join(' ').trimRight();
    // "- ", "1. ", "> " tanpa isi lagi: buang barisnya.
    if (kept.trim().isEmpty || RegExp(r'^\s*([-*+>]|\d+[.)])\s*$').hasMatch(kept)) {
      continue;
    }
    lines.add(kept);
  }
  return lines.join('\n');
}

/// Alamat halaman pembelian di web Infois (Langganan, Dompet Koin, billing):
/// tidak dibuka dari aplikasi.
bool isPurchaseUrl(String url) {
  final uri = Uri.tryParse(url.trim());
  if (uri == null) {
    return false;
  }
  const blocked = {'langganan', 'dompet-koin', 'billing', 'checkout', 'upgrade', 'top-up', 'topup', 'harga', 'pricing'};
  if (uri.pathSegments.any((segment) => blocked.contains(segment.toLowerCase()))) {
    return true;
  }
  final host = uri.host.toLowerCase();
  if (host.contains('midtrans') || host.contains('veritrans')) {
    return true;
  }
  // Situs pemasaran infois.ai memuat harga & tombol daftar/beli: hanya
  // halaman hukum & info hapus akun yang boleh dibuka dari aplikasi.
  if (host == 'infois.ai' || host == 'www.infois.ai') {
    const allowed = {'kebijakan-privasi', 'syarat-dan-ketentuan', 'hapus-akun'};
    return !(uri.pathSegments.isNotEmpty && allowed.contains(uri.pathSegments.first.toLowerCase()));
  }
  return false;
}

/// Halaman panel dashboard Infois (`/app/...` dan beranda dashboard): bilah
/// sampingnya memuat menu Langganan & Dompet Koin, jadi tidak dibuka dari
/// aplikasi (alasan yang sama dengan dihapusnya "Buka Infois di web").
/// Pengecualian: Hapus akun (wajib Google Play). Dokumen cetak/PDF
/// (`/documents/...`) dan halaman publik lain tidak memuat menu itu.
bool isWebPanelUrl(String url) {
  final uri = Uri.tryParse(url.trim());
  if (uri == null || uri.host.isEmpty) {
    return false;
  }
  final host = uri.host.toLowerCase();
  final serverHost = Uri.tryParse(AppConfig.serverUrl)?.host.toLowerCase();
  final dashboard = (host.endsWith('.infois.ai') && host != 'www.infois.ai') || host == serverHost;
  if (!dashboard) {
    return false;
  }
  final segments = [for (final segment in uri.pathSegments) if (segment.isNotEmpty) segment.toLowerCase()];
  if (segments.isEmpty) {
    // Beranda dashboard langsung dialihkan ke panel.
    return true;
  }
  if (segments.first != 'app') {
    return false;
  }
  return !(segments.length >= 2 && segments[1] == deleteAccountPath.split('/').last);
}

/// Slug artikel Pusat Bantuan dari tautan web Infois (`/bantuan/{slug}`
/// atau `/app/{perusahaan}/pusat-bantuan/artikel/{slug}`, mis. dari jawaban
/// Tim AI), atau null. Tautan ini dibuka di layar artikel aplikasi, bukan di
/// browser (halaman panel tetap tidak dibuka).
String? helpArticleSlugFromUrl(String url) {
  final uri = Uri.tryParse(url.trim());
  if (uri == null) {
    return null;
  }
  if (uri.host.isEmpty) {
    // Relatif ("/bantuan/…"); bukan "mailto:" / "#bagian".
    if (uri.hasScheme || !uri.path.startsWith('/')) {
      return null;
    }
  } else {
    final host = uri.host.toLowerCase();
    final serverHost = Uri.tryParse(AppConfig.serverUrl)?.host.toLowerCase();
    final dashboard = (host.endsWith('.infois.ai') && host != 'www.infois.ai') || host == serverHost;
    if (!dashboard || !const {'http', 'https'}.contains(uri.scheme.toLowerCase())) {
      return null;
    }
  }
  final segments = [for (final segment in uri.pathSegments) if (segment.isNotEmpty) segment];
  final slugPattern = RegExp(r'^[A-Za-z0-9-]+$');
  if (segments.length == 2 && segments[0].toLowerCase() == 'bantuan' && slugPattern.hasMatch(segments[1]) && segments[1].toLowerCase() != 'media') {
    return segments[1];
  }
  if (segments.length == 5 && segments[0].toLowerCase() == 'app' && segments[2].toLowerCase() == 'pusat-bantuan' && segments[3].toLowerCase() == 'artikel' && slugPattern.hasMatch(segments[4])) {
    return segments[4];
  }
  return null;
}

/// Tautan yang tidak dibuka aplikasi Play Store: halaman pembelian dan
/// halaman panel dashboard (lihat [isPurchaseUrl], [isWebPanelUrl]).
bool isBlockedInAppUrl(String url) => isPurchaseUrl(url) || isWebPanelUrl(url);

/// Pesan saat tautan diblokir.
const String blockedLinkMessage = 'Halaman ini tidak dibuka dari aplikasi. Untuk pengaturan lengkap, pakai Infois versi web di komputer.';

/// Alasan perusahaan ditolak aplikasi HP, tanpa nama paket / pembelian.
String deniedReasonLabel(String? reason) => switch (reason) {
      'trial' => 'masih masa coba; aplikasi HP belum aktif',
      'langganan_tidak_aktif' => 'akun perusahaan sedang tidak aktif',
      _ => 'aplikasi HP belum aktif',
    };

/// Jawaban Tim AI yang seluruhnya tentang pembelian paket/koin.
const String aiAccountTopicMessage = 'Untuk urusan akun perusahaan dan jatah Tim AI, hubungi pemilik usaha atau admin Infois Anda.';

/// Jawaban Tim AI tanpa kalimat yang mengarah ke pembelian.
String storeSafeAiText(String text) {
  final kept = scrubPurchaseSentences(text);
  return kept.trim().isEmpty && text.trim().isNotEmpty ? aiAccountTopicMessage : kept;
}

/// Kebijakan privasi & syarat (wajib dicantumkan di Play Console; juga
/// ditautkan dari Akun).
const String privacyPolicyUrl = 'https://infois.ai/kebijakan-privasi';
const String termsUrl = 'https://infois.ai/syarat-dan-ketentuan';

/// Halaman hapus akun di web Infois (perlu masuk): [serverWebUrl] tanpa `/`
/// di akhir, mis. https://dashboard.infois.ai.
const String deleteAccountPath = '/app/hapus-akun';
