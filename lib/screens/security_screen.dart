import 'dart:async';
import 'package:flutter/material.dart';
import '../security/dynamic_firewall.dart';
import '../security/license_manager.dart';
import '../services/native_security_bridge.dart';

/// 安全监控面板 — 对应原 Java 版 TamperMonitorPanel.java
/// v1.0.3: 接入 DynamicFirewall 心跳检测 + 事件日志 + 授权状态
class SecurityScreen extends StatefulWidget {
  final bool safeMode;

  const SecurityScreen({super.key, this.safeMode = true});

  @override
  State<SecurityScreen> createState() => _SecurityScreenState();
}

class _SecurityScreenState extends State<SecurityScreen> {
  final _firewall = DynamicFirewall();
  final _events = <Map<String, dynamic>>[];
  bool _monitoring = false;
  Timer? _heartbeatTimer;

  // ── 状态指标 ──────────────────────────────────
  bool _firewallActive = false;
  bool _heartbeatOk = false;
  bool _dynamicVerifyOk = false;
  String _lastChallenge = '';
  String _lastVerifyResult = ''; // 用于事件日志
  int _heartbeatSuccessCount = 0;
  int _heartbeatFailCount = 0;

  // ── 授权状态 ──────────────────────────────────
  bool _activated = false;
  bool _childMode = false;
  String? _deviceId;
  bool _debugDetected = false;

  @override
  void initState() {
    super.initState();
    _loadAuthStatus();
  }

  Future<void> _loadAuthStatus() async {
    final lm = LicenseManager.getInstance();
    final isDebugged = await NativeSecurityBridge.isBeingDebugged();
    setState(() {
      _activated = lm.isActivated;
      _childMode = lm.isChildMode;
      _deviceId = lm.deviceId;
      _debugDetected = isDebugged;
    });
  }

  /// 启动/停止监控
  void _toggleMonitoring(bool value) {
    setState(() => _monitoring = value);
    if (value) {
      _startMonitoring();
    } else {
      _stopMonitoring();
    }
  }

  void _startMonitoring() {
    // 立即执行一次
    _performHeartbeat();

    // 定期心跳：每 60 秒
    _heartbeatTimer = Timer.periodic(
      const Duration(seconds: 60),
      (_) => _performHeartbeat(),
    );

    _addEvent('info', '安全监控已启动', '系统');
  }

  void _stopMonitoring() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _firewallActive = false;
    _heartbeatOk = false;
    _dynamicVerifyOk = false;
    _addEvent('info', '安全监控已停止', '系统');
    setState(() {});
  }

  /// 执行一次心跳校验
  void _performHeartbeat() {
    final result = _firewall.heartbeatCheck();
    final state = _firewall.getDynamicState();

    setState(() {
      _firewallActive = true;
      _heartbeatOk = result;
      _dynamicVerifyOk = result;
      _lastChallenge = state['lastChallenge'] as String? ?? _lastChallenge;
      _lastVerifyResult = result ? 'PASS' : 'FAIL';

      if (result) {
        _heartbeatSuccessCount++;
      } else {
        _heartbeatFailCount++;
        _addEvent('high', '心跳校验失败！可能存在篡改', 'DynamicFirewall');
      }
    });
  }

  void _addEvent(String severity, String reason, String source) {
    _events.insert(0, {
      'severity': severity,
      'reason': reason,
      'source': source,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    });
    // 保留最近 200 条
    if (_events.length > 200) {
      _events.removeRange(200, _events.length);
    }
  }

  /// 手动触发挑战验证
  void _manualChallenge() {
    final challenge = _firewall.generateChallenge();
    final response = _firewall.verifyResponse(challenge, '');
    setState(() {
      _lastChallenge = challenge;
      _lastVerifyResult = response ? 'PASS' : 'FAIL (expected — empty response)';
    });
    _addEvent('medium', '手动验证挑战已生成: ${challenge.substring(0, 16)}...', 'DynamicFirewall');
  }

  /// 手动完整性校验
  Future<void> _manualIntegrityCheck() async {
    final ok = await _firewall.verifyIntegrity();
    setState(() {});
    if (ok) {
      _addEvent('low', '完整性校验通过', 'IntegrityCheck');
    } else {
      _addEvent('high', '⚠️ 完整性校验失败！应用可能被篡改', 'IntegrityCheck');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 标题 + 开关
          Row(
            children: [
              Text(
                '安全监控',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const Spacer(),
              Switch(
                value: _monitoring,
                onChanged: _toggleMonitoring,
                activeColor: Colors.green,
              ),
              Text(_monitoring ? '监控中' : '已停止'),
            ],
          ),
          const SizedBox(height: 16),

          // SAFE_MODE 状态
          if (widget.safeMode)
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.orange.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.orange.withValues(alpha: 0.3)),
              ),
              child: const Row(
                children: [
                  Icon(Icons.shield, color: Colors.orange, size: 18),
                  SizedBox(width: 8),
                  Text('SAFE_MODE 已开启 — 危险指令已被拦截',
                      style: TextStyle(color: Colors.orange, fontSize: 13)),
                ],
              ),
            ),
          const SizedBox(height: 12),

          // 状态卡片
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  _StatusIndicator(
                    label: '防火墙',
                    active: _firewallActive,
                    color: Colors.green,
                  ),
                  const SizedBox(width: 24),
                  _StatusIndicator(
                    label: '心跳检测',
                    active: _heartbeatOk,
                    color: Colors.blue,
                  ),
                  const SizedBox(width: 24),
                  _StatusIndicator(
                    label: '动态验证',
                    active: _dynamicVerifyOk,
                    color: Colors.orange,
                  ),
                  const SizedBox(width: 24),
                  _StatusIndicator(
                    label: '调试检测',
                    active: !_debugDetected,
                    color: Colors.purple,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),

          // 授权状态
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('授权状态', style: Theme.of(context).textTheme.titleSmall),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      _chip('已激活', _activated, Colors.green),
                      const SizedBox(width: 8),
                      _chip('子端模式', _childMode, Colors.blue),
                      const SizedBox(width: 8),
                      _chip('调试中', _debugDetected, Colors.red),
                    ],
                  ),
                  if (_deviceId != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text('设备 ID: $_deviceId',
                          style: const TextStyle(fontSize: 11, color: Colors.grey)),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),

          // 心跳统计
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  _StatItem(label: '成功', value: _heartbeatSuccessCount, color: Colors.green),
                  _StatItem(label: '失败', value: _heartbeatFailCount, color: Colors.red),
                  _StatItem(
                    label: '成功率',
                    value: _heartbeatSuccessCount + _heartbeatFailCount > 0
                        ? '${((_heartbeatSuccessCount / (_heartbeatSuccessCount + _heartbeatFailCount)) * 100).toStringAsFixed(1)}%'
                        : '-',
                    color: Colors.blue,
                    isText: true,
                  ),
                  if (_lastVerifyResult.isNotEmpty)
                    _StatItem(
                      label: '上次校验',
                      value: _lastVerifyResult,
                      color: _lastVerifyResult == 'PASS' ? Colors.green : Colors.red,
                      isText: true,
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),

          // 手动操作按钮
          Row(
            children: [
              OutlinedButton.icon(
                onPressed: _manualChallenge,
                icon: const Icon(Icons.quiz, size: 16),
                label: const Text('手动验证'),
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: _manualIntegrityCheck,
                icon: const Icon(Icons.verified_user, size: 16),
                label: const Text('完整性校验'),
              ),
            ],
          ),
          const SizedBox(height: 16),

          // 事件列表标题
          Row(
            children: [
              Text('安全事件日志', style: Theme.of(context).textTheme.titleMedium),
              const Spacer(),
              if (_events.isNotEmpty)
                TextButton(
                  onPressed: () => setState(() => _events.clear()),
                  child: const Text('清空'),
                ),
            ],
          ),
          const SizedBox(height: 8),

          // 事件列表
          Expanded(
            child: _events.isEmpty
                ? _EmptyState()
                : ListView.builder(
                    itemCount: _events.length,
                    itemBuilder: (ctx, i) {
                      final e = _events[i];
                      return Card(
                        margin: const EdgeInsets.symmetric(vertical: 2),
                        child: ListTile(
                          dense: true,
                          leading: Icon(
                            _severityIcon(e['severity'] as String? ?? 'low'),
                            color: _severityColor(e['severity'] as String? ?? 'low'),
                            size: 20,
                          ),
                          title: Text(
                            e['reason'] as String? ?? '未知',
                            style: const TextStyle(fontSize: 13),
                          ),
                          subtitle: Text(
                            e['source'] as String? ?? '',
                            style: const TextStyle(fontSize: 11),
                          ),
                          trailing: Text(
                            _formatTime(e['timestamp'] as int?),
                            style: const TextStyle(color: Colors.grey, fontSize: 11),
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _chip(String label, bool active, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: active ? color.withValues(alpha: 0.1) : Colors.grey.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: active ? color : Colors.grey, width: 1),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          color: active ? color : Colors.grey,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  IconData _severityIcon(String s) => switch (s) {
    'high' => Icons.error,
    'medium' => Icons.warning,
    'info' => Icons.info,
    _ => Icons.check_circle,
  };

  Color _severityColor(String s) => switch (s) {
    'high' => Colors.red,
    'medium' => Colors.orange,
    'info' => Colors.blue,
    _ => Colors.green,
  };

  String _formatTime(int? ts) {
    if (ts == null) return '';
    final d = DateTime.fromMillisecondsSinceEpoch(ts);
    return '${d.month}-${d.day} ${d.hour}:${d.minute.toString().padLeft(2, '0')}';
  }

  @override
  void dispose() {
    _heartbeatTimer?.cancel();
    super.dispose();
  }
}

/// 状态指示灯组件
class _StatusIndicator extends StatelessWidget {
  final String label;
  final bool active;
  final Color color;

  const _StatusIndicator({
    required this.label,
    required this.active,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(
            color: active ? color : Colors.grey,
            shape: BoxShape.circle,
            boxShadow: active
                ? [BoxShadow(color: color.withValues(alpha: 0.4), blurRadius: 8)]
                : null,
          ),
        ),
        const SizedBox(height: 4),
        Text(label, style: const TextStyle(fontSize: 12)),
      ],
    );
  }
}

/// 统计项
class _StatItem extends StatelessWidget {
  final String label;
  final dynamic value;
  final Color color;
  final bool isText;

  const _StatItem({
    required this.label,
    required this.value,
    required this.color,
    this.isText = false,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(
          isText ? value as String : value.toString(),
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.bold,
            color: color,
          ),
        ),
        const SizedBox(height: 2),
        Text(label, style: const TextStyle(fontSize: 11, color: Colors.grey)),
      ],
    );
  }
}

/// 空状态 — 雷达脉冲动画
class _EmptyState extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          TweenAnimationBuilder<double>(
            tween: Tween(begin: 0, end: 1),
            duration: const Duration(seconds: 2),
            builder: (ctx, v, _) => Container(
              width: 80 + v * 40,
              height: 80 + v * 40,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: Colors.blue.withValues(alpha: 1 - v),
                  width: 2,
                ),
              ),
              child: const Icon(Icons.radar, size: 40, color: Colors.blue),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            '暂无安全事件',
            style: TextStyle(color: Colors.grey[600]),
          ),
        ],
      ),
    );
  }
}
