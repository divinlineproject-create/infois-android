import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../core/format.dart';
import '../../state/sync_controller.dart';
import '../theme.dart';

/// Status koneksi di header: Online · Offline (N menunggu) · Menyinkron.
class SyncStatusBadge extends ConsumerWidget {
  const SyncStatusBadge({super.key, this.onTap});

  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sync = ref.watch(syncProvider);
    final (label, color, icon) = switch (sync) {
      SyncState(syncing: true) => ('Menyinkron', Colors.blueGrey, Icons.sync),
      SyncState(connection: ConnectionStatus.online) when sync.pending > 0 => ('Online · ${sync.pending} menunggu', Brand.green, Icons.cloud_upload_outlined),
      SyncState(connection: ConnectionStatus.online) => ('Online', Brand.green, Icons.cloud_done_outlined),
      SyncState(connection: ConnectionStatus.offline) => ('Offline${sync.pending > 0 ? ' (${sync.pending} menunggu)' : ''}', Brand.amber, Icons.cloud_off_outlined),
      _ => ('Memeriksa…', Colors.grey, Icons.more_horiz),
    };
    return Semantics(
      label: 'Status koneksi: $label',
      button: onTap != null,
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(20)),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 16, color: color),
            const SizedBox(width: 6),
            Text(label, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: color)),
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
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 56, color: Theme.of(context).colorScheme.primary),
            const SizedBox(height: 16),
            Text(title, textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
            if (message != null) ...[
              const SizedBox(height: 8),
              Text(message!, textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodyMedium),
            ],
            if (action != null) ...[const SizedBox(height: 20), action!],
          ]),
        ),
      );
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
      child: Row(children: [Expanded(child: Text(label, style: style)), Text(value, style: style)]),
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
