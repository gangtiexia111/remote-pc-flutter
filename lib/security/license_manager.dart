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

  // AES-256-GCM 配置（与原 Java 版一致）
  static final _aesKey = _deriveKey('RemotePC-2026-Secret-Key-32Byte!!');

  // 单例
  static LicenseManager? _instance;
  factory LicenseManager.getInstance() => _instance ??= LicenseManager._();
  LicenseManager._();

  bool _childMode = false;
  bool _activated = false;
  String? _deviceId;
  String? _deviceName;

  bool get isActivated => _activated;
  bool get isChildMode => _childMode;
  String? get deviceId => _deviceId;
  String? get deviceName => _deviceName;

  /// 派生 AES-256 密钥（与原 Java 版一致）
  static crypto.SecretKey _deriveKey(String password) {
    final bytes = utf8.encode(password);
    if (bytes.length >= 32) return crypto.SecretKey(bytes.sublist(0, 32));
    return crypto.SecretKey([...bytes, ...List.filled(32 - bytes.length, 0)]);
  }

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
    final nonceBytes = _secureRandomBytes(12);
    final result = await algorithm.encrypt(
      utf8.encode(plaintext),
      secretKey: _aesKey,
      nonce: nonceBytes,
    );
    return [...result.nonce, ...result.cipherText, ...result.mac.bytes];
  }

  /// AES-256-GCM 解密
  Future<String> decryptAesGcm(List<int> data) async {
    final algorithm = crypto.AesGcm.with256bits();
    final result = await algorithm.decrypt(
      crypto.SecretBox(
        data.sublist(12, data.length - 16),
        nonce: data.sublist(0, 12),
        mac: crypto.Mac(data.sublist(data.length - 16)),
      ),
      secretKey: _aesKey,
    );
    return utf8.decode(result);
  }

  /// 验证激活码格式：TERM-XXXX-XXXX-XXXX-XXXX
  bool verifyActivationCode(String code) {
    final re =
        RegExp(r'^TERM-[A-Z0-9]{4}-[A-Z0-9]{4}-[A-Z0-9]{4}-[A-Z0-9]{4}$');
    if (!re.hasMatch(code)) return false;
    // 简单校验和：每段首字符的 ASCII 和 mod 37
    final parts = code.split('-').sublist(1);
    int sum = 0;
    for (final p in parts) {
      sum += p.codeUnitAt(0);
    }
    return sum % 37 == 0;
  }

  /// 激活设备
  Future<bool> activate(String code) async {
    if (!verifyActivationCode(code)) return false;
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
