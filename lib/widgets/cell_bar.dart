import 'package:flutter/material.dart';

class CellBar extends StatelessWidget {
  final int   index;
  final double voltage;
  final double percent;   // 0.0 – 1.0
  final Color  color;
  final double? width;
  final bool  balancing;

  static const _card    = Color(0xFF161b22);
  static const _border  = Color(0xFF30363d);
  static const _bg      = Color(0xFF0d1117);
  static const _sub     = Color(0xFF8b949e);
  static const _yellow  = Color(0xFFd29922);

  const CellBar({
    super.key,
    required this.index,
    required this.voltage,
    required this.percent,
    required this.color,
    this.width,
    this.balancing = false,
  });

  @override
  Widget build(BuildContext context) {
    final label = 'C${(index + 1).toString().padLeft(2, '0')}';
    final barWidth = width ?? (MediaQuery.of(context).size.width - 24) / 2 - 4;

    return SizedBox(
      width: barWidth,
      child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: _card,
        border: Border.all(color: _border),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Text(label,
              style: const TextStyle(
                  color: _sub, fontSize: 10, fontWeight: FontWeight.bold)),
          if (balancing) ...[
            const SizedBox(width: 4),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 1),
              decoration: BoxDecoration(
                color: _yellow,
                borderRadius: BorderRadius.circular(3),
              ),
              child: const Text('B',
                  style: TextStyle(
                      color: Colors.black,
                      fontSize: 8,
                      fontWeight: FontWeight.bold)),
            ),
          ],
          const SizedBox(width: 6),
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: Stack(
                children: [
                  Container(height: 10, color: _bg),
                  FractionallySizedBox(
                    widthFactor: percent.clamp(0.01, 1.0),
                    child: Container(
                        height: 10,
                        decoration: BoxDecoration(
                          color: color,
                          borderRadius: BorderRadius.circular(4),
                        )),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 6),
          Text('${voltage.toStringAsFixed(2)}V',
              style: TextStyle(
                  color: color,
                  fontSize: 10,
                  fontWeight: FontWeight.bold)),
        ],
      ),
    ),
    );
  }
}
