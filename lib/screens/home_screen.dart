import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:jbd_bms_android/services/pipHeartbeat.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import '../models/bms_data.dart';
import '../services/bms_ble_service.dart';
import '../services/foreground_task_handler.dart';
import '../widgets/metric_card.dart';
import '../widgets/cell_bar.dart';
import 'scan_screen.dart';

bool isInPIP = false;

Future<String?> _linuxSaveDialog(String filename) async {
  if (!Platform.isLinux) return null;
  try {
    final result = await Process.run('zenity', [
      '--file-save',
      '--confirm-overwrite',
      '--filename=$filename',
      '--title=Salvar log BMS',
    ], environment: {...Platform.environment, 'LC_ALL': 'pt_BR.UTF-8'});
    if (result.exitCode == 0) {
      return (result.stdout as String).trim();
    }
  } catch (_) {}
  final home = Platform.environment['HOME'] ?? '/tmp';
  final dir = Directory('$home/Documents/JBD_BMS_Logs');
  if (!dir.existsSync()) dir.createSync(recursive: true);
  return '${dir.path}/$filename';
}

class HomeScreen extends StatefulWidget {
  final BluetoothDevice? device;
  final bool embedded;
  final bool demoMode;
  const HomeScreen({super.key, this.device, this.embedded = false, this.demoMode = false});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with SingleTickerProviderStateMixin {
  // ── Cores ──────────────────────────────────────────────────────────────────
  static const _bg      = Color(0xFF0d1117);
  static const _card    = Color(0xFF161b22);
  // ignore: unused_field
  static const _card2   = Color(0xFF1f2937);
  static const _border  = Color(0xFF30363d);
  static const _blue    = Color(0xFF58a6ff);
  static const _green   = Color(0xFF3fb950);
  static const _yellow  = Color(0xFFd29922);
  static const _orange  = Color(0xFFf0883e);
  static const _subtext = Color(0xFF8b949e);
  static const _red     = Color(0xFFe94560);

  final BmsBleService _ble = BmsBleService();
  BmsData? _data;
  BmsConnectionState _connState = BmsConnectionState.disconnected;

  // Histórico de gráficos
  final _vHist   = <FlSpot>[];
  final _iHist   = <FlSpot>[];
  final _socHist = <FlSpot>[];
  final _capHist = <FlSpot>[];
  double _t0 = 0;

  // Histórico por célula: índice → lista de (ts, tensão, diffVoltage)
  final Map<int, List<({String ts, double v, double diff})>> _cellHist = {};

  // Limite de amostras por célula. Alto o bastante para não truncar sessões
  // longas — é apenas uma rede de segurança, igual ao polling que nunca para.
  static const _maxCellSamples = 100000;

  // Voltage sag tracking
  double? _lastRestingVolt;

  // Log
  final List<String> _log = [];
  final _logCtrl = ScrollController();

  late TabController _tabCtrl;

  StreamSubscription<BmsData>?            _dataSub;
  StreamSubscription<BmsConnectionState>? _stateSub;
  StreamSubscription<String>?             _logSub;
  Timer? _demoTimer;

  @override
  void initState() {
    super.initState();
    _tabCtrl = TabController(length: 2, vsync: this);
    _t0 = DateTime.now().millisecondsSinceEpoch / 1000.0;

    if (widget.demoMode) {
      _startDemoMode();
    } else {
      _dataSub = _ble.dataStream.listen(_onData);
      _stateSub = _ble.stateStream.listen((s) {
        setState(() => _connState = s);
        if (s == BmsConnectionState.connected) {
          if (Platform.isAndroid || Platform.isIOS) _startForegroundService();
        } else if (s == BmsConnectionState.disconnected ||
            s == BmsConnectionState.error) {
          if (Platform.isAndroid || Platform.isIOS) _stopForegroundService();
        }
      });
      _logSub = _ble.logStream.listen((msg) {
        setState(() => _log.add(msg));
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_logCtrl.hasClients) {
            _logCtrl.animateTo(_logCtrl.position.maxScrollExtent,
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeOut);
          }
        });
      });
      _ble.connect(widget.device!);
      AutoPip(setState((){}));
    }
  }

  int _demoTick = 0;
  void _startDemoMode() {
    _connState = BmsConnectionState.connected;
    _demoTimer = Timer.periodic(const Duration(seconds: 3), (_) => _emitDemoData());
    _emitDemoData();
    _log.add('[Demo] Modo demonstração ativado — dados simulados.');
  }

  void _emitDemoData() {
    _demoTick++;
    final t = _demoTick * 0.1;
    final baseVoltage = 51.2 + (t * 0.3 % 2.0) - 1.0;
    final current = -2.5 + (t * 0.7 % 3.0);
    final soc = (65.0 + (t * 0.5 % 30.0)).clamp(0.0, 100.0);
    final temp = 28.0 + (t * 0.2 % 8.0);
    final cells = List.generate(16, (i) {
      final base = 3.20 + (i * 0.02);
      final variation = (t * 0.1 % 0.05) - 0.025;
      return base + variation;
    });
    final balStart = _demoTick % 16;
    final d = BmsData(
      voltage: baseVoltage,
      current: current,
      soc: soc,
      temperatures: [temp, temp - 3.2, temp - 5.8],
      cellVoltages: cells,
      cycles: 142 + (_demoTick % 10),
      cycleCharge: 45.5 + (t * 0.1 % 10.0),
      designCapacity: 100.0,
      balanceBitmask: _demoTick % 20 < 12
          ? ((1 << balStart) |
             (1 << ((balStart + 1) % 16)) |
             (1 << ((balStart + 2) % 16)))
          : 0,
      chrgMosfet: true,
      dischrgMosfet: current < 0,
      timestamp: DateTime.now(),
    );
    _onData(d);
  }

  @override
  void dispose() {
    _demoTimer?.cancel();
    _dataSub?.cancel();
    _stateSub?.cancel();
    _logSub?.cancel();
    if (!widget.demoMode) _ble.dispose();
    _tabCtrl.dispose();
    _logCtrl.dispose();
    super.dispose();
  }

  void _onData(BmsData d) {
    _ble.lastChrg = d.chrgMosfet;
    _ble.lastDsg  = d.dischrgMosfet;
    final now = DateTime.now().millisecondsSinceEpoch / 1000.0 - _t0;
    setState(() {
      _data = d;
      const maxPts = 80;
      void _add(List<FlSpot> list, double y) {
        list.add(FlSpot(now, y));
        if (list.length > maxPts) list.removeAt(0);
      }
      _add(_vHist,   d.voltage);
      _add(_iHist,   d.current);
      _add(_socHist, d.soc);
      _add(_capHist, d.cycleCharge);

      final ts      = _tsNow();
      final _cvs    = d.cellVoltages;
      final _cspan  = _cvs.isNotEmpty
          ? _cvs.reduce(max) - _cvs.reduce(min)
          : 0.0;
      for (int i = 0; i < _cvs.length; i++) {
        _cellHist.putIfAbsent(i, () => []);
        _cellHist[i]!.add((ts: ts, v: _cvs[i], diff: _cspan));
        if (_cellHist[i]!.length > _maxCellSamples) _cellHist[i]!.removeAt(0);
      }

      // Voltage sag
      String sagStr = '';
      if (d.current.abs() < 0.5) {
        _lastRestingVolt = d.voltage;
      } else if (d.current < -2.0 && _lastRestingVolt != null) {
        final sag = _lastRestingVolt! - d.voltage;
        if (sag > 0.05) sagStr = '  DropV=${sag.toStringAsFixed(2)}V';
      }

      final tempStr = d.temperatures.isEmpty
          ? '—'
          : d.temperatures.map((t) => t.toStringAsFixed(1)).join('/');

      final cap = d.cycleCharge;
      final power = d.power;
      final balStr = 'Bal=${d.balancer ? 'ON' : 'OFF'}';
      _log.add(
        '[${_tsNow()}]  '
        'V=${d.voltage.toStringAsFixed(3)}V  '
        'A=${d.current == 0 ? '0.00' : (d.current > 0 ? '+' : '') + d.current.toStringAsFixed(2)}  '
        'P=${power.toStringAsFixed(0)}W  '
        'Porcentagem=${d.soc.toStringAsFixed(1)}%  '
        'Status=${d.statusLabel}  '
        'T=$tempStr°C  '
        'Cap=${cap.toStringAsFixed(1)}/${d.designCapacity.toStringAsFixed(1)}Ah  '
        'DiffV=${_cspan.toStringAsFixed(3)}V  '
        '$balStr$sagStr',
      );
    });
  }

  String _tsNow() {
    final n = DateTime.now();
    return '${n.hour.toString().padLeft(2,'0')}:'
           '${n.minute.toString().padLeft(2,'0')}:'
           '${n.second.toString().padLeft(2,'0')}';
  }

  Future<void> _startForegroundService() async {
    if (!(Platform.isAndroid || Platform.isIOS)) return;
    final deviceName = widget.device?.platformName.isNotEmpty == true
        ? widget.device!.platformName
        : 'BMS';
    if (await FlutterForegroundTask.isRunningService) {
      await FlutterForegroundTask.updateService(
        notificationTitle: 'JBD BMS Monitor',
        notificationText: 'Conectado a $deviceName — Gravando dados...',
      );
    } else {
      await FlutterForegroundTask.startService(
        serviceId: 256,
        notificationTitle: 'JBD BMS Monitor',
        notificationText: 'Conectado a $deviceName — Gravando dados...',
        callback: startCallback,
      );
    }
  }

  Future<void> _stopForegroundService() async {
    if (!(Platform.isAndroid || Platform.isIOS)) return;
    if (await FlutterForegroundTask.isRunningService) {
      await FlutterForegroundTask.stopService();
    }
  }

  // ── Build ──────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final body = Column(
      children: [
        _statusBar(),
        TabBar(
          controller: _tabCtrl,
          tabs: const [
            Tab(text: 'Dashboard + Células'),
            Tab(text: 'Log'),
          ],
          labelColor: _blue,
          unselectedLabelColor: _subtext,
          indicatorColor: _blue,
          dividerColor: _border,
        ),
        Expanded(
          child: TabBarView(
            controller: _tabCtrl,
            children: [
              _buildDashboard(),
              _buildLog(),
            ],
          ),
        ),
      ],
    );

    if (widget.embedded) return body;

    return Scaffold(
      backgroundColor: _bg,
      appBar: isInPIP == false ? _buildAppBar() : null,
      body: body,
    );
  }

  AppBar _buildAppBar() {
    return AppBar(
      backgroundColor: _card,
      title: const Row(
        children: [
          Text('⚡', style: TextStyle(fontSize: 18)),
          SizedBox(width: 6),
          Text('JBD BMS Monitor',
              style: TextStyle(
                  color: _blue, fontWeight: FontWeight.bold, fontSize: 16)),
        ],
      ),
      actions: [
        IconButton(
          icon: const Icon(Icons.settings, color: _subtext),
          tooltip: 'Controle MOSFET',
          onPressed: _showMosfetDialog,
        ),
        IconButton(
          icon: const Icon(Icons.bluetooth_disabled, color: _red),
          tooltip: 'Desconectar',
          onPressed: () async {
            if (Platform.isAndroid || Platform.isIOS) await _stopForegroundService();
            await _ble.disconnect();
            if (mounted) {
              Navigator.of(context).pushReplacement(
                  MaterialPageRoute(builder: (_) => const ScanScreen()));
            }
          },
        ),
      ],
      bottom: PreferredSize(
        preferredSize: const Size.fromHeight(1),
        child: Container(height: 1, color: _border),
      ),
    );
  }

  void _showMosfetDialog() {
    bool chrg = _data?.chrgMosfet    ?? true;
    bool dsg  = _data?.dischrgMosfet ?? true;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          backgroundColor: const Color(0xFF161b22),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          title: const Row(
            children: [
              Icon(Icons.settings, color: _blue, size: 20),
              SizedBox(width: 8),
              Text('Configurações diversas',
                  style: TextStyle(color: Colors.white, fontSize: 16)),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Divider(color: Color(0xFF30363d), height: 8),
              Center(
                child: Text("Mosfets:"),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('MOSFET Carga',
                    style: TextStyle(color: Colors.white, fontSize: 14)),
                subtitle: Text(
                  chrg ? 'Ativado' : 'Desativado',
                  style: TextStyle(
                      color: chrg ? _green : _red, fontSize: 12),
                ),
                value: chrg,
                activeColor: _green,
                onChanged: (v) {
                  setS(() => chrg = v);
                  _ble.writeChrg(v);
                },
              ),
              const Divider(color: Color(0xFF30363d), height: 8),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('MOSFET Descarga',
                    style: TextStyle(color: Colors.white, fontSize: 14)),
                subtitle: Text(
                  dsg ? 'Ativado' : 'Desativado',
                  style: TextStyle(
                      color: dsg ? _green : _red, fontSize: 12),
                ),
                value: dsg,
                activeColor: _green,
                onChanged: (v) {
                  setS(() => dsg = v);
                  _ble.writeDsg(v);
                },
              ),
              const Divider(color: Color(0xFF30363d), height: 16),
              Center(
                child: Text("Regulagem de porcentagem:"),
              ),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.battery_full,
                      color: _green, size: 18),
                  label: const Text('Regular Porcentagem',
                      style: TextStyle(color: _green, fontSize: 13)),
                  style: OutlinedButton.styleFrom(
                    side: const BorderSide(color: _green),
                    padding: const EdgeInsets.symmetric(vertical: 10),
                  ),
                  onPressed: () {
                    setS(() => Navigator.pop(ctx));
                    _confirmCalibrateSoc();
                  },
                ),
              ),
              const SizedBox(height: 4),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.pop(ctx);
                _showRawDialog();
              },
              child: const Text('Cmd BLE Manual',
                  style: TextStyle(color: _orange)),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Fechar',
                  style: TextStyle(color: _blue)),
            ),
          ],
        ),
      ),
    );
  }

  void _confirmCalibrateSoc() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF161b22),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: const Row(
          children: [
            Icon(Icons.battery_full, color: _green, size: 20),
            SizedBox(width: 8),
            Text('Regular Porcentagem',
                style: TextStyle(color: Colors.white, fontSize: 16)),
          ],
        ),
        content: const Text(
          'Isso recalibra o contador do BMS e define a carga como 100%.\n\n'
          'Use apenas quando a bateria estiver REALMENTE cheia '
          '(ex.: carregou até o fim mas aparece 94%).',
          style: TextStyle(color: _subtext, fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child:
                const Text('Cancelar', style: TextStyle(color: _subtext)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: _green),
            onPressed: () {
              Navigator.pop(ctx);
              _ble.calibrateSocTo100();
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Comando enviado — porcentagem regulada para 100%.'),
                  duration: Duration(seconds: 3),
                ),
              );
            },
            child: const Text('Regular para 100%',
                style: TextStyle(color: Colors.black)),
          ),
        ],
      ),
    );
  }

  void _showRawDialog() {
    final ctrl = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF161b22),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        title: const Text('Comando BLE Manual',
            style: TextStyle(color: Colors.white, fontSize: 15)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Digite bytes em hex (ex: FF AA EA 02 01 00 ED)',
              style: TextStyle(color: Color(0xFF8b949e), fontSize: 11),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: ctrl,
              style: const TextStyle(color: Colors.white, fontFamily: 'monospace'),
              decoration: InputDecoration(
                hintText: 'FF AA EA 02 01 00 ED',
                hintStyle: const TextStyle(color: Color(0xFF8b949e)),
                filled: true,
                fillColor: const Color(0xFF0d1117),
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: const BorderSide(color: Color(0xFF30363d))),
                enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: const BorderSide(color: Color(0xFF30363d))),
              ),
              textCapitalization: TextCapitalization.characters,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancelar',
                style: TextStyle(color: Color(0xFF8b949e))),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: _orange),
            onPressed: () {
              final hex = ctrl.text.trim();
              if (hex.isNotEmpty) {
                _ble.sendRaw(hex);
                Navigator.pop(ctx);
              }
            },
            child: const Text('Enviar', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  Widget _statusBar() {
    Color c;
    String msg;
    if (widget.demoMode) {
      c = const Color(0xFFbc8cff);
      msg = 'Modo Demo — Dados Simulados';
    } else {
      switch (_connState) {
        case BmsConnectionState.connected:
          c = _green; msg = 'Conectado: ${widget.device!.platformName}'; break;
        case BmsConnectionState.connecting:
          c = _yellow; msg = 'Conectando...'; break;
        case BmsConnectionState.error:
          c = _red; msg = 'Erro de conexão'; break;
        default:
          c = _subtext; msg = 'Desconectado'; break;
      }
    }
    return Container(
      width: double.infinity,
      color: _card,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      child: Row(
        children: [
          Expanded(child: Text(msg, style: TextStyle(color: c, fontSize: 12))),
          if (widget.embedded)
            IconButton(
              icon: const Icon(Icons.settings, color: _subtext, size: 18),
              tooltip: 'Controle MOSFET',
              onPressed: _showMosfetDialog,
            ),
        ],
      ),
    );
  }

  // ── Dashboard ──────────────────────────────────────────────────────────────
  Widget _buildDashboard() {
    final d = _data;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(10),
      child: Column(
        children: [
          // Cards — grade uniforme e simétrica
          _metricGrid(d),

          // Mini card de carga com tempo estimado
          if (_chargeEta(d) != null) ...[
            const SizedBox(height: 8),
            _chargingBanner(_chargeEta(d)!),
          ],

          const SizedBox(height: 10),

          // Gráficos
          if (widget.embedded)
            Column(
              children: [
                Row(
                  children: [
                    Expanded(child: _chartCard('Tensão (V)', _vHist, _blue, 'V', null)),
                    const SizedBox(width: 8),
                    Expanded(child: _chartCard('Corrente (A)', _iHist, _yellow, 'A', null)),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    if(d?.status == "C") Expanded(child: _chartCard('Porcentagem (%)', _socHist, _green, '%', const [0, 100])),
                    const SizedBox(width: 8),
                    //Expanded(child: _chartCard('Cap. Rest. (Ah)', _capHist, const Color(0xFFbc8cff), 'Ah', null)),
                  ],
                ),
              ],
            )
          else ...[
            _chartCard('Tensão (V)',   _vHist,   _blue,   'V',  null),
            const SizedBox(height: 8),
            _chartCard('Corrente (A)', _iHist,   _yellow, 'A',  null),
            const SizedBox(height: 8),
            _chartCard('Porcentagem (%)', _socHist, _green,  '%',  const [0, 100]),
            const SizedBox(height: 8),
            _chartCard('Cap. Rest. (Ah)', _capHist, const Color(0xFFbc8cff), 'Ah', null),
          ],

          const SizedBox(height: 10),
          const Divider(color: Color(0xFF30363d)),
          const SizedBox(height: 4),

          // Células
          _buildCells(d),
        ],
      ),
    );
  }

  String _tempStr(List<double> temps, int idx) =>
      idx < temps.length ? temps[idx].toStringAsFixed(1) : '—';

  /// Tempo estimado até 100% durante a carga.
  /// Retorna null quando não está carregando ou já está cheia.
  String? _chargeEta(BmsData? d) {
    if (d == null || d.current <= 0.1) return null;
    if (d.designCapacity <= 0) return null;
    final rem = d.designCapacity - d.cycleCharge;
    if (rem <= 0 || rem < d.designCapacity * 0.005) return null;
    final h = rem / d.current;
    if (h >= 100) return '>99h';
    int hh = h.floor();
    int mm = ((h - hh) * 60).round();
    if (mm >= 60) { hh++; mm = 0; }
    return '${hh}h ${mm.toString().padLeft(2, '0')}m';
  }

  /// Mini card de carga em andamento com tempo estimado.
  Widget _chargingBanner(String eta) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: _card,
        border: Border.all(color: _green.withAlpha(120)),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          const Icon(Icons.bolt, color: _green, size: 20),
          const SizedBox(width: 8),
          const Text('Carregando',
              style: TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.bold)),
          const Spacer(),
          Text('Tempo estimado: $eta',
              style: const TextStyle(color: _green, fontSize: 13)),
        ],
      ),
    );
  }

  Widget _metricGrid(BmsData? d) {
    final cards = <MetricCard>[
      if((d?.soc ?? 0) < 25 || d?.status == "C") MetricCard(label: 'Porcentagem', value: d == null ? '—' : d.soc.toStringAsFixed(1), unit: '%', color: (d?.soc ?? 0) < 25 ? _red : _green),
      MetricCard(label: 'Tensão',      value: d == null ? '—' : d.voltage.toStringAsFixed(2), unit: 'V', color: _blue),
      MetricCard(label: 'Corrente',    value: d == null ? '—' : d.current.toStringAsFixed(2), unit: 'A', color: _yellow),
      MetricCard(label: 'Potência',    value: d == null ? '—' : d.power.toStringAsFixed(1),   unit: 'W', color: _orange),
      MetricCard(label: 'Status',      value: d?.status ?? '—', unit: '', color: d?.statusColor ?? _subtext),
      if(d?.status == "C") MetricCard(label: 'Ciclos',      value: d == null ? '—' : '${d.cycles}',               unit: '',  color: _subtext),
      //MetricCard(label: 'Cap. restante', value: d == null ? '—' : d.cycleCharge.toStringAsFixed(1), unit: 'Ah', color: _blue),
      MetricCard(label: 'Diff Voltagem', value: d == null ? '—' : d.diffVoltage.toStringAsFixed(3), unit: 'V', color: _yellow),
      MetricCard(label: 'Temp. BMS',   value: d == null ? '—' : _tempStr(d.temperatures, 0), unit: '°C', color: _orange),
      MetricCard(label: 'Temp. A1',    value: d == null ? '—' : _tempStr(d.temperatures, 1), unit: '°C', color: _orange),
      MetricCard(label: 'Temp. A2',    value: d == null ? '—' : _tempStr(d.temperatures, 2), unit: '°C', color: _orange),
      MetricCard(label: 'Cap. nominal', value: d == null ? '—' : d.designCapacity.toStringAsFixed(1), unit: 'Ah', color: _subtext),
      MetricCard(label: 'Balanceador',  value: d == null ? '—' : (d.balancer ? 'ON' : 'OFF'), unit: '', color: _green),
      MetricCard(label: 'MOSFET Carga', value: d == null ? '—' : (d.chrgMosfet ? 'ON' : 'OFF'), unit: '', color: _green),
      MetricCard(label: 'MOSFET Desc.', value: d == null ? '—' : (d.dischrgMosfet ? 'ON' : 'OFF'), unit: '', color: _green),
    ];

    return LayoutBuilder(
      builder: (context, constraints) {
        final cols = constraints.maxWidth >= 700 ? 5 : 3;
        const spacing = 6.0;
        final cellW = (constraints.maxWidth - (cols - 1) * spacing) / cols;
        return GridView.count(
          crossAxisCount: cols,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: spacing,
          crossAxisSpacing: spacing,
          childAspectRatio: cellW / 70,
          children: cards,
        );
      },
    );
  }

  Widget _chartCard(String title, List<FlSpot> spots, Color color,
      String unit, List<double>? yRange) {
    // Calcula eixo Y centralizado nos dados reais (com padding)
    double? minY, maxY;
    if (yRange != null) {
      minY = yRange[0];
      maxY = yRange[1];
    } else if (spots.length >= 2) {
      final ys    = spots.map((s) => s.y).toList();
      final dMin  = ys.reduce(min);
      final dMax  = ys.reduce(max);
      final range = dMax - dMin;
      final pad   = max(range * 0.4, max((dMin * 0.02).abs(), 0.25));
      minY = dMin - pad;
      maxY = dMax + pad;
    }

    final chartHeight = widget.embedded ? 100.0 : 160.0;
    return Container(
      height: chartHeight,
      decoration: BoxDecoration(
        color: _card,
        border: Border.all(color: _border),
        borderRadius: BorderRadius.circular(10),
      ),
      padding: const EdgeInsets.fromLTRB(6, 8, 12, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 8, bottom: 4),
            child: Text(title,
                style: const TextStyle(
                    color: _subtext, fontSize: 11, fontWeight: FontWeight.bold)),
          ),
          Expanded(
            child: spots.length < 2
                ? Center(
                    child: Text('Aguardando dados...',
                        style: TextStyle(color: _subtext.withAlpha(100))))
                : LineChart(
                    LineChartData(
                      minY: minY,
                      maxY: maxY,
                      gridData: FlGridData(
                        show: true,
                        getDrawingHorizontalLine: (_) =>
                            FlLine(color: _border, strokeWidth: 0.5),
                        getDrawingVerticalLine: (_) =>
                            FlLine(color: _border, strokeWidth: 0.5),
                      ),
                      borderData: FlBorderData(show: false),
                      titlesData: FlTitlesData(
                        leftTitles: AxisTitles(
                          sideTitles: SideTitles(
                            showTitles: true,
                            reservedSize: 36,
                            getTitlesWidget: (v, _) => Text(
                              v.toStringAsFixed(1),
                              style: const TextStyle(
                                  color: _subtext, fontSize: 9),
                            ),
                          ),
                        ),
                        bottomTitles: AxisTitles(
                          sideTitles: SideTitles(
                            showTitles: true,
                            reservedSize: 16,
                            getTitlesWidget: (v, _) => Text(
                              '${v.round()}s',
                              style: const TextStyle(
                                  color: _subtext, fontSize: 8),
                            ),
                          ),
                        ),
                        topTitles: const AxisTitles(
                            sideTitles: SideTitles(showTitles: false)),
                        rightTitles: const AxisTitles(
                            sideTitles: SideTitles(showTitles: false)),
                      ),
                      lineTouchData: LineTouchData(
                        touchTooltipData: LineTouchTooltipData(
                          getTooltipItems: (spots) => spots
                              .map((s) => LineTooltipItem(
                                    '${s.y.toStringAsFixed(2)} $unit',
                                    TextStyle(
                                        color: color,
                                        fontWeight: FontWeight.bold,
                                        fontSize: 12),
                                  ))
                              .toList(),
                        ),
                      ),
                      lineBarsData: [
                        LineChartBarData(
                          spots: spots,
                          color: color,
                          barWidth: 2,
                          isCurved: true,
                          dotData: const FlDotData(show: false),
                          belowBarData: BarAreaData(
                            show: true,
                            color: color.withAlpha(25),
                          ),
                        ),
                      ],
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildCells(BmsData? d) {
    if (d == null || d.cellVoltages.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(24),
        child: Text('Aguardando dados das células...',
            style: TextStyle(color: _subtext)),
      );
    }

    final cells = d.cellVoltages;
    final vmin  = cells.reduce(min);
    final vmax  = cells.reduce(max);
    final vavg  = cells.reduce((a, b) => a + b) / cells.length;
    final span  = vmax - vmin > 0 ? vmax - vmin : 1e-6;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          const Text('Células',
              style: TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.bold)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'min ${vmin.toStringAsFixed(2)}V  |  '
              'max ${vmax.toStringAsFixed(2)}V  |  '
              'avg ${vavg.toStringAsFixed(2)}V  |  '
              'Diff Voltage ${((vmax - vmin) * 1000).toStringAsFixed(0)}mV',
              style: const TextStyle(color: _subtext, fontSize: 10),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ]),
        const SizedBox(height: 8),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: List.generate(cells.length, (i) {
            final v    = cells[i];
            final diff = (v - vavg).abs();
            final col  = diff < 0.020 ? _green
                       : diff < 0.050 ? _yellow
                       : _red;
            final pct  = ((v - 2.5) / (4.2 - 2.5)).clamp(0.01, 1.0);

            return GestureDetector(
              onTap: () => _showCellHistory(i),
              child: CellBar(
                index: i,
                voltage: v,
                percent: pct,
                color: col,
                width: widget.embedded ? 170 : null,
                balancing: d.isCellBalancing(i),
              ),
            );
          }),
        ),
        const SizedBox(height: 6),
        Text('  Toque em uma célula para ver o histórico detalhado',
            style: TextStyle(color: _subtext.withAlpha(150), fontSize: 10)),
      ],
    );
  }

  void _showCellHistory(int idx) {
    final hist = _cellHist[idx] ?? [];
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF161b22),
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (_) => _CellHistorySheet(
        cellIdx: idx,
        history: hist,
      ),
    );
  }

  void _copyLog() {
    if (_log.isEmpty) return;
    Clipboard.setData(ClipboardData(text: _log.join('\n')));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Log copiado para a área de transferência.'),
        duration: Duration(seconds: 2),
      ),
    );
  }

  Future<void> _exportLog() async {
    if (_log.isEmpty && _cellHist.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Log vazio — nada para exportar.'),
            duration: Duration(seconds: 2)));
      return;
    }
    final buf = StringBuffer();
    final now = DateTime.now();
    buf.writeln('=== JBD BMS Monitor — Log completo ===');
    buf.writeln(
        'Exportado em: ${now.day.toString().padLeft(2, '0')}/'
        '${now.month.toString().padLeft(2, '0')}/${now.year} '
        '${now.hour.toString().padLeft(2, '0')}:'
        '${now.minute.toString().padLeft(2, '0')}');
    buf.writeln();

    // ── Log normal da bateria ──
    buf.writeln('──────── LOG DA BATERIA (${_log.length} leituras) ────────');
    for (final l in _log) {
      buf.writeln(l);
    }

    // ── Histórico das células ──
    if (_cellHist.isNotEmpty) {
      buf.writeln();
      buf.writeln(
          '──────── HISTÓRICO DAS CÉLULAS (${_cellHist.length} células) ────────');
      final keys = _cellHist.keys.toList()..sort();
      for (final k in keys) {
        final hist = _cellHist[k]!;
        final janela = hist.length > 1
            ? '${hist.first.ts} → ${hist.last.ts}'
            : hist.first.ts;
        buf.writeln();
        buf.writeln('Célula C${(k + 1).toString().padLeft(2, '0')} '
            '(${hist.length} leituras, $janela):');
        for (int i = 0; i < hist.length; i++) {
          final e = hist[i];
          final dPrev = i > 0 ? (e.v - hist[i - 1].v) * 1000 : 0.0;
          buf.writeln(
              '[${e.ts}]  ${e.v.toStringAsFixed(3)} V   '
              'DiffPack=${(e.diff * 1000).toStringAsFixed(0)} mV   '
              '${dPrev >= 0 ? '+' : ''}${dPrev.toStringAsFixed(0)} mV vs ant.');
        }
      }
    }

    final text = buf.toString();
    final fname =
        'bms_log_completo_${now.year}${now.month.toString().padLeft(2, '0')}'
        '${now.day.toString().padLeft(2, '0')}_'
        '${now.hour.toString().padLeft(2, '0')}'
        '${now.minute.toString().padLeft(2, '0')}.txt';

    if (Platform.isLinux) {
      final savePath = await _linuxSaveDialog(fname);
      if (savePath != null) {
        final file = File(savePath);
        await file.writeAsString(text);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Log salvo em: $savePath'),
                duration: const Duration(seconds: 4)));
        }
      }
    } else {
      final dir  = await getTemporaryDirectory();
      final file = File('${dir.path}/$fname');
      await file.writeAsString(text);
      await Share.shareXFiles([XFile(file.path)], subject: 'JBD BMS Log');
    }
  }

  // ── Log ────────────────────────────────────────────────────────────────────
  Widget _buildLog() {
    return Column(
      children: [
        Container(
          width: double.infinity,
          color: _card,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          child: Row(
            children: [
              const Expanded(
                child: Text('Registro completo de leituras',
                    style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 13)),
              ),
              TextButton.icon(
                onPressed: _copyLog,
                icon: const Icon(Icons.copy, size: 14),
                label: const Text('Copiar', style: TextStyle(fontSize: 12)),
                style: TextButton.styleFrom(
                  foregroundColor: const Color(0xFF8b949e),
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 0),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
              TextButton.icon(
                onPressed: _exportLog,
                icon: const Icon(Icons.save_alt, size: 14),
                label: const Text('Exportar Tudo', style: TextStyle(fontSize: 12)),
                style: TextButton.styleFrom(
                  foregroundColor: const Color(0xFF8b949e),
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 0),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: _log.isEmpty
              ? Center(
                  child: Text('Nenhum dado ainda.',
                      style: TextStyle(color: _subtext)))
              : ListView.builder(
                  controller: _logCtrl,
                  padding: const EdgeInsets.all(10),
                  itemCount: _log.length,
                  itemBuilder: (_, i) => Text(
                    _log[i],
                    style: const TextStyle(
                        color: Color(0xFF8b949e),
                        fontSize: 10,
                        fontFamily: 'monospace'),
                  ),
                ),
        ),
      ],
    );
  }
}

// ── Sheet de histórico da célula ───────────────────────────────────────────────
class _CellHistorySheet extends StatelessWidget {
  final int cellIdx;
  final List<({String ts, double v, double diff})> history;

  static const _green   = Color(0xFF3fb950);
  static const _blue    = Color(0xFF58a6ff);
  static const _yellow  = Color(0xFFd29922);
  static const _red     = Color(0xFFe94560);
  static const _purple  = Color(0xFFbc8cff);
  static const _subtext = Color(0xFF8b949e);
  static const _card    = Color(0xFF161b22);
  static const _bg      = Color(0xFF0d1117);

  const _CellHistorySheet({required this.cellIdx, required this.history});

  @override
  Widget build(BuildContext context) {
    final volts = history.map((e) => e.v).toList();
    final hasData = volts.isNotEmpty;
    final vmin    = hasData ? volts.reduce(min) : 0.0;
    final vmax    = hasData ? volts.reduce(max) : 0.0;
    final vavg    = hasData ? volts.reduce((a, b) => a + b) / volts.length : 0.0;
    final varT    = vmax - vmin;
    final trend   = hasData && volts.length > 1 ? volts.last - volts.first : 0.0;

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.75,
      maxChildSize: 0.95,
      minChildSize: 0.4,
      builder: (_, ctrl) => Container(
        color: _bg,
        child: Column(
          children: [
            // Handle
            Center(
              child: Container(
                margin: const EdgeInsets.symmetric(vertical: 8),
                width: 40, height: 4,
                decoration: BoxDecoration(
                    color: _subtext, borderRadius: BorderRadius.circular(2)),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Row(
                children: [
                  Text('Histórico — C${(cellIdx + 1).toString().padLeft(2, '0')}',
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.bold)),
                  const Spacer(),
                  Text('${history.length} leituras',
                      style: const TextStyle(color: _subtext, fontSize: 12)),
                  const SizedBox(width: 8),
                  TextButton.icon(
                    onPressed: () async {
                      final lines = history.asMap().entries.map((en) {
                        final i     = en.key;
                        final e     = en.value;
                        final dPrev = i > 0
                            ? (e.v - history[i - 1].v) * 1000
                            : 0.0;
                        return '[${e.ts}]  ${e.v.toStringAsFixed(2)} V  '
                            'Diff pack=${(e.diff * 1000).toStringAsFixed(0)}mV  '
                            'Diff ant=${dPrev.toStringAsFixed(0)}mV';
                      }).join('\n');
                      final now = DateTime.now();
                      final fname = 'C${(cellIdx + 1).toString().padLeft(2, '0')}_'
                          '${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}_'
                          '${now.hour.toString().padLeft(2, '0')}${now.minute.toString().padLeft(2, '0')}.txt';
                      if (Platform.isLinux) {
                        final savePath = await _linuxSaveDialog(fname);
                        if (savePath != null) {
                          await File(savePath).writeAsString(lines);
                          try {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text('Salvo em: $savePath'),
                                  duration: const Duration(seconds: 4)));
                          } catch (_) {}
                        }
                      } else {
                        final dir = await getTemporaryDirectory();
                        final file = File('${dir.path}/$fname');
                        await file.writeAsString(lines);
                        await Share.shareXFiles([XFile(file.path)], subject: fname);
                      }
                    },
                    icon: const Icon(Icons.save_alt, size: 14),
                    label: const Text('Exportar', style: TextStyle(fontSize: 12)),
                    style: TextButton.styleFrom(
                      foregroundColor: _subtext,
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                  ),
                ],
              ),
            ),
            if (hasData) ...[
              // Stats
              Container(
                margin: const EdgeInsets.all(12),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                    color: _card,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: const Color(0xFF30363d))),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                    _stat('Mínimo',   '${vmin.toStringAsFixed(2)} V',   _blue),
                    _stat('Máximo',   '${vmax.toStringAsFixed(2)} V',   _red),
                    _stat('Média',    '${vavg.toStringAsFixed(2)} V',   _green),
                    _stat('Variação', '${(varT * 1000).toStringAsFixed(0)} mV', _yellow),
                    _stat('Tendência','${(trend * 1000) >= 0 ? '+' : ''}${(trend * 1000).toStringAsFixed(0)} mV', _purple),
                  ],
                ),
              ),
            ],
            // Lista de leituras
            Expanded(
              child: hasData
                  ? ListView.builder(
                      controller: ctrl,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      itemCount: history.length,
                      itemBuilder: (_, i) {
                        final ts    = history[i].ts;
                        final v     = history[i].v;
                        final diff  = history[i].diff;
                        final dAvg  = (v - vavg) * 1000;
                        final dPrev = i > 0 ? (v - history[i-1].v) * 1000 : 0.0;
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 1),
                          child: Text(
                            '[$ts]  ${v.toStringAsFixed(2)} V   '
                            '${dAvg >= 0 ? '+' : ''}${dAvg.toStringAsFixed(0)} mV vs avg   '
                            '${dPrev >= 0 ? '+' : ''}${dPrev.toStringAsFixed(0)} mV vs ant.   '
                            'Diff=${(diff * 1000).toStringAsFixed(0)}mV',
                            style: const TextStyle(
                                color: _subtext,
                                fontSize: 10,
                                fontFamily: 'monospace'),
                          ),
                        );
                      },
                    )
                  : Center(
                      child: Text('Nenhum dado coletado.',
                          style: TextStyle(color: _subtext))),
            ),
          ],
        ),
      ),
    );
  }

  Widget _stat(String label, String value, Color color) {
    return Column(
      children: [
        Text(label,
            style: const TextStyle(color: _subtext, fontSize: 9)),
        const SizedBox(height: 2),
        Text(value,
            style: TextStyle(
                color: color, fontSize: 12, fontWeight: FontWeight.bold)),
      ],
    );
  }
}
