import 'package:flutter/material.dart';

/// Plain working calculator (v0.2.6 disguise entry).
///
/// It is a real calculator: +, −, ×, ÷, decimals, %, +/−, clear,
/// backspace, and = all compute correctly. Exactly one input opens the
/// real app: the expression `78+13` followed by `=`. Nothing else does —
/// other expressions that happen to equal 91 (e.g. 90+1) just show 91.
///
/// v0.2.9: the big display shows the LIVE result while typing — once
/// the expression is complete and evaluates (e.g. 78+13 shows 91 before
/// = is pressed); while it is incomplete or unevaluable it shows the
/// number being typed. The live result never unlocks anything: only
/// 78+13 followed by = does.
///
/// There is no hint of the trigger anywhere in this UI.
class CalculatorPage extends StatefulWidget {
  const CalculatorPage({super.key, required this.onUnlock});

  /// Called when the user enters 78+13 and presses =.
  final VoidCallback onUnlock;

  @override
  State<CalculatorPage> createState() => _CalculatorPageState();
}

class _CalculatorPageState extends State<CalculatorPage> {
  /// Expression being built, e.g. "12+3.5". Uses × and ÷.
  String _expr = '';
  /// Big display: current entry, or the last result after =.
  String _display = '0';
  /// True right after = : the next digit starts a fresh expression.
  bool _justEvaluated = false;
  /// True when the display shows an error (next key starts over).
  bool _error = false;

  static const _ops = {'+', '−', '×', '÷'};

  void _reset() {
    _expr = '';
    _display = '0';
    _justEvaluated = false;
    _error = false;
  }

  /// Index of the start of the number currently being typed.
  /// A − directly before the number counts as its sign, not an operator.
  /// Pass an expression to find the last number inside that instead.
  int _numberStart([String? expr]) {
    final e = expr ?? _expr;
    var i = e.length;
    while (i > 0 && !_ops.contains(e[i - 1])) {
      i--;
    }
    if (i > 0 &&
        e[i - 1] == '−' &&
        (i - 1 == 0 || _ops.contains(e[i - 2]))) {
      i--;
    }
    return i;
  }

  String get _currentNumber =>
      _expr.isEmpty ? '' : _expr.substring(_numberStart());

  /// Big display text (v0.2.9): live result while typing. When the
  /// expression is complete and evaluates, the big digits show the
  /// running result (typing 78+13 shows 91 before =); when it is
  /// incomplete (e.g. 5×) or unevaluable (e.g. ÷0), they show the last
  /// number entered. After = or an error the stored display is shown.
  String get _displayText {
    if (_error || _justEvaluated) return _display;
    final live = _liveResult();
    if (live != null) return live;
    // Incomplete expression: drop any trailing operator and show the
    // last number entered (e.g. "5" after typing 5×), not a bare 0.
    var expr = _expr;
    while (expr.isNotEmpty && _ops.contains(expr[expr.length - 1])) {
      expr = expr.substring(0, expr.length - 1);
    }
    if (expr.isEmpty) return '0';
    final num = expr.substring(_numberStart(expr));
    return num.isEmpty ? '0' : num;
  }

  /// The live result, or null when there is nothing to show: no
  /// expression, a trailing operator, no binary operator yet (a lone
  /// number or a leading sign), or an unevaluable expression.
  String? _liveResult() {
    if (_expr.isEmpty) return null;
    if (_ops.contains(_expr[_expr.length - 1])) return null;
    var hasOp = false;
    for (var i = 1; i < _expr.length; i++) {
      if (_ops.contains(_expr[i])) {
        hasOp = true;
        break;
      }
    }
    if (!hasOp) return null;
    final value = _evaluate(_expr);
    if (value == null || value.isNaN || value.isInfinite) return null;
    return _format(value);
  }

  void _inputDigit(String d) {
    setState(() {
      if (_error || _justEvaluated) _reset();
      final cur = _currentNumber;
      if (cur == '0') {
        // Replace a bare leading zero instead of building "05".
        _expr = _expr.substring(0, _expr.length - 1) + d;
      } else if (cur == '−0' || cur == '-0') {
        _expr = _expr.substring(0, _expr.length - 1) + d;
      } else {
        _expr += d;
      }
      _display = _currentNumber;
    });
  }

  void _inputDot() {
    setState(() {
      if (_error || _justEvaluated) _reset();
      final cur = _currentNumber;
      if (cur.contains('.')) return;
      if (cur.isEmpty || cur == '−' || cur == '-') {
        _expr += '0.';
      } else {
        _expr += '.';
      }
      _display = _currentNumber;
    });
  }

  void _inputOperator(String op) {
    setState(() {
      if (_error) _reset();
      if (_justEvaluated) {
        // Continue calculating from the shown result.
        _expr = _display;
        _justEvaluated = false;
      }
      if (_expr.isEmpty) {
        // A leading − starts a negative number; other operators do nothing.
        if (op == '−') {
          _expr = '−';
          _display = '−';
        }
        return;
      }
      if (_ops.contains(_expr[_expr.length - 1])) {
        // Replace a dangling operator instead of stacking two.
        _expr = _expr.substring(0, _expr.length - 1) + op;
      } else {
        _expr += op;
      }
      _display = _currentNumber.isEmpty ? '0' : _currentNumber;
    });
  }

  void _toggleSign() {
    setState(() {
      if (_error) _reset();
      if (_justEvaluated) {
        _expr = _display;
        _justEvaluated = false;
      }
      final start = _numberStart();
      final cur = _currentNumber;
      if (cur.isEmpty) return;
      if (cur.startsWith('−')) {
        _expr = '${_expr.substring(0, start)}${cur.substring(1)}';
      } else {
        _expr = '${_expr.substring(0, start)}−$cur';
      }
      _display = _currentNumber;
    });
  }

  void _percent() {
    setState(() {
      if (_error) _reset();
      if (_justEvaluated) {
        _expr = _display;
        _justEvaluated = false;
      }
      final start = _numberStart();
      final cur = _currentNumber;
      final value = double.tryParse(cur.replaceAll('−', '-'));
      if (cur.isEmpty || value == null) return;
      _expr = _expr.substring(0, start) + _format(value / 100);
      _display = _currentNumber;
    });
  }

  void _backspace() {
    setState(() {
      if (_error || _justEvaluated) {
        _reset();
        return;
      }
      if (_expr.isEmpty) return;
      _expr = _expr.substring(0, _expr.length - 1);
      final cur = _currentNumber;
      _display = cur.isEmpty ? '0' : cur;
    });
  }

  void _equals() {
    var expr = _expr;
    while (expr.isNotEmpty && _ops.contains(expr[expr.length - 1])) {
      expr = expr.substring(0, expr.length - 1);
    }
    if (expr.isEmpty) return;
    // The one and only unlock: exactly 78+13 followed by =.
    if (expr == '78+13') {
      widget.onUnlock();
      return;
    }
    final value = _evaluate(expr);
    setState(() {
      if (value == null || value.isNaN || value.isInfinite) {
        _display = '错误';
        _expr = '';
        _error = true;
        _justEvaluated = false;
      } else {
        _display = _format(value);
        _expr = _display;
        _justEvaluated = true;
      }
    });
  }

  /// Evaluate an expression of numbers joined by + − × ÷.
  /// Returns null when it cannot be evaluated (e.g. division by zero).
  static double? _evaluate(String expr) {
    if (expr.isEmpty) return null;
    // Tokenize into numbers and operators.
    final tokens = <String>[];
    var buf = StringBuffer();
    for (var i = 0; i < expr.length; i++) {
      final ch = expr[i];
      if (_ops.contains(ch)) {
        // A − at the start (or right after another operator) is a sign.
        if (ch == '−' && buf.isEmpty && (tokens.isEmpty || _ops.contains(tokens.last))) {
          buf.write('-');
          continue;
        }
        if (buf.isNotEmpty) {
          tokens.add(buf.toString());
          buf.clear();
        }
        tokens.add(ch);
      } else {
        buf.write(ch);
      }
    }
    if (buf.isNotEmpty) tokens.add(buf.toString());
    if (tokens.isEmpty) return null;
    // First pass: × and ÷.
    final values = <double>[];
    final ops = <String>[];
    double? first = double.tryParse(tokens[0]);
    if (first == null) return null;
    values.add(first);
    var i = 1;
    while (i < tokens.length) {
      final op = tokens[i];
      if (i + 1 >= tokens.length) return null;
      final next = double.tryParse(tokens[i + 1]);
      if (next == null) return null;
      if (op == '×' || op == '÷') {
        if (op == '÷' && next == 0) return null;
        values[values.length - 1] =
            op == '×' ? values.last * next : values.last / next;
      } else {
        ops.add(op);
        values.add(next);
      }
      i += 2;
    }
    // Second pass: + and −.
    var result = values[0];
    for (var j = 0; j < ops.length; j++) {
      result = ops[j] == '+' ? result + values[j + 1] : result - values[j + 1];
    }
    return result;
  }

  static String _format(double value) {
    if (value == value.truncateToDouble() && value.abs() < 1e15) {
      return value.truncate().toString();
    }
    var s = value.toStringAsFixed(10);
    while (s.contains('.') && s.endsWith('0')) {
      s = s.substring(0, s.length - 1);
    }
    if (s.endsWith('.')) s = s.substring(0, s.length - 1);
    if (s.length > 14) s = value.toStringAsPrecision(10);
    return s;
  }

  void _press(String label) {
    switch (label) {
      case 'C':
        setState(_reset);
      case '←':
        _backspace();
      case '%':
        _percent();
      case '±':
        _toggleSign();
      case '=':
        _equals();
      case '+':
      case '−':
      case '×':
      case '÷':
        _inputOperator(label);
      case '.':
        _inputDot();
      default:
        _inputDigit(label);
    }
  }

  @override
  Widget build(BuildContext context) {
    const rows = [
      ['C', '←', '%', '÷'],
      ['7', '8', '9', '×'],
      ['4', '5', '6', '−'],
      ['1', '2', '3', '+'],
      ['±', '0', '.', '='],
    ];
    // Compact, stock-calculator layout (v0.2.7): fixed-size keys and a
    // compact display instead of the old full-screen stretched grid.
    // The display flexes to fill the space above the keypad; the keys
    // stay 64dp tall with tight 8dp gaps, and the keypad is capped at
    // 420dp wide so it never stretches edge to edge. Everything fits
    // on one screen with no scrolling. Logic, trigger rule (78+13 + =),
    // and colours are unchanged.
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.fromLTRB(24, 12, 24, 12),
                alignment: Alignment.bottomRight,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      _justEvaluated ? '' : _expr,
                      maxLines: 2,
                      textAlign: TextAlign.right,
                      style: TextStyle(
                        color: Colors.grey.shade400,
                        fontSize: 20,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      _displayText,
                      maxLines: 1,
                      textAlign: TextAlign.right,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 44,
                        fontWeight: FontWeight.w300,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (var i = 0; i < rows.length; i++) ...[
                      if (i > 0) const SizedBox(height: 8),
                      SizedBox(
                        height: 64,
                        child: Row(
                          children: [
                            for (final label in rows[i])
                              Expanded(
                                child: _KeyButton(
                                  label: label,
                                  onPress: _press,
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }
}

class _KeyButton extends StatelessWidget {
  const _KeyButton({required this.label, required this.onPress});

  final String label;
  final void Function(String label) onPress;

  @override
  Widget build(BuildContext context) {
    final isOperator = label == '÷' || label == '×' || label == '−' || label == '+' || label == '=';
    final isFunction = label == 'C' || label == '←' || label == '%' || label == '±';
    final color = isOperator
        ? Colors.orange
        : isFunction
            ? const Color(0xFFA5A5A5)
            : const Color(0xFF333333);
    final textColor = isFunction ? Colors.black : Colors.white;
    return Padding(
      padding: const EdgeInsets.all(4),
      child: FilledButton(
        onPressed: () => onPress(label),
        style: FilledButton.styleFrom(
          backgroundColor: color,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          padding: EdgeInsets.zero,
        ),
        child: Text(
          label,
          style: TextStyle(color: textColor, fontSize: 26),
        ),
      ),
    );
  }
}
