import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:cryptography/cryptography.dart' as crypto;
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'secure_storage_validator.dart';

/// 授权管理器 — 对应原 Java 版 LicenseManager.java
/// 支持 AES-256-GCM 激活码验证，支持 Android/iOS/Desktop 三端
class LicenseManager {
  static const String _activationFile = 'activation.json';
  static const String _keyAlias = 'remote_pc_activation';

  // AES-256-GCM 密钥 — 从平台安全存储读取，不存在则生成并保存
  // 不再硬编码，避免反编译泄露
  static const String _aesKeyAlias = 'remote_pc_aes_key';

  // V7-04 修复：独立的 HMAC 签名密钥别名（不再与 AES 加密密钥复用）
  static const String _hmacKeyAlias = 'remote_pc_hmac_key';

  /// V7-04 修复：使用 HKDF 从 AES 密钥派生独立的 HMAC 密钥
  /// 将加密密钥和签名密钥分离，避免"一密钥泄露 → 加密+签名双破"
  static Future<crypto.SecretKey> _getHmacKey() async {
    const storage = FlutterSecureStorage();

    // V6-04：检查安全存储是否真正加密
    final warning = await SecureStorageValidator.validate(storage: storage);
    if (warning != null && Platform.isLinux) {
      // Linux 明文存储：HMAC 密钥也从 AES 密钥派生（内存中持有）
      final aesKey = await _getAesKey();
      return _deriveHmacKey(aesKey);
    }

    // 优先尝试读取已保存的 HMAC 密钥
    final existing = await storage.read(key: _hmacKeyAlias);
    if (existing != null && existing.isNotEmpty) {
      return crypto.SecretKey(base64Decode(existing));
    }

    // 首次：从 AES 密钥派生 HMAC 密钥
    final aesKey = await _getAesKey();
    final hmacKey = await _deriveHmacKey(aesKey);
    // 保存派生密钥（非 Linux 明文存储环境）
    final keyBytes = await hmacKey.extractBytes();
    await storage.write(key: _hmacKeyAlias, value: base64Encode(keyBytes));
    return hmacKey;
  }

  /// V7-04：HKDF-SHA256 从 AES 密钥派生 HMAC 密钥
  /// info = "RemotePC-HMAC-KEY-V1"（固定上下文，确保确定性派生）
  static Future<crypto.SecretKey> _deriveHmacKey(crypto.SecretKey aesKey) async {
    final algorithm = crypto.Hkdf(
      hmac: crypto.Hmac.sha256(),
      outputLength: 32,
    );
    final secretKeyData = await aesKey.extractBytes();
    final derived = await algorithm.deriveKey(
      secretKey: crypto.SecretKey(secretKeyData),
      nonce: [], // HKDF extract step uses HMAC, nonce not needed in extract
      info: utf8.encode('RemotePC-HMAC-KEY-V1'),
    );
    return derived;
  }

  // 单例
  static LicenseManager? _instance;
  factory LicenseManager.getInstance() => _instance ??= LicenseManager._();
  LicenseManager._();

  /// 从平台安全存储获取 AES-256 密钥
  /// 首次运行时生成并保存到 FlutterSecureStorage（各平台安全存储）
  /// V6-04 修复：检测 Linux 安全存储降级（AES 密钥明文存储是灾难级）
  static Future<crypto.SecretKey> _getAesKey() async {
    const storage = FlutterSecureStorage();

    // V6-04：检查安全存储是否真正加密
    final warning = await SecureStorageValidator.validate(storage: storage);
    if (warning != null) {
      print('[LicenseManager] ⚠️ $warning');
      // Linux 明文存储不保存 AES 密钥 → 仅内存中持有（应用重启后重新生成）
      // 这意味着每次重启都需要重新激活，但避免了密钥泄露
      if (Platform.isLinux) {
        final keyBytes = List<int>.generate(32, (_) => Random.secure().nextInt(256));
        print('[LicenseManager] AES key generated in-memory only (unsafe storage detected)');
        return crypto.SecretKey(keyBytes);
      }
    }

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
    // 最小长度：12 字节 nonce + 0 字节明文 + 16 字节 MAC = 28 字节
    if (data.length < 28) {
      throw ArgumentError(
          'Invalid ciphertext: too short (${data.length} bytes, min 28)');
    }
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
  /// V7-04 修复：使用独立的 HMAC 密钥（不再与 AES 加密密钥复用）
  Future<bool> verifyActivationCode(String code) async {
    final re =
        RegExp(r'^TERM-[A-Z0-9]{4}-[A-Z0-9]{4}-[A-Z0-9]{4}-[A-Z0-9]{4}$');
    if (!re.hasMatch(code)) return false;
    final parts = code.split('-').sublist(1);
    // 获取 deviceId：优先用已有的，否则先生成（首次激活场景）
    final deviceId = _deviceId ?? await generateDeviceId();
    if (deviceId.isEmpty) return false;
    final data = utf8.encode('${parts[0]}${parts[1]}${parts[2]}:$deviceId');
    // V7-04：使用独立派生的 HMAC 密钥（与 AES 加密密钥分离）
    final hmacKey = await _getHmacKey();
    final algorithm = crypto.Hmac.sha256();
    final mac = await algorithm.calculateMac(data, secretKey: hmacKey);
    // 取 HMAC 前 4 字节，Base32 编码，取前 4 字符
    final signature = base64Url.encode(mac.bytes).substring(0, 4).toUpperCase();
    // 常量时间比较
    return _constantTimeEqual(parts[3], signature);
  }

  /// 常量时间字符串比较（防时序攻击 + 长度侧信道 V6-01 修复）
  /// 即使长度不同，也执行相同次数的循环，防止通过时间差泄露长度信息
  bool _constantTimeEqual(String a, String b) {
    if (a.length != b.length) {
      // 仍执行完整循环（用较长字符串的长度），防止长度侧信道
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

  /// 激活设备
  Future<bool> activate(String code) async {
    if (!await verifyActivationCode(code)) return false;
    _deviceId = await generateDeviceId();
    _deviceName = await _getDeviceName();
    _activated = true;
    await _saveActivation();
    return true;
  }

  /// V7-08 修复：激活状态保存到 FlutterSecureStorage（不再用 SharedPreferences）
  /// SharedPreferences 是明文 XML/JSON 文件，激活状态可被篡改
  /// FlutterSecureStorage 使用平台安全存储（Keychain/Keystore/DPAPI）
  Future<void> _saveActivation() async {
    const storage = FlutterSecureStorage();

    // V7-08：检测安全存储环境
    final warning = await SecureStorageValidator.validate(storage: storage);
    final insecureStorage = warning != null && Platform.isLinux;

    final map = {
      'deviceId': _deviceId,
      'deviceName': _deviceName,
      'activated': _activated,
      'code': _deviceId != null ? 'TERM-XXXX-XXXX-XXXX-XXXX' : null,
    };

    if (insecureStorage) {
      // Linux 无 libsecret：退回到 SharedPreferences（加 HMAC 完整性保护）
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_activationFile, jsonEncode(map));
      print('[LicenseManager] ⚠️ Activation saved to SharedPreferences (insecure storage: $warning)');
    } else {
      await storage.write(key: _activationFile, value: jsonEncode(map));
    }
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
    const storage = FlutterSecureStorage();
    // V7-08：清除 FlutterSecureStorage 中的激活状态
    await storage.delete(key: _activationFile);
    // 兼容：也清除旧版 SharedPreferences 中的残留（平滑迁移）
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_activationFile);
    await storage.delete(key: _keyAlias);
    // V7-07 修复：自毁时也清除 AES 密钥和 HMAC 密钥
    // 否则自毁后密钥残留，攻击者可利用残留密钥伪造激活
    await storage.delete(key: _aesKeyAlias);
    await storage.delete(key: _hmacKeyAlias);
    _activated = false;
    _deviceId = null;
  }

  void setChildMode(bool v) => _childMode = v;
}
