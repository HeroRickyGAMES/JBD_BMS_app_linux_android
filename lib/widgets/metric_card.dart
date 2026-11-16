import 'package:flutter/material.dart';

class MetricCard extends StatelessWidget {
  final String label;
  final String value;
  final String unit;
  final Color  color;

  static const _card   = Color(0xFF161b22);
  static const _border = Color(0xFF30363d);
  static const _sub    = Color(0xFF8b949e);

  const MetricCard({
    super.key,
    required this.label,
    required this.value,
    required this.unit,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 6),
      decoration: BoxDecoration(
        color: _card,
        border: Border.all(color: _border),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label,
              style: const TextStyle(color: _sub, fontSize: 9),
              overflow: TextOverflow.ellipsis),
          const SizedBox(height: 2),
          SizedBox(
            height: 24,
            width: double.infinity,
            child: FittedBox(
              fit: BoxFit.contain,
              child: Text(value,
                  style: TextStyle(
                      color: color,
                      fontSize: 20,
                      fontWeight: FontWeight.bold)),
            ),
          ),
          if (unit.isNotEmpty)
            Text(unit, style: const TextStyle(color: _sub, fontSize: 9)),
        ],
      ),
    );
  }
}
