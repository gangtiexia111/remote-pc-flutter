/// 设备模型 — 对应原 Java 版 Device.java
class Device {
  final String id;
  String name;
  String ip;
  int port;
  bool isOnline;
  int failCount;
  int lastSeen;

  Device({
    required this.id,
    required this.name,
    required this.ip,
    required this.port,
    this.isOnline = false,
    this.failCount = 0,
    int? lastSeen,
  }) : lastSeen = lastSeen ?? DateTime.now().millisecondsSinceEpoch;

  Map<String, dynamic> toMap() => {
        'id': id,
        'name': name,
        'ip': ip,
        'port': port,
        'isOnline': isOnline,
        'failCount': failCount,
        'lastSeen': lastSeen,
      };

  factory Device.fromMap(Map<String, dynamic> m) => Device(
        id: m['id'] as String,
        name: m['name'] as String,
        ip: m['ip'] as String,
        port: m['port'] as int,
        isOnline: m['isOnline'] as bool? ?? false,
        failCount: m['failCount'] as int? ?? 0,
        lastSeen: m['lastSeen'] as int?,
      );

  void markAlive() {
    isOnline = true;
    failCount = 0;
    lastSeen = DateTime.now().millisecondsSinceEpoch;
  }

  void markFailed() {
    failCount++;
    if (failCount >= 3) isOnline = false;
    lastSeen = DateTime.now().millisecondsSinceEpoch;
  }

  String get statusLabel => isOnline ? '在线' : '离线';
}
