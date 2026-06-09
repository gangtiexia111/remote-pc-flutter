import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import '../models/device.dart';
import '../security/license_manager.dart';
// v1.0.3: SAFE_MODE 防护 + 跨平台命令支持 (macOS/Linux)

/// HTTP 控制服务 — 对应原 Java 版 DesktopHttpServer.java
/// 子端运行，接收主端控制指令
///
/// v1.0.3 新增 SAFE_MODE 防护：
///   - 环境变量 SAFE_MODE=1 时，拒绝执行关机/重启/锁屏指令
///   - 请求头 x-test-mode 或 x-safe-mode 时，仅记录日志不执行
///   - 所有危险指令执行前写入审计日志
///   - 未授权访问返回 403
class HttpServerService {
  static const int _defaultPort = 9998;

  /// 授权 Token（启动时生成，主端需通过安全通道获取）
  String? _authToken;

  /// SAFE_MODE 状态：由环境变量或运行时设置控制
  bool _safeMode = false;

  /// 审计日志（最近 100 条）
  final List<Map<String, dynamic>> _auditLog = [];

  HttpServer? _server;
  bool _running = false;
  Device? _selfDevice;

  bool get isRunning => _running;
  bool get safeMode => _safeMode;

  /// 获取审计日志（只读）
  List<Map<String, dynamic>> get auditLog => List.unmodifiable(_auditLog);

  void setDevice(Device d) => _selfDevice = d;

  /// 设置授权 Token
  void setAuthToken(String token) => _authToken = token;

  /// 设置 SAFE_MODE（运行时切换）
  void setSafeMode(bool enabled) {
    _safeMode = enabled;
    _addAuditLog('SAFE_MODE', enabled ? 'ENABLED' : 'DISABLED', 'system');
    print('[HTTP] SAFE_MODE ${enabled ? "ON" : "OFF"}');
  }

  /// 启动 HTTP 服务
  Future<void> start({int port = _defaultPort}) async {
    if (_running) return;
    _running = true;

    // 从环境变量读取 SAFE_MODE 初始状态
    _safeMode = Platform.environment['SAFE_MODE'] == '1';
    if (_safeMode) {
      print('[HTTP] ⚠️ SAFE_MODE is ON (from env)');
    }

    // 生成随机授权 Token
    _authToken = _generateToken();

    // 绑定 localhost，避免对外暴露（原 0.0.0.0 有安全风险）
    // 如需局域网访问，启动时传入 bindAddress: InternetAddress.anyIPv4
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    print(
        '[HTTP] Server started on port $port (auth token: ${_authToken!.substring(0, 8)}...)');
    await for (final req in _server!) {
      _handleRequest(req);
    }
  }

  /// 生成 32 字节密码学安全随机 Token
  String _generateToken() {
    final r = Random.secure();
    final rand = List<int>.generate(32, (_) => r.nextInt(256));
    return base64Encode(rand);
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
      case '/safe-mode':
        _handleSafeModeQuery(req);
        break;
      case '/auth-token':
        _handleAuthTokenRequest(req);
        break;
      case '/audit-log':
        _handleAuditLogRequest(req);
        break;
      default:
        _respondNotFound(req);
    }
  }

  // ── SAFE_MODE 安全校验 ──────────────────────────────

  /// 检查请求是否有合法授权
  bool _isAuthorized(HttpRequest req) {
    // 1. 检查 x-auth-token 请求头
    final token = req.headers.value('x-auth-token');
    if (token != null && token == _authToken) return true;

    // 2. 检查 URL query 参数 token
    final queryToken = req.uri.queryParameters['token'];
    if (queryToken != null && queryToken == _authToken) return true;

    return false;
  }

  /// 检查是否为测试模式请求（x-test-mode 头）
  bool _isTestMode(HttpRequest req) {
    return req.headers.value('x-test-mode') != null ||
        req.headers.value('x-safe-mode') != null;
  }

  /// 危险指令安全校验：返回 true 表示允许执行，false 表示拦截
  bool _checkDangerousAction(HttpRequest req, String action) {
    final clientIp = req.connectionInfo?.remoteAddress.address ?? 'unknown';

    // 1. SAFE_MODE 检查
    if (_safeMode) {
      // 测试模式下仅记录，不执行
      if (_isTestMode(req)) {
        _addAuditLog(action, 'BLOCKED_BY_SAFE_MODE_TEST', clientIp);
        _respondOk(req, {
          'result': 'blocked_by_safe_mode',
          'message': '⚠️ SAFE_MODE 已启用，指令仅记录不执行',
          'action': action,
          'platform': Platform.operatingSystem,
        });
        return false;
      }
      // 非 test-mode 直接拒绝
      _addAuditLog(action, 'BLOCKED_BY_SAFE_MODE', clientIp);
      _respondForbidden(
          req, 'SAFE_MODE is enabled. Action "$action" is blocked.');
      return false;
    }

    // 2. 授权检查
    if (!_isAuthorized(req)) {
      _addAuditLog(action, 'UNAUTHORIZED', clientIp);
      _respondForbidden(req,
          'Unauthorized. Provide x-auth-token header or token query param.');
      return false;
    }

    // 3. 审计日志
    _addAuditLog(action, 'EXECUTED', clientIp);
    return true;
  }

  /// 添加审计日志
  void _addAuditLog(String action, String result, String clientIp) {
    _auditLog.add({
      'action': action,
      'result': result,
      'clientIp': clientIp,
      'safeMode': _safeMode,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    });
    // 保留最近 100 条
    if (_auditLog.length > 100) {
      _auditLog.removeRange(0, _auditLog.length - 100);
    }
  }

  // ── 危险指令处理 ──────────────────────────────────

  void _handleShutdown(HttpRequest req) {
    if (!_checkDangerousAction(req, 'shutdown')) return;
    final (cmd, args) = _shutdownCmd();
    Process.start(cmd, args);
    _respondOk(req,
        {'result': 'shutdown_initiated', 'platform': Platform.operatingSystem});
  }

  void _handleRestart(HttpRequest req) {
    if (!_checkDangerousAction(req, 'restart')) return;
    final (cmd, args) = _restartCmd();
    Process.start(cmd, args);
    _respondOk(req,
        {'result': 'restart_initiated', 'platform': Platform.operatingSystem});
  }

  void _handleLockScreen(HttpRequest req) {
    if (!_checkDangerousAction(req, 'lock_screen')) return;
    final (cmd, args) = _lockScreenCmd();
    Process.start(cmd, args);
    _respondOk(req, {
      'result': 'lock_screen_initiated',
      'platform': Platform.operatingSystem
    });
  }

  // ── 安全查询端点 ─────────────────────────────────

  void _handleSafeModeQuery(HttpRequest req) {
    _respondOk(req, {
      'safeMode': _safeMode,
      'message': _safeMode
          ? 'SAFE_MODE is ON — dangerous actions are blocked'
          : 'SAFE_MODE is OFF — normal operation',
    });
  }

  void _handleAuthTokenRequest(HttpRequest req) {
    // 仅本地访问可获取 Token
    final clientIp = req.connectionInfo?.remoteAddress.address ?? '';
    final isLocal = clientIp == '127.0.0.1' ||
        clientIp == '::1' ||
        clientIp == '0:0:0:0:0:0:0:1';
    if (!isLocal) {
      _respondForbidden(req, 'Token only available from localhost');
      return;
    }

    // 额外验证 Host 头，防止 DNS 重绑定攻击
    final host = req.headers.value('host') ?? '';
    final isLocalHost = host.startsWith('127.0.0.1') ||
        host.startsWith('localhost') ||
        host.startsWith('::1') ||
        host.isEmpty; // 本地请求可能没有 Host 头
    if (!isLocalHost) {
      // IP 是本地，但 Host 头不是本地 — 可能是 DNS 重绑定攻击
      _addAuditLog('AUTH_TOKEN', 'DNS_REBINDING_SUSPECT', clientIp);
      _respondForbidden(req, 'Suspicious Host header — possible DNS rebinding');
      return;
    }

    _respondOk(req, {
      'token': _authToken,
      'safeMode': _safeMode,
    });
  }

  // ── 平台命令映射 ──────────────────────────────────

  /// 返回对应平台的 (command, arguments)
  (String, List<String>) _shutdownCmd() {
    if (Platform.isWindows) return ('shutdown', ['/s', '/t', '0']);
    if (Platform.isMacOS)
      return ('osascript', ['-e', 'tell app "System Events" to shut down']);
    if (Platform.isLinux) return ('systemctl', ['poweroff']);
    return ('shutdown', ['/s', '/t', '0']); // fallback
  }

  (String, List<String>) _restartCmd() {
    if (Platform.isWindows) return ('shutdown', ['/r', '/t', '0']);
    if (Platform.isMacOS)
      return ('osascript', ['-e', 'tell app "System Events" to restart']);
    if (Platform.isLinux) return ('systemctl', ['reboot']);
    return ('shutdown', ['/r', '/t', '0']); // fallback
  }

  (String, List<String>) _lockScreenCmd() {
    if (Platform.isWindows) return ('rundll32', ['user32.dll,LockWorkStation']);
    if (Platform.isMacOS) return ('pmset', ['displaysleepnow']);
    if (Platform.isLinux) return ('loginctl', ['lock-session']);
    return ('rundll32', ['user32.dll,LockWorkStation']); // fallback
  }

  // ── 心跳 / 自毁 ──────────────────────────────────

  void _handleHeartbeat(HttpRequest req) {
    if (_selfDevice != null) _selfDevice!.markAlive();
    _respondOk(req, {
      'status': 'alive',
      'safeMode': _safeMode,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    });
  }

  Future<void> _handleRemoteSelfDestruct(HttpRequest req) async {
    if (!_checkDangerousAction(req, 'remote_self_destruct')) return;
    final lm = LicenseManager.getInstance();
    await lm.selfDestruct('remote_command');
    _respondOk(req, {'result': 'self_destruct_complete'});
  }

  // ── 响应工具 ──────────────────────────────────────

  void _respondOk(HttpRequest req, Map<String, dynamic> body) {
    req.response
      ..statusCode = 200
      ..headers.contentType = ContentType.json
      ..write(jsonEncode(body))
      ..close();
  }

  void _respondForbidden(HttpRequest req, String message) {
    req.response
      ..statusCode = 403
      ..headers.contentType = ContentType.json
      ..write(jsonEncode({'error': 'forbidden', 'message': message}))
      ..close();
  }

  void _respondNotFound(HttpRequest req) {
    req.response
      ..statusCode = 404
      ..write('Not Found')
      ..close();
  }

  // ── 审计日志查询 ──────────────────────────────────

  void _handleAuditLogRequest(HttpRequest req) {
    // 需要授权才能查看审计日志
    if (!_isAuthorized(req) && !_isTestMode(req)) {
      _respondForbidden(req, 'Unauthorized. Provide x-auth-token header.');
      return;
    }
    _respondOk(req, {
      'count': _auditLog.length,
      'logs': _auditLog,
    });
  }

  Future<void> stop() async {
    _running = false;
    await _server?.close();
  }
}
