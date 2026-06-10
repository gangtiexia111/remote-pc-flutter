import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// 设备配对白名单 — 只允许已配对的设备连接主端
///
/// 安全策略：
/// 1. 首次连接需主端确认（弹窗/PIN）
/// 2. 配对成功后记录设备 ID + 指纹到白名单
/// 3. 后续连接直接放行白名单设备
/// 4. 支持手动移除设备
/// 5. 白名单存储在 FlutterSecureStorage（各平台安全存储）
class DeviceWhitelist {
  static const String _whitelistKey = 'remote_pc_device_whitelist';

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

  DeviceWhitelist({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  /// 加载白名单（从安全存储读取）
  Future<void> load() async {
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
  bool isAllowed(String deviceId, {String? fingerprint}) {
    for (final d in _devices) {
      if (d[kDeviceId] == deviceId) {
        // 如果白名单中有指纹，也要验证
        if (fingerprint != null && d.containsKey(kFingerprint)) {
          return d[kFingerprint] == fingerprint;
        }
        return true;
      }
    }
    return false;
  }

  /// 添加设备到白名单（配对成功后调用）
  Future<bool> addDevice({
    required String deviceId,
    String? fingerprint,
    required String name,
  }) async {
    // 检查是否已存在
    if (isAllowed(deviceId, fingerprint: fingerprint)) return true;

    _devices.add({
      kDeviceId: deviceId,
      kFingerprint: fingerprint ?? '',
      kName: name,
      kPairedAt: DateTime.now().millisecondsSinceEpoch,
      kLastSeen: DateTime.now().millisecondsSinceEpoch,
    });
    await _save();
    return true;
  }

  /// 更新设备最后在线时间
  Future<void> updateLastSeen(String deviceId) async {
    for (final d in _devices) {
      if (d[kDeviceId] == deviceId) {
        d[kLastSeen] = DateTime.now().millisecondsSinceEpoch;
        break;
      }
    }
    await _save();
  }

  /// 移除设备（取消配对）
  Future<bool> removeDevice(String deviceId) async {
    final before = _devices.length;
    _devices.removeWhere((d) => d[kDeviceId] == deviceId);
    if (_devices.length < before) {
      await _save();
      return true;
    }
    return false;
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
