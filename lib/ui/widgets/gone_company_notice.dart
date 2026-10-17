import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/session.dart';
import '../theme.dart';

/// Pesan perusahaan yang ditutup / tempat user dikeluarkan, dengan jumlah
/// transaksi yang belum terkirim. Tombol "Mengerti" menghapus data HP
/// perusahaan itu ([SessionController.acknowledgeGone]).
class GoneCompanyNotices extends ConsumerStatefulWidget {
  const GoneCompanyNotices({super.key});

  @override
  ConsumerState<GoneCompanyNotices> createState() => _GoneCompanyNoticesState();
}

class _GoneCompanyNoticesState extends ConsumerState<GoneCompanyNotices> {
  final Set<int> _busy = {};

  Future<void> _acknowledge(GoneCompany gone) async {
    setState(() => _busy.add(gone.tenantId));
    try {
      await ref.read(sessionProvider.notifier).acknowledgeGone(gone);
    } finally {
      if (mounted) {
        setState(() => _busy.remove(gone.tenantId));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final notices = ref.watch(sessionProvider).valueOrNull?.goneNotices ?? const <GoneCompany>[];
    if (notices.isEmpty) {
      return const SizedBox.shrink();
    }
    final color = dangerText(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final gone in notices)
          Card(
            key: Key('gone-notice-${gone.tenantId}'),
            color: color.withValues(alpha: 0.07),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: BorderSide(color: color.withValues(alpha: 0.4))),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(gone.reason == GoneReason.closed ? Icons.store_mall_directory_outlined : Icons.person_off_outlined, color: color),
                      const SizedBox(width: 10),
                      Expanded(child: Text(gone.title, style: TextStyle(fontWeight: FontWeight.w700, color: color))),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(gone.explanation, style: const TextStyle(fontSize: 13.5)),
                  if (gone.lossWarning != null) ...[const SizedBox(height: 6), Text(gone.lossWarning!, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600))],
                  const SizedBox(height: 6),
                  Text('Data perusahaan ini akan dihapus dari HP setelah Anda menekan tombol di bawah.', style: TextStyle(fontSize: 12.5, color: mutedText(context))),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(key: Key('gone-ack-${gone.tenantId}'), onPressed: _busy.contains(gone.tenantId) ? null : () => _acknowledge(gone), child: const Text('Mengerti, hapus dari HP')),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}
