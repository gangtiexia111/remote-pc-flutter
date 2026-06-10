import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// TLS 证书管理器 — 运行时生成自签名证书（V5-02 修复）
///
/// 安全策略：
/// 1. 首次启动时生成 RSA-2048 自签名证书（通过 openssl 子进程）
/// 2. 私钥存储在 FlutterSecureStorage（各平台安全存储），不打包进应用
/// 3. 后续启动从安全存储加载
/// 4. 证书包含设备指纹，每台设备唯一
/// 5. 如果 openssl 不可用，降级到 HTTP（不使用不安全的固定证书）
class CertificateManager {
  static const String _certStorageKey = 'remote_pc_tls_cert_pem';
  static const String _keyStorageKey = 'remote_pc_tls_key_pem';
  static const String _certFingerprintKey = 'remote_pc_tls_fingerprint';
  static const String _certGeneratedAtKey = 'remote_pc_tls_generated_at';

  final FlutterSecureStorage _storage;

  CertificateManager({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  /// TLS 证书数据
  String? certPem;
  String? keyPem;
  String? fingerprint;

  /// 证书是否已加载
  bool get isLoaded => certPem != null && keyPem != null;

  /// 获取或生成 TLS 证书
  ///
  /// 返回 true 表示成功加载证书，false 表示降级到 HTTP
  Future<bool> loadOrGenerate() async {
    // 1. 尝试从安全存储加载
    if (await _loadFromSecureStorage()) {
      print('[TLS] ✅ Certificate loaded from secure storage');
      return true;
    }

    // 2. 尝试通过 openssl 生成新证书
    if (await _generateViaOpenSSL()) {
      print('[TLS] ✅ New certificate generated and stored securely');
      return true;
    }

    // 3. openssl 不可用 — 尝试纯 Dart 生成（ECDHE，非 RSA）
    if (await _generateFallback()) {
      print('[TLS] ✅ Fallback certificate generated (Dart-only)');
      return true;
    }

    // 4. 全部失败 — 降级到 HTTP
    print('[TLS] ⚠️ Cannot generate TLS certificate — falling back to HTTP');
    print('[TLS] ⚠️ Install OpenSSL for HTTPS support');
    return false;
  }

  /// 从 FlutterSecureStorage 加载已有证书
  Future<bool> _loadFromSecureStorage() async {
    try {
      certPem = await _storage.read(key: _certStorageKey);
      keyPem = await _storage.read(key: _keyStorageKey);
      fingerprint = await _storage.read(key: _certFingerprintKey);

      if (certPem == null || keyPem == null) return false;

      // 验证证书是否过期（简单检查：证书中包含有效期）
      final generatedAt = await _storage.read(key: _certGeneratedAtKey);
      if (generatedAt != null) {
        final genTime = int.tryParse(generatedAt) ?? 0;
        final age = DateTime.now().millisecondsSinceEpoch - genTime;
        // 证书有效期 365 天，提前 30 天重新生成
        if (age > 335 * 24 * 60 * 60 * 1000) {
          print('[TLS] ⚠️ Certificate nearing expiry, regenerating...');
          await _clearStorage();
          return false;
        }
      }

      return certPem!.isNotEmpty && keyPem!.isNotEmpty;
    } catch (e) {
      print('[TLS] Error loading from secure storage: $e');
      return false;
    }
  }

  /// 通过 openssl 子进程生成自签名证书
  Future<bool> _generateViaOpenSSL() async {
    try {
      // 检查 openssl 是否可用
      final checkResult = await Process.run(
        Platform.isWindows ? 'where' : 'which',
        ['openssl'],
      );
      if (checkResult.exitCode != 0) {
        print('[TLS] OpenSSL not found in PATH');
        return false;
      }

      // 生成临时目录
      final tempDir = Directory.systemTemp.createTempSync('remote_pc_tls_');
      final certFile = File('${tempDir.path}/cert.pem');
      final keyFile = File('${tempDir.path}/key.pem');

      // 生成设备唯一标识（用于证书 CN）
      final deviceId = _generateDeviceId();

      // 执行 openssl 生成自签名证书
      final result = await Process.run('openssl', [
        'req',
        '-x509',
        '-newkey',
        'rsa:2048',
        '-keyout',
        keyFile.path,
        '-out',
        certFile.path,
        '-days',
        '365',
        '-nodes',
        '-subj',
        '/CN=RemotePC-$deviceId/O=RemotePC/C=US',
      ]);

      if (result.exitCode != 0) {
        print('[TLS] OpenSSL generation failed: ${result.stderr}');
        await _cleanupTemp(tempDir);
        return false;
      }

      // 读取生成的证书和私钥
      certPem = await certFile.readAsString();
      keyPem = await keyFile.readAsString();

      // 计算证书指纹
      fingerprint = await _computeFingerprint(certFile.path);

      // 保存到安全存储
      await _saveToSecureStorage();

      // 清理临时文件（重要：删除磁盘上的私钥！）
      await _cleanupTemp(tempDir);

      return true;
    } catch (e) {
      print('[TLS] OpenSSL generation error: $e');
      return false;
    }
  }

  /// 纯 Dart 降级方案（使用 openssl 命令行替代）
  ///
  /// 如果 openssl 不可用，生成一个标记为 "INSECURE" 的占位证书
  /// 实际上会降级到 HTTP 模式
  Future<bool> _generateFallback() async {
    // 纯 Dart 生成 X.509 证书需要 asn1lib + pointycastle
    // 当前不实现，直接降级到 HTTP
    // 未来版本可以用 pointycastle 实现纯 Dart 证书生成
    print('[TLS] Pure-Dart certificate generation not yet implemented');
    print('[TLS] Please install OpenSSL for HTTPS support:');
    if (Platform.isWindows) {
      print('[TLS]   - Download from https://slproweb.com/products/Win32OpenSSL.html');
      print('[TLS]   - Or install via: choco install openssl');
    } else if (Platform.isLinux) {
      print('[TLS]   - sudo apt install openssl  (Debian/Ubuntu)');
      print('[TLS]   - sudo yum install openssl  (RHEL/CentOS)');
    }
    return false;
  }

  /// 生成设备唯一标识
  String _generateDeviceId() {
    final r = Random.secure();
    final bytes = List<int>.generate(8, (_) => r.nextInt(256));
    return base64Encode(bytes).replaceAll(RegExp(r'[+/=]'), '').substring(0, 12);
  }

  /// 计算证书指纹
  Future<String> _computeFingerprint(String certPath) async {
    try {
      final result = await Process.run('openssl', [
        'x509',
        '-in',
        certPath,
        '-noout',
        '-fingerprint',
        '-sha256',
      ]);
      if (result.exitCode == 0) {
        final output = result.stdout.toString();
        final match = RegExp(r'sha256 Fingerprint=(.+)').firstMatch(output);
        return match?.group(1)?.trim() ?? 'unknown';
      }
    } catch (_) {}
    return 'unknown';
  }

  /// 保存证书和私钥到安全存储
  Future<void> _saveToSecureStorage() async {
    await _storage.write(key: _certStorageKey, value: certPem);
    await _storage.write(key: _keyStorageKey, value: keyPem);
    await _storage.write(key: _certFingerprintKey, value: fingerprint);
    await _storage.write(
      key: _certGeneratedAtKey,
      value: DateTime.now().millisecondsSinceEpoch.toString(),
    );
  }

  /// 清除安全存储中的证书数据
  Future<void> _clearStorage() async {
    await _storage.delete(key: _certStorageKey);
    await _storage.delete(key: _keyStorageKey);
    await _storage.delete(key: _certFingerprintKey);
    await _storage.delete(key: _certGeneratedAtKey);
    certPem = null;
    keyPem = null;
    fingerprint = null;
  }

  /// 清理临时目录（安全删除私钥文件）
  Future<void> _cleanupTemp(Directory dir) async {
    try {
      // 先覆写私钥文件（防止文件恢复）
      final keyFile = File('${dir.path}/key.pem');
      if (await keyFile.exists()) {
        final r = Random.secure();
        final randomData = List<int>.generate(2048, (_) => r.nextInt(256));
        await keyFile.writeAsBytes(randomData);
        await keyFile.delete();
      }
      final certFile = File('${dir.path}/cert.pem');
      if (await certFile.exists()) {
        await certFile.delete();
      }
      await dir.delete();
    } catch (e) {
      print('[TLS] Warning: temp cleanup error: $e');
    }
  }

  /// 获取证书信息（用于 UI 显示）
  Map<String, dynamic> getCertificateInfo() {
    return {
      'loaded': isLoaded,
      'fingerprint': fingerprint ?? 'N/A',
      'hasPrivateKey': keyPem != null,
      'source': isLoaded ? 'secure_storage' : 'none',
    };
  }

  /// 强制重新生成证书（用于证书轮换）
  Future<bool> regenerate() async {
    await _clearStorage();
    return await loadOrGenerate();
  }
}
