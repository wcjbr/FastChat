import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'network_service_stub.dart';

class ChatNetworkService {
  static const _discoveryPort = 45454;
  static const int _fileChunkSize = 48 * 1024;

  final _roomController = StreamController<List<DiscoveredRoom>>.broadcast();
  final _hostedRoomController =
      StreamController<List<DiscoveredRoom>>.broadcast();
  final _joinedRoomController =
      StreamController<List<DiscoveredRoom>>.broadcast();
  final _messageController = StreamController<ChatMessage>.broadcast();
  final _transferController = StreamController<FileTransferStatus>.broadcast();
  final _discovered = <String, DiscoveredRoom>{};
  final _seenMessages = <String>{};
  final _incomingFiles = <String, _IncomingFileTransfer>{};
  final _rooms = <String, _RoomState>{};

  RawDatagramSocket? _udp;
  StreamSubscription<RawSocketEvent>? _udpSubscription;
  Timer? _announceTimer;
  String _displayName = '访客';
  String _signature = '';
  String _birthday = '';
  String _avatarData = '';
  String _acgoInfo = '';
  String? _activeRoomId;

  Stream<List<DiscoveredRoom>> get rooms => _roomController.stream;
  Stream<List<DiscoveredRoom>> get hostedRooms => _hostedRoomController.stream;
  Stream<List<DiscoveredRoom>> get joinedRooms => _joinedRoomController.stream;
  Stream<ChatMessage> get messages => _messageController.stream;
  Stream<FileTransferStatus> get transfers => _transferController.stream;
  String get roomId => _activeRoomId ?? '';
  int get port => _rooms[_activeRoomId]?.port ?? 0;
  DiscoveredRoom? get activeRoom => _rooms[_activeRoomId]?.room;

  Future<void> startDiscovery() async {
    _udp ??= await RawDatagramSocket.bind(
      InternetAddress.anyIPv4,
      _discoveryPort,
      reuseAddress: true,
      reusePort: true,
    );
    _udp!.broadcastEnabled = true;
    _udpSubscription ??= _udp!.listen((event) {
      if (event != RawSocketEvent.read) return;
      final packet = _udp!.receive();
      if (packet == null) return;
      try {
        final json =
            jsonDecode(utf8.decode(packet.data)) as Map<String, dynamic>;
        final id = json['id']?.toString();
        if (json['type'] != 'fast-chat-room' ||
            id == null ||
            _rooms.containsKey(id)) {
          return;
        }
        final room = DiscoveredRoom(
          id: id,
          name: json['name'] ?? '房间',
          host: json['host'] ?? '未知',
          address: packet.address.address,
          port: json['wsPort'] ?? json['port'],
          peers: json['peers'] ?? 1,
          relay: json['relay'] ?? true,
        );
        _discovered[room.id] = room;
        _emitDiscoveredRooms();
      } catch (_) {}
    });
  }

  Future<DiscoveredRoom> hostRoom({
    required String name,
    required bool relay,
  }) async {
    await startDiscovery();
    final roomId =
        '${DateTime.now().millisecondsSinceEpoch}-${Random().nextInt(9999)}';
    final server = await _bindServer(roomId);
    final room = DiscoveredRoom(
      id: roomId,
      name: name,
      host: '本机房主',
      address: '127.0.0.1',
      port: server.port,
      peers: 1,
      relay: relay,
    );
    _rooms[roomId] = _RoomState(
      room: room,
      server: server,
      relay: relay,
      relayNode: false,
    );
    _activeRoomId = roomId;
    _emitHostedRooms();
    _ensureAnnouncing();
    return room;
  }

  Future<void> joinRoom(
    DiscoveredRoom room, {
    required String displayName,
    required bool relay,
  }) async {
    await startDiscovery();
    _displayName = displayName.isEmpty ? '访客' : displayName;
    if (_rooms.containsKey(room.id)) {
      await _closeRoom(room.id);
    }
    final upstream = await WebSocket.connect(
      'ws://${room.address}:${room.port}',
    );
    upstream.pingInterval = const Duration(seconds: 20);
    final state = _RoomState(
      room: room,
      upstream: upstream,
      relay: relay,
      relayNode: relay,
    );
    _rooms[room.id] = state;
    _activeRoomId = room.id;
    upstream.listen(
      (data) => _handleData(room.id, upstream, data.toString()),
      onDone: () => _onUpstreamClosed(room.id),
      onError: (_) => _onUpstreamClosed(room.id),
    );
    if (relay) {
      final server = await _bindServer(room.id);
      state.server = server;
      state.room = DiscoveredRoom(
        id: room.id,
        name: room.name,
        host: '中继节点',
        address: room.address,
        port: server.port,
        peers: state.peerCount,
        relay: true,
      );
      _emitHostedRooms();
      _ensureAnnouncing();
    }
    _emitJoinedRooms();
    _emitDiscoveredRooms();
  }

  Future<void> send(String text, {required String sender}) async {
    final roomId = _activeRoomId;
    final state = roomId == null ? null : _rooms[roomId];
    if (state == null) return;

    final packet = {
      'type': 'message',
      'id':
          '${DateTime.now().microsecondsSinceEpoch}-${Random().nextInt(999999)}',
      'sender': sender.isEmpty ? _displayName : sender,
      'senderSignature': _signature,
      'senderBirthday': _birthday,
      'senderAvatarData': _avatarData,
      'senderAcgoInfo': _acgoInfo,
      'text': text,
      'time': DateTime.now().toIso8601String(),
    };
    final encoded = '${jsonEncode(packet)}\n';
    _seenMessages.add(packet['id'] as String);
    _messageController.add(
      ChatMessage(
        sender: packet['sender'] as String,
        text: text,
        roomId: roomId,
        senderSignature: _signature,
        senderBirthday: _birthday,
        senderAvatarData: _avatarData,
        senderAcgoInfo: _acgoInfo,
      ),
    );
    await _sendPacket(state, encoded);
  }

  Future<void> sendFile({
    required String sender,
    required String fileName,
    required int fileSize,
    required String base64Data,
  }) async {
    final roomId = _activeRoomId;
    final state = roomId == null ? null : _rooms[roomId];
    if (state == null) return;

    final bytes = base64Decode(base64Data);
    final transferId =
        '${DateTime.now().microsecondsSinceEpoch}-${Random().nextInt(999999)}';
    final totalChunks = (bytes.length / _fileChunkSize).ceil();
    final displayName = sender.isEmpty ? _displayName : sender;
    _transferController.add(
      FileTransferStatus(
        transferId: transferId,
        fileName: fileName,
        sender: displayName,
        totalBytes: fileSize,
        transferredBytes: 0,
        incoming: false,
        phase: 'sending',
      ),
    );
    _messageController.add(
      ChatMessage(
        sender: displayName,
        text: '发送了文件：$fileName',
        roomId: roomId,
        senderSignature: _signature,
        senderBirthday: _birthday,
        senderAvatarData: _avatarData,
        senderAcgoInfo: _acgoInfo,
        fileName: fileName,
        fileSize: fileSize,
        fileData: base64Data,
      ),
    );

    await _sendPacket(
      state,
      '${jsonEncode({'type': 'file-start', 'id': '$transferId-start', 'transferId': transferId, 'sender': displayName, 'senderSignature': _signature, 'senderBirthday': _birthday, 'senderAvatarData': _avatarData, 'senderAcgoInfo': _acgoInfo, 'text': '发送了文件：$fileName', 'fileName': fileName, 'fileSize': fileSize, 'chunkSize': _fileChunkSize, 'totalChunks': totalChunks, 'time': DateTime.now().toIso8601String()})}\n',
    );

    for (var index = 0; index < totalChunks; index++) {
      final start = index * _fileChunkSize;
      final end = min(start + _fileChunkSize, bytes.length);
      final chunk = bytes.sublist(start, end);
      await _sendPacket(
        state,
        '${jsonEncode({'type': 'file-chunk', 'id': '$transferId-chunk-$index', 'transferId': transferId, 'sender': displayName, 'fileName': fileName, 'fileSize': fileSize, 'totalChunks': totalChunks, 'index': index, 'data': base64Encode(chunk), 'time': DateTime.now().toIso8601String()})}\n',
      );
      if (index % 8 == 7) {
        await Future<void>.delayed(Duration.zero);
      }
      _transferController.add(
        FileTransferStatus(
          transferId: transferId,
          fileName: fileName,
          sender: displayName,
          totalBytes: fileSize,
          transferredBytes: min(end, fileSize),
          incoming: false,
          phase: 'sending',
        ),
      );
    }

    await _sendPacket(
      state,
      '${jsonEncode({'type': 'file-end', 'id': '$transferId-end', 'transferId': transferId, 'sender': displayName, 'senderSignature': _signature, 'senderBirthday': _birthday, 'senderAvatarData': _avatarData, 'senderAcgoInfo': _acgoInfo, 'fileName': fileName, 'fileSize': fileSize, 'totalChunks': totalChunks, 'time': DateTime.now().toIso8601String()})}\n',
    );
    _transferController.add(
      FileTransferStatus(
        transferId: transferId,
        fileName: fileName,
        sender: displayName,
        totalBytes: fileSize,
        transferredBytes: fileSize,
        incoming: false,
        phase: 'done',
      ),
    );
  }

  Future<void> activateRoom(String roomId) async {
    if (_rooms.containsKey(roomId)) {
      _activeRoomId = roomId;
    }
  }

  void updateProfile({
    required String signature,
    required String birthday,
    required String avatarData,
    required String acgoInfo,
  }) {
    _signature = signature;
    _birthday = birthday;
    _avatarData = avatarData;
    _acgoInfo = acgoInfo;
  }

  Future<void> closeRoom(String roomId) async {
    await _closeRoom(roomId);
  }

  Future<void> leaveRoom() async {
    final roomId = _activeRoomId;
    if (roomId == null) return;
    await _closeRoom(roomId);
  }

  Future<void> dispose() async {
    final roomIds = _rooms.keys.toList();
    for (final roomId in roomIds) {
      await _closeRoom(roomId);
    }
    _announceTimer?.cancel();
    await _udpSubscription?.cancel();
    _udp?.close();
    await _roomController.close();
    await _hostedRoomController.close();
    await _joinedRoomController.close();
    await _messageController.close();
    await _transferController.close();
  }

  Future<HttpServer> _bindServer(String roomId) async {
    final server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    server.listen((request) async {
      if (!WebSocketTransformer.isUpgradeRequest(request)) {
        request.response.statusCode = HttpStatus.badRequest;
        await request.response.close();
        return;
      }
      final webSocket = await WebSocketTransformer.upgrade(request);
      _attachSocket(roomId, webSocket);
    });
    return server;
  }

  void _attachSocket(String roomId, WebSocket client) {
    client.pingInterval = const Duration(seconds: 20);
    final state = _rooms[roomId];
    if (state == null) return;
    state.clients.add(client);
    _emitHostedRooms();
    client.listen(
      (data) => _handleData(roomId, client, data.toString()),
      onDone: () => _removeClient(roomId, client),
      onError: (_) => _removeClient(roomId, client),
    );
  }

  void _handleData(String roomId, WebSocket source, String data) {
    for (final line in data.split('\n')) {
      if (line.trim().isEmpty) continue;
      try {
        final packet = jsonDecode(line) as Map<String, dynamic>;
        final id = packet['id']?.toString();
        if (id == null || _seenMessages.contains(id)) {
          continue;
        }
        _seenMessages.add(id);
        final type = packet['type'];
        if (type == 'message') {
          _messageController.add(
            ChatMessage(
              sender: packet['sender'] ?? '访客',
              text: packet['text'] ?? '',
              roomId: roomId,
              senderSignature: packet['senderSignature']?.toString(),
              senderBirthday: packet['senderBirthday']?.toString(),
              senderAvatarData: packet['senderAvatarData']?.toString(),
              senderAcgoInfo: packet['senderAcgoInfo']?.toString(),
            ),
          );
        } else if (type == 'file-start') {
          final transferId = packet['transferId']?.toString();
          if (transferId == null) continue;
          _incomingFiles[transferId] = _IncomingFileTransfer(
            sender: packet['sender'] ?? '访客',
            senderSignature: packet['senderSignature']?.toString() ?? '',
            senderBirthday: packet['senderBirthday']?.toString() ?? '',
            senderAvatarData: packet['senderAvatarData']?.toString() ?? '',
            senderAcgoInfo: packet['senderAcgoInfo']?.toString() ?? '',
            fileName: packet['fileName'] ?? '文件',
            fileSize: packet['fileSize'] ?? 0,
            totalChunks: packet['totalChunks'] ?? 0,
          );
          _transferController.add(
            FileTransferStatus(
              transferId: transferId,
              fileName: packet['fileName'] ?? '文件',
              sender: packet['sender'] ?? '访客',
              totalBytes: packet['fileSize'] ?? 0,
              transferredBytes: 0,
              incoming: true,
              phase: 'receiving',
            ),
          );
        } else if (type == 'file-chunk') {
          final transferId = packet['transferId']?.toString();
          final chunkData = packet['data']?.toString();
          if (transferId == null || chunkData == null) continue;
          final transfer = _incomingFiles.putIfAbsent(
            transferId,
            () => _IncomingFileTransfer(
              sender: packet['sender'] ?? '访客',
              senderSignature: packet['senderSignature']?.toString() ?? '',
              senderBirthday: packet['senderBirthday']?.toString() ?? '',
              senderAvatarData: packet['senderAvatarData']?.toString() ?? '',
              senderAcgoInfo: packet['senderAcgoInfo']?.toString() ?? '',
              fileName: packet['fileName'] ?? '文件',
              fileSize: packet['fileSize'] ?? 0,
              totalChunks: packet['totalChunks'] ?? 0,
            ),
          );
          final chunkBytes = base64Decode(chunkData);
          transfer.addChunk(chunkBytes);
          _transferController.add(
            FileTransferStatus(
              transferId: transferId,
              fileName: transfer.fileName,
              sender: transfer.sender,
              totalBytes: transfer.fileSize,
              transferredBytes: transfer.receivedBytes,
              incoming: true,
              phase: 'receiving',
            ),
          );
        } else if (type == 'file-end') {
          final transferId = packet['transferId']?.toString();
          if (transferId == null) continue;
          final transfer = _incomingFiles.remove(transferId);
          if (transfer == null) continue;
          final bytes = transfer.bytes.toBytes();
          _messageController.add(
            ChatMessage(
              sender: transfer.sender,
              text: '发送了文件：${transfer.fileName}',
              roomId: roomId,
              senderSignature: transfer.senderSignature,
              senderBirthday: transfer.senderBirthday,
              senderAvatarData: transfer.senderAvatarData,
              senderAcgoInfo: transfer.senderAcgoInfo,
              fileName: transfer.fileName,
              fileSize: transfer.fileSize,
              fileData: base64Encode(bytes),
            ),
          );
          _transferController.add(
            FileTransferStatus(
              transferId: transferId,
              fileName: transfer.fileName,
              sender: transfer.sender,
              totalBytes: transfer.fileSize,
              transferredBytes: transfer.fileSize,
              incoming: true,
              phase: 'done',
            ),
          );
        }
        if (type == 'message' ||
            type == 'file-start' ||
            type == 'file-chunk' ||
            type == 'file-end') {
          final state = _rooms[roomId];
          if (state != null && state.relay) {
            final encoded = '${jsonEncode(packet)}\n';
            if (state.upstream != null && source != state.upstream) {
              _safeAdd(state.upstream, encoded);
            }
            for (final client in List<WebSocket>.from(state.clients)) {
              if (client != source) {
                _safeAdd(client, encoded);
              }
            }
          }
        }
      } catch (_) {}
    }
  }

  Future<void> _sendPacket(_RoomState state, String encoded) async {
    _seenMessages.add(_extractId(encoded));
    if (state.upstream != null) {
      _safeAdd(state.upstream, encoded);
    }
    for (final client in List<WebSocket>.from(state.clients)) {
      _safeAdd(client, encoded);
    }
  }

  String _extractId(String encoded) {
    try {
      final packet = jsonDecode(encoded.trim()) as Map<String, dynamic>;
      return packet['id']?.toString() ?? '';
    } catch (_) {
      return '';
    }
  }

  void _safeAdd(WebSocket? socket, String encoded) {
    if (!_isOpen(socket)) return;
    try {
      socket!.add(encoded);
    } catch (_) {
      if (socket == _rooms[_activeRoomId]?.upstream) {
        final target = socket;
        if (target != null) {
          unawaited(target.close());
        }
      }
    }
  }

  bool _isOpen(WebSocket? socket) => socket?.readyState == WebSocket.open;

  Future<void> _closeRoom(String roomId) async {
    final state = _rooms.remove(roomId);
    if (state == null) return;
    if (_activeRoomId == roomId) {
      _activeRoomId = null;
    }
    await state.close();
    _emitHostedRooms();
    _emitJoinedRooms();
    _emitDiscoveredRooms();
    _stopAnnouncingIfIdle();
  }

  void _removeClient(String roomId, WebSocket client) {
    final state = _rooms[roomId];
    if (state == null) return;
    state.clients.remove(client);
    _emitHostedRooms();
    _announce();
  }

  Future<void> _onUpstreamClosed(String roomId) async {
    final state = _rooms[roomId];
    if (state == null) return;
    state.upstream = null;
    if (state.relay) {
      state.relayNode = false;
    }
    if (state.server == null && state.clients.isEmpty) {
      await _closeRoom(roomId);
      return;
    }
    _emitHostedRooms();
    _emitJoinedRooms();
  }

  void _emitDiscoveredRooms() {
    _roomController.add(
      _discovered.values.where((room) => !_rooms.containsKey(room.id)).toList(),
    );
  }

  void _emitHostedRooms() {
    final hosted = _rooms.values
        .where((room) => room.server != null && !room.relayNode)
        .map((room) => room.room)
        .toList();
    _hostedRoomController.add(hosted);
  }

  void _emitJoinedRooms() {
    final joined = _rooms.values
        .where((room) => room.upstream != null)
        .map((room) => room.room)
        .toList();
    _joinedRoomController.add(joined);
  }

  void _announce() {
    if (_udp == null) return;
    for (final state in _rooms.values) {
      if (state.server == null) continue;
      final packet = utf8.encode(
        jsonEncode({
          'type': 'fast-chat-room',
          'id': state.room.id,
          'name': state.room.name,
          'host': state.relayNode ? '中继节点' : '本机房主',
          'wsPort': state.port,
          'port': state.port,
          'peers': state.peerCount,
          'relay': state.room.relay,
        }),
      );
      _udp!.send(packet, InternetAddress('255.255.255.255'), _discoveryPort);
    }
  }

  void _ensureAnnouncing() {
    _announceTimer ??= Timer.periodic(
      const Duration(seconds: 2),
      (_) => _announce(),
    );
    _announce();
  }

  void _stopAnnouncingIfIdle() {
    if (_rooms.values.any((room) => room.server != null)) return;
    _announceTimer?.cancel();
    _announceTimer = null;
  }
}

class _RoomState {
  _RoomState({
    required this.room,
    this.server,
    this.upstream,
    required this.relay,
    required this.relayNode,
  });

  DiscoveredRoom room;
  HttpServer? server;
  WebSocket? upstream;
  final List<WebSocket> clients = [];
  final bool relay;
  bool relayNode;

  int get port => room.port;
  int get peerCount => clients.length + (upstream == null ? 1 : 1);

  Future<void> close() async {
    try {
      await upstream?.close();
    } catch (_) {}
    upstream = null;
    for (final client in List<WebSocket>.from(clients)) {
      try {
        await client.close();
      } catch (_) {}
    }
    clients.clear();
    try {
      await server?.close();
    } catch (_) {}
    server = null;
  }
}

class _IncomingFileTransfer {
  _IncomingFileTransfer({
    required this.sender,
    required this.senderSignature,
    required this.senderBirthday,
    required this.senderAvatarData,
    required this.senderAcgoInfo,
    required this.fileName,
    required this.fileSize,
    required this.totalChunks,
  });

  final String sender;
  final String senderSignature;
  final String senderBirthday;
  final String senderAvatarData;
  final String senderAcgoInfo;
  final String fileName;
  final int fileSize;
  final int totalChunks;
  final BytesBuilder bytes = BytesBuilder(copy: false);
  int receivedBytes = 0;

  void addChunk(List<int> chunk) {
    bytes.add(chunk);
    receivedBytes += chunk.length;
  }
}
