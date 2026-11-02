import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/pin.dart';
import '../theme.dart';

/// Isian PIN 6 angka dengan papan angka besar (enak untuk tablet kasir).
/// [onCompleted] dipanggil saat angka ke-6 diketik; papan dikosongkan lewat
/// [PinPadController.clear].
class PinPad extends StatefulWidget {
  const PinPad({super.key, required this.onCompleted, this.controller, this.error, this.busy = false, this.label});

  final ValueChanged<String> onCompleted;
  final PinPadController? controller;
  final String? error;
  final bool busy;
  final String? label;

  @override
  State<PinPad> createState() => _PinPadState();
}

class PinPadController extends ChangeNotifier {
  String _value = '';

  String get value => _value;

  void clear() {
    _value = '';
    notifyListeners();
  }
}

class _PinPadState extends State<PinPad> {
  late PinPadController _controller = widget.controller ?? PinPadController();

  @override
  void initState() {
    super.initState();
    _controller.addListener(_changed);
  }

  @override
  void didUpdateWidget(PinPad oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      _controller.removeListener(_changed);
      _controller = widget.controller ?? PinPadController();
      _controller.addListener(_changed);
    }
  }

  @override
  void dispose() {
    _controller.removeListener(_changed);
    super.dispose();
  }

  void _changed() => setState(() {});

  void _tap(String digit) {
    if (widget.busy || _controller._value.length >= PinCode.length) {
      return;
    }
    HapticFeedback.selectionClick();
    _controller._value += digit;
    setState(() {});
    if (_controller._value.length == PinCode.length) {
      widget.onCompleted(_controller._value);
    }
  }

  void _back() {
    if (widget.busy || _controller._value.isEmpty) {
      return;
    }
    _controller._value = _controller._value.substring(0, _controller._value.length - 1);
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final filled = _controller.value.length;
    final error = widget.error;
    Widget key(String label, {VoidCallback? onTap, Widget? child, Key? keyId}) => Padding(
          padding: const EdgeInsets.all(6),
          child: SizedBox(
            width: 76,
            height: 64,
            child: Material(
              color: child == null ? scheme.surfaceContainerHigh : Colors.transparent,
              borderRadius: BorderRadius.circular(16),
              child: InkWell(
                key: keyId,
                borderRadius: BorderRadius.circular(16),
                onTap: onTap,
                child: Center(child: child ?? Text(label, style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w600))),
              ),
            ),
          ),
        );
    return Column(mainAxisSize: MainAxisSize.min, children: [
      if (widget.label != null) ...[
        Text(widget.label!, textAlign: TextAlign.center, style: TextStyle(color: mutedText(context))),
        const SizedBox(height: 12),
      ],
      Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        for (var i = 0; i < PinCode.length; i++)
          AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            margin: const EdgeInsets.symmetric(horizontal: 7),
            width: 16,
            height: 16,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: i < filled ? (error != null ? dangerText(context) : scheme.primary) : Colors.transparent,
              border: Border.all(color: error != null ? dangerText(context) : scheme.outline, width: 2),
            ),
          ),
      ]),
      SizedBox(
        height: 44,
        child: Center(
          child: widget.busy
              ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5))
              : error == null
                  ? null
                  : Text(error, key: const Key('pin-error'), textAlign: TextAlign.center, style: TextStyle(color: dangerText(context), fontWeight: FontWeight.w500)),
        ),
      ),
      for (final row in const [
        ['1', '2', '3'],
        ['4', '5', '6'],
        ['7', '8', '9'],
      ])
        Row(mainAxisSize: MainAxisSize.min, children: [for (final digit in row) key(digit, onTap: () => _tap(digit), keyId: Key('pin-key-$digit'))]),
      Row(mainAxisSize: MainAxisSize.min, children: [
        key('', child: const SizedBox.shrink()),
        key('0', onTap: () => _tap('0'), keyId: const Key('pin-key-0')),
        key('', onTap: _back, keyId: const Key('pin-key-back'), child: Icon(Icons.backspace_outlined, color: scheme.onSurfaceVariant)),
      ]),
    ]);
  }
}
