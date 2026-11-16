import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'home_screen.dart';

class ScanScreen extends StatefulWidget {
  const ScanScreen({super.key});

  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen> {
  static const _primary  = Color(0xFF58a6ff);
  static const _card     = Color(0xFF161b22);
  static const _border   = Color(0xFF30363d);
  static const _subtext  = Color(0xFF8b949e);
  static const _green    = Color(0xFF3fb950);
  static const _bg       = Color(0xFF0d1117);

  final List<ScanResult> _results = [];
  bool _scanning = false;
  StreamSubscription<List<ScanResult>>? _sub;

  @override
  void dispose() {
    _sub?.cancel();
    FlutterBluePlus.stopScan();
    super.dispose();
  }

  Future<void> _requestPermissions() async {
    if (!(Platform.isAndroid || Platform.isIOS)) return;
    await [
      Permission.bluetooth,
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.locationWhenInUse,
    ].request();
  }

  Future<void> _enableBluetooth() async {
    if (!(Platform.isAndroid || Platform.isIOS)) return;
    final state = await FlutterBluePlus.adapterState.first;
    if (state != BluetoothAdapterState.on) {
      await FlutterBluePlus.turnOn();
      await Future.delayed(const Duration(milliseconds: 800));
    }
  }

  Future<void> _startScan() async {
    await _requestPermissions();
    await _enableBluetooth();

    setState(() {
      _results.clear();
      _scanning = true;
    });

    _sub = FlutterBluePlus.scanResults.listen((results) {
      setState(() {
        for (final r in results) {
          final idx = _results.indexWhere(
              (x) => x.device.remoteId == r.device.remoteId);
          if (idx >= 0) {
            _results[idx] = r;
          } else {
            _results.add(r);
          }
        }
        _results.sort((a, b) => (b.rssi).compareTo(a.rssi));
      });
    });

    await FlutterBluePlus.startScan(timeout: const Duration(seconds: 10));
    setState(() => _scanning = false);
  }

  bool _isJbd(ScanResult r) {
    final name = r.device.platformName.toUpperCase();
    return name.startsWith('JBD') ||
        name.startsWith('LSG') ||
        name.startsWith('SX1') ||
        name.startsWith('SBL') ||
        name.startsWith('DWF') ||
        r.advertisementData.serviceUuids.any(
            (u) => u.toString().contains('ff00'));
  }

  @override
  Widget build(BuildContext context) {
    final jbds  = _results.where(_isJbd).toList();
    final others = _results.where((r) => !_isJbd(r)).toList();

    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: _card,
        title: const Row(
          children: [
            Text('⚡', style: TextStyle(fontSize: 20)),
            SizedBox(width: 8),
            Text('JBD BMS Monitor',
                style: TextStyle(
                    color: _primary,
                    fontWeight: FontWeight.bold,
                    fontSize: 18)),
          ],
        ),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(height: 1, color: _border),
        ),
      ),
      body: Column(
        children: [
          // Botão de scan
          Padding(
            padding: const EdgeInsets.all(16),
            child: SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _scanning ? null : _startScan,
                icon: _scanning
                    ? const SizedBox(
                        width: 18, height: 18,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.bluetooth_searching),
                label: Text(_scanning
                    ? 'Escaneando... (aguarde 10s)'
                    : 'Escanear Bluetooth BLE'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: _primary,
                  foregroundColor: Colors.black,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10)),
                ),
              ),
            ),
          ),

          if (_results.isEmpty && !_scanning)
            Expanded(
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.bluetooth_disabled, size: 64, color: _subtext),
                    const SizedBox(height: 12),
                    Text('Nenhum dispositivo encontrado.',
                        style: TextStyle(color: _subtext, fontSize: 14)),
                    const SizedBox(height: 4),
                    Text('Pressione Escanear para buscar.',
                        style: TextStyle(color: _subtext.withAlpha(150), fontSize: 12)),
                  ],
                ),
              ),
            ),

          if (_results.isNotEmpty)
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                children: [
                  if (jbds.isNotEmpty) ...[
                    _sectionHeader('⚡ BMS Compatíveis', _green),
                    ...jbds.map((r) => _DeviceTile(
                          result: r,
                          highlight: true,
                          onTap: () => _connect(r.device),
                        )),
                    const SizedBox(height: 8),
                  ],
                  if (others.isNotEmpty) ...[
                    _sectionHeader('Outros dispositivos', _subtext),
                    ...others.map((r) => _DeviceTile(
                          result: r,
                          highlight: false,
                          onTap: () => _connect(r.device),
                        )),
                  ],
                  const SizedBox(height: 16),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _sectionHeader(String text, Color color) {
    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 6, left: 4),
      child: Text(text,
          style: TextStyle(
              color: color, fontSize: 12, fontWeight: FontWeight.bold)),
    );
  }

  void _connect(BluetoothDevice device) {
    FlutterBluePlus.stopScan();
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => HomeScreen(device: device)),
    );
  }
}

class _DeviceTile extends StatelessWidget {
  final ScanResult result;
  final bool highlight;
  final VoidCallback onTap;

  static const _card    = Color(0xFF161b22);
  static const _card2   = Color(0xFF1f2937);
  static const _border  = Color(0xFF30363d);
  static const _green   = Color(0xFF3fb950);
  static const _subtext = Color(0xFF8b949e);
  static const _primary = Color(0xFF58a6ff);

  const _DeviceTile({
    required this.result,
    required this.highlight,
    required this.onTap,
  });

  String _rssiBar(int rssi) {
    if (rssi >= -50) return '▰▰▰▰▰';
    if (rssi >= -65) return '▰▰▰▰▱';
    if (rssi >= -75) return '▰▰▰▱▱';
    if (rssi >= -85) return '▰▰▱▱▱';
    return '▰▱▱▱▱';
  }

  @override
  Widget build(BuildContext context) {
    final name = result.device.platformName.isEmpty
        ? 'Sem nome'
        : result.device.platformName;
    final addr = result.device.remoteId.toString();
    final rssi = result.rssi;

    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: 6),
        decoration: BoxDecoration(
          color: highlight ? _card2 : _card,
          border: Border.all(
              color: highlight ? _green.withAlpha(100) : _border, width: 1),
          borderRadius: BorderRadius.circular(10),
        ),
        child: ListTile(
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
          leading: Icon(
            highlight ? Icons.bolt : Icons.bluetooth,
            color: highlight ? _green : _subtext,
            size: 28,
          ),
          title: Text(name,
              style: TextStyle(
                  color: highlight ? _green : Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 14)),
          subtitle: Text(addr,
              style: TextStyle(color: _subtext, fontSize: 11)),
          trailing: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(_rssiBar(rssi),
                  style: TextStyle(
                      color: highlight ? _green : _subtext, fontSize: 10)),
              Text('$rssi dBm',
                  style: TextStyle(color: _subtext, fontSize: 10)),
            ],
          ),
        ),
      ),
    );
  }
}
