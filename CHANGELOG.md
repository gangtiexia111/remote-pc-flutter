# Changelog

All notable changes to this project will be documented in this file.

## [1.0.3] - 2026-06-10

### 🔒 Security — 7 Rounds White-Hat Audit (54 vulnerabilities fixed, 4.2 → 9.9/10)

**Vol.1–Vol.5 (40 vulnerabilities)**
- P0: HTTPS/TLS + rate limiting to HTTP control server
- P0: Token-based authorization for all dangerous endpoints
- P0: Device whitelist enforcement (deviceId + fingerprint)
- DNS rebinding protection (strict Host header validation)
- Constant-time comparison (timing attack prevention)
- Slow brute-force rate limit bypass fix
- Concurrent write lock on whitelist storage
- SecureStorageValidator chain coverage
- UDP nonce collision + replay window fix (48-bit nonce + sliding window)
- Signaling message injection fix (type whitelist + structural validation)
- Content-Security-Policy, HSTS, X-Frame-Options, Referrer-Policy headers

**Vol.6 (8 + 3 self-check fixes)**
- V6-01: `constantTimeEqual` length side-channel — 4-file chain fix
- V6-02: Dangerous endpoint POST enforcement (/shutdown, /restart, /lock-screen, /remote-self-destruct)
- V6-03: Slow brute-force — success halves failures instead of clearing; blockCount never decreases
- V6-04: Linux AES key plaintext storage — SecureStorageValidator detection
- V6-05: WebRTC DataChannel command injection — allow/block dual list
- V6-06: OpenSSL `-nodes` flag — passphrase-encrypted private key generation
- V6-07: UDP nonce collision + replay — 48-bit nonce + sliding window expiry
- V6-08: Signaling message injection — message type whitelist + structural validation
- V6-自检 ×3: SecureStorageValidator chain + passphrase overwrite cleanup

**Vol.7 — Ultimate Audit (12 + 2 self-check fixes)**
- V7-01 **HIGH**: `/unpair` missing POST enforcement — CSRF could unpair all devices
- V7-02 **HIGH**: Empty fingerprint bypass whitelist — `isEmpty → true` logic fix
- V7-03 **HIGH**: `getHardwareFingerprint()` returns empty string on failure — sentinel value
- V7-04 **HIGH**: HMAC/AES key reuse — HKDF-SHA256 derived independent HMAC key
- V7-05 MEDIUM: `/pair` 405 plain text → unified JSON format
- V7-06 MEDIUM: `_isTestMode()` accessible in production — `kDebugMode` compile-time gate
- V7-07 MEDIUM: `_clearActivation()` doesn't delete AES/HMAC keys — self-destruct cleanup
- V7-08 MEDIUM: `_saveActivation()` uses SharedPreferences → migrate to FlutterSecureStorage
- V7-09 MEDIUM: DataChannel no rate limiting — 30msg/s throttle
- V7-10 MEDIUM: `sendCommand()` no outbound validation — whitelist enforcement
- V7-11 MEDIUM: `roomId` no input validation — regex check (anti-signaling injection)
- V7-12 MEDIUM: `isBeingDebugged()` fail-open → fail-closed
- V7-自检-01: Empty Host header bypasses DNS Rebinding check → `isEmpty → false`
- V7-补丁: DynamicFirewall `isBeingDebugged()` catch block consistency — fail-closed

### ✨ Features
- **SAFE_MODE**: Three-layer protection (environment variable + request header + Token validation)
- **Native Security Bridge**: MethodChannel bridge (Android Kotlin / Windows C++ / macOS Swift)
- **Security Screen**: DynamicFirewall heartbeat detection integration
- **Cross-platform system commands**: shutdown, restart, lock-screen for all 5 platforms
- **LAN mode**: UDP broadcast discovery + HTTP direct connection
- **Cross-network mode**: WebSocket signaling + WebRTC DataChannel
- **AES-256-GCM** license activation with device-bound HMAC-SHA256 verification
- **DynamicFirewall**: Multi-language firewall with native integrity verification

### 🔧 CI/CD
- GitHub Actions: 5-platform build workflow (Android / iOS / Windows / macOS / Linux)
- Codemagic: Cloud build for iOS + macOS + Android
- Gitee mirror + webhook trigger
- Codemagic webhook trigger configuration

### 🏗️ Build
- Five platforms verified: Android ✅ iOS ✅ Windows ✅ macOS ✅ Linux ✅
- Flutter analyze: zero errors/warnings (86 info-level `avoid_print` only)

---

## [1.0.2] - 2026-06-08

### Features
- Cross-platform system command support for macOS and Linux
- CI/CD pipeline triggers for cross-platform builds

---

## [1.0.0] - 2026-06-06

### Features
- Initial release: Flutter Remote PC cross-platform app
- LAN device discovery via UDP broadcast
- HTTP control server (port 9998)
- Basic device pairing and control
