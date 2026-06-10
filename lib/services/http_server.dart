import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/services.dart' show rootBundle;
import '../models/device.dart';
import '../security/license_manager.dart';
import '../security/device_whitelist.dart';
import '../security/certificate_manager.dart';

/// HTTP 控制服务 — 对应原 Java 版 DesktopHttpServer.java
///
/// v1.0.4 新增：
///   - 速率限制（同 IP 失败 3 次锁 60 秒）
///   - HTTPS 支持（自签名证书，assets/certs/）
///   - 所有危险指令需授权 Token
class HttpServerService {
  static const int _defaultPort = 9998;

  /// 授权 Token（启动时生成，主端需通过安全通道获取）
  String? _authToken;

  /// Token 生成时间（V5-04 修复：Token 过期机制）
  int? _tokenGeneratedAt;

  /// Token 有效期（24 小时）
  static const int _tokenValidityMs = 24 * 60 * 60 * 1000;

  /// SAFE_MODE 状态
  bool _safeMode = false;

  /// 审计日志（最近 100 条）
  final List<Map<String, dynamic>> _auditLog = [];

  /// 速率限制：IP → (失败次数, 封禁截至时间戳 ms)
  final Map<String, RateEntry> _rateLimit = {};

  /// 速率限制阈值
  static const int _maxFailures = 3;

  /// 递增封禁时长（ATK-W09 修复：不再固定 60s，而是递增）
  /// 第 1 次封禁: 60s, 第 2 次: 5min, 第 3 次: 30min, 第 4 次+: 1h
  static const List<int> _blockDurationsMs = [
    60 * 1000, // 1 min
    5 * 60 * 1000, // 5 min
    30 * 60 * 1000, // 30 min
    60 * 60 * 1000, // 1 hour
  ];

  /// 速率限制清理阈值（超过此数量触发清理）
  static const int _rateLimitCleanupThreshold = 100;

  /// 上次速率限制清理时间
  int _lastRateLimitCleanup = 0;

  /// 速率限制清理间隔（5分钟）
  static const int _rateLimitCleanupIntervalMs = 5 * 60 * 1000;

  /// 最大请求体大小（10KB，防止 OOM 攻击 ATK-W08）
  static const int _maxRequestBodySize = 10 * 1024;

  /// 全局请求频率限制：IP → 最后请求时间戳
  final Map<String, int> _lastRequestTime = {};

  /// 全局请求频率限制：同一 IP 每秒最多请求数
  static const int _maxRequestsPerSecond = 10;

  /// 全局请求最小间隔（ms）
  static const int _minRequestIntervalMs = 100;

  HttpServer? _server;
  bool _running = false;
  Device? _selfDevice;

  /// 设备配对白名单
  final DeviceWhitelist _whitelist = DeviceWhitelist();

  /// TLS 证书管理器（V5-02 修复：私钥不再打包进 assets）
  final CertificateManager _certManager = CertificateManager();

  /// TLS 开关（设为 true 启用 HTTPS）
  bool enableTls = true;

  bool get isRunning => _running;
  bool get safeMode => _safeMode;

  List<Map<String, dynamic>> get auditLog => List.unmodifiable(_auditLog);

  void setDevice(Device d) => _selfDevice = d;
  void setAuthToken(String token) => _authToken = token;

  void setSafeMode(bool enabled) {
    _safeMode = enabled;
    _addAuditLog('SAFE_MODE', enabled ? 'ENABLED' : 'DISABLED', 'system');
    print('[HTTP] SAFE_MODE ${enabled ? "ON" : "OFF"}');
  }

  /// 启动 HTTP/HTTPS 服务
  ///
  /// [useTls] 是否启用 HTTPS（默认 true）
  /// V5-02 修复：优先从 CertificateManager 加载证书（私钥在安全存储），
  /// 如果不可用则降级到 assets（兼容旧版本），最终降级到 HTTP
  Future<void> start({
    int port = _defaultPort,
    bool useTls = true,
    List<int>? certBytes,
    List<int>? keyBytes,
  }) async {
    if (_running) return;
    _running = true;

    // 加载设备配对白名单
    await _whitelist.load();

    _safeMode = Platform.environment['SAFE_MODE'] == '1';
    if (_safeMode) print('[HTTP] ⚠️ SAFE_MODE is ON (from env)');

    _authToken = _generateToken();

    // ── 加载 TLS 证书（V5-02 修复：优先使用运行时生成的证书）────
    List<int>? finalCert;
    List<int>? finalKey;
    bool actuallyUseTls = useTls;

    if (useTls) {
      // 1. 优先使用调用方提供的证书
      if (certBytes != null && keyBytes != null) {
        finalCert = certBytes;
        finalKey = keyBytes;
      }
      // 2. 尝试从 CertificateManager 加载（安全存储中的运行时证书）
      else if (await _certManager.loadOrGenerate()) {
        finalCert = utf8.encode(_certManager.certPem!);
        finalKey = utf8.encode(_certManager.keyPem!);
        print('[HTTP] 🔒 Using runtime-generated TLS certificate (fingerprint: '
            '${_certManager.fingerprint?.substring(0, 23)}...)');
      }
      // 3. 降级：从 assets 加载（兼容旧版本，私钥可能被打包进应用）
      else {
        try {
          finalCert = (await rootBundle.load('assets/certs/cert.pem'))
              .buffer
              .asUint8List();
          finalKey = (await rootBundle.load('assets/certs/key.pem'))
              .buffer
              .asUint8List();
          print('[HTTP] ⚠️ Using bundled TLS certificate (INSECURE — private key in app bundle)');
          print('[HTTP] ⚠️ Install OpenSSL for runtime certificate generation');
        } catch (e) {
          // 4. 最终降级：HTTP 明文
          actuallyUseTls = false;
          print('[HTTP] ⚠️ No TLS certificate available — falling back to HTTP');
          print('[HTTP] ⚠️ All data will be transmitted in plaintext!');
        }
      }
    }

    _server = await _bindServer(port, actuallyUseTls, finalCert, finalKey);

    final scheme = actuallyUseTls ? 'HTTPS' : 'HTTP';
    print('[$scheme] Server started on port $port (TLS: $actuallyUseTls)');
    // 注意：不再输出 auth token 任何部分（ATK-W07 修复）

    await for (final req in _server!) {
      _handleRequest(req);
    }
  }

  Future<HttpServer> _bindServer(
    int port,
    bool useTls,
    List<int>? certBytes,
    List<int>? keyBytes,
  ) async {
    if (useTls && certBytes != null && keyBytes != null) {
      final ctx = SecurityContext()
        ..useCertificateChainBytes(certBytes)
        ..usePrivateKeyBytes(keyBytes);
      return HttpServer.bindSecure(
        InternetAddress.anyIPv4,
        port,
        ctx,
      );
    }
    return HttpServer.bind(InternetAddress.loopbackIPv4, port);
  }

  /// 生成 32 字节密码学安全随机 Token（含过期时间 V5-04）
  String _generateToken() {
    final r = Random.secure();
    final rand = List<int>.generate(32, (_) => r.nextInt(256));
    _tokenGeneratedAt = DateTime.now().millisecondsSinceEpoch;
    return base64Encode(rand);
  }

  void _handleRequest(HttpRequest req) {
    final clientIp = _clientIp(req);

    // ── CORS 预检请求处理 ─────────────────────────────
    if (req.method == 'OPTIONS') {
      _handleCorsPreflight(req);
      return;
    }

    // ── 添加安全响应头 ────────────────────────────────
    _addSecurityHeaders(req);

    // ── 速率限制检查（放在最前面）───────────────────
    final blocked = _checkRateLimit(clientIp, req);
    if (blocked) return;

    // ── 全局请求频率限制（防泛洪 ATK-W09）───────────
    if (!_checkGlobalRateLimit(clientIp, req)) return;

    final path = req.uri.path;
    print('[HTTP] ${req.method} $path from $clientIp');
    switch (path) {
      case '/ping':
        // 服务发现端点：仅返回存活状态，不泄露额外信息
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
      case '/pair':
        _handlePairRequest(req);
        break;
      case '/unpair':
        _handleUnpairRequest(req);
        break;
      case '/paired-devices':
        _handlePairedDevicesRequest(req);
        break;
      default:
        _respondNotFound(req);
    }
  }

  /// 严格检查 Host 头是否为本地地址（V5-06 修复：防 DNS rebinding 绕过）
  /// 正确解析 host:port 格式，防止 127.0.0.1.evil.com 类绕过
  bool _isLocalHostHeader(String hostHeader) {
    if (hostHeader.isEmpty) return true;

    // 解析 host:port — Host 头格式为 "hostname:port" 或 "hostname"
    String hostname;
    // IPv6 地址: [::1]:port
    if (hostHeader.startsWith('[')) {
      final bracketEnd = hostHeader.indexOf(']');
      if (bracketEnd == -1) return false;
      hostname = hostHeader.substring(1, bracketEnd);
    } else {
      // IPv4 或域名: hostname:port
      final colonIndex = hostHeader.lastIndexOf(':');
      hostname = colonIndex > 0
          ? hostHeader.substring(0, colonIndex)
          : hostHeader;
    }

    // 严格匹配：必须是精确的本地主机名
    const localHostnames = {'127.0.0.1', 'localhost', '::1', '0:0:0:0:0:0:0:1'};
    return localHostnames.contains(hostname.toLowerCase());
  }

  // ── CORS + 安全响应头 ──────────────────────────────

  /// 允许的来源（仅 localhost，防止浏览器 CSRF）
  static const _allowedOrigins = [
    'http://localhost:9998',
    'https://localhost:9998',
    'http://127.0.0.1:9998',
    'https://127.0.0.1:9998',
  ];

  /// 处理 CORS 预检请求
  void _handleCorsPreflight(HttpRequest req) {
    final origin = req.headers.value('origin') ?? '';
    if (_allowedOrigins.contains(origin)) {
      req.response.headers.add('Access-Control-Allow-Origin', origin);
      req.response.headers
          .add('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
      req.response.headers.add('Access-Control-Allow-Headers',
          'Content-Type, x-auth-token, x-device-id, x-device-fingerprint');
      req.response.headers.add('Access-Control-Max-Age', '86400');
    }
    req.response.statusCode = 204;
    req.response.close();
  }

  /// 添加安全响应头
  void _addSecurityHeaders(HttpRequest req) {
    final res = req.response;
    // CORS：仅允许 localhost 来源（防浏览器 CSRF）
    final origin = req.headers.value('origin') ?? '';
    if (_allowedOrigins.contains(origin)) {
      res.headers.add('Access-Control-Allow-Origin', origin);
    }
    // 防止浏览器 MIME 嗅探
    res.headers.add('X-Content-Type-Options', 'nosniff');
    // 防止点击劫持
    res.headers.add('X-Frame-Options', 'DENY');
    // XSS 保护
    res.headers.add('X-XSS-Protection', '1; mode=block');
    // 禁止浏览器缓存敏感响应
    res.headers.add('Cache-Control', 'no-store, no-cache, must-revalidate');
    res.headers.add('Pragma', 'no-cache');
    // V5-10：添加 Content-Security-Policy（防止注入脚本执行）
    res.headers.add('Content-Security-Policy',
        "default-src 'none'; frame-ancestors 'none'");
    // V5-10：添加 Strict-Transport-Security（HTTPS 时）
    // 告诉浏览器只用 HTTPS 连接此服务（1 年有效期）
    if (req.uri.scheme == 'https') {
      res.headers.add('Strict-Transport-Security',
          'max-age=31536000; includeSubDomains');
    }
    // V5-10：添加 Referrer-Policy（防止 URL 泄露 Token）
    res.headers.add('Referrer-Policy', 'no-referrer');
    // V5-10：权限策略（限制浏览器 API 使用）
    res.headers.add('Permissions-Policy',
        'camera=(), microphone=(), geolocation=()');
  }

  // ── 速率限制 ──────────────────────────────────────

  String _clientIp(HttpRequest req) =>
      req.connectionInfo?.remoteAddress.address ?? 'unknown';

  /// 检查速率限制，返回 true 表示已封禁（已回 429）
  bool _checkRateLimit(String ip, HttpRequest req) {
    final now = DateTime.now().millisecondsSinceEpoch;

    // ── 定期清理：移除过期或多余的速率限制记录（ATK-W05 修复）──
    if (_rateLimit.length > _rateLimitCleanupThreshold ||
        now - _lastRateLimitCleanup > _rateLimitCleanupIntervalMs) {
      _rateLimit.removeWhere((key, entry) {
        // 已过期的封禁记录
        if (entry.blockedUntil > 0 && entry.blockedUntil <= now) return true;
        // 10 分钟内无活动且未封禁的记录
        if (entry.blockedUntil == 0 && entry.failures < _maxFailures) {
          return true;
        }
        return false;
      });
      _lastRateLimitCleanup = now;
    }

    final entry = _rateLimit[ip];
    if (entry != null && entry.blockedUntil > now) {
      _addAuditLog('RATE_LIMIT', 'BLOCKED', ip);
      req.response
        ..statusCode = 429
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({
          'error': 'too_many_requests',
          'message': 'Too many failed attempts. Try again in '
              '${((entry.blockedUntil - now) / 1000).ceil()}s.',
        }))
        ..close();
      return true;
    }
    // 如果封禁已过期（blockedUntil > 0 且已过），清除记录
    // 注意：blockedUntil=0 表示从未封禁（还在累积失败），不能清除
    if (entry != null &&
        entry.blockedUntil > 0 &&
        entry.blockedUntil <= now) {
      _rateLimit.remove(ip);
    }
    return false;
  }

  /// 记录一次失败，超过阈值则封禁（递增封禁时长 ATK-W09）
  void _recordFailure(String ip) {
    final entry = _rateLimit.putIfAbsent(ip, () => RateEntry(0, 0, 0));
    entry.failures++;
    if (entry.failures >= _maxFailures) {
      // 递增封禁：封禁次数越多，封得越久
      final blockIndex =
          entry.blockCount < _blockDurationsMs.length ? entry.blockCount : _blockDurationsMs.length - 1;
      final duration = _blockDurationsMs[blockIndex];
      entry.blockedUntil = DateTime.now().millisecondsSinceEpoch + duration;
      entry.blockCount++;
      print('[HTTP] 🔴 IP $ip BLOCKED for ${duration ~/ 1000}s '
          '(failures: ${entry.failures}, block #${entry.blockCount})');
    }
  }

  /// 记录一次成功，清除该 IP 的限制记录
  void _recordSuccess(String ip) {
    _rateLimit.remove(ip);
  }

  /// 全局请求频率限制（防泛洪 ATK-W09）
  bool _checkGlobalRateLimit(String ip, HttpRequest req) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final lastTime = _lastRequestTime[ip] ?? 0;
    if (now - lastTime < _minRequestIntervalMs) {
      req.response
        ..statusCode = 429
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({
          'error': 'too_many_requests',
          'message': 'Request rate limit exceeded',
        }))
        ..close();
      return false;
    }
    _lastRequestTime[ip] = now;

    // 定期清理全局频率限制记录
    if (_lastRequestTime.length > _rateLimitCleanupThreshold) {
      _lastRequestTime.removeWhere((key, ts) => now - ts > 60000);
    }
    return true;
  }

  // ── 授权 & SAFE_MODE 检查 ────────────────────────

  bool _isAuthorized(HttpRequest req) {
    final clientIp = _clientIp(req);

    // V5-04 修复：检查 Token 是否过期
    if (_tokenGeneratedAt != null) {
      final age = DateTime.now().millisecondsSinceEpoch - _tokenGeneratedAt!;
      if (age > _tokenValidityMs) {
        // Token 过期 → 自动刷新
        _authToken = _generateToken();
        print('[HTTP] 🔄 Auth token refreshed (previous token expired after '
            '${age ~/ 3600000}h)');
        // 过期的 Token 不能通过验证
        _recordFailure(clientIp);
        return false;
      }
    }

    final token = req.headers.value('x-auth-token');
    if (token != null && _constantTimeEqual(token, _authToken ?? '')) {
      _recordSuccess(clientIp);
      return true;
    }
    _recordFailure(clientIp);
    return false;
  }

  /// 常量时间字符串比较（防时序攻击 + 长度侧信道 ATK-W10）
  bool _constantTimeEqual(String a, String b) {
    // 不提前返回 false（即使长度不同也完整比较，防长度泄露）
    if (a.length != b.length) {
      // 仍需遍历较长字符串的长度，防止通过执行时间推断长度
      final maxLen = a.length > b.length ? a.length : b.length;
      // ignore: unused_local_variable
      int dummy = 1;
      for (int i = 0; i < maxLen; i++) {
        final ac = i < a.length ? a.codeUnitAt(i) : 0;
        final bc = i < b.length ? b.codeUnitAt(i) : 0;
        dummy |= ac ^ bc;
      }
      return false; // 长度不同 → 一定不相等
    }
    int result = 0;
    for (int i = 0; i < a.length; i++) {
      result |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return result == 0;
  }

  bool _isTestMode(HttpRequest req) =>
      req.headers.value('x-test-mode') != null ||
      req.headers.value('x-safe-mode') != null;

  bool _checkDangerousAction(HttpRequest req, String action) {
    final clientIp = _clientIp(req);

    // ── 白名单检查：必须提供 deviceId，且设备必须在白名单中 ──
    final deviceId = req.headers.value('x-device-id');
    final fingerprint = req.headers.value('x-device-fingerprint');
    if (deviceId == null || deviceId.isEmpty) {
      // 未提供 deviceId → 拒绝（修复白名单绕过漏洞 ATK-W01）
      _addAuditLog(action, 'NO_DEVICE_ID', clientIp);
      _respondForbidden(req, 'Device ID required. Provide x-device-id header.');
      return false;
    }
    if (fingerprint == null || fingerprint.isEmpty) {
      // 未提供 fingerprint → 拒绝（修复指纹绕过漏洞 ATK-W06）
      _addAuditLog(action, 'NO_FINGERPRINT', clientIp);
      _respondForbidden(req,
          'Device fingerprint required. Provide x-device-fingerprint header.');
      return false;
    }
    if (!_whitelist.isAllowed(deviceId, fingerprint: fingerprint)) {
      _addAuditLog(action, 'DEVICE_NOT_PAIRED', clientIp);
      _respondForbidden(req, 'Device not paired. Use /pair endpoint first.');
      return false;
    }

    if (_safeMode) {
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
      _addAuditLog(action, 'BLOCKED_BY_SAFE_MODE', clientIp);
      _respondForbidden(
          req, 'SAFE_MODE is enabled. Action "$action" is blocked.');
      return false;
    }

    if (!_isAuthorized(req)) {
      _addAuditLog(action, 'UNAUTHORIZED', clientIp);
      _respondForbidden(req,
          'Unauthorized. Provide x-auth-token header or token query param.');
      return false;
    }

    _addAuditLog(action, 'EXECUTED', clientIp);
    return true;
  }

  void _addAuditLog(String action, String result, String clientIp) {
    // 输入消毒：截断过长值（防日志注入 ATK-W10）
    final safeAction = action.length > 64 ? action.substring(0, 64) : action;
    final safeClientIp = clientIp.length > 45 ? clientIp.substring(0, 45) : clientIp;
    _auditLog.add({
      'action': safeAction,
      'result': result,
      'clientIp': safeClientIp,
      'safeMode': _safeMode,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    });
    while (_auditLog.length > 100) {
      _auditLog.removeAt(0);
    }
  }

  // ── 危险指令处理 ────────────────────────────────────

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

  // ── 安全查询端点 ────────────────────────────────────

  void _handleSafeModeQuery(HttpRequest req) {
    // 加固：SAFE_MODE 状态是敏感信息，需认证
    if (!_isAuthorized(req) && !_isTestMode(req)) {
      _respondForbidden(req, 'Unauthorized. Provide x-auth-token header.');
      return;
    }
    _respondOk(req, {
      'safeMode': _safeMode,
      'message': _safeMode
          ? 'SAFE_MODE is ON — dangerous actions are blocked'
          : 'SAFE_MODE is OFF — normal operation',
    });
  }

  void _handleAuthTokenRequest(HttpRequest req) {
    final clientIp = _clientIp(req);
    final isLocal = clientIp == '127.0.0.1' ||
        clientIp == '::1' ||
        clientIp == '0:0:0:0:0:0:0:1';

    if (!isLocal) {
      _respondForbidden(req, 'Token only available from localhost');
      return;
    }

    // V5-06 修复：严格解析 Host 头，防止 DNS rebinding 绕过
    final host = req.headers.value('host') ?? '';
    if (!_isLocalHostHeader(host)) {
      _addAuditLog('AUTH_TOKEN', 'DNS_REBINDING_SUSPECT', clientIp);
      _respondForbidden(req, 'Suspicious Host header — possible DNS rebinding');
      return;
    }

    _respondOk(req, {
      'token': _authToken,
      'safeMode': _safeMode,
      'scheme': req.uri.scheme,
    });
  }

  // ── 平台命令映射 ────────────────────────────────────

  (String, List<String>) _shutdownCmd() {
    if (Platform.isWindows) return ('shutdown', ['/s', '/t', '0']);
    if (Platform.isMacOS) {
      return ('osascript', ['-e', 'tell app "System Events" to shut down']);
    }
    if (Platform.isLinux) return ('systemctl', ['poweroff']);
    return ('shutdown', ['/s', '/t', '0']);
  }

  (String, List<String>) _restartCmd() {
    if (Platform.isWindows) return ('shutdown', ['/r', '/t', '0']);
    if (Platform.isMacOS) {
      return ('osascript', ['-e', 'tell app "System Events" to restart']);
    }
    if (Platform.isLinux) return ('systemctl', ['reboot']);
    return ('shutdown', ['/r', '/t', '0']);
  }

  (String, List<String>) _lockScreenCmd() {
    if (Platform.isWindows) return ('rundll32', ['user32.dll,LockWorkStation']);
    if (Platform.isMacOS) return ('pmset', ['displaysleepnow']);
    if (Platform.isLinux) return ('loginctl', ['lock-session']);
    return ('rundll32', ['user32.dll,LockWorkStation']);
  }

  // ── 心跳 / 自毁 ────────────────────────────────────

  void _handleHeartbeat(HttpRequest req) {
    // 加固：心跳端点不再泄露敏感信息
    // 仅返回存活状态，不暴露时间戳或设备信息
    if (_selfDevice != null) _selfDevice!.markAlive();
    _respondOk(req, {
      'status': 'alive',
    });
  }

  Future<void> _handleRemoteSelfDestruct(HttpRequest req) async {
    if (!_checkDangerousAction(req, 'remote_self_destruct')) return;
    final lm = LicenseManager.getInstance();
    await lm.selfDestruct('remote_command');
    _respondOk(req, {'result': 'self_destruct_complete'});
  }

  // ── 响应工具 ──────────────────────────────────────

  /// 安全读取请求体（带大小限制，防 OOM 攻击 ATK-W08）
  Future<String?> _readBodySafe(HttpRequest req) async {
    try {
      final contentLength = req.contentLength;
      if (contentLength > _maxRequestBodySize) {
        _respondForbidden(req, 'Request body too large (max ${_maxRequestBodySize ~/ 1024}KB)');
        return null;
      }
      final body = await utf8.decoder.bind(req).first;
      if (body.length > _maxRequestBodySize) {
        _respondForbidden(req, 'Request body too large (max ${_maxRequestBodySize ~/ 1024}KB)');
        return null;
      }
      return body;
    } catch (e) {
      _respondForbidden(req, 'Invalid request body');
      return null;
    }
  }

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
    // V5-10：统一 JSON 错误格式，不泄露服务细节
    req.response
      ..statusCode = 404
      ..headers.contentType = ContentType.json
      ..write(jsonEncode({'error': 'not_found'}))
      ..close();
  }

  // ── 审计日志查询 ────────────────────────────────────

  void _handleAuditLogRequest(HttpRequest req) {
    if (!_isAuthorized(req)) {
      _respondForbidden(req, 'Unauthorized. Provide x-auth-token header.');
      return;
    }
    _respondOk(req, {
      'count': _auditLog.length,
      'logs': _auditLog,
    });
  }

  // ── 设备配对管理 ──────────────────────────────────

  /// 配对新设备（需从 localhost 发起确认，防远程配对攻击）
  Future<void> _handlePairRequest(HttpRequest req) async {
    final clientIp = _clientIp(req);

    // 只允许本地配对确认（防止远程恶意配对）
    final isLocal = clientIp == '127.0.0.1' ||
        clientIp == '::1' ||
        clientIp == '0:0:0:0:0:0:0:1';
    if (!isLocal) {
      _addAuditLog('PAIR', 'REJECTED_REMOTE', clientIp);
      _respondForbidden(req, 'Pairing only allowed from localhost');
      return;
    }

    // 第二层：需要认证 Token（V5-EXTRA 修复：本地恶意进程也需 Token）
    if (!_isAuthorized(req)) {
      _addAuditLog('PAIR', 'UNAUTHORIZED', clientIp);
      _respondForbidden(req, 'Unauthorized. Provide x-auth-token header.');
      return;
    }

    if (req.method != 'POST') {
      req.response
        ..statusCode = 405
        ..write('Method Not Allowed')
        ..close();
      return;
    }

    try {
      final body = await _readBodySafe(req);
      if (body == null) return;
      final data = jsonDecode(body) as Map<String, dynamic>;
      final deviceId = data['deviceId'] as String? ?? '';
      final fingerprint = data['fingerprint'] as String? ?? '';
      final name = data['name'] as String? ?? 'Unknown';

      if (deviceId.isEmpty) {
        _respondForbidden(req, 'deviceId is required');
        return;
      }

      // 输入验证：限制字段长度（防注入 ATK-W10）
      if (deviceId.length > 64 || name.length > 128 || fingerprint.length > 256) {
        _addAuditLog('PAIR', 'INVALID_INPUT', clientIp);
        _respondForbidden(req, 'Input too long');
        return;
      }

      await _whitelist.addDevice(
        deviceId: deviceId,
        fingerprint: fingerprint.isNotEmpty ? fingerprint : null,
        name: name,
      );
      _addAuditLog('PAIR', 'SUCCESS', clientIp);
      _respondOk(req, {
        'result': 'paired',
        'deviceId': deviceId,
        'totalDevices': _whitelist.count,
      });
    } catch (e) {
      _addAuditLog('PAIR', 'ERROR', clientIp);
      // 不泄露内部错误细节（ATK-W10 修复）
      _respondForbidden(req, 'Invalid pairing data');
    }
  }

  /// 解除设备配对
  Future<void> _handleUnpairRequest(HttpRequest req) async {
    if (!_isAuthorized(req)) {
      _respondForbidden(req, 'Unauthorized');
      return;
    }

    try {
      final body = await _readBodySafe(req);
      if (body == null) return;
      final data = jsonDecode(body) as Map<String, dynamic>;
      final deviceId = data['deviceId'] as String? ?? '';

      if (deviceId.isEmpty) {
        _respondForbidden(req, 'deviceId is required');
        return;
      }

      // 输入验证：限制字段长度（防注入 ATK-W10）
      if (deviceId.length > 64) {
        _respondForbidden(req, 'Input too long');
        return;
      }

      final removed = await _whitelist.removeDevice(deviceId);
      _addAuditLog('UNPAIR', removed ? 'SUCCESS' : 'NOT_FOUND', _clientIp(req));
      _respondOk(req, {
        'result': removed ? 'unpaired' : 'device_not_found',
        'deviceId': deviceId,
        'totalDevices': _whitelist.count,
      });
    } catch (e) {
      // 不泄露内部错误细节（ATK-W10 修复）
      _respondForbidden(req, 'Invalid unpair data');
    }
  }

  /// 查询已配对设备列表
  void _handlePairedDevicesRequest(HttpRequest req) {
    if (!_isAuthorized(req)) {
      _respondForbidden(req, 'Unauthorized');
      return;
    }
    _respondOk(req, {
      'count': _whitelist.count,
      'devices': _whitelist.devices,
    });
  }

  Future<void> stop() async {
    _running = false;
    await _server?.close();
  }
}

/// 速率限制条目
class RateEntry {
  int failures;
  int blockedUntil; // millisecondsSinceEpoch，0 表示未封禁
  int blockCount; // 累计被封禁次数（用于递增封禁时长 ATK-W09）
  RateEntry(this.failures, this.blockedUntil, this.blockCount);
}
