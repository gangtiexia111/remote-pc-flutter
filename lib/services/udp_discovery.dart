import 'dart:convert';
import 'dart:io';
import '../models/device.dart';

/// UDP 设备发现服务 — 对应原 Java 版 UdpDiscovery.java
/// 支持跨平台（Android/iOS/Windows/macOS/Linux）
class UdpDiscoveryService {
  static const int _discoveryPort = 4567;
  static const String _broadcastAddress = '255.255.255.255';
  static const String _magicHeader = 'REMOTE_PC_V3';

  RawDatagramSocket? _socket;
  final _devices = <String, Device>{};
  final _callbacks = <Function(Device)>[];
  bool _running = false;

  Map<String, Device> get devices => Map.unmodifiable(_devices);

  /// 启动 UDP 监听（接收广播）
  Future<void> startListening() async {
    if (_running) return;
    _running = true;
    _socket = await RawDatagramSocket.bind(
      InternetAddress.anyIPv4,
      _discoveryPort,
      reuseAddress: true,
      reusePort: true,
    );
    _socket!.broadcastEnabled = true;
    _socket!.listen(_onPacket);
    print('[UDP] Listening on port $_discoveryPort');
  }

  /// 发送设备发现广播
  Future<void> sendDiscoveryBroadcast(Device self) async {
    final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    socket.broadcastEnabled = true;
    final msg = jsonEncode({
      'header': _magicHeader,
      'id': self.id,
      'name': self.name,
      'ip': self.ip,
      'port': self.port,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    });
    final data = utf8.encode(msg);
    _socket?.send(data, InternetAddress(_broadcastAddress), _discoveryPort);
    socket.close();
    print('[UDP] Broadcast sent');
  }

  void _onPacket(RawSocketEvent event) {
    if (event != RawSocketEvent.read) return;
    final dg = _socket?.receive();
    if (dg == null) return;
    try {
      final msg = jsonDecode(utf8.decode(dg.data)) as Map<String, dynamic>;
      if (msg['header'] != _magicHeader) return;
      final id = msg['id'] as String;
      if (_devices.containsKey(id)) {
        _devices[id]!.markAlive();
      } else {
        _devices[id] = Device(
          id: id,
          name: msg['name'] as String,
          ip: dg.address.address,
          port: msg['port'] as int,
        )..markAlive();
      }
      for (final cb in _callbacks) {
        cb(_devices[id]!);
      }
    } catch (_) {}
  }

  void addCallback(Function(Device) cb) => _callbacks.add(cb);

  Future<void> stop() async {
    _running = false;
    _socket?.close();
    _socket = null;
  }
}
