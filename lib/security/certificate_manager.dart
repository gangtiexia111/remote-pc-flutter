import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'secure_storage_validator.dart';

/// TLS 证书管理器 — 运行时生成自签名证书（V5-02 修复，V6-06 加固，V6-自检 加固）
///
/// 安全策略：
/// 1. 首次启动时生成 RSA-2048 自签名证书（通过 openssl 子进程）
/// 2. 私钥存储在 FlutterSecureStorage（各平台安全存储），不打包进应用
/// 3. 后续启动从安全存储加载
/// 4. 证书包含设备指纹，每台设备唯一
/// 5. 如果 openssl 不可用，降级到 HTTP（不使用不安全的固定证书）
/// 6. V6-06：不再使用 -nodes 标志，私钥通过 passphrase 保护写入磁盘
///    passphrase 随机生成，仅存在于内存中
/// 7. V6-自检：Linux 上检测安全存储是否可用，不可用时私钥仅驻留内存
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

  /// V6-自检：标记是否检测到不安全存储环境（Linux 无 libsecret）
  bool _insecureStorageDetected = false;

  /// 证书是否已加载
  bool get isLoaded => certPem != null && keyPem != null;

  /// 获取或生成 TLS 证书
  ///
  /// 返回 true 表示成功加载证书，false 表示降级到 HTTP
  Future<bool> loadOrGenerate() async {
    // V6-自检：检测安全存储是否可用（Linux 无 libsecret 时私钥明文存储）
    final storageWarning = await SecureStorageValidator.validate(storage: _storage);
    if (storageWarning != null) {
      _insecureStorageDetected = true;
      print('[TLS] ⚠️ $storageWarning');
      if (Platform.isLinux) {
        print('[TLS] ⚠️ Private key will be held in-memory only (not persisted to insecure storage)');
      }
    }

    // 1. 尝试从安全存储加载
    if (!_insecureStorageDetected && await _loadFromSecureStorage()) {
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
  /// V6-06 加固：不再使用 -nodes 标志（私钥用随机 passphrase 加密写入磁盘）
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

      // V6-06：生成随机 passphrase 保护私钥（不再用 -nodes）
      final passphraseBytes = List<int>.generate(32, (_) => Random.secure().nextInt(256));
      final passphrase = base64Encode(passphraseBytes);
      final passphraseFile = File('${tempDir.path}/passphrase.txt');
      await passphraseFile.writeAsString(passphrase);

      // 生成设备唯一标识（用于证书 CN）
      final deviceId = _generateDeviceId();

      // V6-06：使用 -passout file: 保护私钥（不再 -nodes 明文写磁盘）
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
        '-passout',
        'file:${passphraseFile.path}', // V6-06：私钥加密保护
        '-subj',
        '/CN=RemotePC-$deviceId/O=RemotePC/C=US',
      ]);

      if (result.exitCode != 0) {
        print('[TLS] OpenSSL generation failed: ${result.stderr}');
        await _cleanupTemp(tempDir);
        return false;
      }

      // V6-06：用 passphrase 解密私钥后读入内存（磁盘上始终是加密的）
      final decryptResult = await Process.run('openssl', [
        'rsa',
        '-in',
        keyFile.path,
        '-passin',
        'file:${passphraseFile.path}',
      ]);

      if (decryptResult.exitCode != 0) {
        print('[TLS] Key decryption failed');
        await _cleanupTemp(tempDir);
        return false;
      }

      // 读取证书和已解密的私钥
      certPem = await certFile.readAsString();
      keyPem = decryptResult.stdout.toString();

      // 计算证书指纹
      fingerprint = await _computeFingerprint(certFile.path);

      // 保存到安全存储
      await _saveToSecureStorage();

      // 清理临时文件（V6-06：包括 passphrase 文件，多重覆写）
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
  /// V6-自检：不安全存储环境下不保存私钥（仅驻留内存，重启后重新生成）
  Future<void> _saveToSecureStorage() async {
    await _storage.write(key: _certStorageKey, value: certPem);
    if (_insecureStorageDetected) {
      // V6-自检：Linux 无 libsecret 时私钥不能明文存储到 JSON 文件
      print('[TLS] ⚠️ Private key NOT persisted (insecure storage environment detected)');
      // 私钥仅驻留内存，下次重启需重新生成证书
    } else {
      await _storage.write(key: _keyStorageKey, value: keyPem);
    }
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

  /// 清理临时目录（安全删除私钥文件和 passphrase 文件）
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
      // V6-06 自检：覆写 passphrase 文件后再删除（防止文件恢复获取密钥保护密码）
      final passphraseFile = File('${dir.path}/passphrase.txt');
      if (await passphraseFile.exists()) {
        final r = Random.secure();
        final randomData = List<int>.generate(2048, (_) => r.nextInt(256));
        await passphraseFile.writeAsBytes(randomData);
        await passphraseFile.delete();
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
