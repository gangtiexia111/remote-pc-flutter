# Remote PC Flutter 项目笔记

## 项目基本信息
- 路径: C:/Users/Administrator/Desktop/remote-pc-flutter/
- 当前版本: 1.0.4
- 技术栈: Flutter 3.x + Dart 3.x
- 五端: Android / iOS / Windows / macOS / Linux

## 核心架构
- 入口: main.dart（支持 --headless 模式）
- 双模式: LAN（UDP 广播 + HTTP 直连） / 跨网络（WebSocket 信令 + WebRTC Data Channel）
- 安全: AES-256-GCM 授权 + DynamicFirewall 多语言防火墙 + MethodChannel 原生桥接
- 控制: HTTP 服务端口 9998 / UDP 发现端口 4567

## v1.0.4 安全防线（10 层）
1. **L1 传输层**: HTTPS (TLS 1.2+) RSA-2048 自签名证书
2. **L2 认证层**: 32 字节 CSPRNG Token + 常量时间比较 + 长度侧信道消除
3. **L3 授权层**: 设备白名单 deviceId + fingerprint 双重必填
4. **L4 防护层**: 递增速率限制 (60s→5min→30min→1h) + 全局 10req/s
5. **L5 安全体**: SAFE_MODE + 审计日志 (输入消毒+截断)
6. **L6 原生层**: 调试检测 + 完整性校验 (fail-closed)
7. **L7 加固层**: CORS (localhost-only) + 5 安全头 + DNS rebinding 防护
8. **L8 混淆层**: Android ProGuard + 资源压缩
9. **L9 限制层**: 10KB 请求体上限 + 字段长度验证
10. **L10 信令层**: WebSocket 非本地连接强制 wss://

## 安全评分
- 原始: 4.9 → V1: 7.8 → V2: 8.5 → V3: 9.2 → V4: **9.5/10**

## 四轮白帽攻击已修复漏洞（共 16 个）
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
### Vol.4 (6个)
- W06 CRITICAL: 设备指纹绕过（无 x-device-fingerprint 跳过校验）
- W07 HIGH: Auth Token 日志泄露
- W08 HIGH: 请求体无限制 — OOM 攻击
- W09 MEDIUM: 速率限制无递增 + 无全局频率限制
- W10 MEDIUM: 错误信息泄露 + 输入未消毒 + 时序侧信道
- W11 MEDIUM: WebSocket 信令明文传输

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
