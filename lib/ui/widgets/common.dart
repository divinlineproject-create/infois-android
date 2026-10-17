import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../core/format.dart';
import '../../data/api_client.dart';
import '../../data/app_storage.dart' show ServerMigrationPending;
import '../../data/local_db.dart';
import '../../services/pos_service.dart';
import '../../state/sync_controller.dart';
import '../theme.dart';

/// Status koneksi di header: Online · Offline (N menunggu) · Menyinkron.
class SyncStatusBadge extends ConsumerWidget {
  const SyncStatusBadge({super.key, this.onTap});

  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sync = ref.watch(syncProvider);
    final dark = Theme.of(context).brightness == Brightness.dark;
    final green = dark ? Theme.of(context).colorScheme.primary : Brand.green;
    final muted = mutedText(context);
    final (label, color, icon) = switch (sync) {
      SyncState(syncing: true) => ('Menyinkron', dark ? muted : Colors.blueGrey, Icons.sync),
      SyncState(connection: ConnectionStatus.online) when sync.pending > 0 => ('Online · ${sync.pending} menunggu', green, Icons.cloud_upload_outlined),
      SyncState(connection: ConnectionStatus.online) => ('Online', green, Icons.cloud_done_outlined),
      SyncState(connection: ConnectionStatus.offline) => ('Offline${sync.pending > 0 ? ' (${sync.pending} menunggu)' : ''}', warningText(context), Icons.cloud_off_outlined),
      _ => ('Memeriksa…', muted, Icons.more_horiz),
    };
    return Semantics(
      label: 'Status koneksi: $label',
      button: onTap != null,
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(color: color.withValues(alpha: dark ? 0.16 : 0.12), borderRadius: BorderRadius.circular(20)),
          // Huruf besar / layar sempit: teks dipotong (…), bukan meluap dan
          // menggeser nama perusahaan.
          constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.45),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 16, color: color),
            const SizedBox(width: 6),
            Flexible(child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: color))),
          ]),
        ),
      ),
    );
  }
}

/// Logo tanda Infois.
class BrandMark extends StatelessWidget {
  const BrandMark({super.key, this.size = 56});

  final double size;

  @override
  Widget build(BuildContext context) => SvgPicture.asset('assets/images/infois-mark.svg', width: size, height: size);
}

/// Nominal koin selalu dengan ikon koin (tanpa kata "koin").
class CoinAmount extends StatelessWidget {
  const CoinAmount(this.amount, {super.key, this.size = 18, this.style});

  final num amount;
  final double size;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: [
        SvgPicture.asset('assets/images/infois-coin.svg', width: size, height: size),
        const SizedBox(width: 4),
        Text(rupiah(amount, symbol: false), style: style),
      ]);
}

/// Layar kosong yang ramah ("Segera hadir", belum ada data, dsb).
class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.icon, required this.title, this.message, this.action});

  final IconData icon;
  final String title;
  final String? message;
  final Widget? action;

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, constraints) {
        final compact = constraints.hasBoundedHeight && constraints.maxHeight < 260;
        final content = Center(
          child: Padding(
            padding: EdgeInsets.all(compact ? 12 : 32),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Container(
                width: compact ? 56 : 88,
                height: compact ? 56 : 88,
                decoration: BoxDecoration(color: Theme.of(context).colorScheme.primaryContainer, shape: BoxShape.circle),
                alignment: Alignment.center,
                child: Icon(icon, size: compact ? 28 : 40, color: Theme.of(context).colorScheme.onPrimaryContainer),
              ),
              SizedBox(height: compact ? 8 : 16),
              Text(title, textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
              if (message != null) ...[
                const SizedBox(height: 8),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 360),
                  child: Text(message!, textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: mutedText(context), height: 1.45)),
                ),
              ],
              if (action != null) ...[const SizedBox(height: 20), action!],
            ]),
          ),
        );
        if (!constraints.hasBoundedHeight) {
          return content;
        }
        // Ruang pendek (HP miring, huruf besar): gulir, bukan terpotong.
        return SingleChildScrollView(
          child: ConstrainedBox(constraints: BoxConstraints(minHeight: constraints.maxHeight, minWidth: constraints.maxWidth), child: content),
        );
      });
}

/// Pesan galat untuk pengguna: pesan yang memang ditulis untuk pengguna
/// (server, kasir, database sedang dimuat ulang); selain itu [fallback] tanpa
/// istilah teknis (rinciannya hanya ke log).
String plainError(Object? error, {String fallback = 'Terjadi kendala. Coba lagi.'}) {
  if (error is ApiException) {
    return error.message;
  }
  if (error is CheckoutException) {
    return error.message;
  }
  if (error is LocalDbClosedException) {
    return error.message;
  }
  if (error is ServerMigrationPending) {
    return error.message;
  }
  debugPrint('Galat: $error');
  return fallback;
}

void showMessage(BuildContext context, String message, {bool error = false}) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message), backgroundColor: error ? Brand.danger : null));
}

/// Baris label–nilai di ringkasan.
class AmountRow extends StatelessWidget {
  const AmountRow(this.label, this.value, {super.key, this.bold = false, this.large = false, this.color});

  final String label;
  final String value;
  final bool bold;
  final bool large;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(fontSize: large ? 20 : 15, fontWeight: bold ? FontWeight.w700 : FontWeight.w400, color: color);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: LayoutBuilder(
        builder: (context, constraints) => Row(children: [
          Expanded(child: Text(label, style: style)),
          const SizedBox(width: 8),
          // Nominal sangat besar / huruf besar: diperkecil, tidak meluap.
          ConstrainedBox(
            constraints: BoxConstraints(maxWidth: constraints.hasBoundedWidth ? constraints.maxWidth * 0.6 : double.infinity),
            child: FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerRight, child: Text(value, style: style)),
          ),
        ]),
      ),
    );
  }
}

/// Isi tab yang baru dibangun saat pertama kali dipilih dan tetap hidup
/// setelahnya (IndexedStack malas): tab Laporan/Catatan tidak memanggil
/// server sebelum dibuka.
class LazyTab extends StatefulWidget {
  const LazyTab({super.key, required this.active, required this.builder});

  final bool active;
  final Widget Function() builder;

  @override
  State<LazyTab> createState() => _LazyTabState();
}

class _LazyTabState extends State<LazyTab> {
  Widget? _child;

  @override
  Widget build(BuildContext context) {
    if (widget.active) {
      _child ??= widget.builder();
    }
    return _child ?? const SizedBox.shrink();
  }
}
