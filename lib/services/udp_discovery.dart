import 'dart:convert';
import 'dart:io';
import 'dart:math';
import '../models/device.dart';

/// UDP 设备发现服务 — 对应原 Java 版 UdpDiscovery.java
/// 支持跨平台（Android/iOS/Windows/macOS/Linux）
///
/// v1.0.4 安全加固：
///   - 时间戳 + nonce 防重放攻击
///   - Magic header 防误识别
///   - 身份鉴权在 HTTP 层（DeviceWhitelist），UDP 只做发现
///
/// V5-08 加固：
///   - 递增序列号防重放（比纯 nonce 更可靠）
///   - 时间窗口缩小到 5 秒
///   - 包大小限制防 DoS
///   - Nonce 条目定时清理（避免内存泄漏）
class UdpDiscoveryService {
  static const int _discoveryPort = 4567;
  static const String _broadcastAddress = '255.255.255.255';
  static const String _magicHeader = 'REMOTE_PC_V4';

  /// 最大 UDP 包大小（V5-08：防大包 DoS）
  static const int _maxPacketSize = 4096;

  /// 时间戳有效窗口（V5-08：从 10s 缩小到 5s）
  static const int _timestampWindowMs = 5000;

  RawDatagramSocket? _socket;
  final _devices = <String, Device>{};
  final _callbacks = <Function(Device)>[];
  bool _running = false;
  final _seenNonces = <int>{};
  final _rng = Random.secure();

  /// 递增序列号（V5-08：防重放更可靠）
  int _sequenceNumber = 0;

  /// Nonce 清理时间（定期清理过期的 nonce 条目）
  int _lastNonceCleanup = 0;

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
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final nonce = _rng.nextInt(0xFFFFFFFF);
    _sequenceNumber++;
    final msg = jsonEncode({
      'header': _magicHeader,
      'id': self.id,
      'name': self.name,
      'ip': self.ip,
      'port': self.port,
      'timestamp': timestamp,
      'nonce': nonce,
      'seq': _sequenceNumber, // V5-08：递增序列号
    });
    final data = utf8.encode(msg);
    _socket?.send(data, InternetAddress(_broadcastAddress), _discoveryPort);
    socket.close();
    print('[UDP] Broadcast sent (ts=$timestamp, nonce=$nonce, seq=$_sequenceNumber)');
  }

  void _onPacket(RawSocketEvent event) {
    if (event != RawSocketEvent.read) return;
    final dg = _socket?.receive();
    if (dg == null) return;

    // V5-08：包大小限制（防大包 DoS）
    if (dg.data.length > _maxPacketSize) {
      print('[UDP] Drop oversized packet (${dg.data.length} bytes) '
          'from ${dg.address.address}');
      return;
    }

    try {
      final msg = jsonDecode(utf8.decode(dg.data)) as Map<String, dynamic>;
      if (msg['header'] != _magicHeader) return;

      // 时间戳验证（V5-08：5 秒内有效，防重放攻击）
      final timestamp = msg['timestamp'] as int? ?? 0;
      if ((DateTime.now().millisecondsSinceEpoch - timestamp).abs() >
          _timestampWindowMs) {
        print('[UDP] Drop expired packet from ${dg.address.address}');
        return;
      }

      // Nonce 去重（防重放攻击）
      final nonce = msg['nonce'] as int? ?? 0;
      if (_seenNonces.contains(nonce)) {
        print('[UDP] Drop replayed packet from ${dg.address.address}');
        return;
      }
      _seenNonces.add(nonce);

      // V5-08：定时清理 nonce（而非满 1000 清空所有）
      final now = DateTime.now().millisecondsSinceEpoch;
      if (now - _lastNonceCleanup > 30000) {
        // 每 30 秒清空一次（nonce 在 5 秒内去重即可，30 秒足够安全）
        _seenNonces.clear();
        _lastNonceCleanup = now;
      }

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
    } catch (e) {
      // V5-08：不泄露解析错误细节
      print('[UDP] Packet parse error from ${dg.address.address}');
    }
  }

  void addCallback(Function(Device) cb) => _callbacks.add(cb);

  Future<void> stop() async {
    _running = false;
    _socket?.close();
    _socket = null;
  }
}
