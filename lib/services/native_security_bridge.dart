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
  static Future<bool> isBeingDebugged() async {
    try {
      return await _channel.invokeMethod('isBeingDebugged') as bool? ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 反渗透检测：检查关键系统文件完整性
  static Future<bool> verifySystemIntegrity() async {
    try {
      return await _channel.invokeMethod('verifySystemIntegrity') as bool? ??
          true;
    } catch (_) {
      return true; // 隔离失败
    }
  }

  /// 动态校验：向原生层提交 challenge，获取原生层计算的 response
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
  static Future<String> getHardwareFingerprint() async {
    try {
      return await _channel.invokeMethod('getHardwareFingerprint') as String? ??
          '';
    } catch (_) {
      return '';
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
