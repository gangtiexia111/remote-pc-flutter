/// home_screen.dart
///
/// 主界面 — 支持双模式：
///   🌐 LAN 模式（UDP 广播 + HTTP 直连）
///   ☁️ 跨网络模式（WebSocket 信令 + WebRTC Data Channel）
///
/// v1.0.3: SAFE_MODE 集成 — 危险指令需通过安全校验
library;

import 'dart:io';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import '../models/device.dart';
import '../services/http_server.dart';
import '../services/udp_discovery.dart';
import '../services/webrtc_connection_service.dart';
import 'security_screen.dart';
import 'settings_screen.dart';

/// 主界面
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  // ── 通用 ────────────────────────────────────────
  int _navIndex = 0;
  bool _darkMode = false;

  // ── LAN 模式 ───────────────────────────────────
  final _udp = UdpDiscoveryService();
  final _http = HttpServerService();
  Device? _selfDevice;
  bool _lanServerRunning = false;

  // ── 跨网络模式 ────────────────────────────────
  WebRtcState _webrtcState = WebRtcState.idle;
  String _roomId = '';
  String _signalingUrl = 'wss://three-boats-repeat.loca.lt';
  WebRtcConnectionService? _webrtc;
  final _roomIdController = TextEditingController();

  // ── 模式切换 ──────────────────────────────────
  /// 0 = LAN 模式，1 = 跨网络模式
  int _mode = 0;

  // ── SAFE_MODE ──────────────────────────────────
  bool _safeMode = false;
  String? _authToken;

  @override
  void initState() {
    super.initState();
    _loadSettings();
    _initLanServices();
  }

  /// 从 SharedPreferences 加载配置
  Future<void> _loadSettings() async {
    // 延迟加载避免 build 期间调用
    await Future.delayed(Duration.zero);
    if (!mounted) return;
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _darkMode = prefs.getBool('darkMode') ?? false;
      _signalingUrl =
          prefs.getString('signalingUrl') ?? 'wss://three-boats-repeat.loca.lt';
      _safeMode = prefs.getBool('safeMode') ?? true; // 默认开启 SAFE_MODE
    });
  }

  Future<void> _saveSetting(String key, dynamic value) async {
    final prefs = await SharedPreferences.getInstance();
    if (value is bool) {
      await prefs.setBool(key, value);
    } else if (value is String) {
      await prefs.setString(key, value);
    }
  }

  // ── LAN 模式初始化 ────────────────────────────

  Future<void> _initLanServices() async {
    await _udp.startListening();
    _selfDevice = Device(
      id: 'remote-pc-${DateTime.now().millisecondsSinceEpoch}',
      name: Platform.localHostname.isNotEmpty
          ? Platform.localHostname
          : 'RemotePC',
      ip: '127.0.0.1',
      port: 9998,
      isOnline: true,
    );
    _http.setDevice(_selfDevice!);

    // 同步 SAFE_MODE 状态
    _http.setSafeMode(_safeMode);

    await _http.start(port: 9998);
    setState(() => _lanServerRunning = true);
    await _udp.sendDiscoveryBroadcast(_selfDevice!);

    // 从本地 HTTP 服务获取 auth token
    _fetchAuthToken();
  }

  /// 从本地 HTTP 服务获取授权 Token
  Future<void> _fetchAuthToken() async {
    try {
      final resp =
          await http.get(Uri.parse('http://127.0.0.1:9998/auth-token'));
      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body) as Map<String, dynamic>;
        setState(() {
          _authToken = data['token'] as String?;
          _safeMode = data['safeMode'] as bool? ?? _safeMode;
        });
      }
    } catch (_) {
      // 非 Windows 桌面端可能无 http 包
    }
  }

  /// 切换 SAFE_MODE
  void _toggleSafeMode(bool value) {
    setState(() => _safeMode = value);
    _http.setSafeMode(value);
    _saveSetting('safeMode', value);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(value
            ? '⚠️ SAFE_MODE 已开启 — 危险指令将被拦截'
            : '✅ SAFE_MODE 已关闭 — 危险指令可正常执行'),
        backgroundColor: value ? Colors.orange : Colors.green,
      ),
    );
  }

  // ── 跨网络模式 ───────────────────────────────

  void _initWebRtc() {
    _webrtc = WebRtcConnectionService(
      deviceId: _selfDevice?.id ?? 'unknown',
      signalingUrl: _signalingUrl,
      callbacks: WebRtcCallbacks(
        onConnected: (deviceId) {
          setState(() => _webrtcState = WebRtcState.connected);
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('☁️ 跨网络连接成功')),
          );
        },
        onDisconnected: (deviceId) {
          setState(() => _webrtcState = WebRtcState.idle);
        },
        onCommandReceived: (deviceId, cmd) {
          _handleReceivedCommand(cmd);
        },
        onStateChanged: (state) {
          setState(() => _webrtcState = state);
        },
      ),
    );
    _webrtc!.init();
  }

  /// 处理收到的控制指令（SAFE_MODE 校验）
  void _handleReceivedCommand(String cmd) {
    print('[WebRTC] Command received: $cmd');

    if (_safeMode) {
      print('[WebRTC] ⚠️ SAFE_MODE: blocked command "$cmd"');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('⚠️ SAFE_MODE 拦截指令: $cmd'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    // 非危险指令直接处理
    if (!_isDangerousCommand(cmd)) {
      print('[WebRTC] Executing safe command: $cmd');
      return;
    }

    // 危险指令：弹出二次确认对话框
    _showDangerousCommandDialog(cmd);
  }

  /// 判断是否为危险指令
  bool _isDangerousCommand(String cmd) {
    return ['shutdown', 'restart', 'lock', 'sleep', 'self_destruct']
        .contains(cmd);
  }

  /// 危险指令二次确认对话框
  void _showDangerousCommandDialog(String cmd) {
    final cmdLabel = {
      'shutdown': '关机',
      'restart': '重启',
      'lock': '锁屏',
      'sleep': '休眠',
      'self_destruct': '远程自毁',
    };

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: [
            const Icon(Icons.warning, color: Colors.red),
            const SizedBox(width: 8),
            Text('确认执行${cmdLabel[cmd] ?? cmd}?'),
          ],
        ),
        content: Text('即将执行 "${cmdLabel[cmd] ?? cmd}" 操作，此操作不可撤销。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () {
              Navigator.pop(ctx);
              _executeCommand(cmd);
            },
            child: const Text('确认执行'),
          ),
        ],
      ),
    );
  }

  /// 实际执行控制指令
  void _executeCommand(String cmd) {
    // 通过本地 HTTP 服务执行（走 SAFE_MODE 校验）
    _sendLanCommand(cmd);
  }

  void _createRoom() {
    // v1.0.4: 支持自动生成安全随机 roomId
    var roomId = _roomIdController.text.trim();
    if (roomId.isEmpty) {
      roomId = WebRtcConnectionService.generateRoomId();
      _roomIdController.text = roomId;
    }
    _roomId = roomId;
    _initWebRtc();
    _webrtc!.createRoom(roomId);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('房间已创建: $roomId，等待对方加入...')),
    );
  }

  void _joinRoom() {
    final roomId = _roomIdController.text.trim();
    if (roomId.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请输入房间 ID')),
      );
      return;
    }
    _roomId = roomId;
    _initWebRtc();
    _webrtc!.joinRoom(roomId);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('正在加入房间: $roomId...')),
    );
  }

  void _sendWebRtcCommand(String cmd) {
    if (_webrtcState != WebRtcState.connected) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('WebRTC 未连接')),
      );
      return;
    }

    // 危险指令需要确认
    if (_isDangerousCommand(cmd)) {
      if (_safeMode) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('⚠️ SAFE_MODE 已开启，无法发送: $cmd'),
            backgroundColor: Colors.orange,
          ),
        );
        return;
      }
      _showSendDangerousCommandDialog(cmd);
      return;
    }

    _webrtc!.sendCommand(cmd);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已发送: $cmd')),
    );
  }

  /// 发送危险指令确认
  void _showSendDangerousCommandDialog(String cmd) {
    final cmdLabel = {
      'shutdown': '关机',
      'restart': '重启',
      'lock': '锁屏',
      'sleep': '休眠',
    };

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: [
            const Icon(Icons.warning_amber, color: Colors.orange),
            const SizedBox(width: 8),
            Text('确认发送${cmdLabel[cmd] ?? cmd}指令?'),
          ],
        ),
        content: Text('将通过 WebRTC 向被控端发送 "${cmdLabel[cmd] ?? cmd}" 指令。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(ctx);
              _webrtc!.sendCommand(cmd);
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('已发送: $cmd')),
              );
            },
            child: const Text('确认发送'),
          ),
        ],
      ),
    );
  }

  // ── 界面构建 ───────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: _buildAppBar(),
      body: Row(
        children: [
          // 左侧导航栏
          NavigationRail(
            selectedIndex: _navIndex,
            onDestinationSelected: (i) => setState(() => _navIndex = i),
            labelType: NavigationRailLabelType.all,
            destinations: const [
              NavigationRailDestination(
                icon: Icon(Icons.devices),
                label: Text('设备'),
              ),
              NavigationRailDestination(
                icon: Icon(Icons.security),
                label: Text('安全'),
              ),
              NavigationRailDestination(
                icon: Icon(Icons.settings),
                label: Text('设置'),
              ),
            ],
          ),
          const VerticalDivider(width: 1),
          // 主内容区
          Expanded(
            child: _navIndex == 0
                ? _buildDeviceTab()
                : _navIndex == 1
                    ? _buildSecurityTab()
                    : SettingsScreen(
                        darkMode: _darkMode,
                        onDarkModeChanged: (v) {
                          setState(() => _darkMode = v);
                          _saveSetting('darkMode', v);
                        },
                        signalingUrl: _signalingUrl,
                        onSignalingUrlChanged: (v) {
                          setState(() => _signalingUrl = v);
                          _saveSetting('signalingUrl', v);
                        },
                        safeMode: _safeMode,
                        onSafeModeChanged: _toggleSafeMode,
                      ),
          ),
        ],
      ),
      floatingActionButton: _navIndex == 0 ? _buildFab() : null,
    );
  }

  PreferredSizeWidget _buildAppBar() {
    return AppBar(
      title: const Text('Remote PC Control'),
      actions: [
        // SAFE_MODE 指示器
        _buildSafeModeIndicator(),
        const SizedBox(width: 8),
        // 连接状态指示灯
        _buildStatusLight(),
        const SizedBox(width: 8),
        // 模式切换
        ToggleButtons(
          isSelected: [_mode == 0, _mode == 1],
          onPressed: (i) => setState(() => _mode = i),
          children: const [
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 12),
              child: Text('🌐 LAN'),
            ),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 12),
              child: Text('☁️ 跨网络'),
            ),
          ],
        ),
        const SizedBox(width: 12),
      ],
    );
  }

  /// SAFE_MODE 状态指示器
  Widget _buildSafeModeIndicator() {
    return Tooltip(
      message: _safeMode ? 'SAFE_MODE 已开启 — 危险指令被拦截' : 'SAFE_MODE 已关闭',
      child: InkWell(
        onTap: () => _toggleSafeMode(!_safeMode),
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: _safeMode
                ? Colors.orange.withValues(alpha: 0.15)
                : Colors.green.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: _safeMode ? Colors.orange : Colors.green,
              width: 1,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                _safeMode ? Icons.shield : Icons.shield_outlined,
                size: 14,
                color: _safeMode ? Colors.orange : Colors.green,
              ),
              const SizedBox(width: 4),
              Text(
                _safeMode ? 'SAFE' : 'LIVE',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  color: _safeMode ? Colors.orange : Colors.green,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 连接状态三色灯
  Widget _buildStatusLight() {
    Color color;
    String tooltip;
    if (_mode == 0) {
      color = _lanServerRunning ? Colors.green : Colors.grey;
      tooltip = _lanServerRunning ? 'LAN 服务运行中' : 'LAN 服务已停止';
    } else {
      switch (_webrtcState) {
        case WebRtcState.connected:
          color = Colors.green;
          tooltip = 'WebRTC 已连接';
        case WebRtcState.connecting:
          color = Colors.orange;
          tooltip = '正在连接...';
        case WebRtcState.failed:
          color = Colors.red;
          tooltip = '连接失败';
        case WebRtcState.idle:
          color = Colors.grey;
          tooltip = '未连接';
      }
    }
    return Tooltip(
      message: tooltip,
      child: Icon(Icons.circle, color: color, size: 14),
    );
  }

  // ── 设备列表 Tab ──────────────────────────────

  Widget _buildDeviceTab() {
    if (_mode == 0) {
      return _buildLanDeviceList();
    } else {
      return _buildCrossNetworkPanel();
    }
  }

  /// LAN 模式设备列表（原逻辑）
  Widget _buildLanDeviceList() {
    final devices = _udp.devices.values.toList();
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('设备列表 (LAN)', style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 16),
          Expanded(
            child: devices.isEmpty
                ? const Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.radar, size: 64, color: Colors.grey),
                        SizedBox(height: 16),
                        Text('未发现设备', style: TextStyle(color: Colors.grey)),
                      ],
                    ),
                  )
                : ListView.builder(
                    itemCount: devices.length,
                    itemBuilder: (ctx, i) {
                      final d = devices[i];
                      return Card(
                        child: ListTile(
                          leading: Icon(
                            d.isOnline
                                ? Icons.computer
                                : Icons.computer_outlined,
                            color: d.isOnline ? Colors.green : Colors.grey,
                          ),
                          title: Text(d.name),
                          subtitle:
                              Text('${d.ip}:${d.port} · ${d.statusLabel}'),
                          trailing: d.isOnline
                              ? PopupMenuButton<String>(
                                  onSelected: (v) =>
                                      _sendLanCommandToDevice(d, v),
                                  itemBuilder: (_) => [
                                    const PopupMenuItem(
                                      value: 'shutdown',
                                      child: ListTile(
                                        leading: Icon(Icons.power_settings_new,
                                            color: Colors.red),
                                        title: Text('关机'),
                                      ),
                                    ),
                                    const PopupMenuItem(
                                      value: 'restart',
                                      child: ListTile(
                                        leading: Icon(Icons.restart_alt,
                                            color: Colors.orange),
                                        title: Text('重启'),
                                      ),
                                    ),
                                    const PopupMenuItem(
                                      value: 'lock',
                                      child: ListTile(
                                        leading: Icon(Icons.lock,
                                            color: Colors.blue),
                                        title: Text('锁屏'),
                                      ),
                                    ),
                                  ],
                                )
                              : null,
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  /// 向设备发送 LAN 指令（带 SAFE_MODE 校验和授权 Token）
  Future<void> _sendLanCommandToDevice(Device d, String cmd) async {
    // 本地安全检查
    if (_safeMode && _isDangerousCommand(cmd)) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('⚠️ SAFE_MODE 已开启，无法发送: $cmd'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    // 二次确认
    if (_isDangerousCommand(cmd)) {
      _showDangerousCommandDialog(cmd);
      return;
    }

    // 发送到目标设备的 HTTP 服务
    try {
      final headers = <String, String>{};
      if (_authToken != null) {
        headers['x-auth-token'] = _authToken!;
      }
      final path = cmd == 'lock' ? '/lock-screen' : '/$cmd';
      final resp = await http.post(
        Uri.parse('http://${d.ip}:${d.port}$path'),
        headers: headers,
      );
      if (resp.statusCode == 200) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('✅ 已发送 $cmd 到 ${d.ip}')),
        );
      } else if (resp.statusCode == 403) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('⛔ 目标设备拒绝: 目标 SAFE_MODE 可能已开启'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('发送失败: $e')),
      );
    }
  }

  /// 本地执行控制指令（通过本地 HTTP 服务）
  Future<void> _sendLanCommand(String cmd) async {
    try {
      final headers = <String, String>{};
      if (_authToken != null) {
        headers['x-auth-token'] = _authToken!;
      }
      final path = cmd == 'lock' ? '/lock-screen' : '/$cmd';
      final resp = await http.post(
        Uri.parse('http://127.0.0.1:9998$path'),
        headers: headers,
      );
      if (!mounted) return;
      if (resp.statusCode == 200) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('✅ 指令已执行: $cmd')),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('⛔ 执行失败 (${resp.statusCode})'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('执行失败: $e')),
      );
    }
  }

  // ── 跨网络面板 ────────────────────────────────

  Widget _buildCrossNetworkPanel() {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('跨网络连接', style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 8),
          Text(
            '信令服务器: $_signalingUrl',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 16),
          // 房间 ID 输入
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _roomIdController,
                  decoration: const InputDecoration(
                    labelText: '房间 ID',
                    hintText: '输入或自动生成',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.outlined(
                onPressed: () {
                  final id = WebRtcConnectionService.generateRoomId();
                  _roomIdController.text = id;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('已生成: $id')),
                  );
                },
                icon: const Icon(Icons.casino),
                tooltip: '随机生成房间 ID',
              ),
            ],
          ),
          const SizedBox(height: 12),
          // 创建/加入按钮
          Row(
            children: [
              ElevatedButton.icon(
                onPressed:
                    _webrtcState == WebRtcState.idle ? _createRoom : null,
                icon: const Icon(Icons.add),
                label: const Text('创建房间（主控端）'),
              ),
              const SizedBox(width: 12),
              ElevatedButton.icon(
                onPressed: _webrtcState == WebRtcState.idle ? _joinRoom : null,
                icon: const Icon(Icons.login),
                label: const Text('加入房间（被控端）'),
              ),
            ],
          ),
          const SizedBox(height: 16),
          // 连接状态
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  _buildStatusLight(),
                  const SizedBox(width: 12),
                  Text(_webrtcStateLabel),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          // 控制按钮（连接后可用）
          if (_webrtcState == WebRtcState.connected) ...[
            const Text('控制指令：', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                _buildControlButton('lock', '锁屏', Icons.lock, Colors.blue),
                _buildControlButton(
                    'sleep', '休眠', Icons.bedtime, Colors.indigo),
                _buildControlButton(
                    'restart', '重启', Icons.restart_alt, Colors.orange),
                _buildControlButton(
                    'shutdown', '关机', Icons.power_settings_new, Colors.red),
              ],
            ),
          ],
        ],
      ),
    );
  }

  /// 构建控制按钮（危险指令带警告色）
  Widget _buildControlButton(
      String cmd, String label, IconData icon, Color color) {
    final isDangerous = _isDangerousCommand(cmd);
    final blocked = _safeMode && isDangerous;

    return ElevatedButton.icon(
      onPressed: blocked ? null : () => _sendWebRtcCommand(cmd),
      icon: Icon(icon, size: 16),
      label: Text(label),
      style: ElevatedButton.styleFrom(
        backgroundColor: blocked ? Colors.grey : color.withValues(alpha: 0.1),
        foregroundColor: blocked ? Colors.grey : color,
        side: BorderSide(color: blocked ? Colors.grey : color),
      ),
    );
  }

  String get _webrtcStateLabel {
    switch (_webrtcState) {
      case WebRtcState.idle:
        return '待连接';
      case WebRtcState.connecting:
        return '正在连接...';
      case WebRtcState.connected:
        return '已连接（房间: $_roomId）';
      case WebRtcState.failed:
        return '连接失败';
    }
  }

  // ── 安全 Tab ──────────────────────────────────

  Widget _buildSecurityTab() {
    return SecurityScreen(safeMode: _safeMode);
  }

  // ── FAB ──────────────────────────────────────

  Widget? _buildFab() {
    if (_mode == 0) {
      return FloatingActionButton(
        onPressed: () => _udp.sendDiscoveryBroadcast(_selfDevice!),
        tooltip: '刷新设备',
        child: const Icon(Icons.refresh),
      );
    }
    return null;
  }

  @override
  void dispose() {
    _udp.stop();
    _http.stop();
    _webrtc?.disconnect();
    _roomIdController.dispose();
    super.dispose();
  }
}
