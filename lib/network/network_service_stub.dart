import 'dart:async';

class DiscoveredRoom {
  const DiscoveredRoom({
    required this.id,
    required this.name,
    required this.host,
    required this.address,
    required this.port,
    required this.peers,
    required this.relay,
  });
  final String id, name, host, address;
  final int port, peers;
  final bool relay;
}

class ChatMessage {
  const ChatMessage({
    required this.sender,
    required this.text,
    this.system = false,
  });
  final String sender, text;
  final bool system;
}

class ChatNetworkService {
  final rooms = const Stream<List<DiscoveredRoom>>.empty();
  final messages = const Stream<ChatMessage>.empty();
  String get roomId => '';
  int get port => 0;
  void startDiscovery() {}
  Future<void> hostRoom({required String name, required bool relay}) async {
    throw UnsupportedError('网页端不支持创建和发现局域网房间，请运行原生客户端。');
  }

  Future<void> joinRoom(
    DiscoveredRoom room, {
    required String displayName,
    required bool relay,
  }) async {
    throw UnsupportedError('网页端不支持加入局域网房间，请运行原生客户端。');
  }

  Future<void> send(String text, {required String sender}) async {
    throw UnsupportedError('网页端不支持 WebSocket P2P 模式。');
  }

  Future<void> leaveRoom() async {}
  void dispose() {}
}
