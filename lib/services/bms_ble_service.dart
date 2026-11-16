import 'dart:async';
import 'dart:io';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import '../models/bms_data.dart';

/// UUIDs do serviço JBD BMS (protocolo padrão Xiaoxiang/Jiabaida)
const _svcUuid  = '0000ff00-0000-1000-8000-00805f9b34fb';
const _rxUuid   = '0000ff01-0000-1000-8000-00805f9b34fb';
const _txUuid   = '0000ff02-0000-1000-8000-00805f9b34fb';

/// Comandos BLE do protocolo JBD
final _cmdBasic = [0xDD, 0xA5, 0x03, 0x00, 0xFF, 0xFD, 0x77];
final _cmdCells = [0xDD, 0xA5, 0x04, 0x00, 0xFF, 0xFC, 0x77];

enum BmsConnectionState { disconnected, connecting, connected, error }

class BmsBleService {
  final StreamController<BmsData>             _dataCtrl   = StreamController.broadcast();
  final StreamController<BmsConnectionState>  _stateCtrl  = StreamController.broadcast();
  final StreamController<String>              _logCtrl    = StreamController.broadcast();

  Stream<BmsData>            get dataStream   => _dataCtrl.stream;
  Stream<BmsConnectionState> get stateStream  => _stateCtrl.stream;
  Stream<String>             get logStream    => _logCtrl.stream;

  BluetoothDevice? _device;
  BluetoothCharacteristic? _rx;
  BluetoothCharacteristic? _tx;
  bool _txWithoutResponse = true;
  Timer? _pollTimer;
  final List<int> _rxBuffer = [];
  BmsData? _lastBasic;
  bool _disposed = false;
  bool _bleBusy = false;   // mutex: true quando escrevendo comandos MOSFET/críticos no BLE

  void _log(String msg) {
    if (!_disposed && !_logCtrl.isClosed) _logCtrl.add(msg);
  }

  void _emitState(BmsConnectionState s) {
    if (!_disposed && !_stateCtrl.isClosed) _stateCtrl.add(s);
  }

  void _emitData(BmsData d) {
    if (!_disposed && !_dataCtrl.isClosed) _dataCtrl.add(d);
  }

  // ── Conectar ────────────────────────────────────────────────────────────────
  Future<void> connect(BluetoothDevice device) async {
    if (_disposed) return;
    _emitState(BmsConnectionState.connecting);
    _log('Conectando a ${device.platformName}...');

    try {
      _device = device;
      if (Platform.isLinux) {
        await Future.delayed(const Duration(milliseconds: 1000));
      }

      // BlueZ às vezes aborta a conexão (le-connection-abort-by-local)
      // quando o adaptador ainda está ocupado — tenta até 4 vezes.
      const maxAttempts = 4;
      Object? lastError;
      for (int attempt = 1; attempt <= maxAttempts; attempt++) {
        if (_disposed) return;
        try {
          _log('Tentativa $attempt de $maxAttempts...');
          await device.connect(
              timeout: const Duration(seconds: 12),
              autoConnect: false);
          lastError = null;
          break;
        } catch (e) {
          lastError = e;
          final msg = e.toString();
          final transient =
              msg.contains('abort-by-local') ||
              msg.contains('le-connection') ||
              msg.contains('timeout') ||
              msg.contains('Timeout');
          try { await device.disconnect(); } catch (_) {}
          if (!transient || attempt == maxAttempts) break;
          _log('Conexão falhou ($msg). Tentando de novo em 2s...');
          await Future.delayed(const Duration(seconds: 2));
        }
      }
      if (_disposed) return;
      if (lastError != null) {
        throw lastError;
      }
      _log('Conectado. Descobrindo serviços...');

      final services = await device.discoverServices();
      if (_disposed) return;
      BluetoothService? bmsService;

      for (final s in services) {
        if (s.uuid.toString().toLowerCase().contains('ff00') ||
            s.uuid.toString().toLowerCase() == _svcUuid) {
          bmsService = s;
          break;
        }
      }

      if (bmsService == null) {
        _log('Serviço JBD não encontrado. UUIDs disponíveis:');
        for (final s in services) {
          _log('  ${s.uuid}');
        }
        _emitState(BmsConnectionState.error);
        return;
      }

      _log('Características encontradas:');
      for (final c in bmsService.characteristics) {
        final id    = c.uuid.toString().toLowerCase();
        final props = c.properties;
        _log('  $id  write=${props.write}  writeNoResp=${props.writeWithoutResponse}  notify=${props.notify}');
        if (id.contains('ff01') || id == _rxUuid) _rx = c;
        if (id.contains('ff02') || id == _txUuid) _tx = c;
      }

      // Se RX/TX não achados por UUID padrão, tenta por propriedades
      if (_rx == null || _tx == null) {
        for (final c in bmsService.characteristics) {
          if (_rx == null && c.properties.notify)              _rx = c;
          if (_tx == null && (c.properties.write || c.properties.writeWithoutResponse)) _tx = c;
        }
      }

      if (_rx == null || _tx == null) {
        _log('Características RX/TX não encontradas. Serviços disponíveis:');
        for (final s in services) {
          _log('  Serviço: ${s.uuid}');
          for (final c in s.characteristics) {
            _log('    ${c.uuid}  props=${c.properties}');
          }
        }
        _emitState(BmsConnectionState.error);
        return;
      }

      // Detecta se TX suporta write com ou sem resposta
      _txWithoutResponse = !_tx!.properties.write && _tx!.properties.writeWithoutResponse;
      _log('TX write mode: ${_txWithoutResponse ? "withoutResponse" : "withResponse"}');

      // Ativa notificações no RX
      await _rx!.setNotifyValue(true);
      _rx!.lastValueStream.listen(_onRxData);

      _emitState(BmsConnectionState.connected);
      _log('Pronto. Iniciando leitura periódica...');

      // Mantém a CPU acorda para o BLE continuar funcionando com tela desligada
      await WakelockPlus.enable();

      // Poll a cada 3s
      _pollTimer = Timer.periodic(const Duration(seconds: 3), (_) => _poll());
      _poll();

    } catch (e) {
      _log('Erro na conexão: $e');
      _emitState(BmsConnectionState.error);
    }
  }

  /// Poll periódico — respeita _bleBusy para não atrapalhar comandos MOSFET.
  Future<void> _poll() async {
    if (_bleBusy) return;   // não interromper comando MOSFET em andamento
    await _pollRaw();
  }

  /// Poll interno — executa mesmo com _bleBusy (usado p/ confirmar MOSFET).
  Future<void> _pollRaw() async {
    if (_tx == null) return;
    try {
      // Pede info básica (tensão, corrente, SOC, temp...)
      _rxBuffer.clear();
      await _tx!.write(_cmdBasic, withoutResponse: _txWithoutResponse);
      await Future.delayed(const Duration(milliseconds: 400));

      // Pede tensões individuais das células
      _rxBuffer.clear();
      await _tx!.write(_cmdCells, withoutResponse: _txWithoutResponse);
    } catch (e) {
      _log('Erro no poll: $e');
    }
  }

  void _onRxData(List<int> data) {
    _rxBuffer.addAll(data);
    _processBufferedFrames();
  }

  /// Extrai e processa frames completos (terminados em 0x77) do buffer.
  /// Suporta múltiplos frames concatenados numa mesma notificação BLE.
  void _processBufferedFrames() {
    while (_rxBuffer.length >= 4) {
      // Procura o início do frame (0xDD)
      final int startIdx = _rxBuffer.indexOf(0xDD);
      if (startIdx < 0) {
        _rxBuffer.clear();
        return;
      }
      if (startIdx > 0) _rxBuffer.removeRange(0, startIdx);

      // Procura o fim do frame (0x77) a partir da posição 3
      int endIdx = -1;
      for (int i = 3; i < _rxBuffer.length; i++) {
        if (_rxBuffer[i] == 0x77) { endIdx = i; break; }
      }
      if (endIdx < 0) return;  // frame incompleto, aguarda mais dados

      final frame = _rxBuffer.sublist(0, endIdx + 1);
      _rxBuffer.removeRange(0, endIdx + 1);
      _processFrame(frame);
    }
  }

  void _processFrame(List<int> frame) {
    if (frame.length < 4) return;
    final cmdByte = frame[1];

    if (cmdByte == 0x03) {
      // Resposta do comando basic info (0x03)
      final basic = JbdParser.parseBasicInfo(frame);
      if (basic != null) {
        _lastBasic = basic;
      }
    } else if (cmdByte == 0x04) {
      // Resposta do comando cell voltages (0x04)
      final cells = JbdParser.parseCellVoltages(frame);
      if (cells.isNotEmpty && _lastBasic != null) {
        _emitData(BmsData(
          voltage:        _lastBasic!.voltage,
          current:        _lastBasic!.current,
          soc:            _lastBasic!.soc,
          temperatures:   _lastBasic!.temperatures,
          cellVoltages:   cells,
          cycles:         _lastBasic!.cycles,
          cycleCharge:    _lastBasic!.cycleCharge,
          designCapacity: _lastBasic!.designCapacity,
          balanceBitmask: _lastBasic!.balanceBitmask,
          chrgMosfet:     _lastBasic!.chrgMosfet,
          dischrgMosfet:  _lastBasic!.dischrgMosfet,
          timestamp:      DateTime.now(),
        ));
      }
    }
    // Acks de comando DD 5A (unlock/E1) e frames desconhecidos: descartados
  }

  bool _lastChrg = true;
  bool _lastDsg  = true;

  set lastChrg(bool v) => _lastChrg = v;
  set lastDsg(bool v)  => _lastDsg  = v;

  // ── Controle MOSFET ──────────────────────────────────────────────────────────
  // Tenta todos os protocolos conhecidos — o BMS aceita o que reconhecer.

  List<int> _ffaaCmd(int cmdByte, bool on) {
    final payload = [cmdByte, 0x02, on ? 0x01 : 0x00, 0x00];
    final cksum = payload.reduce((a, b) => a + b) & 0xFF;
    return [0xFF, 0xAA, ...payload, cksum];
  }

  List<int> _dd5aCmd(int reg, List<int> data) {
    final inner = [reg, data.length, ...data];
    final crc = (0x10000 - inner.reduce((a, b) => a + b)) & 0xFFFF;
    return [0xDD, 0x5A, ...inner, (crc >> 8) & 0xFF, crc & 0xFF, 0x77];
  }

  String _hex(List<int> b) =>
      b.map((v) => v.toRadixString(16).padLeft(2, '0').toUpperCase()).join(' ');

  Future<void> _mosWrite(String label, bool on) async {
    if (_tx == null) { _log('MOSFET $label: TX não disponível.'); return; }
    // Protocolo confirmado 2026-06-24:
    //   DD 5A E1 02 00 [CTRL] [CRC] 77
    //   CTRL bitmask: bit0=0x01=chrg OFF, bit1=0x02=dsg OFF
    //     0x00=ambos ON  0x01=chrg OFF  0x02=dsg OFF  0x03=ambos OFF
    _bleBusy = true;
    try {
      final bool targetChrg = label == 'Carga'    ? on : _lastChrg;
      final bool targetDsg  = label == 'Descarga' ? on : _lastDsg;
      final ctrl = (targetChrg ? 0x00 : 0x01) | (targetDsg ? 0x00 : 0x02);
      final unlock = _dd5aCmd(0x00, [0x00, 0x00, 0x00, 0x00]);
      final cmd    = _dd5aCmd(0xE1, [0x00, ctrl]);

      // Tenta enviar o comando até 3 vezes (alguns BMS ignoram o 1º write
      // quando o RX ainda está processando notificações anteriores)
      const maxAttempts = 3;
      for (int attempt = 1; attempt <= maxAttempts; attempt++) {
        // Drena notificações antigas antes de enviar o comando
        _rxBuffer.clear();
        await Future.delayed(const Duration(milliseconds: 100));
        _rxBuffer.clear();

        await _tx!.write(unlock, withoutResponse: _txWithoutResponse);
        await Future.delayed(const Duration(milliseconds: 150));
        await _tx!.write(cmd, withoutResponse: _txWithoutResponse);
        _log('MOSFET $label ${on ? "ON" : "OFF"} '
             '(tentativa $attempt/$maxAttempts): '
             '[${_hex(unlock)}] → [${_hex(cmd)}]');

        // Espera o BMS processar e responder (E1 ack via notificação)
        await Future.delayed(const Duration(milliseconds: 800));

        // Drena o E1 ack que chegou via notificação
        _rxBuffer.clear();
        await Future.delayed(const Duration(milliseconds: 100));
        _rxBuffer.clear();

        // Polls de confirmação: lê basic info para ver o estado real do FET
        for (int p = 0; p < 2; p++) {
          await _pollRaw();
          await Future.delayed(const Duration(milliseconds: 500));
        }

        // Verifica se o BMS aplicou a mudança
        final bool confirmed = label == 'Carga'
            ? (_lastBasic?.chrgMosfet    == on)
            : (_lastBasic?.dischrgMosfet == on);
        if (confirmed) {
          if (attempt > 1) {
            _log('MOSFET $label confirmado na tentativa $attempt');
          }
          break;
        }
        if (attempt < maxAttempts) {
          _log('MOSFET $label não confirmado, reenviando...');
          await Future.delayed(const Duration(milliseconds: 500));
        } else {
          _log('MOSFET $label: FALHOU após $maxAttempts tentativas');
        }
      }
    } catch (e) {
      _log('Erro MOSFET $label: $e');
    } finally {
      _bleBusy = false;
    }
  }

  Future<void> writeChrg(bool on) async {
    _lastChrg = on;   // atualização otimista imediata
    await _mosWrite('Carga', on);
  }

  Future<void> writeDsg(bool on) async {
    _lastDsg = on;    // atualização otimista imediata
    await _mosWrite('Descarga', on);
  }

  /// Regula a porcentagem (SOC) para 100%.
  /// Registrador 0x10 do protocolo JBD com dado 0x01 marca a bateria
  /// como totalmente carregada e recalibra o contador de SOC.
  /// Use somente quando a bateria estiver realmente cheia!
  Future<void> calibrateSocTo100() async {
    if (_tx == null) { _log('Regular porcentagem: TX não disponível.'); return; }
    _bleBusy = true;
    try {
      final unlock = _dd5aCmd(0x00, [0x00, 0x00, 0x00, 0x00]);
      final cmd    = _dd5aCmd(0x10, [0x01]);
      await _tx!.write(unlock, withoutResponse: _txWithoutResponse);
      await Future.delayed(const Duration(milliseconds: 150));
      await _tx!.write(cmd, withoutResponse: _txWithoutResponse);
      _log('Regular Porcentagem → 100%: [${_hex(unlock)}] → [${_hex(cmd)}]');
      // Drena notificações antigas e força leitura imediata p/ confirmar
      await Future.delayed(const Duration(milliseconds: 500));
      _rxBuffer.clear();
      await Future.delayed(const Duration(milliseconds: 100));
      _rxBuffer.clear();
      await _pollRaw();
    } catch (e) {
      _log('Erro ao regular porcentagem: $e');
    } finally {
      _bleBusy = false;
    }
  }

  Future<void> sendRaw(String hexStr) async {
    if (_tx == null) { _log('TX não disponível'); return; }
    _bleBusy = true;
    try {
      final bytes = <int>[];
      final clean = hexStr.replaceAll(' ', '').replaceAll(':', '');
      for (var i = 0; i < clean.length - 1; i += 2) {
        bytes.add(int.parse(clean.substring(i, i + 2), radix: 16));
      }
      await _tx!.write(bytes, withoutResponse: _txWithoutResponse);
      _log('RAW enviado [${_hex(bytes)}]');
    } catch (e) {
      _log('Erro raw: $e');
    } finally {
      _bleBusy = false;
    }
  }

  // ── Desconectar ─────────────────────────────────────────────────────────────
  Future<void> disconnect() async {
    _pollTimer?.cancel();
    _pollTimer = null;
    try {
      await _device?.disconnect();
    } catch (_) {}
    _device = null;
    _rx = null;
    _tx = null;
    _lastBasic = null;
    try {
      await WakelockPlus.disable();
    } catch (_) {}
    _emitState(BmsConnectionState.disconnected);
    _log('Desconectado.');
  }

  void dispose() {
    _disposed = true;
    _pollTimer?.cancel();
    _pollTimer = null;
    _device?.disconnect().catchError((_) {});
    _device = null;
    _rx = null;
    _tx = null;
    _lastBasic = null;
    if (!_dataCtrl.isClosed) _dataCtrl.close();
    if (!_stateCtrl.isClosed) _stateCtrl.close();
    if (!_logCtrl.isClosed) _logCtrl.close();
  }
}
