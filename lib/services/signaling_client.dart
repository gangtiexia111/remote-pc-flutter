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

/// V6-08：信令消息类型白名单（只接受已知消息类型）
const _allowedMessageTypes = {
  'offer', 'answer', 'ice_candidate', 'room_list',
  'create_room', 'join_room', 'leave_room', 'list_rooms',
  'error',
};

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

  /// 确保使用 wss://（ATK-W11 修复：信令必须加密传输）
  String _ensureSecureUrl(String url) {
    if (url.startsWith('ws://') && !url.startsWith('ws://localhost') &&
        !url.startsWith('ws://127.0.0.1')) {
      // 非本地连接必须使用 wss://
      final secureUrl = url.replaceFirst('ws://', 'wss://');
      print('[Signaling] ⚠️ Upgraded ws:// to wss:// for security');
      return secureUrl;
    }
    return url;
  }

  /// 连接到信令服务器
  void connect() {
    _shouldReconnect = true;
    _doConnect();
  }

  void _doConnect() {
    try {
      final secureUrl = _ensureSecureUrl(serverUrl);
      print('[Signaling] Connecting to $secureUrl');
      _channel = WebSocketChannel.connect(Uri.parse(secureUrl));
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
  /// V6-08：添加消息结构验证（防恶意信令服务器注入伪造消息）
  void _handleMessage(dynamic raw) {
    try {
      final Map<String, dynamic> msg = jsonDecode(raw as String);
      final type = msg['type'] as String?;

      // V6-08：消息类型白名单验证
      if (type == null || !_allowedMessageTypes.contains(type)) {
        print('[Signaling] ⛔ Rejected unknown message type: $type');
        return;
      }

      // V6-08：结构验证 — 各消息类型必须包含的必要字段
      switch (type) {
        case 'offer':
        case 'answer':
          if (!_validateSdpMessage(msg)) return;
          break;
        case 'ice_candidate':
          if (!_validateIceCandidateMessage(msg)) return;
          break;
        case 'room_list':
          final rooms = msg['rooms'] as List<dynamic>? ?? [];
          callbacks.onRoomList?.call(rooms);
          return; // room_list 直接处理，不走下面的通用 switch
        case 'error':
          print('[Signaling] Server error: ${msg['message']}');
          return;
      }

      print('[Signaling] Received: $type');

      switch (type) {
        case 'offer':
          callbacks.onOffer?.call(msg);
        case 'answer':
          callbacks.onAnswer?.call(msg);
        case 'ice_candidate':
          callbacks.onIceCandidate?.call(msg);
      }
    } catch (e) {
      print('[Signaling] Message parse error');
    }
  }

  /// V6-08：验证 SDP 消息结构
  bool _validateSdpMessage(Map<String, dynamic> msg) {
    final sdp = msg['sdp'];
    if (sdp == null) {
      print('[Signaling] ⛔ SDP message missing "sdp" field');
      return false;
    }
    // sdp 必须是 Map 且包含 sdp 和 type 字段
    if (sdp is! Map<String, dynamic>) {
      print('[Signaling] ⛔ SDP field is not a Map');
      return false;
    }
    final sdpStr = sdp['sdp'] as String?;
    final sdpType = sdp['type'] as String?;
    if (sdpStr == null || sdpType == null) {
      print('[Signaling] ⛔ SDP missing "sdp" or "type" field');
      return false;
    }
    // V6-08：SDP 类型必须合法
    if (!{'offer', 'answer', 'pranswer', 'rollback'}.contains(sdpType)) {
      print('[Signaling] ⛔ Invalid SDP type: $sdpType');
      return false;
    }
    // V6-08：SDP 内容长度限制（防止注入超大 payload）
    if (sdpStr.length > 65536) {
      print('[Signaling] ⛔ SDP too large (${sdpStr.length} chars)');
      return false;
    }
    return true;
  }

  /// V6-08：验证 ICE Candidate 消息结构
  bool _validateIceCandidateMessage(Map<String, dynamic> msg) {
    final candidate = msg['candidate'];
    if (candidate == null) {
      print('[Signaling] ⛔ ICE candidate message missing "candidate" field');
      return false;
    }
    if (candidate is! Map<String, dynamic>) {
      print('[Signaling] ⛔ Candidate field is not a Map');
      return false;
    }
    final candidateStr = candidate['candidate'] as String?;
    if (candidateStr == null) {
      print('[Signaling] ⛔ ICE candidate missing "candidate" string');
      return false;
    }
    if (candidateStr.length > 8192) {
      print('[Signaling] ⛔ ICE candidate string too long');
      return false;
    }
    return true;
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
