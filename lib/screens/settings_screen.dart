/// settings_screen.dart
///
/// 设置页面
/// 新增：信令服务器地址配置（跨网络模式需要）
/// v1.0.3: SAFE_MODE 开关
library;

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 设置页面
class SettingsScreen extends StatefulWidget {
  final bool darkMode;
  final ValueChanged<bool>? onDarkModeChanged;
  final String signalingUrl;
  final ValueChanged<String>? onSignalingUrlChanged;
  final bool safeMode;
  final ValueChanged<bool>? onSafeModeChanged;

  const SettingsScreen({
    super.key,
    this.darkMode = false,
    this.onDarkModeChanged,
    this.signalingUrl = 'wss://three-boats-repeat.loca.lt',
    this.onSignalingUrlChanged,
    this.safeMode = true,
    this.onSafeModeChanged,
  });

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _darkMode = false;
  bool _safeMode = true;
  bool _autoStart = false;
  String _activationCode = '';
  late TextEditingController _signalingUrlController;

  @override
  void initState() {
    super.initState();
    _darkMode = widget.darkMode;
    _safeMode = widget.safeMode;
    _signalingUrlController = TextEditingController(text: widget.signalingUrl);
    _loadAutoStart();
  }

  Future<void> _loadAutoStart() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _autoStart = prefs.getBool('autoStart') ?? false;
    });
  }

  Future<void> _saveAutoStart(bool v) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('autoStart', v);
  }

  @override
  void didUpdateWidget(covariant SettingsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.darkMode != widget.darkMode) {
      setState(() => _darkMode = widget.darkMode);
    }
    if (oldWidget.safeMode != widget.safeMode) {
      setState(() => _safeMode = widget.safeMode);
    }
    if (oldWidget.signalingUrl != widget.signalingUrl) {
      _signalingUrlController.text = widget.signalingUrl;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: ListView(
        children: [
          Text(
            '设置',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 24),

          // SAFE_MODE 开关（醒目位置）
          _buildSafeModeCard(),
          const SizedBox(height: 16),

          // 激活区
          _buildActivationCard(),
          const SizedBox(height: 16),

          // 跨网络配置
          _buildCrossNetworkCard(),
          const SizedBox(height: 16),

          // 开关设置
          _buildSwitchCard(),
          const SizedBox(height: 16),

          // 关于
          _buildAboutCard(),
        ],
      ),
    );
  }

  /// SAFE_MODE 安全模式卡片
  Card _buildSafeModeCard() {
    return Card(
      color: _safeMode
          ? Colors.orange.withValues(alpha: 0.08)
          : Colors.green.withValues(alpha: 0.05),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: _safeMode
              ? Colors.orange.withValues(alpha: 0.3)
              : Colors.green.withValues(alpha: 0.2),
          width: 1,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  _safeMode ? Icons.shield : Icons.shield_outlined,
                  color: _safeMode ? Colors.orange : Colors.green,
                  size: 24,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '安全模式 (SAFE_MODE)',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        _safeMode
                            ? '已开启 — 关机/重启/锁屏指令将被拦截，仅记录日志'
                            : '已关闭 — 危险指令可正常执行，请确保在受控环境中使用',
                        style: TextStyle(
                          fontSize: 12,
                          color: _safeMode
                              ? Colors.orange[700]
                              : Colors.green[700],
                        ),
                      ),
                    ],
                  ),
                ),
                Switch(
                  value: _safeMode,
                  onChanged: (v) {
                    setState(() => _safeMode = v);
                    widget.onSafeModeChanged?.call(v);
                  },
                  activeColor: Colors.orange,
                ),
              ],
            ),
            if (!_safeMode) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.red.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Row(
                  children: [
                    Icon(Icons.warning_amber, color: Colors.red, size: 18),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '⚠️ 关闭 SAFE_MODE 后，远程关机/重启指令将直接执行，请谨慎操作！',
                        style: TextStyle(fontSize: 12, color: Colors.red),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Card _buildActivationCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('授权激活', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            TextField(
              onChanged: (v) => _activationCode = v,
              decoration: const InputDecoration(
                labelText: '激活码',
                hintText: 'TERM-XXXX-XXXX-XXXX-XXXX',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: ElevatedButton(
                onPressed: () {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('激活码: $_activationCode')),
                  );
                },
                child: const Text('激活'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Card _buildCrossNetworkCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.cloud, size: 20),
                const SizedBox(width: 8),
                Text('跨网络配置', style: Theme.of(context).textTheme.titleMedium),
              ],
            ),
            const SizedBox(height: 8),
            const Text(
              '配置信令服务器地址，用于跨网络（WiFi/4G/5G）远程控制。\n'
              '格式：ws:// 或 wss:// 开头',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _signalingUrlController,
              decoration: const InputDecoration(
                labelText: '信令服务器地址',
                hintText: 'ws://localhost:3000',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.language),
              ),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: ElevatedButton.icon(
                onPressed: _saveSignalingUrl,
                icon: const Icon(Icons.save, size: 16),
                label: const Text('保存'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _saveSignalingUrl() async {
    final url = _signalingUrlController.text.trim();
    if (url.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('地址不能为空')),
      );
      return;
    }
    if (!url.startsWith('ws://') && !url.startsWith('wss://')) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('地址格式错误，需以 ws:// 或 wss:// 开头')),
      );
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('signalingUrl', url);
    widget.onSignalingUrlChanged?.call(url);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('信令服务器地址已保存: $url')),
    );
  }

  Card _buildSwitchCard() {
    return Card(
      child: Column(
        children: [
          SwitchListTile(
            title: const Text('深色模式'),
            subtitle: const Text('使用深色主题'),
            value: _darkMode,
            onChanged: (v) async {
              setState(() => _darkMode = v);
              widget.onDarkModeChanged?.call(v);
              final prefs = await SharedPreferences.getInstance();
              await prefs.setBool('darkMode', v);
            },
          ),
          SwitchListTile(
            title: const Text('开机自启'),
            subtitle: const Text('系统启动时自动运行'),
            value: _autoStart,
            onChanged: (v) async {
              setState(() => _autoStart = v);
              await _saveAutoStart(v);
            },
          ),
        ],
      ),
    );
  }

  Card _buildAboutCard() {
    return Card(
      child: ListTile(
        leading: const Icon(Icons.info),
        title: const Text('关于 Remote PC Control'),
        subtitle: const Text('版本 1.0.3 · Flutter 跨平台版（含 WebRTC + SAFE_MODE）'),
        trailing: const Icon(Icons.chevron_right),
        onTap: () {},
      ),
    );
  }

  @override
  void dispose() {
    _signalingUrlController.dispose();
    super.dispose();
  }
}
