/**
 * Remote PC — WebRTC 信令服务器
 * 
 * 协议（WebSocket JSON 消息）：
 *   → create_room { roomId }
 *   → join_room   { roomId }
 *   → leave_room  { roomId }
 *   → list_rooms  {}
 *   → offer       { roomId, sdp }
 *   → answer      { roomId, sdp }
 *   → ice_candidate{ roomId, candidate }
 *
 *   ← offer       { roomId, sdp }  (转发给 Guest)
 *   ← answer      { roomId, sdp }  (转发给 Host)
 *   ← ice_candidate { roomId, candidate } (互相转发)
 *   ← room_list   { rooms: [...] }
 *   ← error       { message }
 */

const WebSocket = require('ws');
const http = require('http');
const { v4: uuidv4 } = require('uuid');

const PORT = process.env.PORT || 3000;
const HEARTBEAT_INTERVAL = 30000; // 30s
const ROOM_TIMEOUT = 5 * 60 * 1000; // 5 分钟无活动自动清理

// ── 房间数据模型 ──────────────────────────────
// rooms: Map<roomId, { host, guests[], createdAt, lastActive }>
const rooms = new Map();

// ws → meta 映射（每个连接携带的元信息）
const wsMeta = new WeakMap();

// ── HTTP 健康检查 ────────────────────────────
const server = http.createServer((req, res) => {
  if (req.url === '/health') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({
      status: 'ok',
      rooms: rooms.size,
      connections: wss.clients.size,
      uptime: process.uptime(),
    }));
    return;
  }
  if (req.url === '/') {
    res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
    res.end(`
      <h2>Remote PC 信令服务器</h2>
      <p>状态：<b>运行中</b></p>
      <p>房间数：${rooms.size}</p>
      <p>连接数：${wss.clients.size}</p>
      <p>健康检查：<code>/health</code></p>
    `);
    return;
  }
  res.writeHead(404);
  res.end('Not Found');
});

// ── WebSocket 服务器 ─────────────────────────
const wss = new WebSocket.Server({ server });

wss.on('connection', (ws) => {
  const clientId = uuidv4();
  wsMeta.set(ws, { clientId, roomId: null });

  console.log(`[Connect] Client ${clientId} connected (total: ${wss.clients.size})`);

  // 心跳 Pong
  ws.isAlive = true;
  ws.on('pong', () => { ws.isAlive = true; });

  ws.on('message', (raw) => {
    let msg;
    try {
      msg = JSON.parse(raw);
    } catch {
      ws.send(JSON.stringify({ type: 'error', message: 'Invalid JSON' }));
      return;
    }

    const type = msg.type;
    const roomId = msg.roomId;
    const meta = wsMeta.get(ws);

    try {
      switch (type) {
        case 'create_room':  handleCreateRoom(ws, meta, roomId); break;
        case 'join_room':    handleJoinRoom(ws, meta, roomId); break;
        case 'leave_room':  handleLeaveRoom(ws, meta, roomId); break;
        case 'list_rooms':  handleListRooms(ws); break;
        case 'offer':        handleOffer(ws, meta, roomId, msg.sdp); break;
        case 'answer':       handleAnswer(ws, meta, roomId, msg.sdp); break;
        case 'ice_candidate': handleIceCandidate(ws, meta, roomId, msg.candidate); break;
        default:
          ws.send(JSON.stringify({ type: 'error', message: `Unknown type: ${type}` }));
      }
    } catch (err) {
      console.error(`[Error] ${type}:`, err.message);
      ws.send(JSON.stringify({ type: 'error', message: err.message }));
    }
  });

  ws.on('close', () => {
    const meta = wsMeta.get(ws);
    if (meta?.roomId) {
      _leaveRoom(ws, meta.roomId);
    }
    console.log(`[Disconnect] Client ${meta?.clientId} disconnected (total: ${wss.clients.size})`);
  });
});

// ── 心跳检测 ──────────────────────────────────
setInterval(() => {
  wss.clients.forEach((ws) => {
    if (ws.isAlive === false) {
      console.log(`[Heartbeat] Client timeout, terminating`);
      return ws.terminate();
    }
    ws.isAlive = false;
    ws.ping();
  });
}, HEARTBEAT_INTERVAL);

// ── 房间超时清理 ──────────────────────────────
setInterval(() => {
  const now = Date.now();
  for (const [roomId, room] of rooms) {
    if (now - room.lastActive > ROOM_TIMEOUT) {
      console.log(`[Cleanup] Room ${roomId} timed out`);
      // 通知房间内所有人
      broadcastToRoom(roomId, { type: 'room_closed', reason: 'timeout' });
      rooms.delete(roomId);
    }
  }
}, 60000);

// ── 消息处理函数 ──────────────────────────────

function handleCreateRoom(ws, meta, roomId) {
  if (!roomId || typeof roomId !== 'string') {
    throw new Error('roomId required');
  }
  if (rooms.has(roomId)) {
    throw new Error(`Room ${roomId} already exists`);
  }
  rooms.set(roomId, {
    host: ws,
    guests: [],
    createdAt: Date.now(),
    lastActive: Date.now(),
  });
  meta.roomId = roomId;
  console.log(`[Room] Created: ${roomId}`);
  ws.send(JSON.stringify({ type: 'room_created', roomId }));
}

function handleJoinRoom(ws, meta, roomId) {
  if (!rooms.has(roomId)) {
    throw new Error(`Room ${roomId} not found`);
  }
  const room = rooms.get(roomId);
  room.guests.push(ws);
  meta.roomId = roomId;
  room.lastActive = Date.now();
  console.log(`[Room] Joined: ${roomId} (guests: ${room.guests.length})`);
  ws.send(JSON.stringify({ type: 'room_joined', roomId }));

  // 通知 Host 有新 Guest 加入（触发 Offer）
  if (room.host && room.host.readyState === WebSocket.OPEN) {
    room.host.send(JSON.stringify({ type: 'guest_joined', roomId }));
  }
}

function handleLeaveRoom(ws, meta, roomId) {
  _leaveRoom(ws, roomId ?? meta.roomId);
}

function _leaveRoom(ws, roomId) {
  if (!roomId || !rooms.has(roomId)) return;
  const room = rooms.get(roomId);
  const meta = wsMeta.get(ws);

  if (room.host === ws) {
    // Host 离开，关闭整个房间
    broadcastToRoom(roomId, { type: 'room_closed', reason: 'host_left' });
    rooms.delete(roomId);
    console.log(`[Room] Closed (host left): ${roomId}`);
  } else {
    room.guests = room.guests.filter((g) => g !== ws);
    room.lastActive = Date.now();
    console.log(`[Room] Guest left: ${roomId} (remaining: ${room.guests.length})`);
  }
  if (meta) meta.roomId = null;
}

function handleListRooms(ws) {
  const list = [];
  for (const [roomId, room] of rooms) {
    list.push({
      roomId,
      guestCount: room.guests.length,
      createdAt: room.createdAt,
    });
  }
  ws.send(JSON.stringify({ type: 'room_list', rooms: list }));
}

function handleOffer(ws, meta, roomId, sdp) {
  const room = rooms.get(roomId);
  if (!room) throw new Error(`Room ${roomId} not found`);
  room.lastActive = Date.now();
  // 转发 Offer 给 Guest（第一个 Guest）
  const guest = room.guests[0];
  if (guest && guest.readyState === WebSocket.OPEN) {
    guest.send(JSON.stringify({ type: 'offer', roomId, sdp }));
    console.log(`[Signal] Offer → Guest (room: ${roomId})`);
  } else {
    throw new Error('No guest in room to receive offer');
  }
}

function handleAnswer(ws, meta, roomId, sdp) {
  const room = rooms.get(roomId);
  if (!room) throw new Error(`Room ${roomId} not found`);
  room.lastActive = Date.now();
  // 转发 Answer 给 Host
  if (room.host && room.host.readyState === WebSocket.OPEN) {
    room.host.send(JSON.stringify({ type: 'answer', roomId, sdp }));
    console.log(`[Signal] Answer → Host (room: ${roomId})`);
  }
}

function handleIceCandidate(ws, meta, roomId, candidate) {
  const room = rooms.get(roomId);
  if (!room) return;
  room.lastActive = Date.now();
  // 转发 ICE candidate 给对端
  const target = room.host === ws
    ? room.guests[0]
    : room.host;
  if (target && target.readyState === WebSocket.OPEN) {
    target.send(JSON.stringify({ type: 'ice_candidate', roomId, candidate }));
  }
}

// ── 工具函数 ──────────────────────────────────

function broadcastToRoom(roomId, message) {
  const room = rooms.get(roomId);
  if (!room) return;
  const raw = JSON.stringify(message);
  if (room.host?.readyState === WebSocket.OPEN) room.host.send(raw);
  room.guests.forEach((g) => {
    if (g.readyState === WebSocket.OPEN) g.send(raw);
  });
}

// ── 启动 ──────────────────────────────────────
server.listen(PORT, () => {
  console.log(`
  ╔══════════════════════════════════════╗
  ║   Remote PC 信令服务器                  ║
  ║   运行在 :${PORT}                            ║
  ║   健康检查: http://localhost:${PORT}/health ║
  ╚══════════════════════════════════════╝
  `);
});
