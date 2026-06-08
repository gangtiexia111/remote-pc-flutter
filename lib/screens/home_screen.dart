import 'package:flutter/material.dart';
import '../services/udp_discovery.dart';
import '../services/http_server.dart';
import '../models/device.dart';

/// 主界面 — 对应原 Java 版 DesktopControlApp 主窗口
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _udp = UdpDiscoveryService();
  final _http = HttpServerService();
  Device? _selfDevice;
  bool _serverRunning = false;

  @override
  void initState() {
    super.initState();
    _initServices();
  }

  Future<void> _initServices() async {
    // 启动 UDP 发现
    await _udp.startListening();
    // 启动 HTTP 服务
    _selfDevice = Device(
      id: 'remote-pc-${DateTime.now().millisecondsSinceEpoch}',
      name: 'RemotePC-Desktop',
      ip: '127.0.0.1',
      port: 9998,
    );
    _http.setDevice(_selfDevice!);
    await _http.start(port: 9998);
    setState(() => _serverRunning = true);
    // 发送首次广播
    await _udp.sendDiscoveryBroadcast(_selfDevice!);
  }

  @override
  void dispose() {
    _udp.stop();
    _http.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Remote PC Control'),
        actions: [
          IconButton(
            icon: Icon(_serverRunning ? Icons.circle : Icons.circle_outlined),
            color: _serverRunning ? Colors.green : Colors.grey,
            onPressed: () {},
            tooltip: _serverRunning ? '服务运行中' : '服务已停止',
          ),
        ],
      ),
      body: Row(
        children: [
          // 左侧导航栏
          NavigationRail(
            selectedIndex: 0,
            onDestinationSelected: (idx) {},
            labelType: NavigationRailLabelType.all,
            destinations: const [
              NavigationRailDestination(
                icon: Icon(Icons.devices),
                label: Text('设备列表'),
              ),
              NavigationRailDestination(
                icon: Icon(Icons.security),
                label: Text('安全监控'),
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
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '设备列表',
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 16),
                  Expanded(
                    child: _DeviceList(udp: _udp),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _udp.sendDiscoveryBroadcast(_selfDevice!),
        tooltip: '刷新设备',
        child: const Icon(Icons.refresh),
      ),
    );
  }
}

/// 设备列表组件
class _DeviceList extends StatefulWidget {
  final UdpDiscoveryService udp;
  const _DeviceList({required this.udp});

  @override
  State<_DeviceList> createState() => _DeviceListState();
}

class _DeviceListState extends State<_DeviceList> {
  @override
  void initState() {
    super.initState();
    widget.udp.addCallback((_) => setState(() {}));
  }

  @override
  Widget build(BuildContext context) {
    final devices = widget.udp.devices.values.toList();
    if (devices.isEmpty) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.radar, size: 64, color: Colors.grey),
            SizedBox(height: 16),
            Text('未发现设备', style: TextStyle(color: Colors.grey)),
          ],
        ),
      );
    }
    return ListView.builder(
      itemCount: devices.length,
      itemBuilder: (ctx, i) {
        final d = devices[i];
        return Card(
          child: ListTile(
            leading: Icon(
              d.isOnline ? Icons.computer : Icons.computer_outlined,
              color: d.isOnline ? Colors.green : Colors.grey,
            ),
            title: Text(d.name),
            subtitle: Text('${d.ip}:${d.port} · ${d.statusLabel}'),
            trailing: d.isOnline
                ? PopupMenuButton<String>(
                    onSelected: (v) => _sendCommand(d, v),
                    itemBuilder: (_) => [
                      const PopupMenuItem(value: 'shutdown', child: Text('关机')),
                      const PopupMenuItem(value: 'restart', child: Text('重启')),
                      const PopupMenuItem(value: 'lock', child: Text('锁屏')),
                    ],
                  )
                : null,
          ),
        );
      },
    );
  }

  void _sendCommand(Device d, String cmd) {
    // 发送 HTTP 控制指令到子端
    // 实际应使用 http 包发送请求
    print('[CMD] Send $cmd to ${d.ip}:${d.port}');
  }
}
