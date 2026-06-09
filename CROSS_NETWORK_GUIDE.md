# Remote PC 跨网络部署指南

## 当前状态

| 组件 | 状态 | 备注 |
|------|:--:|------|
| Flutter 5端代码 | ✅ 完成 | 0 error, 0 warning |
| 信令服务器 | ✅ 完成 | `signaling-server/index.js`（WebSocket） |
| 启动脚本 | ✅ 完成 | `start_signal.bat` 一键启动 |
| STUN 服务器 | ✅ 免费 | `stun.l.google.com:19302` |
| TURN 服务器 | ✅ 免费 | `openrelay.metered.ca`（50GB/月） |
| 公网地址 | ❌ | 需要一个稳定地址让外网访问信令服务器 |

## 你唯一要做的事

**给信令服务器搞一个公网地址**，让它能从外网（WiFi/4G/5G）访问。

以下是 5 个方案，从易到难：

---

### 方案1：ngrok（¥0，5分钟，Windows）

```bash
# 1. 注册账号：https://ngrok.com（邮箱注册，不用 GitHub）
# 2. 根据网页提示下载 Windows 客户端
# 3. 配置 token（注册后网页会显示）
ngrok config add-authtoken <你的token>
# 4. 启动穿透
ngrok http 3000
# 5. 复制公网地址，形如：https://xxxx.ngrok-free.app
```

如果下载不了（被墙），用国内镜像或联系我帮你传。

---

### 方案2：cpolar（¥0，国产，更适合中国网络）⭐推荐

```bash
# 1. 注册：https://www.cpolar.com（手机号注册）
# 2. 下载 Windows 客户端
# 3. 启动穿透
cpolar http 3000
# 4. 复制公网地址
```

优点：国产服务，国内网络友好，有免费域名。

---

### 方案3：花生壳（¥0，老牌国产）

```bash
# 1. 下载：https://hsk.oray.com/download/
# 2. 注册账号（手机号）
# 3. 添加映射：内网端口 3000 → 外网域名
# 4. 免费版 1GB/月流量，信令够用
```

---

### 方案4：fly.io 部署（¥0，真正24h在线）

```bash
# 1. 注册：https://fly.io（邮箱注册，不需要 GitHub）
# 2. 安装 flyctl 命令行工具
# 3. 在 signaling-server 目录下部署
cd signaling-server
flyctl launch
flyctl deploy
# 4. 获得固定域名：xxx.fly.dev
```

优点：真正云端部署，不依赖本地电脑运行，7×24稳定。

---

### 方案5：腾讯云/阿里云 VPS（月付 ¥30-60，最稳定）

```bash
# 1. 买一台最便宜的轻量 VPS（1核1G，30元/月）
# 2. SSH 登录，安装 Node.js
# 3. 上传 signaling-server/ 目录
# 4. 使用 PM2 守护进程
npm install -g pm2
cd signaling-server && npm install
pm2 start index.js --name signal
pm2 save && pm2 startup
# 5. 开放防火墙 3000 端口
```

---

## 拿到地址后

1. 打开 `Remote PC Control` App
2. 进入左侧导航栏「设置」
3. 在「跨网络配置」中填入信令服务器地址
   - 格式：`ws://你的地址`（HTTP）或 `wss://你的地址`（HTTPS）
4. 保存 → 返回主界面 → 切换到「☁️ 跨网络」模式

## 两端测试步骤

### 主控端（Host）
1. 切换到「☁️ 跨网络」模式
2. 输入房间 ID（如 `test123`）
3. 点击「创建房间」

### 被控端（Guest）
1. 切换到「☁️ 跨网络」模式
2. 输入相同房间 ID（`test123`）
3. 点击「加入房间」

> 两端自动完成信令交换 → WebRTC Data Channel 建立 → 可以发送控制指令

---

## 本地启动

1. 双击 `start_signal.bat`
2. 信令服务器在 `http://localhost:3000` 运行
3. 设置页面填入 `ws://localhost:3000` 即可局域网测试
