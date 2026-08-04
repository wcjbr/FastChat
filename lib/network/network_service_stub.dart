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
    this.roomId,
    this.senderSignature,
    this.senderBirthday,
    this.senderAvatarData,
    this.fileName,
    this.fileSize,
    this.fileData,
  });
  final String sender, text;
  final bool system;
  final String? roomId;
  final String? senderSignature;
  final String? senderBirthday;
  final String? senderAvatarData;
  final String? fileName;
  final int? fileSize;
  final String? fileData;

  bool get hasFile => fileName != null && fileData != null;
}

class FileTransferStatus {
  const FileTransferStatus({
    required this.transferId,
    required this.fileName,
    required this.sender,
    required this.totalBytes,
    required this.transferredBytes,
    required this.incoming,
    required this.phase,
  });

  final String transferId;
  final String fileName;
  final String sender;
  final int totalBytes;
  final int transferredBytes;
  final bool incoming;
  final String phase;

  double get progress => totalBytes <= 0 ? 0 : transferredBytes / totalBytes;

  bool get done => phase == 'done';
  bool get failed => phase == 'failed';
}

class ChatNetworkService {
  final rooms = const Stream<List<DiscoveredRoom>>.empty();
  final hostedRooms = const Stream<List<DiscoveredRoom>>.empty();
  final joinedRooms = const Stream<List<DiscoveredRoom>>.empty();
  final messages = const Stream<ChatMessage>.empty();
  final transfers = const Stream<FileTransferStatus>.empty();
  String get roomId => '';
  int get port => 0;
  void startDiscovery() {}
  Future<DiscoveredRoom> hostRoom({
    required String name,
    required bool relay,
  }) async {
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

  void updateProfile({
    required String signature,
    required String birthday,
    required String avatarData,
  }) {}

  Future<void> sendFile({
    required String sender,
    required String fileName,
    required int fileSize,
    required String base64Data,
  }) async {
    throw UnsupportedError('网页端不支持 WebSocket P2P 模式。');
  }

  Future<void> activateRoom(String roomId) async {}

  Future<void> closeRoom(String roomId) async {}

  Future<void> leaveRoom() async {}
  void dispose() {}
}
