import 'dart:async';
import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'secure_storage_validator.dart';

/// 设备配对白名单 — 只允许已配对的设备连接主端
///
/// 安全策略：
/// 1. 首次连接需主端确认（弹窗/PIN）
/// 2. 配对成功后记录设备 ID + 指纹到白名单
/// 3. 后续连接直接放行白名单设备
/// 4. 支持手动移除设备
/// 5. 白名单存储在 FlutterSecureStorage（各平台安全存储）
/// 6. V5-03 修复：并发操作互斥锁，防止数据覆盖
class DeviceWhitelist {
  static const String _whitelistKey = 'remote_pc_device_whitelist';

  /// 白名单最大设备数（防无限增长）
  static const int _maxDevices = 16;

  /// 白名单条目
  /// [deviceId] 设备唯一标识
  /// [fingerprint] 设备硬件指纹（防伪造设备 ID）
  /// [name] 设备名称（方便用户识别）
  /// [pairedAt] 配对时间戳
  /// [lastSeen] 最后在线时间戳
  static const String kDeviceId = 'deviceId';
  static const String kFingerprint = 'fingerprint';
  static const String kName = 'name';
  static const String kPairedAt = 'pairedAt';
  static const String kLastSeen = 'lastSeen';

  final FlutterSecureStorage _storage;
  List<Map<String, dynamic>> _devices = [];

  /// 并发操作互斥锁（V5-03 修复：防止多个 await 同时修改 _devices）
  Completer<void>? _writeLock;

  DeviceWhitelist({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  /// 使用互斥锁执行写操作（防止并发数据覆盖）
  Future<T> _withLock<T>(Future<T> Function() fn) async {
    // 等待之前的写操作完成
    while (_writeLock != null) {
      await _writeLock!.future;
    }
    _writeLock = Completer<void>();
    try {
      return await fn();
    } finally {
      _writeLock!.complete();
      _writeLock = null;
    }
  }

  /// 加载白名单（从安全存储读取）
  /// V5-05：检测 Linux 安全存储降级
  Future<void> load() async {
    // 检查存储安全性
    final warning = await SecureStorageValidator.validate(storage: _storage);
    if (warning != null) {
      print('[Whitelist] $warning');
    }

    final raw = await _storage.read(key: _whitelistKey);
    if (raw != null && raw.isNotEmpty) {
      try {
        final list = jsonDecode(raw) as List<dynamic>;
        _devices = list.cast<Map<String, dynamic>>();
      } catch (_) {
        _devices = [];
      }
    }
  }

  /// 保存白名单（写入安全存储）
  Future<void> _save() async {
    await _storage.write(
      key: _whitelistKey,
      value: jsonEncode(_devices),
    );
  }

  /// 检查设备是否在白名单中
  /// 同时验证设备 ID + 指纹（防止单纯伪造设备 ID）
  ///
  /// 安全策略（V7-02 修复）：
  /// - 白名单中该设备有指纹 → 请求必须提供匹配的指纹
  /// - 白名单中该设备无指纹（空字符串）→ 请求也必须提供非空指纹，但只做 deviceId 匹配
  ///   （不再因 storedFingerprint 为空就直接放行，防止空指纹绕过白名单）
  /// - fingerprint 参数为必填，不允许为空或 null
  bool isAllowed(String deviceId, {String? fingerprint}) {
    for (final d in _devices) {
      if (d[kDeviceId] == deviceId) {
        final storedFingerprint = d[kFingerprint] as String? ?? '';
        // V7-02 修复：请求必须提供非空指纹（杜绝空指纹绕过）
        if (fingerprint == null || fingerprint.isEmpty) return false;
        // 白名单中该设备没有指纹 → 仅验证 deviceId 匹配 + 请求提供了非空指纹
        if (storedFingerprint.isEmpty) return true;
        // 白名单中有指纹 → 必须精确匹配
        return _constantTimeEqual(fingerprint, storedFingerprint);
      }
    }
    return false;
  }

  /// 常量时间字符串比较（防时序攻击 + 长度侧信道 V5-01 修复）
  /// 即使长度不同，也执行相同次数的循环，防止通过时间差泄露长度信息
  bool _constantTimeEqual(String a, String b) {
    if (a.length != b.length) {
      // 仍执行完整循环（用较长字符串的长度），防止长度侧信道
      final maxLen = a.length > b.length ? a.length : b.length;
      // ignore: unused_local_variable
      int dummy = 1; // 预设为非零，确保最后返回 false
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

  /// 添加设备到白名单（配对成功后调用）
  /// V5-03 修复：使用互斥锁防止并发覆盖
  Future<bool> addDevice({
    required String deviceId,
    String? fingerprint,
    required String name,
  }) async {
    return _withLock(() async {
      // 检查是否已存在
      if (isAllowed(deviceId, fingerprint: fingerprint)) return true;

      // 检查设备数上限
      if (_devices.length >= _maxDevices) {
        print('[Whitelist] ❌ Max devices ($_maxDevices) reached');
        return false;
      }

      _devices.add({
        kDeviceId: deviceId,
        kFingerprint: fingerprint ?? '',
        kName: name,
        kPairedAt: DateTime.now().millisecondsSinceEpoch,
        kLastSeen: DateTime.now().millisecondsSinceEpoch,
      });
      await _save();
      return true;
    });
  }

  /// 更新设备最后在线时间
  Future<void> updateLastSeen(String deviceId) async {
    await _withLock(() async {
      for (final d in _devices) {
        if (d[kDeviceId] == deviceId) {
          d[kLastSeen] = DateTime.now().millisecondsSinceEpoch;
          break;
        }
      }
      await _save();
    });
  }

  /// 移除设备（取消配对）
  Future<bool> removeDevice(String deviceId) async {
    return _withLock(() async {
      final before = _devices.length;
      _devices.removeWhere((d) => d[kDeviceId] == deviceId);
      if (_devices.length < before) {
        await _save();
        return true;
      }
      return false;
    });
  }

  /// 获取所有已配对设备
  List<Map<String, dynamic>> get devices => List.unmodifiable(_devices);

  /// 获取已配对设备数量
  int get count => _devices.length;

  /// 清空白名单（慎用！）
  Future<void> clear() async {
    _devices = [];
    await _save();
  }
}
