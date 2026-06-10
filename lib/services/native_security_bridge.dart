// ignore_for_file: dangling_library_doc_comments
/// 原生层桥接接口 — 用于调用各平台原生 API
/// 桌面端（Windows/macOS/Linux）防破解关键逻辑应通过 MethodChannel 在此实现
///
/// 对应原 Java 版中需要 JNI 调用的部分

import 'package:flutter/services.dart';

class NativeSecurityBridge {
  static const _channel = MethodChannel('com.remotepc/security');

  /// 检测是否正在被调试（桌面端）
  /// Windows: IsDebuggerPresent() API
  /// macOS: sysctl kinfo_proc -> P_TRACED flag
  /// V7-12 修复：调用失败时返回 true（fail-closed）
  /// 安全检测应遵循"检测失败 = 已被攻击"原则
  static Future<bool> isBeingDebugged() async {
    try {
      return await _channel.invokeMethod('isBeingDebugged') as bool? ?? true;
    } catch (_) {
      // V7-12：MethodChannel 失败 → 认为正在被调试（fail-closed）
      return true;
    }
  }

  /// 反渗透检测：检查关键系统文件完整性
  static Future<bool> verifySystemIntegrity() async {
    try {
      return await _channel.invokeMethod('verifySystemIntegrity') as bool? ??
          false; // 调用失败 → 认为不完整（安全优先）
    } catch (_) {
      return false; // 异常 → 认为不完整（安全优先）
    }
  }

  /// 动态校验：向原生层提交 challenge，获取原生层计算的 response
  /// 注意：v1.0.3 起，DynamicFirewall 已在 Dart 侧使用 HMAC-SHA256 完成验证，
  /// 此方法保留用于兼容性，实际已不再被调用。
  @Deprecated('Use DynamicFirewall.verifyResponse() directly (HMAC-SHA256)')
  static Future<String> computeNativeResponse(String challenge) async {
    try {
      return await _channel.invokeMethod(
              'computeNativeResponse', {'challenge': challenge}) as String? ??
          '';
    } catch (_) {
      return '';
    }
  }

  /// 获取设备硬件指纹（原生层实现）
  /// V7-03 修复：失败时返回唯一的 sentinel 值而非空字符串
  /// 空字符串会与 device_whitelist 的空指纹检查冲突导致绕过
  /// sentinel 格式: __UNAVAILABLE__ 前缀，不会与真实指纹冲突
  static Future<String> getHardwareFingerprint() async {
    try {
      final result = await _channel.invokeMethod('getHardwareFingerprint') as String?;
      // V7-03：如果原生层返回空或 null，返回 sentinel 而非空串
      if (result == null || result.isEmpty) {
        return '__FINGERPRINT_UNAVAILABLE__';
      }
      return result;
    } catch (_) {
      // V7-03：异常时也返回 sentinel（非空串），避免白名单空指纹绕过
      return '__FINGERPRINT_UNAVAILABLE__';
    }
  }

  /// 原生层自毁（清除所有本地数据 + 上报主端）
  static Future<bool> nativeSelfDestruct(String reason) async {
    try {
      return await _channel.invokeMethod(
              'nativeSelfDestruct', {'reason': reason}) as bool? ??
          false;
    } catch (_) {
      return false;
    }
  }
}
