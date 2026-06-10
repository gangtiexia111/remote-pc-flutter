/// signaling_client.dart
///
/// WebSocket 信令客户端
/// 负责与信令服务器通信，交换 SDP offer/answer 和 ICE candidate
/// 支持自动重连（指数退避）
library;

import 'dart:async';
import 'dart:convert';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/status.dart' as status;

/// 信令客户端回调接口
class SignalingCallbacks {
  final void Function(Map<String, dynamic> data)? onOffer;
  final void Function(Map<String, dynamic> data)? onAnswer;
  final void Function(Map<String, dynamic> data)? onIceCandidate;
  final void Function(List<dynamic> rooms)? onRoomList;
  final void Function()? onConnected;
  final void Function()? onDisconnected;

  SignalingCallbacks({
    this.onOffer,
    this.onAnswer,
    this.onIceCandidate,
    this.onRoomList,
    this.onConnected,
    this.onDisconnected,
  });
}

/// WebSocket 信令客户端
class SignalingClient {
  final String serverUrl;
  final String deviceId;
  final SignalingCallbacks callbacks;

  WebSocketChannel? _channel;
  bool _connected = false;
  bool _shouldReconnect = true;
  Timer? _reconnectTimer;
  int _reconnectAttempts = 0;
  final int _maxReconnectAttempts = 10;

  /// 重连延迟（毫秒），指数退避：1s, 2s, 4s, 8s... 最大 30s
  int get _reconnectDelay =>
      (_reconnectAttempts < 5 ? (1 << _reconnectAttempts) * 1000 : 30000)
          .clamp(1000, 30000);

  bool get isConnected => _connected;

  SignalingClient({
    required this.serverUrl,
    required this.deviceId,
    required this.callbacks,
  });

  /// 连接到信令服务器
  void connect() {
    _shouldReconnect = true;
    _doConnect();
  }

  void _doConnect() {
    try {
      print('[Signaling] Connecting to $serverUrl');
      _channel = WebSocketChannel.connect(Uri.parse(serverUrl));
      _connected = true;
      _reconnectAttempts = 0;

      callbacks.onConnected?.call();

      // 监听消息
      _channel!.stream.listen(
        (message) => _handleMessage(message),
        onDone: () {
          print('[Signaling] Connection closed');
          _connected = false;
          callbacks.onDisconnected?.call();
          _tryReconnect();
        },
        onError: (error) {
          print('[Signaling] Error: $error');
          _connected = false;
          callbacks.onDisconnected?.call();
          _tryReconnect();
        },
      );
    } catch (e) {
      print('[Signaling] Connect failed: $e');
      _connected = false;
      _tryReconnect();
    }
  }

  /// 处理服务器消息
  void _handleMessage(dynamic raw) {
    try {
      final Map<String, dynamic> msg = jsonDecode(raw as String);
      final type = msg['type'] as String?;
      print('[Signaling] Received: $type');

      switch (type) {
        case 'offer':
          callbacks.onOffer?.call(msg);
        case 'answer':
          callbacks.onAnswer?.call(msg);
        case 'ice_candidate':
          callbacks.onIceCandidate?.call(msg);
        case 'room_list':
          final rooms = msg['rooms'] as List<dynamic>? ?? [];
          callbacks.onRoomList?.call(rooms);
        case 'error':
          print('[Signaling] Server error: ${msg['message']}');
        default:
          print('[Signaling] Unknown message type: $type');
      }
    } catch (e) {
      print('[Signaling] Message parse error: $e');
    }
  }

  /// 发送消息
  void _send(Map<String, dynamic> msg) {
    if (!_connected || _channel == null) {
      print('[Signaling] Cannot send, not connected');
      return;
    }
    try {
      _channel!.sink.add(jsonEncode(msg));
    } catch (e) {
      print('[Signaling] Send error: $e');
    }
  }

  // ── 房间操作 ──────────────────────────────────────

  /// 创建房间（作为 Host/主控端）
  void createRoom(String roomId) {
    _send({'type': 'create_room', 'roomId': roomId});
  }

  /// 加入房间（作为 Guest/被控端）
  void joinRoom(String roomId) {
    _send({'type': 'join_room', 'roomId': roomId});
  }

  /// 离开房间
  void leaveRoom(String roomId) {
    _send({'type': 'leave_room', 'roomId': roomId});
  }

  /// 请求房间列表
  void listRooms() {
    _send({'type': 'list_rooms'});
  }

  // ── WebRTC 信令 ────────────────────────────────────

  /// 发送 SDP Offer
  void sendOffer(String roomId, Map<String, dynamic> sdp) {
    _send({'type': 'offer', 'roomId': roomId, 'sdp': sdp});
  }

  /// 发送 SDP Answer
  void sendAnswer(String roomId, Map<String, dynamic> sdp) {
    _send({'type': 'answer', 'roomId': roomId, 'sdp': sdp});
  }

  /// 发送 ICE Candidate
  void sendIceCandidate(String roomId, Map<String, dynamic> candidate) {
    _send({'type': 'ice_candidate', 'roomId': roomId, 'candidate': candidate});
  }

  // ── 重连逻辑 ──────────────────────────────────────

  void _tryReconnect() {
    if (!_shouldReconnect) return;
    if (_reconnectAttempts >= _maxReconnectAttempts) {
      // 超过最大重试次数后，切换为每 5 分钟轮询，而非永久放弃
      print('[Signaling] Max retries reached, switching to slow poll (5min)');
      _reconnectTimer?.cancel();
      _reconnectTimer = Timer(const Duration(minutes: 5), () {
        _reconnectAttempts = 0; // 重置计数，允许重新指数退避
        _doConnect();
      });
      return;
    }

    _reconnectAttempts++;
    print('[Signaling] Reconnecting in $_reconnectDelay ms '
        '(attempt $_reconnectAttempts)');

    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(Duration(milliseconds: _reconnectDelay), () {
      _doConnect();
    });
  }

  /// 断开连接
  void disconnect() {
    _shouldReconnect = false;
    _reconnectTimer?.cancel();
    if (_channel != null) {
      _channel!.sink.close(status.normalClosure);
      _channel = null;
    }
    _connected = false;
  }
}
