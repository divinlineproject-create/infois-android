import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/api_client.dart';
import '../../domain/models.dart';
import '../../state/session.dart';
import '../theme.dart';
import '../widgets/auth_layout.dart';
import '../widgets/pin_pad.dart';

/// Daftar orang yang bisa membuka tablet ini (server bila online, cadangan tersimpan).
final pinUsersProvider = FutureProvider.autoDispose<List<PinUser>>((ref) async {
  ref.watch(sessionProvider.select((value) => (value.valueOrNull?.tenantId, value.valueOrNull?.host?.id)));
  return ref.read(sessionProvider.notifier).pinUsers();
});

/// Tablet kasir bersama terkunci: pilih nama, lalu ketik PIN 6 angka —
/// tanpa email, kata sandi, dan kode email.
class LockScreen extends ConsumerStatefulWidget {
  const LockScreen({super.key});

  @override
  ConsumerState<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends ConsumerState<LockScreen> {
  PinUser? _selected;
  String? _error;
  bool _busy = false;
  final _pad = PinPadController();

  @override
  void dispose() {
    _pad.dispose();
    super.dispose();
  }

  Future<void> _submit(String pin) async {
    final user = _selected;
    if (user == null) {
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(sessionProvider.notifier).unlock(user, pin);
    } on ApiException catch (error) {
      if (mounted) {
        setState(() => _error = error.message);
      }
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Belum bisa membuka. Coba lagi.');
      }
    } finally {
      _pad.clear();
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(sessionProvider).valueOrNull;
    final users = ref.watch(pinUsersProvider);
    final tenantName = session?.tenant?.name ?? 'Infois';
    return AuthSplitLayout(
      headline: tenantName,
      lead: 'Tablet kasir bersama. Pilih nama Anda, lalu ketik PIN 6 angka.',
      child: _selected == null ? _picker(context, users) : _pinStep(context, _selected!),
    );
  }

  Widget _picker(BuildContext context, AsyncValue<List<PinUser>> users) {
    final list = users.valueOrNull ?? const <PinUser>[];
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text('Siapa yang bertugas?', key: const Key('lock-title'), style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700)),
      const SizedBox(height: 6),
      Text('Ketuk nama Anda.', style: TextStyle(color: mutedText(context))),
      const SizedBox(height: 20),
      if (users.isLoading && list.isEmpty) const Center(child: Padding(padding: EdgeInsets.all(24), child: CircularProgressIndicator())),
      Wrap(spacing: 12, runSpacing: 12, children: [
        for (final user in list)
          _UserTile(
            user: user,
            onTap: () => setState(() {
              _selected = user;
              _error = null;
            }),
          ),
      ]),
      const SizedBox(height: 24),
      TextButton.icon(
        onPressed: () => ref.invalidate(pinUsersProvider),
        icon: const Icon(Icons.refresh),
        label: const Text('Muat ulang daftar'),
      ),
      const SizedBox(height: 8),
      Text(
        'Nama Anda belum ada? Buat PIN di Akun aplikasi (setelah masuk) atau di website: Profil › PIN aplikasi HP. Pemilik usaha juga bisa membuatkannya di Tim & Akses.',
        style: TextStyle(fontSize: 12.5, color: mutedText(context), height: 1.4),
      ),
    ]);
  }

  Widget _pinStep(BuildContext context, PinUser user) {
    return Column(crossAxisAlignment: CrossAxisAlignment.center, children: [
      _Avatar(user: user, size: 64),
      const SizedBox(height: 10),
      Text(user.name, key: const Key('lock-selected-name'), style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
      if (user.roleLabel != null || user.isHost) Text(user.isHost ? 'Pemilik login tablet' : user.roleLabel!, style: TextStyle(color: mutedText(context))),
      const SizedBox(height: 16),
      PinPad(controller: _pad, busy: _busy, error: _error, label: 'Ketik PIN 6 angka', onCompleted: _submit),
      const SizedBox(height: 8),
      TextButton(
        key: const Key('lock-change-user'),
        onPressed: _busy
            ? null
            : () => setState(() {
                  _selected = null;
                  _error = null;
                  _pad.clear();
                }),
        child: const Text('Bukan saya — pilih nama lain'),
      ),
      Text('Lupa PIN? Atur ulang di website (Profil › PIN aplikasi HP) atau minta pemilik usaha.', textAlign: TextAlign.center, style: TextStyle(fontSize: 12.5, color: mutedText(context))),
    ]);
  }
}

class _UserTile extends StatelessWidget {
  const _UserTile({required this.user, required this.onTap});

  final PinUser user;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 124,
      child: Material(
        color: Theme.of(context).colorScheme.surfaceContainerLow,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: BorderSide(color: Theme.of(context).colorScheme.outlineVariant)),
        child: InkWell(
          key: Key('lock-user-${user.id}'),
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 14, 8, 12),
            child: Column(children: [
              _Avatar(user: user, size: 48),
              const SizedBox(height: 8),
              Text(user.name, maxLines: 2, textAlign: TextAlign.center, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
              if (user.isHost || user.roleLabel != null)
                Text(user.isHost ? 'Pemilik tablet' : user.roleLabel!, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: mutedText(context))),
            ]),
          ),
        ),
      ),
    );
  }
}

class _Avatar extends StatelessWidget {
  const _Avatar({required this.user, required this.size});

  final PinUser user;
  final double size;

  @override
  Widget build(BuildContext context) => CircleAvatar(
        radius: size / 2,
        backgroundColor: Theme.of(context).colorScheme.primaryContainer,
        child: Text(user.initials, style: TextStyle(fontSize: size * 0.36, fontWeight: FontWeight.w700, color: Theme.of(context).colorScheme.onPrimaryContainer)),
      );
}
