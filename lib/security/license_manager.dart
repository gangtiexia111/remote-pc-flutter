import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:cryptography/cryptography.dart' as crypto;
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 授权管理器 — 对应原 Java 版 LicenseManager.java
/// 支持 AES-256-GCM 激活码验证，支持 Android/iOS/Desktop 三端
class LicenseManager {
  static const String _activationFile = 'activation.json';
  static const String _keyAlias = 'remote_pc_activation';

  // AES-256-GCM 密钥 — 从平台安全存储读取，不存在则生成并保存
  // 不再硬编码，避免反编译泄露
  static const String _aesKeyAlias = 'remote_pc_aes_key';

  // 单例
  static LicenseManager? _instance;
  factory LicenseManager.getInstance() => _instance ??= LicenseManager._();
  LicenseManager._();

  /// 从平台安全存储获取 AES-256 密钥
  /// 首次运行时生成并保存到 FlutterSecureStorage（各平台安全存储）
  static Future<crypto.SecretKey> _getAesKey() async {
    const storage = FlutterSecureStorage();
    final existing = await storage.read(key: _aesKeyAlias);
    if (existing != null && existing.isNotEmpty) {
      return crypto.SecretKey(base64Decode(existing));
    }
    // 首次运行：生成随机密钥并安全存储
    final r = Random.secure();
    final keyBytes = List<int>.generate(32, (_) => r.nextInt(256));
    await storage.write(key: _aesKeyAlias, value: base64Encode(keyBytes));
    print('[LicenseManager] AES key generated and stored securely');
    return crypto.SecretKey(keyBytes);
  }

  bool _childMode = false;
  bool _activated = false;
  String? _deviceId;
  String? _deviceName;

  bool get isActivated => _activated;
  bool get isChildMode => _childMode;
  String? get deviceId => _deviceId;
  String? get deviceName => _deviceName;

  /// 生成设备唯一 ID（跨平台）
  Future<String> generateDeviceId() async {
    const storage = FlutterSecureStorage();
    final String? stored = await storage.read(key: _keyAlias);
    if (stored != null && stored.isNotEmpty) return stored;
    final rand = _secureRandomBytes(16);
    final id =
        'REM-${base64Encode(rand).substring(0, 22).replaceAll('/', 'X').replaceAll('+', 'Y')}';
    await storage.write(key: _keyAlias, value: id);
    return id;
  }

  List<int> _secureRandomBytes(int len) {
    final r = Random.secure();
    return List<int>.generate(len, (_) => r.nextInt(256));
  }

  /// AES-256-GCM 加密（与原 Java 版兼容）
  Future<List<int>> encryptAesGcm(String plaintext) async {
    final algorithm = crypto.AesGcm.with256bits();
    final secretKey = await _getAesKey();
    final nonceBytes = _secureRandomBytes(12);
    final result = await algorithm.encrypt(
      utf8.encode(plaintext),
      secretKey: secretKey,
      nonce: nonceBytes,
    );
    return [...result.nonce, ...result.cipherText, ...result.mac.bytes];
  }

  /// AES-256-GCM 解密
  Future<String> decryptAesGcm(List<int> data) async {
    final algorithm = crypto.AesGcm.with256bits();
    final secretKey = await _getAesKey();
    final result = await algorithm.decrypt(
      crypto.SecretBox(
        data.sublist(12, data.length - 16),
        nonce: data.sublist(0, 12),
        mac: crypto.Mac(data.sublist(data.length - 16)),
      ),
      secretKey: secretKey,
    );
    return utf8.decode(result);
  }

  /// 验证激活码格式：TERM-XXXX-XXXX-XXXX-XXXX
  /// v2: 使用 HMAC-SHA256 签名，防伪造
  Future<bool> verifyActivationCode(String code) async {
    final re =
        RegExp(r'^TERM-[A-Z0-9]{4}-[A-Z0-9]{4}-[A-Z0-9]{4}-[A-Z0-9]{4}$');
    if (!re.hasMatch(code)) return false;
    final parts = code.split('-').sublist(1);
    // 计算前 3 段 + 设备 ID 的 HMAC（绑定设备，防滥用）
    final deviceId = _deviceId ?? '';
    if (deviceId.isEmpty) return false;
    final data = utf8.encode('${parts[0]}${parts[1]}${parts[2]}:$deviceId');
    final key = await _getAesKey();
    final algorithm = crypto.Hmac.sha256();
    final mac = await algorithm.calculateMac(data, secretKey: key);
    // 取 HMAC 前 4 字节，Base32 编码，取前 4 字符
    final signature = base64Url.encode(mac.bytes).substring(0, 4).toUpperCase();
    // 常量时间比较
    return _constantTimeEqual(parts[3], signature);
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

  /// 激活设备
  Future<bool> activate(String code) async {
    if (!await verifyActivationCode(code)) return false;
    _deviceId = await generateDeviceId();
    _deviceName = await _getDeviceName();
    _activated = true;
    await _saveActivation();
    return true;
  }

  Future<void> _saveActivation() async {
    final map = {
      'deviceId': _deviceId,
      'deviceName': _deviceName,
      'activated': _activated,
      'code': _deviceId != null ? 'TERM-XXXX-XXXX-XXXX-XXXX' : null,
    };
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_activationFile, jsonEncode(map));
  }

  Future<String> _getDeviceName() async {
    // 使用 device_info_plus 获取真实设备名
    try {
      final plugin = DeviceInfoPlugin();
      if (Platform.isAndroid) {
        final info = await plugin.androidInfo;
        return info.model;
      } else if (Platform.isIOS) {
        final info = await plugin.iosInfo;
        return info.model;
      }
    } catch (_) {}
    return 'Unknown-Device';
  }

  /// 自毁（子端模式）— 对应原 Java 版 selfDestruct()
  Future<void> selfDestruct(String reason) async {
    if (!_childMode || !_activated) return;
    // 先上报主端，再删除激活信息（先读后删，修复原 Bug）
    final did = _deviceId;
    final dname = _deviceName;
    if (did != null && dname != null) {
      await _reportTamperToMaster(reason, did, dname);
    }
    await _clearActivation();
  }

  Future<void> _reportTamperToMaster(
      String reason, String deviceId, String deviceName) async {
    // 通过 HTTP 上报主端 MasterAlertServer (:9990)
    try {
      final client = HttpClient();
      final req = await client.post('127.0.0.1', 9990, '/alert');
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode({
        'deviceId': deviceId,
        'deviceName': deviceName,
        'reason': reason,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      }));
      await req.close();
    } catch (_) {}
  }

  Future<void> _clearActivation() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_activationFile);
    const storage = FlutterSecureStorage();
    await storage.delete(key: _keyAlias);
    _activated = false;
    _deviceId = null;
  }

  void setChildMode(bool v) => _childMode = v;
}
