import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'home_screen.dart';

class DesktopHomeScreen extends StatefulWidget {
  const DesktopHomeScreen({super.key});

  @override
  State<DesktopHomeScreen> createState() => _DesktopHomeScreenState();
}

class _DesktopHomeScreenState extends State<DesktopHomeScreen> {
  static const _primary  = Color(0xFF58a6ff);
  static const _card     = Color(0xFF161b22);
  static const _border   = Color(0xFF30363d);
  static const _subtext  = Color(0xFF8b949e);
  static const _green    = Color(0xFF3fb950);
  static const _bg       = Color(0xFF0d1117);

  final List<ScanResult> _results = [];
  bool _scanning = false;
  StreamSubscription<List<ScanResult>>? _sub;

  BluetoothDevice? _connectedDevice;
  bool _demoMode = false;
  int _refreshKey = 0;

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

  void _connect(BluetoothDevice device) async {
    await FlutterBluePlus.stopScan();
    _sub?.cancel();
    await Future.delayed(const Duration(milliseconds: 500));
    if (!mounted) return;
    setState(() {
      _connectedDevice = device;
      _refreshKey++;
    });
  }

  void _startDemo() {
    FlutterBluePlus.stopScan();
    _sub?.cancel();
    setState(() {
      _scanning = false;
      _demoMode = true;
      _refreshKey++;
    });
  }

  void _disconnect() {
    setState(() {
      _connectedDevice = null;
      _demoMode = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final jbds   = _results.where(_isJbd).toList();
    final others = _results.where((r) => !_isJbd(r)).toList();

    return Scaffold(
      backgroundColor: _bg,
      body: Row(
        children: [
          // ── Left panel: Scan ──────────────────────────────────────────────
          SizedBox(
            width: 380,
            child: Container(
              decoration: BoxDecoration(
                color: _card,
                border: Border(right: BorderSide(color: _border)),
              ),
              child: Column(
                children: [
                  // Header
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                    decoration: BoxDecoration(
                      border: Border(bottom: BorderSide(color: _border)),
                    ),
                    child: Row(
                      children: [
                        const Text('⚡', style: TextStyle(fontSize: 18)),
                        const SizedBox(width: 8),
                        const Expanded(
                          child: Text('JBD BMS Monitor',
                              style: TextStyle(
                                  color: _primary,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 16)),
                        ),
                        if (_connectedDevice != null || _demoMode)
                          IconButton(
                            icon: Icon(_demoMode && _connectedDevice == null
                                ? Icons.stop_circle
                                : Icons.bluetooth_disabled,
                                color: _demoMode && _connectedDevice == null
                                    ? const Color(0xFFbc8cff)
                                    : const Color(0xFFe94560),
                                size: 20),
                            tooltip: _demoMode && _connectedDevice == null
                                ? 'Sair do Modo Demo'
                                : 'Desconectar',
                            onPressed: _disconnect,
                          ),
                      ],
                    ),
                  ),

                  // Scan button
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(
                          width: double.infinity,
                          child: ElevatedButton.icon(
                            onPressed: _scanning ? null : _startScan,
                            icon: _scanning
                                ? const SizedBox(
                                    width: 16, height: 16,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2, color: Colors.white))
                                : const Icon(Icons.bluetooth_searching, size: 18),
                            label: Text(_scanning
                                ? 'Escaneando... (10s)'
                                : 'Escanear Bluetooth BLE'),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: _primary,
                              foregroundColor: Colors.black,
                              padding: const EdgeInsets.symmetric(vertical: 12),
                              shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(8)),
                            ),
                          ),
                        ),
                        const SizedBox(height: 8),
                        SizedBox(
                          width: double.infinity,
                          child: OutlinedButton.icon(
                            onPressed: _scanning ? null : _startDemo,
                            icon: const Icon(Icons.science, size: 18),
                            label: const Text('Modo Demo'),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: const Color(0xFFbc8cff),
                              side: BorderSide(
                                  color: const Color(0xFFbc8cff)
                                      .withAlpha(_demoMode ? 255 : 120)),
                              padding:
                                  const EdgeInsets.symmetric(vertical: 12),
                              shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(8)),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),

                  // Device list
                  Expanded(
                    child: _results.isEmpty && !_scanning
                        ? Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.bluetooth_disabled, size: 48, color: _subtext),
                                const SizedBox(height: 8),
                                Text('Nenhum dispositivo encontrado.',
                                    style: TextStyle(color: _subtext, fontSize: 13)),
                                const SizedBox(height: 4),
                                Text('Pressione Escanear para buscar.',
                                    style: TextStyle(color: _subtext.withAlpha(150), fontSize: 11)),
                              ],
                            ),
                          )
                        : ListView(
                            padding: const EdgeInsets.symmetric(horizontal: 10),
                            children: [
                              if (jbds.isNotEmpty) ...[
                                _sectionHeader('⚡ BMS Compatíveis', _green),
                                ...jbds.map((r) => _DeviceTile(
                                      result: r,
                                      highlight: true,
                                      selected: _connectedDevice?.remoteId == r.device.remoteId,
                                      onTap: () => _connect(r.device),
                                    )),
                                const SizedBox(height: 8),
                              ],
                              if (others.isNotEmpty) ...[
                                _sectionHeader('Outros dispositivos', _subtext),
                                ...others.map((r) => _DeviceTile(
                                      result: r,
                                      highlight: false,
                                      selected: false,
                                      onTap: () => _connect(r.device),
                                    )),
                              ],
                              const SizedBox(height: 16),
                            ],
                          ),
                  ),
                ],
              ),
            ),
          ),

          // ── Right panel: Dashboard ────────────────────────────────────────
          Expanded(
            child: _connectedDevice != null
                ? HomeScreen(
                    key: ValueKey('home_$_refreshKey'),
                    device: _connectedDevice!,
                    embedded: true,
                  )
                : _demoMode
                    ? HomeScreen(
                        key: const ValueKey('home_demo'),
                        demoMode: true,
                        embedded: true,
                      )
                    : _buildPlaceholder(),
          ),
        ],
      ),
    );
  }

  Widget _buildPlaceholder() {
    return Container(
      color: _bg,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.bluetooth_searching, size: 80, color: _subtext.withAlpha(80)),
            const SizedBox(height: 16),
            Text('JBD BMS Monitor',
                style: TextStyle(
                    color: _primary,
                    fontSize: 22,
                    fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Text('Selecione um dispositivo BMS na barra lateral',
                style: TextStyle(color: _subtext.withAlpha(150), fontSize: 13)),
          ],
        ),
      ),
    );
  }

  Widget _sectionHeader(String text, Color color) {
    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 6, left: 4),
      child: Text(text,
          style: TextStyle(
              color: color, fontSize: 11, fontWeight: FontWeight.bold)),
    );
  }
}

class _DeviceTile extends StatelessWidget {
  final ScanResult result;
  final bool highlight;
  final bool selected;
  final VoidCallback onTap;

  static const _card    = Color(0xFF161b22);
  static const _card2   = Color(0xFF1f2937);
  static const _border  = Color(0xFF30363d);
  static const _green   = Color(0xFF3fb950);
  static const _subtext = Color(0xFF8b949e);

  const _DeviceTile({
    required this.result,
    required this.highlight,
    required this.selected,
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
        margin: const EdgeInsets.only(bottom: 4),
        decoration: BoxDecoration(
          color: selected ? _green.withAlpha(20)
              : highlight ? _card2 : _card,
          border: Border.all(
              color: selected ? _green
                  : highlight ? _green.withAlpha(100) : _border,
              width: selected ? 1.5 : 1),
          borderRadius: BorderRadius.circular(8),
        ),
        child: ListTile(
          dense: true,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
          leading: Icon(
            highlight ? Icons.bolt : Icons.bluetooth,
            color: selected ? _green
                : highlight ? _green : _subtext,
            size: 22,
          ),
          title: Text(name,
              style: TextStyle(
                  color: selected ? _green
                      : highlight ? _green : Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 13)),
          subtitle: Text(addr,
              style: TextStyle(color: _subtext, fontSize: 10)),
          trailing: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(_rssiBar(rssi),
                  style: TextStyle(
                      color: highlight ? _green : _subtext, fontSize: 9)),
              Text('$rssi dBm',
                  style: TextStyle(color: _subtext, fontSize: 9)),
            ],
          ),
        ),
      ),
    );
  }
}
