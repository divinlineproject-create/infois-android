import 'package:flutter/foundation.dart' show kReleaseMode;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/config.dart';
import '../../data/api_client.dart';
import '../../services/file_downloads.dart';
import '../../state/session.dart';
import '../theme.dart';
import '../widgets/common.dart';

/// Pesan "aplikasi HP tidak tersedia" + alasan per perusahaan + tombol
/// Lihat paket (website › Langganan).
class AccessNoticeCard extends ConsumerWidget {
  const AccessNoticeCard({super.key, required this.notice, this.onClose});

  final AccessNotice notice;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final color = warningText(context);
    final server = ref.watch(sessionProvider).valueOrNull;
    return Card(
      key: const Key('access-notice'),
      color: color.withValues(alpha: 0.08),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: BorderSide(color: color.withValues(alpha: 0.4))),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 8, 10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(Icons.phonelink_lock_outlined, color: color),
            const SizedBox(width: 10),
            Expanded(child: Text('Aplikasi HP belum tersedia', style: TextStyle(fontWeight: FontWeight.w700, color: color))),
            if (onClose != null) IconButton(visualDensity: VisualDensity.compact, tooltip: 'Tutup', icon: const Icon(Icons.close, size: 18), onPressed: onClose),
          ]),
          const SizedBox(height: 6),
          Padding(padding: const EdgeInsets.only(right: 8), child: Text(notice.message, style: const TextStyle(fontSize: 13.5))),
          if (notice.tenants.isNotEmpty) ...[
            const SizedBox(height: 8),
            for (final tenant in notice.tenants)
              Padding(
                padding: const EdgeInsets.only(bottom: 4, right: 8),
                child: Text('• ${tenant.name}: ${tenant.reasonLabel}.', key: Key('access-notice-tenant-${tenant.id ?? tenant.name}'), style: const TextStyle(fontSize: 13)),
              ),
          ],
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              key: const Key('access-notice-plans'),
              onPressed: server == null ? null : () => openExternalLink(context, ref, server.webUrl(billingPath(notice.billingSlug))),
              icon: const Icon(Icons.open_in_new, size: 18),
              label: const Text('Lihat paket'),
            ),
          ),
        ]),
      ),
    );
  }
}

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _form = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _deviceName = TextEditingController(text: 'HP Kasir');
  bool _busy = false;
  bool _hidePassword = true;
  String? _error;
  AccessNotice? _notice;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    _deviceName.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_form.currentState!.validate()) {
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
    });
    ref.read(sessionProvider.notifier).clearNotice();
    try {
      await ref.read(sessionProvider.notifier).login(email: _email.text, password: _password.text, deviceName: _deviceName.text);
    } on ApiException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        if (error.status == 403 && error.code == ApiException.mobileAccessDeniedCode) {
          _notice = AccessNotice.fromError(error);
        } else {
          _error = error.message;
        }
      });
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Belum bisa masuk. Coba lagi.');
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _editServer() async {
    final current = ref.read(sessionProvider).valueOrNull?.serverUrl ?? '';
    final controller = TextEditingController(text: current);
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Alamat server'),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Biarkan seperti ini, kecuali diminta mengganti oleh tim Infois.'),
          if (!kReleaseMode)
            const Padding(
              padding: EdgeInsets.only(top: 6),
              child: Text('Uji coba: emulator Android http://10.0.2.2:8000; HP fisik pakai alamat IP komputer di Wi-Fi yang sama, mis. http://192.168.1.10:8000.', style: TextStyle(fontSize: 12)),
            ),
          const SizedBox(height: 12),
          TextField(controller: controller, keyboardType: TextInputType.url, autocorrect: false, decoration: const InputDecoration(hintText: AppConfig.productionServerUrl)),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Batal')),
          FilledButton(onPressed: () => Navigator.pop(context, controller.text), child: const Text('Simpan')),
        ],
      ),
    );
    if (result != null && result.trim().isNotEmpty) {
      await ref.read(sessionProvider.notifier).setServerUrl(result);
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(sessionProvider).valueOrNull;
    final server = session?.serverUrl ?? '';
    final notice = _notice ?? session?.notice;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Form(
                key: _form,
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  const Center(child: BrandMark(size: 64)),
                  const SizedBox(height: 16),
                  Text('Masuk ke Infois', textAlign: TextAlign.center, style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 6),
                  const Text('Pakai akun yang sama dengan website.', textAlign: TextAlign.center),
                  if (notice != null) ...[
                    const SizedBox(height: 20),
                    AccessNoticeCard(
                      notice: notice,
                      onClose: () {
                        setState(() => _notice = null);
                        ref.read(sessionProvider.notifier).clearNotice();
                      },
                    ),
                  ],
                  const SizedBox(height: 28),
                  TextFormField(
                    key: const Key('login-email'),
                    controller: _email,
                    keyboardType: TextInputType.emailAddress,
                    autocorrect: false,
                    autofillHints: const [AutofillHints.email],
                    decoration: const InputDecoration(labelText: 'Email', prefixIcon: Icon(Icons.mail_outline)),
                    validator: (value) => (value ?? '').contains('@') ? null : 'Isi email yang benar.',
                  ),
                  const SizedBox(height: 14),
                  TextFormField(
                    key: const Key('login-password'),
                    controller: _password,
                    obscureText: _hidePassword,
                    autofillHints: const [AutofillHints.password],
                    decoration: InputDecoration(
                      labelText: 'Kata sandi',
                      prefixIcon: const Icon(Icons.lock_outline),
                      suffixIcon: IconButton(
                        tooltip: _hidePassword ? 'Tampilkan' : 'Sembunyikan',
                        icon: Icon(_hidePassword ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                        onPressed: () => setState(() => _hidePassword = !_hidePassword),
                      ),
                    ),
                    validator: (value) => (value ?? '').isEmpty ? 'Isi kata sandi.' : null,
                    onFieldSubmitted: (_) => _submit(),
                  ),
                  const SizedBox(height: 14),
                  TextFormField(
                    controller: _deviceName,
                    decoration: const InputDecoration(labelText: 'Nama HP ini', helperText: 'Tampil di web (Tim & Akses › Perangkat).', prefixIcon: Icon(Icons.smartphone)),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 16),
                    Text(_error!, style: TextStyle(color: dangerText(context), fontWeight: FontWeight.w500)),
                  ],
                  const SizedBox(height: 24),
                  FilledButton(
                    key: const Key('login-submit'),
                    onPressed: _busy ? null : _submit,
                    child: _busy ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white)) : const Text('Masuk'),
                  ),
                  const SizedBox(height: 12),
                  const Text('Belum punya akun? Daftarkan usaha lewat website Infois.', textAlign: TextAlign.center, style: TextStyle(fontSize: 13)),
                  const SizedBox(height: 24),
                  TextButton.icon(
                    onPressed: _editServer,
                    icon: const Icon(Icons.dns_outlined, size: 18),
                    label: Text('Server: $server', overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12)),
                  ),
                ]),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
