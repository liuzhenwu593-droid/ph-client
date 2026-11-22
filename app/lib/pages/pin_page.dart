import 'package:flutter/material.dart';

/// 4-digit PIN entry with an on-screen keypad (no system keyboard).
/// Modes:
/// - verify: enter the current PIN once; [onSubmit] returns true when it
///   matches, false to show "PIN 不对".
/// - set: enter a new PIN twice; calls [onSet] once the two entries match.
enum PinMode { verify, set }

class PinScreen extends StatefulWidget {
  const PinScreen({
    super.key,
    required this.mode,
    required this.title,
    this.hint,
    this.onSubmit,
    this.onSet,
  });

  final PinMode mode;
  final String title;
  final String? hint;
  final Future<bool> Function(String pin)? onSubmit;
  final Future<void> Function(String pin)? onSet;

  @override
  State<PinScreen> createState() => _PinScreenState();
}

class _PinScreenState extends State<PinScreen> {
  String _pin = '';
  String? _firstEntry;
  String? _error;
  bool _busy = false;

  bool get _isSecondEntry => widget.mode == PinMode.set && _firstEntry != null;

  Future<void> _press(String digit) async {
    if (_busy || _pin.length >= 4) return;
    setState(() {
      _pin += digit;
      _error = null;
    });
    if (_pin.length < 4) return;
    final pin = _pin;
    if (widget.mode == PinMode.verify) {
      setState(() => _busy = true);
      final ok = await widget.onSubmit!(pin);
      if (!mounted) return;
      setState(() => _busy = false);
      if (ok) {
        Navigator.of(context).pop(true);
      } else {
        setState(() {
          _pin = '';
          _error = 'PIN 不对，请重试';
        });
      }
      return;
    }
    // set mode
    if (_firstEntry == null) {
      setState(() {
        _firstEntry = pin;
        _pin = '';
      });
      return;
    }
    if (pin != _firstEntry) {
      setState(() {
        _firstEntry = null;
        _pin = '';
        _error = '两次输入不一致，请重新设置';
      });
      return;
    }
    setState(() => _busy = true);
    await widget.onSet!(pin);
    if (!mounted) return;
    Navigator.of(context).pop(true);
  }

  void _delete() {
    if (_pin.isEmpty) return;
    setState(() => _pin = _pin.substring(0, _pin.length - 1));
  }

  @override
  Widget build(BuildContext context) {
    final prompt = _isSecondEntry ? '请再输入一次确认' : widget.title;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.mode == PinMode.set ? '设置 PIN' : '输入 PIN'),
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                prompt,
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                ),
              ),
              if (widget.hint != null) ...[
                const SizedBox(height: 8),
                Text(
                  widget.hint!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.grey),
                ),
              ],
              const SizedBox(height: 32),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: List.generate(4, (i) {
                  final filled = i < _pin.length;
                  return Container(
                    width: 18,
                    height: 18,
                    margin: const EdgeInsets.symmetric(horizontal: 10),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: filled ? Colors.white : Colors.transparent,
                      border: Border.all(color: Colors.white70, width: 2),
                    ),
                  );
                }),
              ),
              if (_error != null) ...[
                const SizedBox(height: 16),
                Text(_error!, style: const TextStyle(color: Colors.redAccent)),
              ],
              const SizedBox(height: 32),
              SizedBox(
                width: 264,
                child: GridView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 3,
                    mainAxisSpacing: 12,
                    crossAxisSpacing: 12,
                  ),
                  itemCount: 12,
                  itemBuilder: (context, index) {
                    if (index == 9) return const SizedBox.shrink();
                    if (index == 10) {
                      return _keyButton('0', () => _press('0'));
                    }
                    if (index == 11) {
                      return _keyButton('⌫', _delete);
                    }
                    return _keyButton(
                      '${index + 1}',
                      () => _press('${index + 1}'),
                    );
                  },
                ),
              ),
              if (_busy) ...[
                const SizedBox(height: 16),
                const CircularProgressIndicator(),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _keyButton(String label, VoidCallback onPressed) {
    return FilledButton.tonal(
      onPressed: _busy ? null : onPressed,
      style: FilledButton.styleFrom(
        shape: const CircleBorder(),
        padding: EdgeInsets.zero,
      ),
      child: Text(label, style: const TextStyle(fontSize: 24)),
    );
  }
}
