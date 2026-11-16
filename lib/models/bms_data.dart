import 'package:flutter/material.dart';

/// Dados recebidos do JBD BMS via BLE.
class BmsData {
  final double voltage;
  final double current;
  final double soc;
  final List<double> temperatures; // NTC: [BMS, Andar1, Andar2]
  final List<double> cellVoltages;
  final int cycles;
  final double cycleCharge;
  final double designCapacity;

  /// Bitmask de balanceamento: bit N = célula N+1 balanceando.
  final int balanceBitmask;
  final bool chrgMosfet;
  final bool dischrgMosfet;
  final DateTime timestamp;

  BmsData({
    required this.voltage,
    required this.current,
    required this.soc,
    required this.temperatures,
    required this.cellVoltages,
    required this.cycles,
    required this.cycleCharge,
    required this.designCapacity,
    required this.balanceBitmask,
    required this.chrgMosfet,
    required this.dischrgMosfet,
    required this.timestamp,
  });

  /// Balanceador ativo (alguma célula balanceando).
  bool get balancer => balanceBitmask != 0;

  /// Célula específica (índice 0-based) está balanceando.
  bool isCellBalancing(int index) => ((balanceBitmask >> index) & 0x01) == 1;

  double get temperature => temperatures.isEmpty ? 0.0 : temperatures[0];

  double get power => voltage * current.abs();

  double get diffVoltage =>
      cellVoltages.isEmpty ? 0 : _max(cellVoltages) - _min(cellVoltages);

  /// C = carregando, D = descarregando, P = parada
  String get status {
    if (current.abs() < 0.1) return 'P';
    return current > 0 ? 'C' : 'D';
  }

  Color get statusColor {
    switch (status) {
      case 'C':
        return const Color(0xFF3fb950);
      case 'D':
        return const Color(0xFFe94560);
      default:
        return const Color(0xFF8b949e);
    }
  }

  String get statusLabel {
    switch (status) {
      case 'C':
        return 'Carregando';
      case 'D':
        return 'Descarregando';
      default:
        return 'Parada';
    }
  }
}

double _min(List<double> l) => l.reduce((a, b) => a < b ? a : b);
double _max(List<double> l) => l.reduce((a, b) => a > b ? a : b);

/// Parser do protocolo JBD BMS (UART/BLE).
class JbdParser {
  /// Interpreta a resposta do comando 0x03 (basic info).
  static BmsData? parseBasicInfo(List<int> data) {
    if (data.length < 27) return null;

    // Verificação de header/tail
    if (data[0] != 0xDD || data[2] != 0x00) return null;

    final int len = data[3];
    if (data.length < 4 + len + 3) return null;

    // Protocolo JBD BMS 0x03 — offsets a partir do byte 4 (início dos dados)
    // Ref: https://github.com/syssi/esphome-jbd-bms
    int i = 4;
    final voltage  = _u16(data, i) / 100.0; i += 2;  // [4-5]  tensão total (0.01V)
    final currentR = _s16(data, i) / 100.0; i += 2;  // [6-7]  corrente (0.01A, signed)
    final capRem   = _u16(data, i) / 100.0; i += 2;  // [8-9]  cap. restante (0.01Ah)
    final capNom   = _u16(data, i) / 100.0; i += 2;  // [10-11] cap. nominal (0.01Ah)
    final cycles   = _u16(data, i); i += 2;           // [12-13] ciclos
    i += 2;    // [14-15] data de fabricação (2 bytes, não 4!)
    final balanceMask = _u32(data, i); i += 4;       // [16-19] balance bitmask
    i += 2;    // [20-21] protection status
    i++;       // [22]    software version
    final socRaw   = data[i]; i++;                    // [23]    SOC (%)
    final fetStat  = data[i]; i++;                    // [24]    FET status
    i++;       // [25]    número de células
    final nTemps   = data[i]; i++;                    // [26]    número de sensores NTC

    final temps = <double>[];
    for (int t = 0; t < nTemps && i + 1 < data.length; t++) {
      temps.add((_u16(data, i) - 2731) / 10.0);
      i += 2;
    }

    return BmsData(
      voltage:        voltage,
      current:        currentR,
      soc:            socRaw.toDouble(),
      temperatures:   temps,
      cellVoltages:   [],
      cycles:         cycles,
      cycleCharge:    capRem,
      designCapacity: capNom,
      balanceBitmask: balanceMask,
      chrgMosfet:     (fetStat & 0x01) != 0,
      dischrgMosfet:  (fetStat & 0x02) != 0,
      timestamp:      DateTime.now(),
    );
  }

  /// Interpreta a resposta do comando 0x04 (cell voltages).
  static List<double> parseCellVoltages(List<int> data) {
    if (data.length < 6 || data[0] != 0xDD || data[2] != 0x00) return [];
    final int len = data[3];
    final count = len ~/ 2;
    final List<double> result = [];
    for (int i = 0; i < count; i++) {
      final offset = 4 + i * 2;
      if (offset + 1 < data.length) {
        result.add(_u16(data, offset) / 1000.0);
      }
    }
    return result;
  }

  static int _u16(List<int> d, int i) => ((d[i] & 0xFF) << 8) | (d[i + 1] & 0xFF);
  static int _u32(List<int> d, int i) =>
      ((d[i] & 0xFF) << 24) | ((d[i+1] & 0xFF) << 16) |
      ((d[i+2] & 0xFF) << 8) | (d[i+3] & 0xFF);
  static int _s16(List<int> d, int i) {
    int v = _u16(d, i);
    return v >= 0x8000 ? v - 0x10000 : v;
  }
}
