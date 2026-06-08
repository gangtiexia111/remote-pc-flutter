import 'dart:async';
import 'dart:convert';
import 'dart:io';
import '../models/device.dart';
import '../security/license_manager.dart';

/// HTTP 控制服务 — 对应原 Java 版 DesktopHttpServer.java
/// 子端运行，接收主端控制指令
class HttpServerService {
  static const int _defaultPort = 9998;
  HttpServer? _server;
  bool _running = false;
  Device? _selfDevice;

  bool get isRunning => _running;

  void setDevice(Device d) => _selfDevice = d;

  /// 启动 HTTP 服务
  Future<void> start({int port = _defaultPort}) async {
    if (_running) return;
    _running = true;
    _server = await HttpServer.bind(InternetAddress.anyIPv4, port);
    print('[HTTP] Server started on port $port');
    await for (final req in _server!) {
      _handleRequest(req);
    }
  }

  void _handleRequest(HttpRequest req) {
    final path = req.uri.path;
    print('[HTTP] ${req.method} $path');
    switch (path) {
      case '/ping':
        _respondOk(req, {'status': 'alive'});
        break;
      case '/shutdown':
        _handleShutdown(req);
        break;
      case '/restart':
        _handleRestart(req);
        break;
      case '/lock-screen':
        _handleLockScreen(req);
        break;
      case '/heartbeat':
        _handleHeartbeat(req);
        break;
      case '/remote-self-destruct':
        _handleRemoteSelfDestruct(req);
        break;
      default:
        _respondNotFound(req);
    }
  }

  void _respondOk(HttpRequest req, Map<String, dynamic> body) {
    req.response
      ..statusCode = 200
      ..headers.contentType = ContentType.json
      ..write(jsonEncode(body))
      ..close();
  }

  void _respondNotFound(HttpRequest req) {
    req.response
      ..statusCode = 404
      ..write('Not Found')
      ..close();
  }

  void _handleShutdown(HttpRequest req) {
    Process.start('shutdown', ['/s', '/t', '0']);
    _respondOk(req, {'result': 'shutdown_initiated'});
  }

  void _handleRestart(HttpRequest req) {
    Process.start('shutdown', ['/r', '/t', '0']);
    _respondOk(req, {'result': 'restart_initiated'});
  }

  void _handleLockScreen(HttpRequest req) {
    // Windows: rundll32 user32.dll,LockWorkStation
    // macOS: pmset sleepnow 或 /System/Library/CoreServices/Menu\ Extras/User.menu/Contents/Resources/CGSession -suspend
    _respondOk(req, {'result': 'lock_screen_initiated'});
  }

  void _handleHeartbeat(HttpRequest req) {
    if (_selfDevice != null) _selfDevice!.markAlive();
    _respondOk(req, {'status': 'alive', 'timestamp': DateTime.now().millisecondsSinceEpoch});
  }

  Future<void> _handleRemoteSelfDestruct(HttpRequest req) async {
    final lm = LicenseManager.getInstance();
    await lm.selfDestruct('remote_command');
    _respondOk(req, {'result': 'self_destruct_complete'});
  }

  Future<void> stop() async {
    _running = false;
    await _server?.close();
  }
}
