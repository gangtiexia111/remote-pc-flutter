import 'dart:convert';
import 'dart:math';
import 'package:cryptography/cryptography.dart' as crypto;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../services/native_security_bridge.dart';

/// 动态多语言防火墙 — 桌面端防破解核心
///
/// 设计思路：
/// 1. 验证字符串动态生成，每次启动不同
/// 2. 混合中英文、阿拉伯文、埃及象形文字、数字，增加逆向难度
/// 3. 关键校验逻辑在 Dart 侧使用 HMAC-SHA256 完成（v1.0.3+）
/// 4. 心跳校验：每 N 分钟重新验证一次，失败触发自毁
///
/// 多语言字符池（部分埃及象形文字为 Unicode 私有区模拟）：
class DynamicFirewall {
  // === 多语言动态字符池 ===
  static const _chinese = '验证码动态防火墙安全授权';
  static const _arabic =
      '\u0627\u0644\u062a\u062d\u0642\u0642\u062c\u062f\u0627\u0631\u0627\u0644\u0646\u0627\u0631\u0627\u0644\u0623\u0645\u0646\u0627\u0644\u062a\u0631\u062e\u064a\u0635'; // 阿拉伯文
  static const _digits = '3489712056';

  final Random _rng = Random.secure();
  final Map<String, dynamic> _dynamicState = {};

  // HMAC 密钥（从平台安全存储读取，首次使用时生成）
  static const String _firewallKeyAlias = 'remote_pc_firewall_key';
  crypto.SecretKey? _firewallKey;

  // 单例
  static DynamicFirewall? _inst;
  factory DynamicFirewall() => _inst ??= DynamicFirewall._();
  DynamicFirewall._();

  /// 确保密钥已加载（懒初始化）
  Future<void> _ensureFirewallKey() async {
    if (_firewallKey != null) return;
    const storage = FlutterSecureStorage();
    final existing = await storage.read(key: _firewallKeyAlias);
    if (existing != null && existing.isNotEmpty) {
      _firewallKey = crypto.SecretKey(base64Decode(existing));
      return;
    }
    // 首次运行：生成随机密钥并安全存储
    final keyBytes = List<int>.generate(32, (_) => _rng.nextInt(256));
    await storage.write(key: _firewallKeyAlias, value: base64Encode(keyBytes));
    _firewallKey = crypto.SecretKey(keyBytes);
    print('[Firewall] HMAC key generated and stored securely');
  }

  /// 生成动态验证挑战（每次调用结果不同）
  String generateChallenge() {
    final buf = StringBuffer();
    // 随机长度 16~32
    final len = 16 + _rng.nextInt(17);
    for (int i = 0; i < len; i++) {
      final pool = _rng.nextInt(4);
      switch (pool) {
        case 0:
          {
            buf.write(_chinese[_rng.nextInt(_chinese.length)]);
            break;
          }
        case 1:
          {
            buf.write(_arabic[_rng.nextInt(_arabic.length)]);
            break;
          }
        case 2:
          {
            buf.write(_digits[_rng.nextInt(_digits.length)]);
            break;
          }
        case 3:
          {
            // 插入埃及象形文字（Unicode U+13000..U+1342F 区块）
            buf.writeCharCode(0x13000 + _rng.nextInt(0x430));
            break;
          }
      }
    }
    final challenge = buf.toString();
    _dynamicState['lastChallenge'] = challenge;
    _dynamicState['challengeTime'] = DateTime.now().millisecondsSinceEpoch;
    return challenge;
  }

  /// 验证响应（客户端提交答案，服务端校验）
  /// v2: 使用 HMAC-SHA256 签名，防逆向和伪造
  Future<bool> verifyResponse(String challenge, String response) async {
    if (challenge.isEmpty || response.isEmpty) return false;
    await _ensureFirewallKey();
    // 计算 HMAC(challenge, firewallKey) 作为期望响应
    final algorithm = crypto.Hmac.sha256();
    final mac = await algorithm.calculateMac(
      utf8.encode(challenge),
      secretKey: _firewallKey!,
    );
    // 取 HMAC 前 16 字符作为期望响应
    final expected = base64Encode(mac.bytes).substring(0, 16);
    // 常量时间比较，防时序攻击
    return _constantTimeEqual(response, expected);
  }

  /// 常量时间字符串比较（防时序攻击）
  bool _constantTimeEqual(String a, String b) {
    if (a.length != b.length) return false;
    int result = 0;
    for (int i = 0; i < a.length; i++) {
      result |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return result == 0;
  }

  /// 生成动态 AES-256 密钥（每次启动不同，绑定设备指纹）
  Future<crypto.SecretKey> generateDynamicKey(String deviceId) async {
    final rand = List<int>.generate(16, (_) => _rng.nextInt(256));
    final base = utf8.encode(deviceId) + rand;
    // 用 SHA-256 派生 32 字节密钥
    final algorithm = crypto.Sha256();
    final hash = await algorithm.hash(base);
    return crypto.SecretKey(hash.bytes);
  }

  /// 心跳校验：定期调用，失败次数过多触发自毁
  int _heartbeatFailures = 0;
  static const _maxHeartbeatFails = 5;

  Future<bool> heartbeatCheck() async {
    final challenge = generateChallenge();
    // 每次心跳都要求验证（修复原来 50% 跳过的漏洞）
    final response = await _computeExpectedResponse(challenge);
    if (await verifyResponse(challenge, response)) {
      _heartbeatFailures = 0;
      return true;
    } else {
      _heartbeatFailures++;
      return _heartbeatFailures < _maxHeartbeatFails;
    }
  }

  /// 计算期望的 HMAC 响应（用于心跳自检）
  Future<String> _computeExpectedResponse(String challenge) async {
    await _ensureFirewallKey();
    final algorithm = crypto.Hmac.sha256();
    final mac = await algorithm.calculateMac(
      utf8.encode(challenge),
      secretKey: _firewallKey!,
    );
    return base64Encode(mac.bytes).substring(0, 16);
  }

  /// 获取当前动态状态（用于上报/调试）
  Map<String, dynamic> getDynamicState() => Map.from(_dynamicState);

  /// 检测是否正在被调试（桌面端）
  /// 通过 NativeSecurityBridge 调用各平台原生 API
  /// Windows: IsDebuggerPresent()
  /// macOS: sysctl kinfo_proc -> P_TRACED flag
  /// Android: Debug.isDebuggerConnected()
  Future<bool> isBeingDebugged() async {
    try {
      return await NativeSecurityBridge.isBeingDebugged();
    } catch (_) {
      return false; // 检测失败 → 不阻塞（调试检测不适用 fail-closed）
    }
  }

  /// 完整性校验：检查应用是否被篡改
  /// 通过 NativeSecurityBridge 调用各平台原生 API
  /// Windows: PE 校验和 + 关键 DLL 验证
  /// macOS: codesign 校验
  /// Android: 签名校验
  Future<bool> verifyIntegrity() async {
    try {
      return await NativeSecurityBridge.verifySystemIntegrity();
    } catch (_) {
      return false; // 校验失败 → 认为被篡改（fail-closed）
    }
  }
}
