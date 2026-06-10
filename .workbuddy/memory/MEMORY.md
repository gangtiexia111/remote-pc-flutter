# Remote PC Flutter 项目笔记

## 项目基本信息
- 路径: C:/Users/Administrator/Desktop/remote-pc-flutter/
- 当前版本: 1.0.3
- 技术栈: Flutter 3.x + Dart 3.x
- 五端: Android / iOS / Windows / macOS / Linux

## 核心架构
- 入口: main.dart（支持 --headless 模式）
- 双模式: LAN（UDP 广播 + HTTP 直连） / 跨网络（WebSocket 信令 + WebRTC Data Channel）
- 安全: AES-256-GCM 授权 + DynamicFirewall 多语言防火墙 + MethodChannel 原生桥接
- 控制: HTTP 服务端口 9998 / UDP 发现端口 4567

## 安全评分
- 原始: 4.2 → V1: 7.5 → V2: 8.8 → V3: 9.3 → V4: 9.7 → V5: 9.7 → V6: 9.8 → V7: **9.9/10**

## 七轮白帽攻击已修复漏洞（共 53 个）

### Vol.1~Vol.5 (40个)
- 详见之前各轮审计报告

### Vol.6 (8个 + 3 自检)
- V6-01: constantTimeEqual 长度侧信道（4 文件链式修复）
- V6-02: 危险端点 POST 强制（/shutdown, /restart, /lock-screen, /remote-self-destruct）
- V6-03: 慢速暴力破解 — 成功减半而非清零 + blockCount 永不减少
- V6-04: Linux AES 密钥明文存储
- V6-05: WebRTC DataChannel 命令注入 — 允许/禁止双列表
- V6-06: OpenSSL -nodes 标志 — 私钥明文写磁盘 → passphrase 加密
- V6-07: UDP nonce 碰撞 + 重放窗口 — 48-bit nonce + 滑动窗口
- V6-08: 信令消息注入 — 消息类型白名单 + 结构验证
- V6-自检 ×3: SecureStorageValidator 链式覆盖 + passphrase 覆写清理

### Vol.7 (12个 + 1 自检) — 终极审计
- V7-01 HIGH: /unpair 缺少 POST 强制 — CSRF 可解绑设备
- V7-02 HIGH: 空指纹绕过白名单 — isAllowed isEmpty→true
- V7-03 HIGH: getHardwareFingerprint() 失败返回空串 → sentinel 修复
- V7-04 HIGH: HMAC/AES 密钥复用 → HKDF-SHA256 派生独立 HMAC 密钥
- V7-05 MEDIUM: /pair 405 纯文本 → 统一 JSON 格式
- V7-06 MEDIUM: _isTestMode() 生产环境可用 → kDebugMode 门控
- V7-07 MEDIUM: _clearActivation() 不删密钥 → 自毁清除 AES+HMAC
- V7-08 MEDIUM: SharedPreferences 存激活状态 → 迁移 FlutterSecureStorage
- V7-09 MEDIUM: DataChannel 无速率限制 → 30msg/s 限流
- V7-10 MEDIUM: sendCommand() 无出站校验 → 白名单双检
- V7-11 MEDIUM: roomId 无验证 → 正则校验防信令注入
- V7-12 MEDIUM: isBeingDebugged() fail-open → fail-closed
- V7-自检-01: 空 Host 头绕过 DNS Rebinding → isEmpty→false

### LOW 记录不修 (5)
- L1: 硬编码 TURN 凭证（外部依赖）
- L2: 心跳端点无 auth（设计如此）
- L3: Process.start 无结果校验（关机场景）
- L4: deprecated computeNativeResponse 仍可调用
- L5: UDP 设备永不过期

## 链式漏洞自检覆盖
- _constantTimeEqual: 4 文件 (http_server, device_whitelist, dynamic_firewall, license_manager)
- SecureStorageValidator: 5 文件 (certificate_manager, device_whitelist, license_manager×2, dynamic_firewall)
- POST 方法强制: 6 端点 (/shutdown, /restart, /lock-screen, /remote-self-destruct, /pair, /unpair)
- fail-closed 策略: isBeingDebugged + verifySystemIntegrity 一致

## 构建环境
- Gitee: git@gitee.com:iron-man-111/remote-pc-flutter.git
- GitHub: git@github.com:gangtiexia111/remote-pc-flutter.git
- Flutter: C:/Users/Administrator/flutter/bin/flutter.bat

## 安全规则
- ⚠️ 关机/重启指令必须先确认 SAFE_MODE 状态
- SAFE_MODE=1 时所有危险指令仅记录不执行
- V7-06 后: x-test-mode 仅在 DEBUG 构建生效，生产环境不可用
