import Cocoa
import FlutterMacOS
import CryptoKit

/// Remote PC main window
/// v1.0.3: integrated native security MethodChannel
class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    // -- Register native security MethodChannel --
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

  // -- Debug detection --

  /// Detect if being debugged
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

  // -- System integrity verification --

  /// Verify system integrity
  private static func verifySystemIntegrity() -> Bool {
    let bundlePath = Bundle.main.bundlePath

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
      return true
    }
  }

  // -- Dynamic verification --

  /// Native compute verification response
  /// Algorithm: sum of Unicode code points in challenge mod 997
  /// Corresponds to Dart side DynamicFirewall.verifyResponse
  // -- Hardware fingerprint --

  /// Generate hardware fingerprint
  /// Uses system_profiler to get hardware info, then SHA-256 via CryptoKit
  private static func getHardwareFingerprint() -> String {
    let serialNumber = runSystemProfilerQuery(key: "serial_number") ?? "unknown"
    let hardwareUUID = runSystemProfilerQuery(key: "hardware_uuid") ?? "unknown"

    let raw = "\(serialNumber)|\(hardwareUUID)"

    let data = raw.data(using: .utf8) ?? Data()
    let hash = SHA256.hash(data: data)
    return hash.compactMap { String(format: "%02x", $0) }.joined()
  }

  /// Query hardware info via system_profiler (avoids IOKit linkage)
  private static func runSystemProfilerQuery(key: String) -> String? {
    let task = Process()
    task.launchPath = "/usr/sbin/system_profiler"
    task.arguments = ["SPHardwareDataType", "-json"]

    let pipe = Pipe()
    task.standardOutput = pipe

    do {
      try task.run()
      task.waitUntilExit()

      let data = pipe.fileHandleForReading.readDataToEndOfFile()
      if let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
         let first = json.first,
         let value = first[key] as? String {
        return value
      }
    } catch {
      // Fallback: try ioreg
    }

    // Fallback to ioreg if system_profiler fails
    let ioregTask = Process()
    ioregTask.launchPath = "/usr/sbin/ioreg"
    ioregTask.arguments = ["-l", "-d", "2"]

    let ioregPipe = Pipe()
    ioregTask.standardOutput = ioregPipe

    do {
      try ioregTask.run()
      ioregTask.waitUntilExit()

      let outputData = ioregPipe.fileHandleForReading.readDataToEndOfFile()
      if let output = String(data: outputData, encoding: .utf8) {
        let pattern = "\"\(key)\" = \"([^\"]+)\""
        if let regex = try? NSRegularExpression(pattern: pattern, options: []),
           let match = regex.firstMatch(in: output, options: [], range: NSRange(location: 0, length: output.utf16.count)) {
          if let range = Range(match.range(at: 1), in: output) {
            return String(output[range])
          }
        }
      }
    } catch {
      // ioreg also failed
    }

    return nil
  }

  // -- Native self-destruct --

  /// Native self-destruct: clear application data
  private static func nativeSelfDestruct(reason: String) -> Bool {
    let fileManager = FileManager.default

    let appSupport = fileManager.urls(for: .applicationSupportDirectory,
      in: .userDomainMask).first?.appendingPathComponent("remote_pc")

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
        // plist may not exist
      }
    }

    // Clear Keychain
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: "com.remotepc.activation",
    ]
    SecItemDelete(query as CFDictionary)

    return success
  }
}
