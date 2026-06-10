/// webrtc_connection_service.dart
///
/// WebRTC 跨网络连接管理服务
/// 通过 Data Channel 传输控制指令
/// 自动降级：LAN 优先，WebRTC 兜底
library;

import 'dart:async';
import 'dart:convert';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'signaling_client.dart';

/// WebRTC 连接状态
enum WebRtcState {
  idle,
  connecting,
  connected,
  failed,
}

/// WebRTC 连接回调
class WebRtcCallbacks {
  final void Function(String deviceId)? onConnected;
  final void Function(String deviceId)? onDisconnected;
  final void Function(String deviceId, String command)? onCommandReceived;
  final void Function(WebRtcState state)? onStateChanged;

  WebRtcCallbacks({
    this.onConnected,
    this.onDisconnected,
    this.onCommandReceived,
    this.onStateChanged,
  });
}

/// WebRTC 连接管理服务
class WebRtcConnectionService {
  final String deviceId;
  final String signalingUrl;
  final WebRtcCallbacks callbacks;

  RTCPeerConnection? _peerConnection;
  RTCDataChannel? _dataChannel;
  SignalingClient? _signalingClient;
  WebRtcState _state = WebRtcState.idle;

  /// 当前房间 ID
  String? _currentRoomId;

  /// 是否是 Host（主控端）
  bool _isHost = false;

  /// V6-05 修复：DataChannel 允许的指令白名单
  /// 只允许安全控制指令，禁止通过 WebRTC 直接触发关机/重启等高危操作
  static const _allowedCommands = {
    'mouse_move', 'mouse_click', 'mouse_double_click',
    'mouse_right_click', 'mouse_drag',
    'key_press', 'key_combo', 'key_type',
    'scroll_up', 'scroll_down',
    'volume_up', 'volume_down', 'volume_mute',
    'brightness_up', 'brightness_down',
    'get_screen', 'get_clipboard', 'set_clipboard',
    'ping', 'status', 'screenshot',
  };

  /// V6-05：通过 DataChannel 严禁的高危指令（必须通过 HTTP + 白名单 + Token）
  static const _blockedCommands = {
    'shutdown', 'restart', 'lock_screen', 'self_destruct',
    'remote_self_destruct', 'pair', 'unpair',
  };

  /// V7-09 修复：DataChannel 消息速率限制
  /// 同一连接每秒最多允许 _maxMessagesPerSecond 条消息，防止泛洪攻击
  static const int _maxMessagesPerSecond = 30;
  int _messageCount = 0;
  int _messageCountResetAt = 0; // 上次重置时间戳（ms）
  static const int _messageWindowMs = 1000; // 1 秒窗口

  WebRtcState get state => _state;

  WebRtcConnectionService({
    required this.deviceId,
    required this.signalingUrl,
    required this.callbacks,
  });

  /// 设置连接状态并发回调
  void _setState(WebRtcState s) {
    _state = s;
    callbacks.onStateChanged?.call(s);
  }

  // ── ICE Server 配置 ──────────────────────────────

  /// Google 免费 STUN + Metered.ca 免费 TURN
  static const _iceServers = [
    {
      'urls': ['stun:stun.l.google.com:19302'],
    },
    {
      'urls': ['stun:stun.cloudflare.com:3478'],
    },
    {
      'urls': ['turn:openrelay.metered.ca:80'],
      'username': 'openrelayproject',
      'credential': 'openrelayproject',
    },
    {
      'urls': ['turn:openrelay.metered.ca:443'],
      'username': 'openrelayproject',
      'credential': 'openrelayproject',
    },
  ];

  // ── 初始化 ──────────────────────────────────────

  /// 初始化并连接信令服务器
  void init() {
    _signalingClient = SignalingClient(
      serverUrl: signalingUrl,
      deviceId: deviceId,
      callbacks: SignalingCallbacks(
        onOffer: _onOfferReceived,
        onAnswer: _onAnswerReceived,
        onIceCandidate: _onIceCandidateReceived,
        onConnected: () => print('[WebRTC] Signaling connected'),
        onDisconnected: () {
          _setState(WebRtcState.idle);
          print('[WebRTC] Signaling disconnected');
        },
      ),
    );
    _signalingClient!.connect();
  }

  // ── Host 模式（主控端）────────────────────────

  /// 作为 Host 创建房间，等待 Guest 连接
  Future<void> createRoom(String roomId) async {
    _isHost = true;
    _currentRoomId = roomId;
    _setState(WebRtcState.connecting);

    await _createPeerConnection();

    // Host 创建 DataChannel
    _dataChannel = await _peerConnection!.createDataChannel(
      'commands',
      RTCDataChannelInit()
        ..ordered = true
        ..maxRetransmits = 30,
    );
    _setupDataChannel(_dataChannel!);

    // 创建 Offer
    final offer = await _peerConnection!.createOffer();
    await _peerConnection!.setLocalDescription(offer);

    // 通过信令服务器发送 Offer
    _signalingClient!.sendOffer(roomId, offer.toMap());

    // 监听 ICE candidate 并发送
    _peerConnection!.onIceCandidate = (candidate) {
      _signalingClient!.sendIceCandidate(
        roomId,
        candidate.toMap(),
      );
    };

    _signalingClient!.createRoom(roomId);
  }

  // ── Guest 模式（被控端）────────────────────────

  /// 作为 Guest 加入房间
  Future<void> joinRoom(String roomId) async {
    _isHost = false;
    _currentRoomId = roomId;
    _setState(WebRtcState.connecting);

    await _createPeerConnection();
    _signalingClient!.joinRoom(roomId);
  }

  /// 收到 Offer（Guest 端处理）
  void _onOfferReceived(Map<String, dynamic> data) {
    if (!_isHost) _handleOffer(data);
  }

  Future<void> _handleOffer(Map<String, dynamic> data) async {
    final sdp = data['sdp'] as Map<String, dynamic>?;
    if (sdp == null) return;

    await _peerConnection!.setRemoteDescription(
      RTCSessionDescription(sdp['sdp'], sdp['type']),
    );

    final answer = await _peerConnection!.createAnswer();
    await _peerConnection!.setLocalDescription(answer);

    _signalingClient!.sendAnswer(
      _currentRoomId!,
      answer.toMap(),
    );
  }

  /// 收到 Answer（Host 端处理）
  void _onAnswerReceived(Map<String, dynamic> data) {
    if (_isHost) _handleAnswer(data);
  }

  Future<void> _handleAnswer(Map<String, dynamic> data) async {
    final sdp = data['sdp'] as Map<String, dynamic>?;
    if (sdp == null) return;

    await _peerConnection!.setRemoteDescription(
      RTCSessionDescription(sdp['sdp'], sdp['type']),
    );
  }

  /// 收到 ICE Candidate
  void _onIceCandidateReceived(Map<String, dynamic> data) {
    final candidate = data['candidate'] as Map<String, dynamic>?;
    if (candidate == null) return;

    _peerConnection!.addCandidate(
      RTCIceCandidate(
        candidate['candidate'],
        candidate['sdpMid'],
        candidate['sdpMLineIndex'],
      ),
    );
  }

  // ── PeerConnection 管理 ─────────────────────────

  Future<void> _createPeerConnection() async {
    _peerConnection = await createPeerConnection({
      'iceServers': _iceServers,
      'sdpSemantics': 'unified-plan',
    });

    // Guest 端等待 Host 的 DataChannel
    _peerConnection!.onDataChannel = (channel) {
      _dataChannel = channel;
      _setupDataChannel(channel);
    };

    // 连接状态监控
    _peerConnection!.onConnectionState = (state) {
      print('[WebRTC] ConnectionState: $state');
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
        _setState(WebRtcState.connected);
        callbacks.onConnected?.call(_currentRoomId ?? '');
      } else if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
          state == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected) {
        _setState(WebRtcState.failed);
        callbacks.onDisconnected?.call(_currentRoomId ?? '');
      }
    };
  }

  // ── DataChannel 管理 ────────────────────────────

  void _setupDataChannel(RTCDataChannel channel) {
    channel.onDataChannelState = (state) {
      print('[WebRTC] DataChannelState: $state');
    };

    // flutter_webrtc 0.12.x: onMessage 是 setter
    channel.onMessage = (message) {
      _handleDataChannelMessage(message.text);
    };
  }

  void _handleDataChannelMessage(String data) {
    // V7-09 修复：DataChannel 消息速率限制
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _messageCountResetAt >= _messageWindowMs) {
      _messageCount = 0;
      _messageCountResetAt = now;
    }
    _messageCount++;
    if (_messageCount > _maxMessagesPerSecond) {
      print('[WebRTC] ⛔ Rate limit exceeded: $_messageCount messages in ${now - _messageCountResetAt}ms');
      return;
    }

    try {
      final msg = jsonDecode(data) as Map<String, dynamic>;
      final cmd = msg['command'] as String?;
      if (cmd == null) return;

      // V6-05 修复：指令安全过滤
      // 1. 高危指令严禁通过 DataChannel（必须走 HTTP + Token + 白名单）
      if (_blockedCommands.contains(cmd)) {
        print('[WebRTC] ⛔ Blocked dangerous command via DataChannel: $cmd');
        return;
      }
      // 2. 非白名单指令也拒绝
      if (!_allowedCommands.contains(cmd)) {
        print('[WebRTC] ⛔ Unknown command rejected: $cmd');
        return;
      }

      callbacks.onCommandReceived?.call(_currentRoomId ?? '', cmd);
    } catch (e) {
      print('[WebRTC] DataChannel message error');
    }
  }

  // ── 发送控制指令 ────────────────────────────────

  /// 通过 DataChannel 发送控制指令
  /// V7-10 修复：出站指令也需通过白名单验证（与入站一致）
  void sendCommand(String command) {
    if (_dataChannel == null) {
      print('[WebRTC] DataChannel is null, cannot send: $command');
      return;
    }
    // V7-10：出站指令安全校验（防止应用层代码绕过安全策略发送高危指令）
    if (_blockedCommands.contains(command)) {
      print('[WebRTC] ⛔ Outbound blocked command rejected: $command');
      return;
    }
    if (!_allowedCommands.contains(command)) {
      print('[WebRTC] ⛔ Outbound unknown command rejected: $command');
      return;
    }
    // flutter_webrtc 0.12.x: send() 直接接受 String
    final raw = jsonEncode({
      'command': command,
      'ts': DateTime.now().toIso8601String(),
    });
    // flutter_webrtc 0.12.x: RTCDataChannelMessage 用位置参数
    _dataChannel!.send(RTCDataChannelMessage(raw));
    print('[WebRTC] Sent: $command');
  }

  // ── 断开 ────────────────────────────────────────

  Future<void> disconnect() async {
    _signalingClient?.leaveRoom(_currentRoomId ?? '');
    _signalingClient?.disconnect();
    _dataChannel?.close();
    await _peerConnection?.close();
    _peerConnection = null;
    _dataChannel = null;
    _currentRoomId = null;
    _setState(WebRtcState.idle);
  }
}
