import 'dart:io';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// 安全存储验证器 — 检测 FlutterSecureStorage 在各平台是否真正加密
///
/// V5-05 修复：Linux 上 libsecret 不可用时，FlutterSecureStorage
/// 会降级到明文 JSON 文件存储。本工具检测并警告用户。
class SecureStorageValidator {
  /// 检查当前平台的 FlutterSecureStorage 是否安全
  ///
  /// 返回 null 表示安全（或无法检测），返回 String 表示警告信息
  static Future<String?> validate({FlutterSecureStorage? storage}) async {
    if (!Platform.isLinux) {
      // 非 Linux 平台：Android (Keystore), iOS/macOS (Keychain),
      // Windows (DPAPI) 都是硬件或系统级加密
      return null;
    }

    // Linux: 检查 libsecret 是否可用
    return await _checkLinuxStorage(storage ?? const FlutterSecureStorage());
  }

  /// Linux 安全存储检查
  static Future<String?> _checkLinuxStorage(
      FlutterSecureStorage storage) async {
    try {
      // 1. 检查 libsecret 是否安装
      final libsecretCheck = await Process.run(
        'ldconfig',
        ['-p'],
      );
      if (libsecretCheck.exitCode == 0) {
        final output = libsecretCheck.stdout.toString();
        if (output.contains('libsecret-1.so')) {
          return null; // libsecret 可用，存储是加密的
        }
      }

      // 2. 备用检查：pkg-config
      final pkgConfigCheck = await Process.run(
        'pkg-config',
        ['--exists', 'libsecret-1'],
      );
      if (pkgConfigCheck.exitCode == 0) {
        return null; // libsecret 可用
      }

      // 3. libsecret 不可用 → 检查是否已降级到明文存储
      final homeDir = Platform.environment['HOME'] ?? '';
      if (homeDir.isNotEmpty) {
        final plainTextFile = File(
            '$homeDir/.local/share/flutter_secure_storage/flutter_secure_storage.dat');
        if (await plainTextFile.exists()) {
          return '⚠️ Linux 安全存储已降级到明文文件！\n'
              '文件位置: ${plainTextFile.path}\n'
              '请安装 libsecret: sudo apt install libsecret-1-0 libsecret-1-dev\n'
              '或: sudo yum install libsecret-devel\n'
              '未加密存储可能导致白名单和密钥泄露！';
        }
      }

      // 4. libsecret 不可用但还没有明文文件 → 警告
      return '⚠️ Linux 上 libsecret 未安装，安全存储可能降级到明文！\n'
          '请安装: sudo apt install libsecret-1-0 libsecret-1-dev\n'
          '或: sudo yum install libsecret-devel';
    } catch (e) {
      // 无法检测 → 不阻止启动，但发出警告
      return '⚠️ 无法验证 Linux 安全存储状态: $e\n'
          '请确保已安装 libsecret';
    }
  }

  /// 执行安全存储测试（读写验证）
  static Future<bool> performReadWriteTest(
      {FlutterSecureStorage? storage}) async {
    storage ??= const FlutterSecureStorage();
    const testKey = '__security_test_${DateTime.now().millisecondsSinceEpoch}';
    const testValue = 'test_value_12345';

    try {
      await storage.write(key: testKey, value: testValue);
      final readBack = await storage.read(key: testKey);
      await storage.delete(key: testKey);
      return readBack == testValue;
    } catch (e) {
      return false;
    }
  }
}
