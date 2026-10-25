import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/config.dart';
import '../../core/store_policy.dart';
import '../../data/api_client.dart';
import '../../state/session.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/gone_company_notice.dart';

/// Pesan "aplikasi HP tidak tersedia" + alasan per perusahaan. Sesuai
/// kebijakan Google Play tidak ada nama paket, harga, atau tautan ke halaman
/// pembelian; pengguna diminta menghubungi pemilik usaha / admin Infois.
class AccessNoticeCard extends StatelessWidget {
  const AccessNoticeCard({super.key, required this.notice, this.onClose});

  final AccessNotice notice;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final color = warningText(context);
    final message = purchasePattern.hasMatch(notice.message) || notice.message.trim().isEmpty ? mobileAccessMessage : notice.message;
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
          Padding(padding: const EdgeInsets.only(right: 8), child: Text(message, style: const TextStyle(fontSize: 13.5))),
          if (notice.tenants.isNotEmpty) ...[
            const SizedBox(height: 8),
            for (final tenant in notice.tenants)
              Padding(
                padding: const EdgeInsets.only(bottom: 4, right: 8),
                child: Text('• ${tenant.name}: ${deniedReasonLabel(tenant.reason)}.', key: Key('access-notice-tenant-${tenant.id ?? tenant.name}'), style: const TextStyle(fontSize: 13)),
              ),
          ],
          const SizedBox(height: 6),
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
  final _code = TextEditingController();
  bool _busy = false;
  bool _hidePassword = true;
  String? _error;
  AccessNotice? _notice;

  /// Verifikasi dua langkah: cara yang aktif (`aplikasi`, `email`); null =
  /// masih di langkah email & kata sandi.
  List<String>? _methods;

  String? _codeError;
  bool _useRecovery = false;

  /// Detik sebelum "Kirim ulang kode" boleh diketuk lagi (dari server:
  /// `resend_available_in` / `retry_after`).
  int _resendIn = 0;
  Timer? _resendTimer;

  /// Jeda bawaan bila server lama tidak menyebut sisa jedanya.
  static const _defaultResendSeconds = 60;

  static final _sixDigits = RegExp(r'^\d{6}$');
  static final _recoveryCode = RegExp(r'^[A-Za-z0-9]{10}-[A-Za-z0-9]{10}$');

  @override
  void dispose() {
    _resendTimer?.cancel();
    _email.dispose();
    _password.dispose();
    _deviceName.dispose();
    _code.dispose();
    super.dispose();
  }

  bool get _codeStep => _methods != null;

  void _startResendCooldown(int seconds) {
    _resendTimer?.cancel();
    setState(() => _resendIn = seconds < 0 ? 0 : seconds);
    if (seconds <= 0) {
      return;
    }
    _resendTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted || _resendIn <= 1) {
        timer.cancel();
        if (mounted) {
          setState(() => _resendIn = 0);
        }
        return;
      }
      setState(() => _resendIn--);
    });
  }

  /// "59" (sampai 60 detik) atau "12:05" (menit:detik).
  static String resendCountdown(int seconds) => seconds <= 60 ? '$seconds' : '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';

  /// Kembali ke langkah email & kata sandi.
  void _backToPassword() => setState(_resetCodeStep);

  void _resetCodeStep() {
    _resendTimer?.cancel();
    _code.clear();
    _methods = null;
    _codeError = null;
    _useRecovery = false;
    _resendIn = 0;
  }

  String? _validateCode(String value) {
    final code = value.replaceAll(' ', '');
    if (code.isEmpty) {
      return _useRecovery ? 'Isi kode pemulihan.' : 'Isi kode 6 angka.';
    }
    if (_useRecovery) {
      return _recoveryCode.hasMatch(code) ? null : 'Kode pemulihan berbentuk 10 huruf/angka, tanda -, lalu 10 huruf/angka.';
    }
    return _sixDigits.hasMatch(code) ? null : 'Kode terdiri dari 6 angka.';
  }

  Future<void> _submit({bool resend = false}) async {
    if (_busy) {
      return;
    }
    if (!_codeStep && !_form.currentState!.validate()) {
      return;
    }
    String? code;
    if (_codeStep && !resend) {
      final invalid = _validateCode(_code.text);
      if (invalid != null) {
        setState(() => _codeError = invalid);
        return;
      }
      code = _code.text.replaceAll(' ', '');
    }
    setState(() {
      _busy = true;
      _error = null;
      _codeError = null;
      _notice = null;
    });
    ref.read(sessionProvider.notifier).clearNotice();
    try {
      await ref.read(sessionProvider.notifier).login(email: _email.text, password: _password.text, deviceName: _deviceName.text, code: code, resend: resend);
    } on ApiException catch (error) {
      if (!mounted) {
        return;
      }
      if (error.twoFactorRequired) {
        final methods = error.twoFactorMethods;
        final wasCodeStep = _codeStep;
        setState(() {
          _methods = methods.isEmpty ? const ['aplikasi'] : methods;
          if (!(_methods!.contains('aplikasi'))) {
            _useRecovery = false;
          }
        });
        if (_methods!.contains('email')) {
          _startResendCooldown(error.resendAvailableIn ?? _defaultResendSeconds);
          if (resend || wasCodeStep) {
            showMessage(context, 'Kode baru sudah dikirim ke email Anda.');
          }
        }
        return;
      }
      if (resend && error.status == 429) {
        // Kirim ulang terlalu cepat: email tidak dikirim, hitung mundur
        // mengikuti sisa jeda dari server; kode yang sudah diketik tetap.
        final wait = error.retryAfter;
        if (wait != null && wait > 0) {
          _startResendCooldown(wait);
        }
        showMessage(context, error.message);
        return;
      }
      setState(() {
        if (error.status == 403 && error.code == ApiException.mobileAccessDeniedCode) {
          _notice = AccessNotice.fromError(error);
          _resetCodeStep();
        } else if (_codeStep && (error.code == ApiException.twoFactorInvalidCode || error.code == ApiException.twoFactorThrottledCode)) {
          _codeError = error.message;
          _code.clear();
        } else if (_codeStep && error.code == 'login_gagal') {
          // Kata sandi diganti di tempat lain: ulangi dari awal.
          _resetCodeStep();
          _error = error.message;
        } else if (_codeStep) {
          _codeError = error.message;
        } else {
          _error = error.message;
        }
      });
    } catch (_) {
      if (mounted) {
        setState(() => _codeStep ? _codeError = 'Belum bisa masuk. Coba lagi.' : _error = 'Belum bisa masuk. Coba lagi.');
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  String get _codeHint {
    final methods = _methods ?? const [];
    final app = methods.contains('aplikasi');
    final email = methods.contains('email');
    if (_useRecovery) {
      return 'Masukkan salah satu kode pemulihan yang Anda simpan saat mengaktifkan verifikasi dua langkah. Setiap kode hanya bisa dipakai sekali.';
    }
    if (app && email) {
      return 'Masukkan 6 angka dari aplikasi autentikator (mis. Google Authenticator), atau kode yang kami kirim ke ${_email.text.trim()}.';
    }
    if (email) {
      return 'Kami mengirim kode 6 angka ke ${_email.text.trim()}. Periksa juga folder Spam. Kode berlaku 10 menit.';
    }
    return 'Buka aplikasi autentikator (mis. Google Authenticator) lalu masukkan 6 angka untuk Infois.';
  }

  List<Widget> _codeFields(BuildContext context) {
    final methods = _methods ?? const [];
    return [
      Text('Verifikasi dua langkah', key: const Key('login-2fa-title'), style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
      const SizedBox(height: 6),
      Text(_codeHint, key: const Key('login-2fa-hint'), style: const TextStyle(fontSize: 13.5, height: 1.4)),
      const SizedBox(height: 16),
      TextField(
        key: const Key('login-2fa-code'),
        controller: _code,
        autofocus: true,
        keyboardType: _useRecovery ? TextInputType.visiblePassword : TextInputType.number,
        autofillHints: _useRecovery ? null : const [AutofillHints.oneTimeCode],
        autocorrect: false,
        enableSuggestions: false,
        maxLength: _useRecovery ? 21 : 6,
        textAlign: _useRecovery ? TextAlign.start : TextAlign.center,
        style: _useRecovery ? null : const TextStyle(fontSize: 22, letterSpacing: 8, fontWeight: FontWeight.w600),
        inputFormatters: [_useRecovery ? FilteringTextInputFormatter.allow(RegExp(r'[A-Za-z0-9-]')) : FilteringTextInputFormatter.digitsOnly],
        decoration: InputDecoration(
          labelText: _useRecovery ? 'Kode pemulihan' : 'Kode 6 angka',
          hintText: _useRecovery ? 'xxxxxxxxxx-xxxxxxxxxx' : null,
          counterText: '',
          errorText: _codeError,
          errorMaxLines: 4,
          prefixIcon: const Icon(Icons.password_rounded),
        ),
        onChanged: (value) {
          if (_codeError != null) {
            setState(() => _codeError = null);
          }
          if (!_useRecovery && _sixDigits.hasMatch(value)) {
            _submit();
          }
        },
        onSubmitted: (_) => _submit(),
      ),
      const SizedBox(height: 16),
      FilledButton(
        key: const Key('login-2fa-submit'),
        onPressed: _busy ? null : _submit,
        child: _busy ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white)) : const Text('Verifikasi & masuk'),
      ),
      const SizedBox(height: 8),
      if (methods.contains('aplikasi'))
        TextButton(
          key: const Key('login-2fa-recovery'),
          onPressed:
              _busy
                  ? null
                  : () {
                    _code.clear();
                    setState(() {
                      _useRecovery = !_useRecovery;
                      _codeError = null;
                    });
                  },
          child: Text(_useRecovery ? 'Pakai kode 6 angka' : 'Pakai kode pemulihan'),
        ),
      if (methods.contains('email'))
        TextButton(
          key: const Key('login-2fa-resend'),
          onPressed: _busy || _resendIn > 0 ? null : () => _submit(resend: true),
          child: Text(_resendIn > 0 ? 'Kirim ulang kode ke email (${resendCountdown(_resendIn)})' : 'Kirim ulang kode ke email'),
        ),
      TextButton(key: const Key('login-2fa-back'), onPressed: _busy ? null : _backToPassword, child: const Text('Kembali')),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(sessionProvider).valueOrNull;
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
                  const SizedBox(height: Space.m),
                  Text(
                    AppConfig.name,
                    key: const Key('app-name'),
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, letterSpacing: 1.2, color: Theme.of(context).colorScheme.primary),
                  ),
                  const SizedBox(height: Space.xs),
                  Text('Masuk ke Infois', textAlign: TextAlign.center, style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 6),
                  const Text('Pakai akun yang sama dengan website.', textAlign: TextAlign.center),
                  if (session?.goneNotices.isNotEmpty ?? false) ...[
                    const SizedBox(height: 20),
                    const GoneCompanyNotices(),
                  ],
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
                  if (_codeStep)
                    ..._codeFields(context)
                  else ...[
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
                    onPressed: _busy ? null : () => _submit(),
                    child: _busy ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white)) : const Text('Masuk'),
                  ),
                  ],
                  const SizedBox(height: 12),
                  const Text('Belum punya akun? Akun dibuat oleh pemilik usaha atau admin Infois Anda.', key: Key('login-no-account'), textAlign: TextAlign.center, style: TextStyle(fontSize: 13)),
                ]),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
