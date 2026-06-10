# Remote PC Flutter 项目笔记

## 项目基本信息
- 路径: C:/Users/Administrator/Desktop/remote-pc-flutter/
- 当前版本: 1.0.3+3
- 技术栈: Flutter 3.x + Dart 3.x
- 五端: Android / iOS / Windows / macOS / Linux

## 核心架构
- 入口: main.dart（支持 --headless 模式）
- 双模式: LAN（UDP 广播 + HTTP 直连） / 跨网络（WebSocket 信令 + WebRTC Data Channel）
- 安全: AES-256-GCM 授权 + DynamicFirewall 多语言防火墙 + MethodChannel 原生桥接
- 控制: HTTP 服务端口 9998 / UDP 发现端口 4567

## v1.0.3-v1.0.4 安全演进
- SAFE_MODE 三层防护（环境变量 + 请求头 + Token 校验）
- 原生安全桥接三端实现（Android Kotlin / Windows C++ / macOS Swift）
- HTTPS (TLS) 自签名 RSA-2048 证书
- 速率限制 (3次失败→60s封禁 + 定期清理)
- 设备配对白名单 (deviceId 必须 + 指纹验证)
- CORS + 安全响应头
- Android ProGuard 代码混淆
- 常量时间比较 (防时序攻击)
- DNS rebinding 防护
- fail-closed 策略 (verifySystemIntegrity 调用失败→false)

## 安全评分
- 原始: 4.9/10 → Vol.1: 7.8/10 → Vol.2: 8.5/10 → Vol.3: **9.2/10**

## 三轮白帽攻击已修复漏洞
### Vol.1 (7个)
- 硬编码密钥、无认证、明文 Token、无审计、无 TLS 等
### Vol.2 (5个修复，3个延后)
- AES-GCM 短数据崩溃、激活码死锁、Nonce内存泄漏、审计日志越界、信令永久放弃
### Vol.3 (5个)
- W01 CRITICAL: 白名单绕过（无 x-device-id 跳过检查）
- W02 HIGH: test-mode 后门（审计日志绕过认证）
- W03 HIGH: 未授权信息泄露（/safe-mode, /heartbeat）
- W04 MEDIUM: 无 CORS/安全头（浏览器 CSRF）
- W05 MEDIUM: 速率限制内存泄漏

## 已知剩余风险
- P2: WebRTC DataChannel 无独立认证
- P2: WebSocket 信令无 auth
- P2: TURN 服务器凭据硬编码
- P3: WinVerifyTrust 未实现
- P3: 自签名证书无 Certificate Pinning

## 构建环境
- Codemagic 账号: 2093098597@qq.com
- 项目 ID: 6a266fedc2a029edf2e98d3c
- Gitee remote: git@gitee.com:iron-man-111/remote-pc-flutter.git
- GitHub remote: git@github.com:gangtiexia111/remote-pc-flutter.git
- Flutter path: C:/Users/Administrator/flutter/bin/flutter.bat

## 安全规则
- ⚠️ 关机/重启指令必须先确认 SAFE_MODE 状态
- SAFE_MODE=1 时所有危险指令仅记录不执行
- 测试时使用 x-test-mode 请求头（仅 SAFE_MODE 分支有效）
