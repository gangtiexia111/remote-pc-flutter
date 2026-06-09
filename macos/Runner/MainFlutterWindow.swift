import Cocoa
import FlutterMacOS
import CommonCrypto

/// Remote PC 主窗口
/// v1.0.3: 集成原生安全 MethodChannel
class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    // ── 注册原生安全 MethodChannel ──────────────
    let channel = FlutterMethodChannel(
      name: "com.remotepc/security",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )

    channel.setMethodCallHandler { (call, result) in
      switch call.method {
      case "isBeingDebugged":
        result(Self.isBeingDebugged())
      case "verifySystemIntegrity":
        result(Self.verifySystemIntegrity())
      case "computeNativeResponse":
        let args = call.arguments as? [String: Any]
        let challenge = args?["challenge"] as? String ?? ""
        result(Self.computeNativeResponse(challenge: challenge))
      case "getHardwareFingerprint":
        result(Self.getHardwareFingerprint())
      case "nativeSelfDestruct":
        let args = call.arguments as? [String: Any]
        let reason = args?["reason"] as? String ?? "unknown"
        result(Self.nativeSelfDestruct(reason: reason))
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    super.awakeFromNib()
  }

  // ── 调试检测 ──────────────────────────────────────

  /// 检测是否正在被调试
  /// macOS: sysctl kinfo_proc -> P_TRACED flag
  private static func isBeingDebugged() -> Bool {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.size
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]

    let result = sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0)
    if result == 0 {
      return (info.kp_proc.p_flag & P_TRACED) != 0
    }
    return false
  }

  // ── 系统完整性校验 ────────────────────────────────

  /// 校验系统完整性
  private static func verifySystemIntegrity() -> Bool {
    // 检查代码签名
    // 简化实现：检查应用是否通过 Mac App Store 或公证
    let bundlePath = Bundle.main.bundlePath

    // 使用 codesign 检查签名
    let task = Process()
    task.launchPath = "/usr/bin/codesign"
    task.arguments = ["-v", bundlePath]

    let pipe = Pipe()
    task.standardError = pipe

    do {
      try task.run()
      task.waitUntilExit()
      return task.terminationStatus == 0
    } catch {
      // codesign 不可用时，默认返回 true
      return true
    }
  }

  // ── 动态验证 ──────────────────────────────────────

  /// 原生层计算验证响应
  /// 算法：challenge 中 Unicode 码点之和 mod 997
  /// 与 Dart 侧 DynamicFirewall.verifyResponse 对应
  private static func computeNativeResponse(challenge: String) -> String {
    if challenge.isEmpty { return "" }

    var sum = 0
    for codePoint in challenge.unicodeScalars {
      sum += Int(codePoint.value)
    }
    return String(sum % 997)
  }

  // ── 硬件指纹 ──────────────────────────────────────

  /// 生成硬件指纹
  /// 组合：IOPlatformSerialNumber + IOPlatformUUID → SHA-256
  private static func getHardwareFingerprint() -> String {
    let serialNumber = getIOPlatformProperty("serial-number") ?? "unknown"
    let uuid = getIOPlatformProperty("UUID") ?? "unknown"

    let raw = "\(serialNumber)|\(uuid)"

    // SHA-256
    var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
    raw.data(using: .utf8)?.withUnsafeBytes {
      _ = CC_SHA256($0.baseAddress, CC_LONG(raw.count), &hash)
    }

    return hash.map { String(format: "%02x", $0) }.joined()
  }

  /// 从 IOKit 获取平台属性
  private static func getIOPlatformProperty(_ key: String) -> String? {
    let service = IOServiceGetMatchingService(kIOMainPortDefault,
      IOServiceMatching("IOPlatformExpertDevice"))

    defer { IOObjectRelease(service) }

    guard service != 0 else { return nil }

    if let data = IORegistryEntryCreateCFProperty(service, key as CFString,
      kCFAllocatorDefault, 0) {
      if let value = data.takeRetainedValue() as? Data {
        return String(data: value, encoding: .utf8)?.trimmingCharacters(
          in: CharacterSet(charactersIn: "\0"))
      }
      if let value = data.takeRetainedValue() as? String {
        return value
      }
    }

    return nil
  }

  // ── 原生自毁 ──────────────────────────────────────

  /// 原生自毁：清除应用数据
  private static func nativeSelfDestruct(reason: String) -> Bool {
    let fileManager = FileManager.default

    // 清除 Application Support 目录
    let appSupport = fileManager.urls(for: .applicationSupportDirectory,
      in: .userDomainMask).first?.appendingPathComponent("remote_pc")

    // 清除 Preferences
    let prefs = fileManager.urls(for: .libraryDirectory,
      in: .userDomainMask).first?.appendingPathComponent("Preferences/remote_pc.plist")

    var success = true

    if let appSupport = appSupport {
      do {
        try fileManager.removeItem(at: appSupport)
      } catch {
        success = false
      }
    }

    if let prefs = prefs {
      do {
        try fileManager.removeItem(at: prefs)
      } catch {
        // plist 可能不存在
      }
    }

    // 清除 Keychain
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: "com.remotepc.activation",
    ]
    SecItemDelete(query as CFDictionary)

    return success
  }
}
