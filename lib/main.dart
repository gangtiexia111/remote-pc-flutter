import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'models/device.dart';
import 'security/license_manager.dart';
import 'security/dynamic_firewall.dart';
import 'services/http_server.dart';
import 'screens/home_screen.dart';

/// Remote PC Control — 跨平台入口
/// 支持 Android / iOS / Windows / macOS / Linux
void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final lm = LicenseManager.getInstance();
  final fw = DynamicFirewall();
  final args = Platform.executableArguments;

  // --headless 模式：不启动 UI，仅启动后台服务（对应原 Java 版）
  if (args.contains('--headless')) {
    await _startHeadless(lm, fw);
    return;
  }

  // 正常模式：启动 UI
  runApp(const RemotePcApp());
}

/// Headless 模式：仅启动网络服务，无 UI
Future<void> _startHeadless(LicenseManager lm, DynamicFirewall fw) async {
  print('[RemotePC] Starting in headless mode...');
  lm.setChildMode(true);
  final device = Device(
    id: await lm.generateDeviceId(),
    name: 'Headless-Device',
    ip: '127.0.0.1',
    port: 9998,
  )..markAlive();
  final httpSvc = HttpServerService();
  httpSvc.setDevice(device);
  await httpSvc.start(port: 9998);
  print('[RemotePC] Headless mode ready. HTTP server on :9998');
  // 阻塞主线程
  await Completer<void>().future;
}

class RemotePcApp extends StatelessWidget {
  const RemotePcApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Remote PC Control',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      home: const HomeScreen(),
      debugShowCheckedModeBanner: false,
    );
  }
}
