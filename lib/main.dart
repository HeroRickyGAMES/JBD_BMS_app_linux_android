import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'screens/scan_screen.dart';
import 'screens/desktop_home_screen.dart';

void main() {
  if (Platform.isAndroid || Platform.isIOS) {
    FlutterForegroundTask.initCommunicationPort();
  }
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const BMSApp());
}

class BMSApp extends StatefulWidget {
  const BMSApp({super.key});

  @override
  State<BMSApp> createState() => _BMSAppState();
}

class _BMSAppState extends State<BMSApp> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _requestPermissions();
      _initService();
    });
  }

  Future<void> _requestPermissions() async {
    if (!(Platform.isAndroid || Platform.isIOS)) return;

    final notificationPermission =
        await FlutterForegroundTask.checkNotificationPermission();
    if (notificationPermission != NotificationPermission.granted) {
      await FlutterForegroundTask.requestNotificationPermission();
    }

    if (Platform.isAndroid) {
      if (!await FlutterForegroundTask.isIgnoringBatteryOptimizations) {
        await FlutterForegroundTask.requestIgnoreBatteryOptimization();
      }
    }
  }

  void _initService() {
    if (!(Platform.isAndroid || Platform.isIOS)) return;

    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'bms_monitor',
        channelName: 'JBD BMS Monitor',
        channelDescription: 'Mantém a conexão BLE ativa em background.',
        onlyAlertOnce: true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: false,
        playSound: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.repeat(5000),
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'JBD BMS Monitor',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF58a6ff),
          secondary: Color(0xFF3fb950),
          surface: Color(0xFF161b22),
          error: Color(0xFFf85149),
        ),
        scaffoldBackgroundColor: const Color(0xFF0d1117),
        cardColor: const Color(0xFF161b22),
      ),
      home: Platform.isLinux ? const DesktopHomeScreen() : const ScanScreen(),
    );
  }
}
