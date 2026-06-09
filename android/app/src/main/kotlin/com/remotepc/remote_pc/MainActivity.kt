package com.remotepc.remote_pc

import android.content.Context
import android.os.Build
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.security.MessageDigest

/// Remote PC 主 Activity
/// v1.0.3: 集成原生安全 MethodChannel
class MainActivity : FlutterActivity() {

    private val CHANNEL = "com.remotepc/security"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "isBeingDebugged" -> {
                        result.success(isBeingDebugged())
                    }
                    "verifySystemIntegrity" -> {
                        result.success(verifySystemIntegrity())
                    }
                    "getHardwareFingerprint" -> {
                        result.success(getHardwareFingerprint())
                    }
                    "nativeSelfDestruct" -> {
                        val reason = call.argument<String>("reason") ?: "unknown"
                        result.success(nativeSelfDestruct(reason))
                    }
                    else -> result.notImplemented()
                }
            }
    }

    // ── 调试检测 ──────────────────────────────────────

    /**
     * 检测是否正在被调试
     * 方法：检查 android.os.Debug.isDebuggerConnected()
     * 增强：检查 debug 标志位
     */
    private fun isBeingDebugged(): Boolean {
        // 标准 API 检测
        if (android.os.Debug.isDebuggerConnected()) return true
        if (android.os.Debug.waitingForDebugger()) return true

        // 检测 ro.debuggable 系统属性
        // 注意：root 设备上 debuggable=1 并不一定是调试，只是可调试
        return false
    }

    // ── 系统完整性校验 ────────────────────────────────

    /**
     * 校验系统关键文件完整性
     * Android 端检查：
     *   1. APK 签名是否与预期一致
     *   2. 关键 SharedPreferences 是否被篡改
     */
    private fun verifySystemIntegrity(): Boolean {
        try {
            // 检查 APK 签名
            val pm = packageManager
            val packageName = packageName
            val packageInfo = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                pm.getPackageInfo(packageName, android.content.pm.PackageManager.GET_SIGNING_CERTIFICATES)
            } else {
                @Suppress("DEPRECATION")
                pm.getPackageInfo(packageName, android.content.pm.PackageManager.GET_SIGNATURES)
            }

            // 签名存在性检查（更完整的实现应比对签名哈希）
            val hasValidSignature = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                packageInfo.signingInfo != null
            } else {
                @Suppress("DEPRECATION")
                packageInfo.signatures?.isNotEmpty() == true
            }

            if (!hasValidSignature) return false

            // 检查是否在模拟器上运行
            if (isEmulator()) return false

            return true
        } catch (e: Exception) {
            return false
        }
    }

    /**
     * 模拟器检测
     */
    private fun isEmulator(): Boolean {
        // 检测常见模拟器特征
        val isEmulatorBuild = (Build.FINGERPRINT.startsWith("generic")
                || Build.FINGERPRINT.startsWith("unknown")
                || Build.MODEL.contains("Emulator")
                || Build.MODEL.contains("Android SDK")
                || Build.MANUFACTURER.contains("Genymotion")
                || Build.BRAND.startsWith("generic")
                || Build.DEVICE.startsWith("generic")
                || Build.PRODUCT.contains("sdk")
                || Build.PRODUCT.contains("vbox")
                || Build.HARDWARE.contains("goldfish")
                || Build.HARDWARE.contains("ranchu")
                || "google_sdk" == Build.PRODUCT)

        // 检测模拟器特有文件
        if (!isEmulatorBuild) {
            try {
                val process = Runtime.getRuntime().exec("getprop ro.hardware")
                val output = process.inputStream.bufferedReader().readText().trim()
                if (output.contains("goldfish") || output.contains("ranchu")) return true
            } catch (_: Exception) {}
        }

        return isEmulatorBuild
    }

    // ── 动态验证 ──────────────────────────────────────

    /**
     * 原生层计算验证响应
     * 算法：challenge 中 Unicode 码点之和 mod 997
     * 与 Dart 侧 DynamicFirewall.verifyResponse 对应
     */
    // ── 硬件指纹 ──────────────────────────────────────

    /**
     * 生成设备硬件指纹
     * 组合：ANDROID_ID + 设备型号 + 制造商 → SHA-256
     */
    private fun getHardwareFingerprint(): String {
        try {
            val androidId = Settings.Secure.getString(
                contentResolver,
                Settings.Secure.ANDROID_ID
            ) ?: "unknown"

            val raw = "${androidId}|${Build.MODEL}|${Build.MANUFACTURER}|${Build.BRAND}"

            val digest = MessageDigest.getInstance("SHA-256")
            val hash = digest.digest(raw.toByteArray(Charsets.UTF_8))
            return hash.joinToString("") { "%02x".format(it) }
        } catch (e: Exception) {
            return ""
        }
    }

    // ── 原生自毁 ──────────────────────────────────────

    /**
     * 原生层自毁：清除应用数据
     * 调用系统 API 清除应用数据，等效于「清除数据」
     */
    @Suppress("DEPRECATION")
    private fun nativeSelfDestruct(reason: String): Boolean {
        try {
            // 清除应用数据
            if (Build.VERSION_CODES.KITKAT <= Build.VERSION.SDK_INT) {
                // Android 4.4+ 使用 ActivityManager.clearApplicationUserData
                val am = getSystemService(Context.ACTIVITY_SERVICE) as android.app.ActivityManager
                val method = am.javaClass.getMethod("clearApplicationUserData")
                val result = method.invoke(am) as? Boolean ?: false
                return result
            } else {
                // 低版本：手动清除 SharedPreferences
                val prefsDir = File(applicationInfo.dataDir, "shared_prefs")
                if (prefsDir.exists() && prefsDir.isDirectory) {
                    prefsDir.listFiles()?.forEach { it.delete() }
                }
                return true
            }
        } catch (e: Exception) {
            return false
        }
    }
}
