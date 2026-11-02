import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/pin.dart';
import '../../data/api_client.dart';
import '../../state/session.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/pin_pad.dart';

/// Buat / ganti PIN aplikasi sendiri (untuk perusahaan aktif). Mengembalikan
/// true bila tersimpan.
Future<bool> showPinSetupSheet(BuildContext context, {required bool hasPin}) async {
  final saved = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _PinSetupSheet(hasPin: hasPin),
  );
  return saved == true;
}

class _PinSetupSheet extends ConsumerStatefulWidget {
  const _PinSetupSheet({required this.hasPin});

  final bool hasPin;

  @override
  ConsumerState<_PinSetupSheet> createState() => _PinSetupSheetState();
}

enum _Step { current, fresh, confirm }

class _PinSetupSheetState extends ConsumerState<_PinSetupSheet> {
  late _Step _step = widget.hasPin ? _Step.current : _Step.fresh;
  final _pad = PinPadController();
  String? _current;
  String? _fresh;
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _pad.dispose();
    super.dispose();
  }

  String get _label => switch (_step) {
        _Step.current => 'Ketik PIN Anda yang sekarang',
        _Step.fresh => 'Ketik PIN baru (6 angka)',
        _Step.confirm => 'Ketik sekali lagi PIN baru',
      };

  Future<void> _entered(String pin) async {
    _pad.clear();
    switch (_step) {
      case _Step.current:
        setState(() {
          _current = pin;
          _error = null;
          _step = _Step.fresh;
        });
      case _Step.fresh:
        final reason = PinCode.invalidReason(pin);
        setState(() {
          _error = reason;
          if (reason == null) {
            _fresh = pin;
            _step = _Step.confirm;
          }
        });
      case _Step.confirm:
        if (pin != _fresh) {
          setState(() {
            _error = 'PIN tidak sama. Ulangi PIN baru.';
            _fresh = null;
            _step = _Step.fresh;
          });
          return;
        }
        await _save(pin);
    }
  }

  Future<void> _save(String pin) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(sessionProvider.notifier).setOwnPin(pin, currentPin: _current);
      if (mounted) {
        Navigator.pop(context, true);
        showMessage(context, 'PIN disimpan. Pakai PIN ini untuk membuka tablet kasir.');
      }
    } on ApiException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _error = error.message;
        // PIN lama salah: ulangi dari PIN lama.
        _step = widget.hasPin && error.code == 'pin_salah' ? _Step.current : _Step.fresh;
        _fresh = null;
      });
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(widget.hasPin ? 'Ganti PIN aplikasi' : 'Buat PIN aplikasi', style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          Text(
            'PIN 6 angka untuk membuka tablet kasir dengan cepat: pilih nama, ketik PIN, tanpa email dan kode. Jangan pakai angka yang sama semua atau berurutan.',
            textAlign: TextAlign.center,
            style: TextStyle(color: mutedText(context), fontSize: 13),
          ),
          const SizedBox(height: 16),
          PinPad(key: ValueKey(_step), controller: _pad, label: _label, error: _error, busy: _busy, onCompleted: _entered),
        ]),
      ),
    );
  }
}
