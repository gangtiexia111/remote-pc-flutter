import 'package:flutter/material.dart';

/// 安全监控面板 — 对应原 Java 版 TamperMonitorPanel.java
class SecurityScreen extends StatefulWidget {
  const SecurityScreen({super.key});

  @override
  State<SecurityScreen> createState() => _SecurityScreenState();
}

class _SecurityScreenState extends State<SecurityScreen> {
  final _events = <Map<String, dynamic>>[];
  bool _monitoring = false;

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
                onChanged: (v) => setState(() => _monitoring = v),
                activeColor: Colors.green,
              ),
              Text(_monitoring ? '监控中' : '已停止'),
            ],
          ),
          const SizedBox(height: 16),
          // 状态卡片
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  _StatusIndicator(
                    label: '防火墙',
                    active: _monitoring,
                    color: Colors.green,
                  ),
                  const SizedBox(width: 24),
                  _StatusIndicator(
                    label: '心跳检测',
                    active: _monitoring,
                    color: Colors.blue,
                  ),
                  const SizedBox(width: 24),
                  _StatusIndicator(
                    label: '动态验证',
                    active: _monitoring,
                    color: Colors.orange,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          // 事件列表标题
          Text(
            '篡改事件日志',
            style: Theme.of(context).textTheme.titleMedium,
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
                        child: ListTile(
                          leading: Icon(
                            Icons.warning,
                            color: _severityColor(e['severity'] as String? ?? 'low'),
                          ),
                          title: Text(e['reason'] as String? ?? '未知'),
                          subtitle: Text(e['device'] as String? ?? ''),
                          trailing: Text(
                            _formatTime(e['timestamp'] as int?),
                            style: const TextStyle(color: Colors.grey),
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

  Color _severityColor(String s) => switch (s) {
    'high' => Colors.red,
    'medium' => Colors.orange,
    _ => Colors.green,
  };

  String _formatTime(int? ts) {
    if (ts == null) return '';
    final d = DateTime.fromMillisecondsSinceEpoch(ts);
    return '${d.month}-${d.day} ${d.hour}:${d.minute.toString().padLeft(2, '0')}';
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

/// 空状态 — 对应原 Java 版雷达脉冲动画
class _EmptyState extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // 模拟雷达脉冲动画
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
            '暂无篡改事件',
            style: TextStyle(color: Colors.grey[600]),
          ),
        ],
      ),
    );
  }
}
